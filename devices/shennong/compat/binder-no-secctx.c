/* SPDX-License-Identifier: GPL-2.0-only
 * Bionic-side compatibility for this device's SELinux-disabled Linux host.
 * No Android/vendor binary or Binder protocol is rewritten. Opt in only on
 * the host profile that explicitly boots with selinux=0. Without that opt-in
 * ioctl forwards its arguments unchanged.
 *
 * This freestanding shared object uses the stable arm64 Bionic C ABI. Its
 * declarations avoid depending on the build host's glibc headers/sysroot.
 */
typedef __UINT32_TYPE__ uint32_t;
typedef __UINT64_TYPE__ uint64_t;
extern void *dlsym(void *, const char *);
extern char *getenv(const char *);
extern int *__errno(void);

#define RTLD_NEXT ((void *) -1L)
#define BINDER_SET_CONTEXT_MGR_EXT 0x4018620dUL
#define FLAT_BINDER_FLAG_TXN_SECURITY_CTX 0x1000U

struct flat_binder_object {
    uint32_t type;
    uint32_t flags;
    uint64_t binder;
    uint64_t cookie;
};
_Static_assert(sizeof(struct flat_binder_object) == 24, "arm64 Binder ABI");

static int opted_in(void)
{
    const char *value = getenv("SHENNONG_BINDER_NO_SECCTX");
    return value && value[0] == '1' && value[1] == '\0';
}

int ioctl(int fd, unsigned long request, ...)
{
    typedef int (*ioctl_fn)(int, unsigned long, ...);
    static ioctl_fn next;
    ioctl_fn real = __atomic_load_n(&next, __ATOMIC_ACQUIRE);
    if (!real) {
        real = (ioctl_fn) dlsym(RTLD_NEXT, "ioctl");
        if (!real) {
            *__errno() = 38; /* ENOSYS: fail rather than call a missing symbol. */
            return -1;
        }
        __atomic_store_n(&next, real, __ATOMIC_RELEASE);
    }
    __builtin_va_list ap;
    __builtin_va_start(ap, request);
    void *arg = __builtin_va_arg(ap, void *);
    __builtin_va_end(ap);
    if (request == BINDER_SET_CONTEXT_MGR_EXT && arg && opted_in()) {
        struct flat_binder_object object = *(struct flat_binder_object *) arg;
        object.flags &= ~FLAT_BINDER_FLAG_TXN_SECURITY_CTX;
        return real(fd, request, &object);
    }
    return real(fd, request, arg);
}
