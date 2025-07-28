#!/bin/bash

set -euxo pipefail

IMAGE_NAME="localhost/archlinux-bootc"
IMAGE_TAG="test"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

if [ $UID -ne 0 ]; then
  echo "You need to run this script as root"
  exit 1
fi

echo "Building image..."
echo "Command: podman build -t \"$FULL_IMAGE\" --build-arg *** ."
# Do not print the MOK.key
set +x
podman build -t "$FULL_IMAGE" --build-arg "MOK_KEY=$(<MOK.key)" .
set -x
rm test.img || true
truncate -s 10G test.img
podman run --rm --privileged --pid=host --security-opt label=type:unconfined_t -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v .:/output "$FULL_IMAGE" bootc install to-disk --generic-image --filesystem xfs --via-loopback /output/test.img
