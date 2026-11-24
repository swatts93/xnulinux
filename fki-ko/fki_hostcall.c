// SPDX-License-Identifier: GPL-2.0-only
/*
 * Host calls: a message channel from the foreign kernel to a Linux user process (a host service such as the DRM bridge,
 * gpu/xnu-drm/xnudrmd). The foreign kernel calls fki_hostcall() with a request; the service reads it from
 * /dev/xnu-hostcall, does the work with ordinary system calls and writes the reply back. fki only moves bytes: the
 * message format belongs to the two ends.
 *
 * One call at a time. The calling foreign CPU is blocked in the call and deaf to the other foreign CPUs' interrupts, so
 * a call with no service to answer it fails at once (-ENODEV), not after HC_TIMEOUT: the other CPUs would time out
 * waiting on that one (an XNU panic). The service also asks fki to translate its own mappings into physical addresses
 * (XNU_HOSTCALL_XLATE), so the foreign kernel can map the same pages.
 */
#include "fki.h"
#include "fki_internal.h"
#include <linux/capability.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>
#include <linux/wait.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0)
#error "fki.ko needs Linux 6.12 or later (follow_pfnmap_start); on Ubuntu 24.04 install the HWE kernel (linux-generic-hwe-24.04)"
#endif

#define HC_MAX (8UL << 20)		/* largest request or reply */
#define HC_TIMEOUT (120 * HZ)		/* a service that does not answer: the call fails */

struct xnu_hostcall_xlate {
	__u64 va, len;			/* a range of the caller's address space, 4 KiB aligned */
	__u64 out;			/* user pointer: one __u64 physical address per 4 KiB page */
	__u64 max;			/* entries at out */
};
#define XNU_HOSTCALL_XLATE _IOWR('X', 1, struct xnu_hostcall_xlate)

static DECLARE_WAIT_QUEUE_HEAD(hc_req_wait);
static DECLARE_WAIT_QUEUE_HEAD(hc_done_wait);
static DEFINE_SPINLOCK(hc_lock);
static void *hc_buf;			/* request, then reply */
static unsigned long hc_len;
static u64 hc_seq;			/* the call in flight (0: none) */
static int hc_state;			/* 0 idle, 1 request waiting, 2 read by the service, 4 reply being copied in, 3 replied */
static long hc_result;
static int hc_open;			/* the service's opens of /dev/xnu-hostcall (0: no service, calls fail at once) */

struct hc_call { const void *req; unsigned long len; void *reply; unsigned long max; long result; };
static DEFINE_MUTEX(hc_mutex);		/* one call at a time through the single slot (several CPUs may call) */

static void hc_call_body(void *p)
{
	struct hc_call *c = p;
	static u64 seq;
	long r;

	local_irq_enable();
	preempt_enable();
	mutex_lock(&hc_mutex);
	if (!hc_buf)
		hc_buf = kvmalloc(HC_MAX, GFP_KERNEL);
	if (!hc_buf || c->len > HC_MAX) {
		r = hc_buf ? -EMSGSIZE : -ENOMEM;
		goto out;
	}
	preempt_disable(); local_irq_disable();
	memcpy(hc_buf, c->req, c->len);		/* the foreign kernel's memory: read with interrupts off */
	local_irq_enable(); preempt_enable();
	spin_lock(&hc_lock);
	if (!hc_open) {
		spin_unlock(&hc_lock);
		r = -ENODEV;
		goto out;
	}
	hc_len = c->len;
	hc_seq = ++seq;
	hc_state = 1;
	spin_unlock(&hc_lock);
	wake_up_interruptible(&hc_req_wait);
	/* until the reply, or the service closing its device with the call unanswered */
	wait_event_timeout(hc_done_wait, READ_ONCE(hc_state) == 3 || !READ_ONCE(hc_open), HC_TIMEOUT);
	/* a reply already being copied into hc_buf: let it finish, or the next call's request would be overwritten */
	wait_event(hc_done_wait, READ_ONCE(hc_state) != 4);
	spin_lock(&hc_lock);
	if (hc_state != 3) {
		r = hc_open ? -ETIMEDOUT : -ENODEV;
		hc_state = 0; hc_seq = 0;
		spin_unlock(&hc_lock);
		goto out;
	}
	spin_unlock(&hc_lock);
	r = hc_result;
	if (r >= 0) {
		unsigned long n = min_t(unsigned long, hc_len, c->max);
		preempt_disable(); local_irq_disable();
		memcpy(c->reply, hc_buf, n);
		local_irq_enable(); preempt_enable();
		r = hc_len > c->max ? -EMSGSIZE : (long)n;
	}
	spin_lock(&hc_lock);
	hc_state = 0; hc_seq = 0;
	spin_unlock(&hc_lock);
out:
	mutex_unlock(&hc_mutex);
	preempt_disable();
	local_irq_disable();
	c->result = r;
}

