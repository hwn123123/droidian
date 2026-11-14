/* SPDX-License-Identifier: GPL-2.0-only
 * Bionic-side adaptation for the stock Composer's multiple DRM opens.
 * Reuse only a DRM master already owned by this process, on the same device.
 * Never acquire master, alter capabilities, or redirect page-flip events.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*commit_fn)(int, void *, uint32_t, void *);
typedef int (*master_fn)(int);

static int same_device(int source, int candidate)
{
    struct stat a, b;
    return source != candidate && fstat(source, &a) == 0 &&
        fstat(candidate, &b) == 0 && S_ISCHR(a.st_mode) && S_ISCHR(b.st_mode) &&
        a.st_rdev == b.st_rdev && a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

int drmModeAtomicCommit(int fd, void *request, uint32_t flags, void *user_data)
{
    commit_fn real = (commit_fn)dlsym(RTLD_NEXT, "drmModeAtomicCommit");
    if (!real) { errno = ENOSYS; return -1; }
    const char *enabled = getenv("SHENNONG_DRM_SHARED_MASTER");
    if (!enabled || enabled[0] != '1' || enabled[1] || (flags & 1U))
        return real(fd, request, flags, user_data);

    static int cached = -1;
    master_fn is_master = (master_fn)dlsym(RTLD_NEXT, "drmIsMaster");
    int target = __atomic_load_n(&cached, __ATOMIC_ACQUIRE);
    if (is_master && same_device(fd, target) && is_master(target))
        return real(target, request, flags, user_data);

    int result = real(fd, request, flags, user_data);
    int saved = errno;
    if (result == 0 || (saved != EACCES && result != -EACCES) || !is_master)
        return result;

    DIR *directory = opendir("/proc/self/fd");
    if (!directory) { errno = saved; return result; }
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        char *end;
        long number = strtol(entry->d_name, &end, 10);
        if (!*entry->d_name || *end || number < 0 || number > 0x7fffffff)
            continue;
        target = (int)number;
        if (!same_device(fd, target) || !is_master(target)) continue;
        result = real(target, request, flags, user_data);
        saved = errno;
        if (result == 0) __atomic_store_n(&cached, target, __ATOMIC_RELEASE);
        break;
    }
    closedir(directory);
    errno = saved;
    return result;
}
