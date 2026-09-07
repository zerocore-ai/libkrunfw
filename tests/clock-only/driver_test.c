// Exercise the actual patched driver's worker with mocked config space and clock APIs.
// This is a host-side logic test, not a replacement for a guest-kernel live test.
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint32_t __le32;
#define BIT(n) (1U << (n))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define S64_MAX INT64_MAX
#define cpu_to_le32(x) (x)
#define le32_to_cpu(x) (x)
#define upper_32_bits(x) ((u32)((x) >> 32))
#define lower_32_bits(x) ((u32)(x))
#define container_of(p, type, field) ((type *)((char *)(p) - offsetof(type, field)))
#define pr_warn_ratelimited(...) ((void)0)
#define dev_err(...) ((void)0)
#define cond_resched() ((void)0)

struct work_struct { unsigned unused; };
struct virtqueue;
struct virtio_device;
struct virtio_config_ops {
    void (*get)(struct virtio_device *, unsigned, void *, unsigned);
    void (*set)(struct virtio_device *, unsigned, const void *, unsigned);
};
struct virtio_device { struct virtio_config_ops *config; };
struct timespec64 { int64_t tv_sec; long tv_nsec; };
static u8 registers[128];
static u64 raw_ns, real_ns;
static unsigned clone_notifications, clock_updates;
static int set_clock_error;

static void get_config(struct virtio_device *device, unsigned offset, void *out, unsigned size) {
    (void)device;
    assert(offset + size <= sizeof(registers));
    memcpy(out, registers + offset, size);
}
static void set_config(struct virtio_device *device, unsigned offset, const void *in, unsigned size) {
    (void)device;
    assert(offset + size <= sizeof(registers));
    memcpy(registers + offset, in, size);
}
static void add_vmfork_randomness(const void *id, size_t size) {
    assert(id && size == 16);
    clone_notifications++;
}
static u64 ktime_get_raw_ns(void) { return raw_ns++; }
static u64 ktime_get_real_ns(void) { return real_ns; }
static struct timespec64 ns_to_timespec64(u64 ns) {
    return (struct timespec64){(int64_t)(ns / 1000000000), (long)(ns % 1000000000)};
}
static int do_settimeofday64(const struct timespec64 *time) {
    if (set_clock_error) return set_clock_error;
    real_ns = (u64)time->tv_sec * 1000000000 + (u64)time->tv_nsec;
    clock_updates++;
    return 0;
}

// Extracted verbatim from the patch by run.sh; no copied implementation under test.
#include "driver.inc"

static struct virtio_config_ops ops = { get_config, set_config };
static struct virtio_device device = { &ops };
static struct msb_vmgenid_dev guest;

static void reset(void) {
    memset(registers, 0, sizeof(registers));
    memset(&guest, 0, sizeof(guest));
    guest.vdev = &device;
    raw_ns = real_ns = 0;
    clone_notifications = clock_updates = 0;
    set_clock_error = 0;
    msb_vmgenid_write_word(&device, offsetof(struct virtio_msb_vmgenid_config, version), 1);
}

static void request(u64 sequence, u32 flags, u8 id, u64 host_ns) {
    struct virtio_msb_vmgenid_config config;
    memcpy(&config, registers, sizeof(config));
    config.request_sequence_low = lower_32_bits(sequence);
    config.request_sequence_high = upper_32_bits(sequence);
    memset(config.generation_id, id, sizeof(config.generation_id));
    config.request_flags = flags;
    config.clock_low = lower_32_bits(host_ns);
    config.clock_high = upper_32_bits(host_ns);
    memcpy(registers, &config, sizeof(config));
    msb_vmgenid_process(&guest.process_work);
}

static u64 processed(void) {
    return msb_vmgenid_join_sequence(
        msb_vmgenid_read_word(&device, offsetof(struct virtio_msb_vmgenid_config, processed_sequence_low)),
        msb_vmgenid_read_word(&device, offsetof(struct virtio_msb_vmgenid_config, processed_sequence_high)));
}

static void assert_failed(void) {
    assert(msb_vmgenid_read_word(&device, offsetof(struct virtio_msb_vmgenid_config, driver_status)) & MSB_VMGENID_STATUS_ERROR);
}

int main(void) {
    reset();
    request(1, MSB_VMGENID_SYNC_CLOCK, 0x11, 1000);
    assert(processed() == 1 && clone_notifications == 1 && clock_updates == 1);
    request(2, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0x11, 2000);
    assert(processed() == 2 && clone_notifications == 1 && clock_updates == 2);
    request(2, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0x11, 3000);
    assert(processed() == 2 && clone_notifications == 1 && clock_updates == 2);
    request(3, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0x11, 3000);
    assert(processed() == 3 && clone_notifications == 1 && clock_updates == 3);
    request(4, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0x22, 4000);
    assert_failed();
    assert(processed() == 3 && clone_notifications == 1 && clock_updates == 3);

    reset();
    request(1, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0, 1000);
    assert(processed() == 1 && clone_notifications == 0 && clock_updates == 1);
    request(2, MSB_VMGENID_CLOCK_ONLY, 0, 2000);
    assert_failed();
    assert(processed() == 1 && clone_notifications == 0 && clock_updates == 1);

    reset();
    request(1, BIT(3), 0, 1000);
    assert_failed();
    assert(processed() == 0 && clone_notifications == 0 && clock_updates == 0);

    reset();
    set_clock_error = -ERANGE;
    request(1, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0, 1000);
    assert_failed();
    assert(processed() == 0 && clone_notifications == 0 && clock_updates == 0);

    reset();
    real_ns = 2000;
    request(1, MSB_VMGENID_SYNC_CLOCK | MSB_VMGENID_CLOCK_ONLY, 0, 1000);
    assert(processed() == 1 && clone_notifications == 0 && clock_updates == 0 && real_ns == 2000);
    puts("PASS: clone activation, clock-only resume, retries, fresh boot, invalid requests, clock failure, forward-only time");
}
