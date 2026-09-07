#!/usr/bin/env bash
set -euo pipefail
test_dir=$(cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -f "$scratch/driver.inc" "$scratch/driver-test"; rmdir "$scratch"' EXIT

# Build artifacts only: extract the real request-processing code from the kernel patch.
awk '
    /^\+#define MSB_VMGENID_VERSION/ { copying = 1 }
    /^\+static void msb_vmgenid_config_changed/ { copying = 0 }
    copying { print substr($0, 2) }
' "$test_dir/../../patches/0034-virtio-add-microsandbox-vm-generation-driver.patch" > "$scratch/driver.inc"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I "$scratch" "$test_dir/driver_test.c" -o "$scratch/driver-test"
"$scratch/driver-test"
