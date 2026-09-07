# Clock-only request tests

Run `bash tests/clock-only/run.sh` to compile the actual request worker extracted from the kernel patch against mocked virtio-config and kernel-time APIs. The test covers clone activation, clock-only resume without clone notification, repeated corrections, retry idempotence, fresh boot, changed-identity rejection, unsupported flags, clock failure, and forward-only wall time.

This is a host-side logic test. It does not qualify interrupt delivery, scheduling, real kernel timekeeping, workload thaw ordering, or a deployed firmware bundle. Those still require building and booting the patched kernel on each backend.

The protocol adds a clock-only driver capability and request flag without changing config offsets. New hosts must check the capability before requesting clock-only correction. An old kernel remains usable for existing identity-and-clock activation; it is not silently treated as supporting clock-only resume.
