# fki.ko and xnu.ko tests

Tests for the Linux-facing parts that can run without a macOS disk. They load and unload `fki.ko` and `xnu.ko`, so run
them **as root on a disposable arm64 test VM**, never on a host running the hosted system.

```
tests/fki/build.sh [KDIR] [OUT]        # native on arm64; cross: ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ...
OUT/test-hostcall.sh                   # fki.ko: /dev/xnu-hostcall, XLATE, fki_phys_peek, fki_window_l1, unload
OUT/test-xnu-load.sh                   # xnu.ko: a failed load gives back its files, memory and kernel-table window
```

Each prints `TEST PASS`/`TEST FAIL` lines and ends with `TESTS-DONE fails=N`; the exit status is non-zero on a
failure. The scripts need only a POSIX shell (busybox is enough).

- `build.sh` builds `fki.ko` with a 3-second host-call timeout (`HC_TIMEOUT`, 120 s normally) so the timeout cases run
  quickly, plus `hctest.ko` (a kernel client making host calls as `xnu.ko` does, inside `fki_enter`), `hcsvc` (a stand-in
  service on `/dev/xnu-hostcall`) and a 16 KB Mach-O image for the `xnu.ko` mode 3 failure path.
- `test-hostcall.sh` covers: no service (`-ENODEV` at once), round trips up to 1 MiB, empty requests, replies too big
  for the caller, a read too small for the request (the request must survive), duplicate and late replies (`ESTALE`),
  a reply whose copy stalls in the kernel past the timeout (userfaultfd: the next call must not get it), address
  translation limits (private anonymous memory refused, shared mappings translated, alignment, bounds, a 1000-page range),
  opening without `CAP_SYS_ADMIN`, and a clean unload with no kernel warnings.
- `NOMAP=<address>` adds a check that `fki_phys_peek` refuses RAM the device tree marks `no-map` (reading it oopsed
  before). With QEMU: dump the `virt` machine's device tree (`-M virt,dumpdtb=virt.dtb`), add a `reserved-memory` node
  with a `no-map` region (for example 2 MB at `0x60000000` in a 2 GB guest), boot with `-dtb`, and pass that address.

Checked with Ubuntu's arm64 `6.17.0-42-generic` and `7.0.0-44-generic` kernels under `qemu-system-aarch64 -M virt -cpu
max` (pointer authentication present): every test passes. The fki.ko and xnu.ko from before these fixes fail the
checks for: the stalled reply reaching the next call, the lost request, the missing capability check, translation of private
memory, the `no-map` read (an oops), and a failed `xnu.ko` load leaving its files open, its window in Linux's kernel
table (later loads fail with `EBUSY`) and its memory allocated (740 MB after three attempts).