/*
 * From inside fki_enter(): send len bytes at req to the service and wait for its reply (at most max bytes into reply).
 * Returns the reply's length, -EMSGSIZE when it does not fit, -ETIMEDOUT when no service answered in time.
 */
long fki_hostcall(const void *req, unsigned long len, void *reply, unsigned long max)
{
	struct hc_call c = { req, len, reply, max, -EIO };

	fki_linux_runs_ext(hc_call_body, &c);
	return c.result;
}
EXPORT_SYMBOL(fki_hostcall);

/* The service: read() the next request, prefixed with its 8-byte sequence number. */
static ssize_t hc_read(struct file *f, char __user *buf, size_t n, loff_t *off)
{
	u64 seq;
	int err;

	unsigned long len;

	err = wait_event_interruptible(hc_req_wait, READ_ONCE(hc_state) == 1);
	if (err)
		return err;
	spin_lock(&hc_lock);
	if (hc_state != 1) {
		spin_unlock(&hc_lock);
		return -EAGAIN;
	}
	len = hc_len;			/* one snapshot: the size check and the copy use the same length */
	if (n < 8 + len) {		/* too small: the request stays waiting for a read that fits */
		spin_unlock(&hc_lock);
		return -EMSGSIZE;
	}
	hc_state = 2;
	seq = hc_seq;
	spin_unlock(&hc_lock);
	if (copy_to_user(buf, &seq, 8) || copy_to_user(buf + 8, hc_buf, len))
		return -EFAULT;
	return 8 + len;
}

/* The service: write() the reply, prefixed with the request's sequence number. */
static ssize_t hc_write(struct file *f, const char __user *buf, size_t n, loff_t *off)
{
	u64 seq;

	if (n < 8 || n - 8 > HC_MAX)
		return -EINVAL;
	if (copy_from_user(&seq, buf, 8))
		return -EFAULT;
	spin_lock(&hc_lock);
	if (hc_state != 2 || seq != hc_seq) {
		spin_unlock(&hc_lock);
		return -ESTALE;		/* the call timed out meanwhile, or another write answered it */
	}
	hc_state = 4;			/* ours: the caller waits for the copy, a second writer gets -ESTALE */
	spin_unlock(&hc_lock);
	if (copy_from_user(hc_buf, buf + 8, n - 8)) {
		spin_lock(&hc_lock);
		hc_state = 2;		/* not answered: the service may write again */
		spin_unlock(&hc_lock);
		wake_up(&hc_done_wait);
		return -EFAULT;
	}
	spin_lock(&hc_lock);
	hc_len = n - 8;
	hc_result = 0;
	hc_state = 3;
	spin_unlock(&hc_lock);
	wake_up(&hc_done_wait);
	return n;
}

