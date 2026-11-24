// SPDX-License-Identifier: GPL-2.0-only
/* Test service for /dev/xnu-hostcall. Replies with the request's bytes inverted. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <linux/capability.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

struct xnu_hostcall_xlate { uint64_t va, len, out, max; };
#define XNU_HOSTCALL_XLATE _IOWR('X', 1, struct xnu_hostcall_xlate)
#define BIG (9u << 20)
static int fails;
#define CHECK(c, ...) do { if (c) printf("SVC PASS " __VA_ARGS__); else { printf("SVC FAIL " __VA_ARGS__); fails++; } printf("\n"); fflush(stdout); } while (0)

static uint8_t *uffd_page; static int uffd; static int stall_ms;
static uint8_t uffd_src[4096] __attribute__((aligned(4096)));	/* what the stalled page gets once the stall ends */
static void *uffd_thread(void *unused)
{
	struct pollfd p = { uffd, POLLIN };
	struct uffd_msg m;
	(void)unused;
	poll(&p, 1, -1);
	if (read(uffd, &m, sizeof m) != sizeof m) return NULL;
	printf("SVC info: reply copy stalled in the kernel for %d ms\n", stall_ms); fflush(stdout);
	usleep(stall_ms * 1000);
	struct uffdio_copy c = { (uintptr_t)uffd_page, (uintptr_t)uffd_src, 4096, 0, 0 };
	ioctl(uffd, UFFDIO_COPY, &c);
	return NULL;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "echo";
	int n = argc > 2 ? atoi(argv[2]) : 1, arg = argc > 3 ? atoi(argv[3]) : 0;
	static uint8_t buf[BIG + 16];

	if (!strcmp(mode, "nocap")) {	/* without CAP_SYS_ADMIN (still root): the device must refuse */
		struct __user_cap_header_struct h = { _LINUX_CAPABILITY_VERSION_3, 0 };
		struct __user_cap_data_struct d[2];
		syscall(SYS_capget, &h, d);
		d[0].effective &= ~(1u << CAP_SYS_ADMIN); d[0].permitted &= ~(1u << CAP_SYS_ADMIN);
		if (syscall(SYS_capset, &h, d)) { perror("capset"); return 2; }
		int fd = open("/dev/xnu-hostcall", O_RDWR);
		CHECK(fd < 0 && errno == EPERM, "open without CAP_SYS_ADMIN refused (fd=%d errno=%d)", fd, errno);
		return fails != 0;
	}
	int fd = open("/dev/xnu-hostcall", O_RDWR);
	if (fd < 0) { perror("open /dev/xnu-hostcall"); return 2; }
	if (!strcmp(mode, "xlate")) {
		uint64_t pa[8] = {0};
		uint8_t *anon = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		anon[0] = anon[4096] = 1;
		struct xnu_hostcall_xlate x = { (uintptr_t)anon, 8192, (uintptr_t)pa, 8 };
		int r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		CHECK(r < 0 && errno == EINVAL, "private anonymous memory refused (r=%d errno=%d)", r, errno);
		int mfd = memfd_create("t", 0); if (ftruncate(mfd, 4 * 4096)) return 2;
		uint8_t *sh = mmap(NULL, 4 * 4096, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0);
		for (int i = 0; i < 4; i++) sh[i * 4096] = 1;
		x = (struct xnu_hostcall_xlate){ (uintptr_t)sh, 4 * 4096, (uintptr_t)pa, 8 };
		r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		CHECK(r == 0 && pa[0] && !(pa[0] & 4095) && pa[3] && pa[4] == 0, "shared file mapping translated (r=%d pa0=%#llx pa3=%#llx)", r, (unsigned long long)pa[0], (unsigned long long)pa[3]);
		x.va = (uintptr_t)sh + 1; r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		CHECK(r < 0 && errno == EINVAL, "misaligned range refused");
		x = (struct xnu_hostcall_xlate){ (uintptr_t)sh, 4 * 4096, (uintptr_t)pa, 3 }; r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		CHECK(r < 0 && errno == E2BIG, "too small an output refused");
		x = (struct xnu_hostcall_xlate){ (uintptr_t)sh, 4 * 4096, 16, 8 }; r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		CHECK(r < 0 && errno == EFAULT, "bad output pointer gives EFAULT");
		/* a large shared range: chunked copy-out (>64 entries) */
		size_t np = 1000; uint64_t *pb = calloc(np, 8);
		int mfd2 = memfd_create("t2", 0); if (ftruncate(mfd2, np * 4096)) return 2;
		uint8_t *sh2 = mmap(NULL, np * 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, mfd2, 0);
		x = (struct xnu_hostcall_xlate){ (uintptr_t)sh2, np * 4096, (uintptr_t)pb, np }; r = ioctl(fd, XNU_HOSTCALL_XLATE, &x);
		size_t zero = 0; for (size_t i = 0; i < np; i++) zero += !pb[i];
		CHECK(r == 0 && zero == 0, "1000-page shared range translated in chunks (r=%d unfilled=%zu)", r, zero);
		return fails != 0;
	}
	for (int i = 0; i < n; i++) {
		ssize_t r;
		if (!strcmp(mode, "small") ) {	/* a read too small for the request: refused, the request stays */
			r = read(fd, buf, 8);
			CHECK(r < 0 && errno == EMSGSIZE, "small read refused with EMSGSIZE (r=%zd errno=%d)", r, errno);
		}
		r = read(fd, buf, sizeof buf);
		if (r < 8) { printf("SVC FAIL read %zd errno %d\n", r, errno); fails++; break; }
		size_t len = r - 8, rl = len;
		for (size_t j = 0; j < len; j++) buf[8 + j] = ~buf[8 + j];
		if (!strcmp(mode, "big")) { rl = arg; for (size_t j = len; j < rl; j++) buf[8 + j] = ~buf[8 + (len ? j % len : 0)]; }
		if (!strcmp(mode, "late")) usleep(arg * 1000);
		if (!strcmp(mode, "uffd") && i == 0) {	/* the reply's bytes come from a page whose fault stalls arg ms */
			uffd = syscall(SYS_userfaultfd, O_CLOEXEC);
			struct uffdio_api api = { UFFD_API, 0, 0 }; ioctl(uffd, UFFDIO_API, &api);
			/* two pages: the 8-byte sequence number at the end of an ordinary one, the payload on one whose first
			 * touch stalls, so the kernel has accepted the reply when its copy of the payload stalls */
			uint8_t *two = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			uffd_page = two + 4096;
			memcpy(uffd_page - 8, buf, 8);
			struct uffdio_register reg = { { (uintptr_t)uffd_page, 4096 }, UFFDIO_REGISTER_MODE_MISSING, 0 };
			if (uffd < 0 || ioctl(uffd, UFFDIO_REGISTER, &reg)) { printf("SVC FAIL userfaultfd setup (%d)\n", errno); return 2; }
			memcpy(uffd_src, buf + 8, len);
			stall_ms = arg; pthread_t t; pthread_create(&t, NULL, uffd_thread, NULL);
			r = write(fd, uffd_page - 8, 8 + len);
			CHECK(r == (ssize_t)(8 + len), "reply copied in after a stall longer than the timeout (r=%zd errno=%d)", r, errno);
			pthread_join(t, NULL);
			continue;
		}
		r = write(fd, buf, 8 + rl);
		if (!strcmp(mode, "late"))
			CHECK(r < 0 && errno == ESTALE, "late reply refused with ESTALE (r=%zd errno=%d)", r, errno);
		else if (r != (ssize_t)(8 + rl)) { printf("SVC FAIL write %zd errno %d\n", r, errno); fails++; }
		if (!strcmp(mode, "dup")) {
			r = write(fd, buf, 8 + rl);
			CHECK(r < 0 && errno == ESTALE, "second reply to the same call refused (r=%zd errno=%d)", r, errno);
		}
	}
	printf("SVC done mode=%s fails=%d\n", mode, fails);
	return fails != 0;
}
