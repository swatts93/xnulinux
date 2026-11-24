// SPDX-License-Identifier: GPL-2.0-only
/* Test client for fki.ko: unit checks at load, then host calls from a kthread, as xnu.ko makes them (inside fki_enter). */
#include <linux/module.h>
#include <linux/kthread.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/io.h>
#include "fki.h"

static int calls = 0;		module_param(calls, int, 0444);
static ulong len = 64;		module_param(len, ulong, 0444);
static ulong max = 1 << 20;	module_param(max, ulong, 0444);
static ulong nomap_pa = 0;	module_param(nomap_pa, ulong, 0444);	/* RAM marked no-map in the device tree */
static int expect = 0;		module_param(expect, int, 0444);	/* the return expected: 0 = len, else -errno */
static struct task_struct *th;
static struct fki_pac_keys k, saved;

static long call(const void *req, unsigned long n, void *rep, unsigned long m)
{
	unsigned long cookie;
	long r;

	fki_pac_swap(&k, &k);			/* read this CPU's keys (and load them back): the "foreign" keys are ours */
	cookie = fki_enter(&k, &saved);
	r = fki_hostcall(req, n, rep, m);
	fki_leave(cookie, &saved);
	return r;
}

static int body(void *unused)
{
	u8 *req = vmalloc(len + 1), *rep = vmalloc(max + 1);
	int i, bad = 0;

	for (i = 0; req && rep && i < calls; i++) {
		unsigned long j;
		long r;
		int ok = 1;

		for (j = 0; j < len; j++)
			req[j] = (u8)(i * 7 + j);
		memset(rep, 0, max);
		r = call(req, len, rep, max);
		if (r >= 0)
			for (j = 0; j < (unsigned long)r; j++)
				if (rep[j] != (u8)~req[j % (len ? len : 1)]) { ok = 0; break; }
		if (expect == 0 ? (r != (long)len || !ok) : r != expect)
			bad++;
		pr_info("HCTEST call %d ret=%ld content=%s\n", i, r, ok ? "ok" : "BAD");
	}
	pr_info("HCTEST done calls=%d bad=%d%s\n", calls, bad, req && rep ? "" : " (no memory)");
	vfree(req); vfree(rep);
	while (!kthread_should_stop())
		schedule_timeout_interruptible(HZ / 10);
	return 0;
}

static int __init hct_init(void)
{
	u64 *x = kmalloc(64, GFP_KERNEL);
	unsigned long long *l1; fki_u64 l1pa; int w;

	/* fki_phys_peek: RAM reads back; a non-RAM address (the virt machine's flash at 0) and a hole read ~0 */
	x[0] = 0x1122334455667788ULL;
	pr_info("HCTEST unit peek_ram=%s peek_flash=%s peek_hole=%s\n",
		fki_phys_peek(virt_to_phys(x)) == x[0] ? "ok" : "BAD",
		fki_phys_peek(0) == ~0ULL ? "ok" : "BAD",
		fki_phys_peek(0x7000000000ULL) == ~0ULL ? "ok" : "BAD");
	kfree(x);
	if (nomap_pa)
		pr_info("HCTEST unit pfn_valid(nomap)=%d peek_nomap=%s\n", pfn_valid(PHYS_PFN(nomap_pa)),
			fki_phys_peek(nomap_pa) == ~0ULL ? "ok" : "BAD");
	/* fki_window_l1 on a 4 KB / 4-level kernel: a top-level entry for the kernel's own linear map exists */
	w = fki_window_l1((unsigned long)&k, &l1, &l1pa);
	pr_info("HCTEST unit window_l1=%d (%s)\n", w, w == 0 ? "ok" : "BAD");
	th = kthread_run(body, NULL, "hctest");
	return PTR_ERR_OR_ZERO(th);
}

static void __exit hct_exit(void)
{
	if (!IS_ERR_OR_NULL(th))
		kthread_stop(th);
}
module_init(hct_init);
module_exit(hct_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("fki.ko test client: host calls as xnu.ko makes them");
