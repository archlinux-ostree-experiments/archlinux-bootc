#!/bin/bash

set -euxo pipefail

qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -m 2048 \
  -drive format=raw,file=test.img,if=virtio
