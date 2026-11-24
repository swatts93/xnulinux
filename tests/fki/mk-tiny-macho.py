#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# A 16 KB Mach-O with one __TEXT segment at XNU's link address and nothing else: xnu.ko mode=3 maps its window and
# memory for it, then fails (no __thread_starts), which is what test-xnu-load.sh needs.
import struct
import sys

mh = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 72, 0, 0)	# MH_MAGIC_64, arm64, MH_EXECUTE, 1 command
seg = struct.pack('<2I16s4Q4I', 0x19, 72, b'__TEXT', 0xfffffff007004000, 0x4000, 0, 0x4000, 5, 5, 0, 0)
with open(sys.argv[1], 'wb') as f:
    f.write((mh + seg).ljust(0x4000, b'\0'))
