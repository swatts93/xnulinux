# SPDX-License-Identifier: APSL-2.0
# xnu.ko: the APSL side. Out-of-tree, non-GPL module that only uses fki.h.
obj-m += xnu.o
xnu-y := xnu_main.o macho.o adt.o world.o
ccflags-y += -Wno-declaration-after-statement
# xnu.ko calls Linux only through fki_*: keep the distribution kernel's instrumentation from inserting calls of its own
# (__stack_chk_fail with a canary read through sp_el0, __ubsan_*, __asan_*, KCOV, kCFI checks on calls into world.S).
ccflags-y += -fno-stack-protector
ccflags-remove-y += $(CC_FLAGS_CFI)
KASAN_SANITIZE := n
UBSAN_SANITIZE := n
KCSAN_SANITIZE := n
KMSAN_SANITIZE := n
KCOV_INSTRUMENT := n
