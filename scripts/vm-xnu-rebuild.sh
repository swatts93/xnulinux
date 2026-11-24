#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Inside the VM: apply xnulinux's XNU patches to the k27 tree, rebuild the kernel incrementally, and (when the macOS 27.2
# kernelcache is there) relink the kernel collection with Apple's kexts. The kernel's segment slots inside the collection
# (k27/segaddrs.sh) follow the kernel's size: when kc27-layout.py moves them, the kernel is linked again.
set -e -o pipefail	# a failed kernel build stops here: never repackage the previous kernel
cd ~/w/dvm
export PATH=$PATH:/usr/lib/llvm-21/bin
T=out/k27/xnu
# back to the tree's own sources: every file the patches touched last time (.linux64-patched) or touch now, then the
# patches again. A file that comes out as it was keeps its old time, so the build recompiles only what changed (assert.h
# and cpu_data.h are included everywhere: touching them rebuilds the whole kernel)
P=~/w/poc/xnu-patches
FILES=$(cat $T/.linux64-patched 2>/dev/null; grep -h '^+++ b/' $P/*.patch | sed 's|^+++ b/||')
SNAP=$(mktemp -d); trap 'rm -rf "$SNAP"' EXIT
for f in $FILES; do [ -e $T/$f ] && mkdir -p $SNAP/$(dirname $f) && cp -p $T/$f $SNAP/$f; done
for f in $FILES; do git -C $T checkout -q -- $f 2>/dev/null || rm -f $T/$f; done
for p in $P/*.patch; do
  if ! git -C $T apply $p; then	# leave the tree as it was (patched, built), not half reverted
    echo "$(basename $p) does not apply: the tree is left as it was" >&2
    for f in $FILES; do if [ -e $SNAP/$f ]; then cp -p $SNAP/$f $T/$f; else rm -f $T/$f; fi; done
    exit 1
  fi
  echo "applied $(basename $p)"
done
for f in $FILES; do [ -e $SNAP/$f ] && cmp -s $SNAP/$f $T/$f && touch -r $SNAP/$f $T/$f; done
grep -h '^+++ b/' $P/*.patch | sed 's|^+++ b/||' > $T/.linux64-patched
# the machine layer's headers (shared with xnu.ko), where every component's sources find them
mkdir -p $T/EXTERNAL_HEADERS/linux64
for h in $P/include/*.h; do cmp -s $h $T/EXTERNAL_HEADERS/linux64/$(basename $h) || cp $h $T/EXTERNAL_HEADERS/linux64/; done
t=$SECONDS; JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -15; echo "kernel: $((SECONDS - t)) s"
if [ -e out/kc/kc27.bin ]; then
  # the hosted system's extra Apple kexts (in kc27, not kept by default): IOSurface for actool, CoreImage and friends
  for id in $(grep -v '^#' ~/w/poc/xnu-patches/kc-keep-extra.txt); do grep -qx "$id" configs/kc-keep.txt || echo "$id" >> configs/kc-keep.txt; done
  BEFORE=$(mktemp); cp k27/segaddrs.sh "$BEFORE"
  python3 k27/kc27-layout.py out/kc/kc27.bin out/k27/kernel-k27.macho --write k27/segaddrs.sh | tail -2
  MOVED=0; cmp -s "$BEFORE" k27/segaddrs.sh || MOVED=1; rm -f "$BEFORE"
  if [ $MOVED = 1 ]; then
    echo "kernel slots moved: linking the kernel again"
    JOBS=12 bash k27/build-kernel27.sh 2>&1 | tail -3
  fi
  # xnulinux's own kexts (kexts/*/NAME.json + NAME.cpp), built against the k27 kernel's objects and linked into the collection
  NATIVE=
  # IONetworkingFamily's kernel headers (IOKit/network/*.h) for XnuEthernet: Apple's open source IONetworkingFamily-188 (APSL,
  # fetched here, not kept in the repository), whose __PRIVATE_SPI__ declarations name the reserved slots 2-5 the shipped family
  # uses (the SDK's headers leave slot 5 a reserved stub the collection does not export)
  NETINC=~/w/poc/build/netinc; NETSRC=~/w/poc/build/IONetworkingFamily-188; mkdir -p $NETINC/IOKit
  [ -e $NETSRC/IOEthernetController.h ] || git clone -q --depth 1 --branch IONetworkingFamily-188 https://github.com/apple-oss-distributions/IONetworkingFamily.git $NETSRC
  ln -sfn $NETSRC $NETINC/IOKit/network
  # IOHIDFamily's kernel headers (IOKit/hid/*.h) for XnuInput and IOStorageFamily's (IOKit/storage/*.h) for XnuDisk: the SDK's
  # Kernel.framework has them
  for h in toolchains/sdks/*.sdk/System/Library/Frameworks/Kernel.framework/Headers/IOKit/hid; do
    [ -e $h/IOHIDDevice.h ] && { ln -sfn $PWD/$h $NETINC/IOKit/hid; ln -sfn $PWD/$h/../hidsystem $NETINC/IOKit/hidsystem; ln -sfn $PWD/$h/../graphics $NETINC/IOKit/graphics; ln -sfn $PWD/$h/../storage $NETINC/IOKit/storage
      ln -sfn $PWD/${h%%/System/*}/usr/include/TargetConditionals.h $NETINC/TargetConditionals.h
      ln -sfn $PWD/$h/../../HIDDriverKit $NETINC/HIDDriverKit; break; }	# IOHIDDevice.h includes HIDDriverKit/IOHIDDevice.h
  done
  for j in ~/w/poc/kexts/*/*.json; do
    [ -e "$j" ] || continue
    n=$(basename $j .json)
    # a kext that does not build is left out of the collection (reported), not the whole rebuild
    python3 scripts/build-native-kext.py $n $(dirname $j)/$n.cpp -I $NETINC --obj ${KEXT_OBJ:-k27-obj} || { echo "kext $n failed to build: left out"; continue; }
    NATIVE="$NATIVE $j"
  done
  t=$SECONDS; K27_NO_BOOT=1 NATIVE="$NATIVE" bash k27/try.sh 0 2>&1 | tail -3; echo "collection: $((SECONDS - t)) s"
  grep -iE 'error|unresolved|XnuCpuMetal' out/k27/kc-build.log | tail -8 || true
  # AMFI of the collection's macOS expects the code-signature platform version of that build; the system disk's binaries
  # carry their own (macOS 27.0.1: 26 where 27.2's AMFI expects 27)
  python3 ~/w/poc/scripts/kc-amfi-platform.py out/k27/kc-k27.bin ${AMFI_PLATFORM:-26}
  sudo cp out/k27/kc-k27.bin /lib/firmware/xnu/kc.bin
fi
ls -la out/k27/kernel-k27.macho
sudo cp out/k27/kernel-k27.macho /lib/firmware/xnu/kernel.macho
sync	# the VM may be stopped from the host right after (tart/krunkit stop): unsynced pages of the collection would be lost
