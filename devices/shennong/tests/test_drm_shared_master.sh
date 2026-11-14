#!/bin/bash
# Exercise descriptor/device/event boundaries without opening real DRM hardware.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -r "$work"' EXIT
cat > "$work/mock.c" <<'C'
#include <errno.h>
#include <stdint.h>
int expected_master = -1;
int last_fd = -1;
int fake_error = EACCES;
int drmIsMaster(int fd) { return fd == expected_master; }
int drmModeAtomicCommit(int fd, void *request, uint32_t flags, void *data) {
    (void)request; (void)flags; (void)data; last_fd = fd;
    if (fd == expected_master) return 0;
    errno = fake_error; return -1;
}
C
cat > "$work/test.c" <<'C'
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
extern int expected_master, last_fd, fake_error;
extern int drmModeAtomicCommit(int, void *, uint32_t, void *);
int main(void) {
    int source = open("/dev/null", O_RDWR);
    int master = open("/dev/null", O_RDWR);
    int other = open("/dev/zero", O_RDWR);
    assert(source >= 0 && master >= 0 && other >= 0);
    expected_master = master;
    unsetenv("SHENNONG_DRM_SHARED_MASTER");
    assert(drmModeAtomicCommit(source, 0, 0, 0) == -1 && last_fd == source);
    setenv("SHENNONG_DRM_SHARED_MASTER", "1", 1);
    assert(drmModeAtomicCommit(source, 0, 1, 0) == -1 && last_fd == source);
    fake_error = EINVAL;
    assert(drmModeAtomicCommit(source, 0, 0, 0) == -1 && errno == EINVAL);
    fake_error = EACCES;
    expected_master = other;
    assert(drmModeAtomicCommit(source, 0, 0, 0) == -1 && last_fd == source);
    expected_master = master;
    assert(drmModeAtomicCommit(source, 0, 0, 0) == 0 && last_fd == master);
    assert(drmModeAtomicCommit(source, 0, 0, 0) == 0 && last_fd == master);
    close(master);
    expected_master = other;
    assert(drmModeAtomicCommit(source, 0, 0, 0) == -1 && last_fd == source);
    close(source); close(other);
    return 0;
}
C
cc -shared -fPIC -O2 -Wall -Wextra -Werror "$work/mock.c" -o "$work/mock.so"
cc -shared -fPIC -O2 -Wall -Wextra -Werror "$here/../compat/drm-shared-master.c" -ldl -o "$work/compat.so"
cc -O2 -Wall -Wextra -Werror "$work/test.c" -L"$work" -l:mock.so -Wl,-rpath,"$work" -o "$work/test"
LD_PRELOAD="$work/compat.so" "$work/test"
echo 'DRM adaptation: opt-in, same-device master, error propagation, event and stale-fd boundaries passed'
