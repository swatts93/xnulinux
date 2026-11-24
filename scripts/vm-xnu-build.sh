#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Inside the arm64 Ubuntu VM: the DroidVM Linux toolchain (native compile, no Darling: the kernel build does not need it)
# and the xnu-12377 kernel from source.
set -ex
export DEBIAN_FRONTEND=noninteractive
if [ ! -x /usr/lib/llvm-21/bin/clang ]; then
  # the key signs apt.llvm.org's packages only (signed-by), not every repository as in /etc/apt/trusted.gpg.d
  sudo install -d -m 0755 /etc/apt/keyrings
  wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/keyrings/apt.llvm.org.asc >/dev/null
  CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  echo "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.asc] http://apt.llvm.org/$CODENAME/ llvm-toolchain-$CODENAME-21 main" |
    sudo tee /etc/apt/sources.list.d/llvm21.list
  sudo apt-get update -qq
fi
sudo -E apt-get install -y -qq build-essential autoconf automake libtool pkg-config git python3 python3-yaml python3-packaging \
  cmake ninja-build meson bison flex m4 unifdef tcsh pax libbsd-dev uuid-dev libssl-dev zlib1g-dev cpio xz-utils zstd llvm-21 clang-21 lld-21 \
  libmd-dev linux-headers-$(uname -r) 7zip p7zip-full >/dev/null
mkdir -p ~/w && cd ~/w
[ -d dvm ] || git clone -q https://github.com/Droid-VM/macOS-DroidVM dvm
cd dvm
python3 - <<'PY'
p='scripts/setup-env.py'; s=open(p).read()
a=s.find("    apple = linux / 'appleclang'"); b=s.find("    # bin26: the kernel's adapters")
if a>0 and b>a:
    s=s[:a]+"    # (xnupoc) no Darling/AppleClang: native_compile builds the kernel with host LLVM\n"+s[b:]
    open(p,'w').write(s)
s=open(p).read()
# arm64 host: the committed gunyah-linux.mk names x86_64 multiarch paths
k="    (X / 'gunyah-linux.mk').write_text('\\n'.join(lines) + '\\n')"
if k in s and 'aarch64-linux-gnu' not in s:
    s=s.replace(k, k.replace("'\\n'.join(lines)", "'\\n'.join(lines).replace('x86_64-linux-gnu', 'aarch64-linux-gnu')"))
    open(p,'w').write(s)
PY
# cctools' foreign mach/machine headers know x86 only; host tools (kextsymboltool, ...) only need LP64 types
for f in $(grep -rl -E 'defined *\(__x86_64__\)' toolchains/linux/cctools-work/cctools/include/foreign); do
  grep -q __aarch64__ $f || sed -i 's/defined *(__x86_64__)/defined(__x86_64__) || defined(__aarch64__)/g' $f
done
T=toolchains/linux/cctools-work/cctools/include/foreign/mach/thread_status.h
grep -q 'xnupoc' $T || sed -i 's|^typedef\tnatural_t\tthread_state_data_t\[THREAD_STATE_MAX\];|#ifndef THREAD_STATE_MAX /* xnupoc: aarch64 host */\n#define THREAD_STATE_MAX 144\n#endif\n&|' $T
grep -n -B3 'thread_state_data_t\[' $T
python3 scripts/setup-env.py toolchain --jobs 12
# decomment keeps getc() in a char: EOF never matches where char is unsigned (aarch64) and it spins forever
D=out/k27/xnu/SETUP/decomment/decomment.c
[ -f $D ] && sed -i 's/^\tchar bufchar;/\tint bufchar;/' $D && grep -n 'bufchar;' $D && rm -f out/x12377/build/xnu/hdrs-obj/SETUP/decomment/decomment
pkill -x decomment || true
# libclang_rt.cc_kext comes from the CLTools package (unpacked only; Darling is not needed for it)
A=toolchains/linux/appleclang; mkdir -p $A
python3 compat/xnu-linux/scripts/setup-appleclang.py fetch --directory $A
[ -d $A/apple-tools ] || python3 compat/xnu-linux/scripts/setup-appleclang.py extract --directory $A
ls $A/apple-tools/Library/Developer/CommandLineTools/usr/lib/clang/*/lib/darwin/ | grep cc_kext
python3 scripts/setup-env.py x12377 --jobs 12
JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -30
ls -la out/k27/kernel-k27.macho
