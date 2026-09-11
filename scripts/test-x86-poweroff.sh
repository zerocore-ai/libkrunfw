#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
patch_file=${1:-"$script_dir/../patches/0035-x86-register-krun-poweroff-handler.patch"}
scratch=$(mktemp -d)
trap 'rm -f "$scratch/poweroff.inc" "$scratch/poweroff-test"; rmdir "$scratch"' EXIT

# Extract the actual implementation, including its parameter/initcall bindings. Fail if the
# expected block disappears or is duplicated; do not silently test an empty extraction.
awk '
    /^\+static bool krun_i8042_poweroff_enabled / { copying = 1; starts++ }
    copying {
        if (substr($0, 1, 1) != "+") exit 1
        print substr($0, 2)
    }
    /^\+late_initcall\(krun_poweroff_init\);$/ { copying = 0; ends++ }
    END { if (starts != 1 || ends != 1 || copying) exit 1 }
' "$patch_file" > "$scratch/poweroff.inc"

# Registration and I/O are synthetic host-side stubs: no privileged instruction is executed.
# This qualifies the added C logic, not kernel init/shutdown ordering or a real VMM exit.
# The kernel callback intentionally has an unused data parameter.
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$scratch" -x c - -o "$scratch/poweroff-test" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define __init
#define __initdata
#define early_param(name, function) \
    static const char *parameter_name = name; \
    static int (*parameter_setup)(char *) = function
#define late_initcall(function) static int (*initialization)(void) = function
#define SYS_OFF_PRIO_LOW (-128)
#define NOTIFY_DONE 0
#define IS_ERR(pointer) ((uintptr_t)(pointer) >= (uintptr_t)-4095)
#define PTR_ERR(pointer) ((long)(intptr_t)(pointer))
#define pr_err(...) ((void)++error_logs)
#define pr_info(...) ((void)++info_logs)

enum sys_off_mode {
    SYS_OFF_MODE_POWER_OFF_PREPARE,
    SYS_OFF_MODE_POWER_OFF,
    SYS_OFF_MODE_RESTART_PREPARE,
    SYS_OFF_MODE_RESTART,
};
struct sys_off_data { void *cb_data; };
struct sys_off_handler { unsigned unused; };

static struct sys_off_handler handler;
static unsigned registrations, writes, error_logs, info_logs;
static int registration_error, registered_priority;
static enum sys_off_mode registered_mode;
static int (*registered_callback)(struct sys_off_data *);
static void *registered_data;
static unsigned char written_byte;
static unsigned short written_port;

static struct sys_off_handler *register_sys_off_handler(enum sys_off_mode mode,
        int priority, int (*callback)(struct sys_off_data *), void *data)
{
    registrations++;
    registered_mode = mode;
    registered_priority = priority;
    registered_callback = callback;
    registered_data = data;
    if (registration_error)
        return (struct sys_off_handler *)(intptr_t)registration_error;
    return &handler;
}

static void outb(unsigned char value, unsigned short port)
{
    writes++;
    written_byte = value;
    written_port = port;
}

/* Extracted verbatim above: the parser, initializer and callback are not duplicated here. */
#include "poweroff.inc"

static void reset(void)
{
    krun_i8042_poweroff_enabled = false;
    registrations = writes = error_logs = info_logs = 0;
    registration_error = registered_priority = 0;
    registered_mode = SYS_OFF_MODE_RESTART;
    registered_callback = NULL;
    registered_data = &handler;
    written_byte = 0;
    written_port = 0;
}

static void assert_disabled(void)
{
    assert(!krun_i8042_poweroff_enabled);
    assert(initialization() == 0);
    assert(registrations == 0 && writes == 0);
    assert(error_logs == 0 && info_logs == 0);
}

int main(void)
{
    char *invalid[] = {NULL, "", "I8042", "i8042x", "i8042 ", " i8042", "i8042\n", "0", "1"};
    int errors[] = {-ENOMEM, -EBUSY};
    struct sys_off_data data = {NULL};

    assert(strcmp(parameter_name, "krun.poweroff") == 0);
    assert(parameter_setup == krun_poweroff_setup);
    assert(initialization == krun_poweroff_init);
    /* No parameter callback at all models an absent command-line marker. */
    assert_disabled();

    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        reset();
        assert(parameter_setup(invalid[i]) == -EINVAL);
        assert_disabled();
    }

    /* The last occurrence controls admission; a malformed later marker fails closed. */
    reset();
    assert(parameter_setup("i8042") == 0);
    assert(parameter_setup("invalid") == -EINVAL);
    assert_disabled();

    reset();
    assert(parameter_setup("invalid") == -EINVAL);
    assert(parameter_setup("i8042") == 0);
    assert(registrations == 0 && writes == 0);
    assert(initialization() == 0);
    assert(registrations == 1 && writes == 0);
    assert(registered_mode == SYS_OFF_MODE_POWER_OFF);
    assert(registered_priority == SYS_OFF_PRIO_LOW);
    assert(registered_callback == krun_i8042_poweroff);
    assert(registered_data == NULL);
    assert(info_logs == 1 && error_logs == 0);
    assert(registered_callback(&data) == NOTIFY_DONE);
    assert(writes == 1 && written_port == 0x64 && written_byte == 0xfe);

    for (size_t i = 0; i < sizeof(errors) / sizeof(errors[0]); i++) {
        reset();
        registration_error = errors[i];
        assert(parameter_setup("i8042") == 0);
        assert(initialization() == errors[i]);
        assert(registrations == 1 && writes == 0);
        assert(error_logs == 1 && info_logs == 0);
    }

    puts("PASS: absent/invalid marker, exact opt-in, LOW POWER_OFF registration, registration errors, i8042 byte/port");
    puts("Host-side stubs only: full kernel build and live guest poweroff still required.");
    return 0;
}
C
"$scratch/poweroff-test"