static long hc_xlate_one(struct mm_struct *mm, unsigned long va, u64 *pa)
{
	struct vm_area_struct *vma = vma_lookup(mm, va);
	struct page *pg;

	if (!vma)
		return -EFAULT;
	/*
	 * Only a shared mapping of a device's buffer (the DRM render node's GEM objects) has a lifetime the foreign kernel's
	 * mapping can follow: private anonymous pages are not pinned here and can be migrated or reused under it.
	 */
	if (!(vma->vm_flags & (VM_IO | VM_PFNMAP | VM_MAYSHARE)) || !vma->vm_file)
		return -EINVAL;
	if (vma->vm_flags & (VM_IO | VM_PFNMAP)) {
		struct follow_pfnmap_args args = { .vma = vma, .address = va };
		int err = follow_pfnmap_start(&args);
		if (err)
			return err;
		*pa = (u64)args.pfn << PAGE_SHIFT;
		follow_pfnmap_end(&args);
		return 0;
	}
	if (get_user_pages_remote(mm, va, 1, FOLL_WRITE, &pg, NULL) != 1)
		return -EFAULT;
	*pa = page_to_phys(pg);
	put_page(pg);		/* the mapping's owner (a GEM object) keeps the page */
	return 0;
}

static long hc_xlate(struct xnu_hostcall_xlate __user *ua)
{
	struct xnu_hostcall_xlate a;
	struct mm_struct *mm = current->mm;
	unsigned long i, n;
	long err = 0;

	if (copy_from_user(&a, ua, sizeof(a)))
		return -EFAULT;
	if ((a.va | a.len) & (PAGE_SIZE - 1))
		return -EINVAL;
	n = a.len >> PAGE_SHIFT;
	if (n > a.max)
		return -E2BIG;
	/*
	 * In chunks: the results go to user memory with mmap_lock dropped (a fault on a.out takes it again), and a long
	 * range can be interrupted by a fatal signal.
	 */
	for (i = 0; i < n && !err; ) {
		u64 pa[64];
		unsigned long k, c = min_t(unsigned long, n - i, ARRAY_SIZE(pa));

		if (fatal_signal_pending(current))
			return -EINTR;
		mmap_read_lock(mm);
		for (k = 0; k < c && !err; k++)
			err = hc_xlate_one(mm, a.va + ((i + k) << PAGE_SHIFT), &pa[k]);
		mmap_read_unlock(mm);
		if (err)
			break;
		if (copy_to_user((u64 __user *)a.out + i, pa, c * sizeof(u64)))
			err = -EFAULT;
		i += c;
	}
	return err;
}

static long hc_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	if (cmd == XNU_HOSTCALL_XLATE)
		return hc_xlate((struct xnu_hostcall_xlate __user *)arg);
	return -ENOTTY;
}

static int hc_dev_open(struct inode *i, struct file *f)
{
	/* the service sees physical addresses (as /proc/pid/pagemap, which needs the same) and answers the foreign kernel */
	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;
	spin_lock(&hc_lock);
	hc_open++;
	spin_unlock(&hc_lock);
	return 0;
}

static int hc_dev_release(struct inode *i, struct file *f)
{
	spin_lock(&hc_lock);
	hc_open--;
	spin_unlock(&hc_lock);
	wake_up(&hc_done_wait);		/* a call waiting on this service fails now */
	return 0;
}

static const struct file_operations hc_fops = {
	.owner = THIS_MODULE,
	.open = hc_dev_open,
	.release = hc_dev_release,
	.read = hc_read,
	.write = hc_write,
	.unlocked_ioctl = hc_ioctl,
	.llseek = noop_llseek,
};

static struct miscdevice hc_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "xnu-hostcall",
	.fops = &hc_fops,
	.mode = 0600,
};

static bool hc_registered;

int fki_hostcall_init(void)
{
	int err = misc_register(&hc_dev);

	hc_registered = !err;
	return err;
}

void fki_hostcall_exit(void)
{
	if (hc_registered)
		misc_deregister(&hc_dev);
	hc_registered = false;
	kvfree(hc_buf);
	hc_buf = NULL;
}
