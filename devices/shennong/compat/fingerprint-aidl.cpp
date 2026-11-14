// SPDX-License-Identifier: LGPL-3.0-only
// AIDL transport for Droidian's existing libhybris biometry ABI.
#include "biometry.h"
#include <aidl/android/hardware/biometrics/fingerprint/BnSessionCallback.h>
#include <aidl/android/hardware/biometrics/fingerprint/IFingerprint.h>
#include <aidl/android/hardware/biometrics/common/OperationContext.h>
#include <aidl/android/hardware/gatekeeper/IGatekeeper.h>
#include <aidl/android/hardware/security/sharedsecret/ISharedSecret.h>
#include <aidl/vendor/xiaomi/hardware/fingerprintextension/IXiaomiFingerprint.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <array>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <sys/random.h>
#include <sys/stat.h>
#include <unistd.h>

namespace fp = aidl::android::hardware::biometrics::fingerprint;
using Hat = aidl::android::hardware::keymaster::HardwareAuthToken;
using Status = ndk::ScopedAStatus;
using Cancel = aidl::android::hardware::biometrics::common::ICancellationSignal;
namespace gk = aidl::android::hardware::gatekeeper;
namespace shared = aidl::android::hardware::security::sharedsecret;
namespace xfp = aidl::vendor::xiaomi::hardware::fingerprintextension;

static bool initialize_shared_secret()
{
    // This transport uses the stock TEE Gatekeeper/fingerprint pair. The
    // minimized Halium image omits keystore2, which normally initializes their
    // authentication HMAC. Negotiate the TEE's own public ISharedSecret HAL;
    // this bridge does not provide Android Keystore or StrongBox key storage.
    const std::vector<std::string> instances{"default"};
    std::vector<std::shared_ptr<shared::ISharedSecret>> services;
    std::vector<shared::SharedSecretParameters> parameters;
    for (const auto &instance : instances) {
        std::string name = std::string(shared::ISharedSecret::descriptor) + "/" + instance;
        auto binder = ndk::SpAIBinder(AServiceManager_checkService(name.c_str()));
        auto service = shared::ISharedSecret::fromBinder(binder);
        shared::SharedSecretParameters parameter;
        if (!service) {
            std::fprintf(stderr, "fingerprint AIDL: shared-secret participant unavailable: %s\n", instance.c_str());
            return false;
        }
        auto status = service->getSharedSecretParameters(&parameter);
        if (!status.isOk() || parameter.nonce.size() != 32) {
            std::fprintf(stderr, "fingerprint AIDL: shared-secret parameters failed for %s: %s (nonce bytes=%zu)\n",
                         instance.c_str(), status.getDescription().c_str(), parameter.nonce.size());
            return false;
        }
        services.push_back(service);
        parameters.push_back(parameter);
    }
    std::sort(parameters.begin(), parameters.end());
    std::vector<uint8_t> reference;
    for (const auto &service : services) {
        std::vector<uint8_t> check;
        auto status = service->computeSharedSecret(parameters, &check);
        if (!status.isOk() || check.size() != 32) {
            std::fprintf(stderr, "fingerprint AIDL: shared-secret calculation failed: %s\n",
                         status.getDescription().c_str());
            return false;
        }
        if (reference.empty()) reference = check;
        else if (check != reference) {
            std::fprintf(stderr, "fingerprint AIDL: shared-secret verification values differ\n");
            return false;
        }
    }
    std::fprintf(stderr, "fingerprint AIDL: secure shared-secret agreement verified (%zu participants)\n",
                 services.size());
    return true;
}

struct UHardwareBiometry_;
class SessionCallback final : public fp::BnSessionCallback {
public:
    explicit SessionCallback(UHardwareBiometry_ *owner) : owner(owner) {}
    Status onChallengeGenerated(int64_t value) override;
    Status onChallengeRevoked(int64_t) override { return Status::ok(); }
    Status onAcquired(fp::AcquiredInfo info, int32_t vendor) override;
    Status onError(fp::Error error, int32_t vendor) override;
    Status onEnrollmentProgress(int32_t id, int32_t remaining) override;
    Status onAuthenticationSucceeded(int32_t id, const Hat &) override;
    Status onAuthenticationFailed() override;
    Status onLockoutTimed(int64_t) override;
    Status onLockoutPermanent() override;
    Status onLockoutCleared() override { return Status::ok(); }
    Status onInteractionDetected() override { return Status::ok(); }
    Status onEnrollmentsEnumerated(const std::vector<int32_t> &ids) override;
    Status onEnrollmentsRemoved(const std::vector<int32_t> &ids) override;
    Status onAuthenticatorIdRetrieved(int64_t value) override;
    Status onAuthenticatorIdInvalidated(int64_t value) override {
        return onAuthenticatorIdRetrieved(value);
    }
    Status onSessionClosed() override;
private:
    UHardwareBiometry_ *owner;
};

struct UHardwareBiometry_ {
    UHardwareBiometryParams callbacks{};
    std::shared_ptr<fp::IFingerprint> hal;
    std::shared_ptr<xfp::IXiaomiFingerprint> extension;
    std::shared_ptr<fp::ISession> session;
    std::shared_ptr<SessionCallback> callback;
    std::shared_ptr<Cancel> cancel;
    std::mutex mutex;
    std::mutex display_mutex;
    std::condition_variable changed;
    int32_t sensor = -1;
    int32_t user = -1;
    int32_t sensor_x = 0;
    int32_t sensor_y = 0;
    int32_t sensor_radius = 0;
    std::atomic<int> operation{0};
    std::atomic<bool> pressed{false};
    int64_t challenge = 0;
    int64_t authenticator = 0;
    bool challenge_ready = false;
    bool authenticator_ready = false;
    bool closed = false;
    std::vector<int32_t> enrollments;
};

static int result(const Status &status)
{
    if (status.isOk()) return SYS_OK;
    std::fprintf(stderr, "fingerprint AIDL: %s\n", status.getDescription().c_str());
    return status.getStatus() == STATUS_DEAD_OBJECT ? SYS_ENOENT : SYS_EIO;
}

static bool vendor_state(UHardwareBiometry self, int command, int value)
{
    int32_t response = -1;
    if (!self->extension) return false;
    auto status = self->extension->extCmd(command, value, &response);
    if (status.isOk() && response == 0) return true;
    std::fprintf(stderr, "fingerprint AIDL: vendor state %d=%d failed (%d): %s\n",
                 command, value, response, status.getDescription().c_str());
    return false;
}

// Stock mi_disp UAPI: DISP_FEATURE_LOCAL_HBM=9, FP_STATUS=12.
// Values follow the device's published display/drm/mi_disp.h interface.
static bool display_feature(int feature, int value)
{
    constexpr const char *path = "/sys/devices/virtual/mi_display/disp_feature/disp-DSI-0/disp_param";
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char data[32];
    int length = std::snprintf(data, sizeof(data), "%d %d", feature, value);
    bool ok = write(fd, data, length) == length;
    close(fd);
    if (!ok) std::fprintf(stderr, "fingerprint AIDL: display feature %d failed\n", feature);
    return ok;
}

static void stop_display(UHardwareBiometry self)
{
    std::lock_guard<std::mutex> guard(self->display_mutex);
    int operation = self->operation.exchange(0);
    if (self->pressed.exchange(false)) display_feature(9, 0);
    if (operation) {
        vendor_state(self, 1, 0); // UDFPS presentation hidden: stop touch detection.
        vendor_state(self, 4, operation == 1 ? 2 : 4);
        display_feature(12, operation == 1 ? 2 : 4);
    }
}

// The dedicated Droidian user must retain its Gatekeeper handle. Generating a
// new Gatekeeper identity for every enrollment would orphan existing templates.
// This record belongs to the privileged daemon, not to a display/login script.
static bool transfer(int fd, void *data, size_t size, bool write)
{
    auto bytes = static_cast<uint8_t *>(data);
    while (size) {
        ssize_t n = write ? ::write(fd, bytes, size) : ::read(fd, bytes, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        bytes += n;
        size -= n;
    }
    return true;
}

static bool credential(const std::shared_ptr<gk::IGatekeeper> &gatekeeper,
                       std::vector<uint8_t> &secret, std::vector<uint8_t> &handle)
{
    constexpr const char *path = "/data/vendor_de/100000/.droidian-gatekeeper";
    constexpr std::array<uint8_t, 8> magic{'S','F','P','G','K','0','0','1'};
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd >= 0) {
        struct stat st{};
        std::array<uint8_t, 8> header{};
        uint32_t size = 0;
        secret.resize(32);
        bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0 &&
                  (st.st_mode & 0777) == 0600 &&
                  transfer(fd, header.data(), header.size(), false) && header == magic &&
                  transfer(fd, secret.data(), secret.size(), false) &&
                  transfer(fd, &size, sizeof(size), false) && size > 0 && size <= 4096 &&
                  st.st_size == static_cast<off_t>(44 + size);
        if (ok) {
            handle.resize(size);
            ok = transfer(fd, handle.data(), handle.size(), false);
        }
        close(fd);
        return ok;
    }
    if (errno != ENOENT) return false;
    secret.resize(32);
    if (getrandom(secret.data(), secret.size(), 0) != static_cast<ssize_t>(secret.size()))
        return false;
    gk::GatekeeperEnrollResponse response;
    auto status = gatekeeper->enroll(100000, {}, {}, secret, &response);
    if (!status.isOk() || response.statusCode != gk::IGatekeeper::STATUS_OK ||
        response.data.empty() || response.data.size() > 4096) return false;
    handle = response.data;
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    uint32_t size = handle.size();
    auto header = magic;
    bool ok = transfer(fd, header.data(), header.size(), true) &&
              transfer(fd, secret.data(), secret.size(), true) &&
              transfer(fd, &size, sizeof(size), true) &&
              transfer(fd, handle.data(), handle.size(), true) && fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    if (!ok) unlink(path);
    return ok;
}

Status SessionCallback::onChallengeGenerated(int64_t value)
{
    std::lock_guard<std::mutex> guard(owner->mutex);
    owner->challenge = value;
    owner->challenge_ready = true;
    owner->changed.notify_all();
    return Status::ok();
}

Status SessionCallback::onAcquired(fp::AcquiredInfo info, int32_t vendor)
{
    // AIDL adds UNKNOWN at zero; legacy biometry GOOD starts at zero.
    int value = static_cast<int>(info);
    value = value >= 1 && value <= 7 ? value - 1 : ACQUIRED_INSUFFICIENT;
    auto &cb = owner->callbacks;
    if (cb.acquired_cb) cb.acquired_cb(owner->sensor, value, vendor, cb.context);
    return Status::ok();
}

Status SessionCallback::onError(fp::Error error, int32_t vendor)
{
    stop_display(owner);
    auto &cb = owner->callbacks;
    int value = static_cast<int>(error);
    if (error == fp::Error::VENDOR) value = ERROR_VENDOR;
    else if (value < 1 || value > 6) value = ERROR_UNABLE_TO_PROCESS;
    if (cb.error_cb) cb.error_cb(owner->sensor, value, vendor, cb.context);
    return Status::ok();
}

Status SessionCallback::onEnrollmentProgress(int32_t id, int32_t remaining)
{
    auto &cb = owner->callbacks;
    if (remaining == 0 && id > 0) {
        stop_display(owner);
        std::lock_guard<std::mutex> guard(owner->mutex);
        if (std::find(owner->enrollments.begin(), owner->enrollments.end(), id) == owner->enrollments.end())
            owner->enrollments.push_back(id);
    }
    if (cb.enrollresult_cb && remaining >= 0 && (id > 0 || remaining > 0))
        cb.enrollresult_cb(owner->sensor, id, 0, remaining, cb.context);
    return Status::ok();
}

Status SessionCallback::onAuthenticationSucceeded(int32_t id, const Hat &)
{
    // Only the real HAL success callback may report a successful match.
    stop_display(owner);
    auto &cb = owner->callbacks;
    if (cb.authenticated_cb && id > 0)
        cb.authenticated_cb(owner->sensor, id, 0, cb.context);
    return Status::ok();
}

Status SessionCallback::onAuthenticationFailed()
{
    auto &cb = owner->callbacks;
    if (cb.authenticated_cb) cb.authenticated_cb(owner->sensor, 0, 0, cb.context);
    return Status::ok();
}

Status SessionCallback::onLockoutTimed(int64_t)
{
    stop_display(owner);
    auto &cb = owner->callbacks;
    if (cb.error_cb) cb.error_cb(owner->sensor, ERROR_LOCKOUT, 0, cb.context);
    return Status::ok();
}

Status SessionCallback::onLockoutPermanent() { return onLockoutTimed(0); }

Status SessionCallback::onEnrollmentsEnumerated(const std::vector<int32_t> &ids)
{
    {
        std::lock_guard<std::mutex> guard(owner->mutex);
        owner->enrollments = ids;
    }
    auto &cb = owner->callbacks;
    if (!cb.enumerate_cb) return Status::ok();
    if (ids.empty()) cb.enumerate_cb(owner->sensor, 0, 0, 0, cb.context);
    for (size_t i = 0; i < ids.size(); ++i)
        cb.enumerate_cb(owner->sensor, ids[i], 0, ids.size() - i - 1, cb.context);
    return Status::ok();
}

Status SessionCallback::onEnrollmentsRemoved(const std::vector<int32_t> &ids)
{
    auto &cb = owner->callbacks;
    if (!cb.removed_cb) return Status::ok();
    if (ids.empty()) cb.removed_cb(owner->sensor, 0, 0, 0, cb.context);
    for (size_t i = 0; i < ids.size(); ++i)
        cb.removed_cb(owner->sensor, ids[i], 0, ids.size() - i - 1, cb.context);
    return Status::ok();
}

Status SessionCallback::onAuthenticatorIdRetrieved(int64_t value)
{
    std::lock_guard<std::mutex> guard(owner->mutex);
    owner->authenticator = value;
    owner->authenticator_ready = true;
    owner->changed.notify_all();
    return Status::ok();
}

Status SessionCallback::onSessionClosed()
{
    std::lock_guard<std::mutex> guard(owner->mutex);
    owner->closed = true;
    owner->changed.notify_all();
    return Status::ok();
}

extern "C" UHardwareBiometry u_hardware_biometry_new()
{
    auto self = new UHardwareBiometry_;
    ABinderProcess_setThreadPoolMaxThreadCount(3);
    ABinderProcess_startThreadPool();
    if (!initialize_shared_secret()) {
        std::fprintf(stderr, "fingerprint AIDL: secure shared-secret agreement failed\n");
        delete self;
        return nullptr;
    }
    auto binder = ndk::SpAIBinder(AServiceManager_checkService(
        "android.hardware.biometrics.fingerprint.IFingerprint/default"));
    self->hal = fp::IFingerprint::fromBinder(binder);
    auto extension_binder = ndk::SpAIBinder(AServiceManager_checkService(
        "vendor.xiaomi.hardware.fingerprintextension.IXiaomiFingerprint/default"));
    self->extension = xfp::IXiaomiFingerprint::fromBinder(extension_binder);
    std::vector<fp::SensorProps> props;
    if (!self->hal || !self->extension || !self->hal->getSensorProps(&props).isOk() || props.size() != 1) {
        delete self;
        return nullptr;
    }
    self->sensor = props.front().commonProps.sensorId;
    if (props.front().sensorLocations.size() != 1) {
        delete self;
        return nullptr;
    }
    const auto &location = props.front().sensorLocations.front();
    self->sensor_x = location.sensorLocationX;
    self->sensor_y = location.sensorLocationY;
    self->sensor_radius = location.sensorRadius;
    self->callback = ndk::SharedRefBase::make<SessionCallback>(self);
    return self;
}

extern "C" uint64_t u_hardware_biometry_setNotify(UHardwareBiometry self,
                                                UHardwareBiometryParams *params)
{
    if (!self || !params) return 0;
    self->callbacks = *params;
    return static_cast<uint64_t>(self->sensor) + 1;
}

extern "C" int u_hardware_biometry_setActiveGroup(UHardwareBiometry self,
                                                 uint32_t group, char *path)
{
    if (!self || !path) return SYS_EINVAL;
    unsigned int user;
    int consumed = 0;
    if (std::sscanf(path, "/data/vendor_de/%u/fpdata%n", &user, &consumed) != 1 ||
        path[consumed] != '\0' || user != 100000 || group != 0) return SYS_EACCES;
    if (self->session) {
        if (self->user == static_cast<int32_t>(user)) return SYS_OK;
        return SYS_EBUSY;
    }
    // Preserve the native daemon's Android group 0. Linux UID 100000 is
    // the Gatekeeper/store identity, not the Android fingerprint group.
    // Android's /data is the B system's private container data directory.
    for (const char *directory : {"/data/vendor_de/0", "/data/vendor_de/0/fpdata"}) {
        if (mkdir(directory, 0700) == 0) {
            if (chown(directory, 1000, 1000) != 0) return SYS_EACCES;
        } else if (errno != EEXIST) return SYS_EACCES;
        struct stat info{};
        if (lstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 1000)
            return SYS_EACCES;
    }
    auto status = self->hal->createSession(self->sensor, group, self->callback, &self->session);
    if (status.isOk()) self->user = user;
    return result(status);
}

extern "C" uint64_t u_hardware_biometry_preEnroll(UHardwareBiometry self)
{
    if (!self || !self->session) return 0;
    std::unique_lock<std::mutex> lock(self->mutex);
    self->challenge_ready = false;
    lock.unlock();
    if (!self->session->generateChallenge().isOk()) return 0;
    lock.lock();
    // libhybris supports pthread_cond_timedwait, but not Android's newer
    // pthread_cond_clockwait used by libc++'s steady-clock wait_for overload.
    if (!self->changed.wait_until(lock, std::chrono::system_clock::now() + std::chrono::seconds(5),
                               [&]{ return self->challenge_ready; })) return 0;
    return self->challenge;
}

extern "C" int u_hardware_biometry_enroll(UHardwareBiometry self,
                                         uint32_t, uint32_t, uint32_t user)
{
    if (!self || !self->session) return SYS_ENOENT;
    if (user != 100000 || self->user != 100000) return SYS_EACCES;
    const int64_t challenge = u_hardware_biometry_preEnroll(self);
    if (!challenge) return SYS_ETIMEDOUT;
    auto binder = ndk::SpAIBinder(AServiceManager_checkService(
        "android.hardware.gatekeeper.IGatekeeper/default"));
    auto gatekeeper = gk::IGatekeeper::fromBinder(binder);
    if (!gatekeeper) return SYS_ENOENT;
    std::vector<uint8_t> secret, handle;
    if (!credential(gatekeeper, secret, handle)) return SYS_EACCES;
    gk::GatekeeperVerifyResponse response;
    auto status = gatekeeper->verify(user, challenge, handle, secret, &response);
    // Bionic does not expose glibc's explicit_bzero. Volatile stores keep the
    // credential wipe from being removed as an unused memory write.
    volatile uint8_t *wipe = secret.data();
    for (size_t i = 0; i < secret.size(); ++i) wipe[i] = 0;
    if (!status.isOk() || response.statusCode < 0) return SYS_EACCES;
    auto &token = response.hardwareAuthToken;
    if (token.challenge != challenge || token.mac.size() != 32) return SYS_EACCES;
    Hat hat;
    hat.challenge = token.challenge;
    hat.userId = token.userId;
    hat.authenticatorId = token.authenticatorId;
    hat.authenticatorType = static_cast<decltype(hat.authenticatorType)>(token.authenticatorType);
    hat.timestamp.milliSeconds = token.timestamp.milliSeconds;
    hat.mac = token.mac;
    aidl::android::hardware::biometrics::common::OperationContext context;
    context.displayState = aidl::android::hardware::biometrics::common::DisplayState::NO_UI;
    if (!display_feature(12, 1)) return SYS_EIO;
    self->operation = 1;
    if (!vendor_state(self, 4, 1)) {
        stop_display(self);
        return SYS_EIO;
    }
    auto enrolled = self->session->enrollWithContext(hat, context, &self->cancel);
    if (!enrolled.isOk()) stop_display(self);
    return result(enrolled);
}

extern "C" int u_hardware_biometry_postEnroll(UHardwareBiometry self)
{
    if (!self || !self->session) return SYS_ENOENT;
    return result(self->session->revokeChallenge(self->challenge));
}

extern "C" uint64_t u_hardware_biometry_getAuthenticatorId(UHardwareBiometry self)
{
    if (!self || !self->session) return 0;
    std::unique_lock<std::mutex> lock(self->mutex);
    self->authenticator_ready = false;
    lock.unlock();
    if (!self->session->getAuthenticatorId().isOk()) return 0;
    lock.lock();
    if (!self->changed.wait_until(lock, std::chrono::system_clock::now() + std::chrono::seconds(5),
                               [&]{ return self->authenticator_ready; })) return 0;
    return self->authenticator;
}

extern "C" int u_hardware_biometry_cancel(UHardwareBiometry self)
{
    if (!self) return SYS_EINVAL;
    stop_display(self);
    if (!self->cancel) return SYS_OK;
    auto cancel = std::move(self->cancel);
    return result(cancel->cancel());
}

extern "C" int u_hardware_biometry_enumerate(UHardwareBiometry self)
{
    if (!self || !self->session) return SYS_ENOENT;
    return result(self->session->enumerateEnrollments());
}

extern "C" int u_hardware_biometry_remove(UHardwareBiometry self,
                                         uint32_t, uint32_t id)
{
    if (!self || !self->session) return SYS_ENOENT;
    std::vector<int32_t> ids;
    {
        std::lock_guard<std::mutex> guard(self->mutex);
        if (id == 0) ids = self->enrollments;
        else {
            for (auto known : self->enrollments)
                if (known == static_cast<int32_t>(id)) ids.push_back(known);
            if (ids.empty()) return SYS_ENOENT;
        }
    }
    if (ids.empty()) {
        self->callback->onEnrollmentsRemoved({});
        return SYS_OK;
    }
    return result(self->session->removeEnrollments(ids));
}

extern "C" int u_hardware_biometry_authenticate(UHardwareBiometry self,
                                               uint64_t operation, uint32_t)
{
    if (!self || !self->session) return SYS_ENOENT;
    if (!display_feature(12, 3)) return SYS_EIO;
    self->operation = 2;
    if (!vendor_state(self, 4, 3)) {
        stop_display(self);
        return SYS_EIO;
    }
    auto authenticated = self->session->authenticate(operation, &self->cancel);
    if (!authenticated.isOk()) stop_display(self);
    return result(authenticated);
}

// Native Phosh renders the target and forwards physical touches through FPD.
extern "C" int u_hardware_biometry_uiVisible(UHardwareBiometry self, int32_t visible)
{
    if (!self || !self->session) return SYS_ENOENT;
    std::lock_guard<std::mutex> guard(self->display_mutex);
    if (visible && !self->operation) return SYS_EBUSY;
    if (!visible && self->pressed.exchange(false)) display_feature(9, 0);
    // Verified stock FodEngineCore states: 3=display power (2=ON),
    // 1=visible UDFPS presentation. The HAL owns touch-feature mode changes.
    if (!visible) return vendor_state(self, 1, 0) ? SYS_OK : SYS_EIO;
    return vendor_state(self, 3, 2) && vendor_state(self, 1, 1) ? SYS_OK : SYS_EIO;
}

extern "C" int u_hardware_biometry_sensorLocation(UHardwareBiometry self, int32_t *position)
{
    if (!self || !position || self->sensor_radius <= 0) return SYS_ENOENT;
    position[0] = self->sensor_x;
    position[1] = self->sensor_y;
    position[2] = self->sensor_radius;
    return SYS_OK;
}

extern "C" int u_hardware_biometry_pointerDown(UHardwareBiometry self, int32_t x, int32_t y)
{
    if (!self || !self->session || !self->operation) return SYS_EBUSY;
    int64_t dx = static_cast<int64_t>(x) - self->sensor_x;
    int64_t dy = static_cast<int64_t>(y) - self->sensor_y;
    if (dx * dx + dy * dy > static_cast<int64_t>(self->sensor_radius) * self->sensor_radius)
        return SYS_EINVAL;
    {
        std::lock_guard<std::mutex> guard(self->display_mutex);
        if (!self->operation) return SYS_EBUSY;
        if (self->pressed.exchange(true)) return SYS_OK;
        if (!display_feature(9, 1)) {
            self->pressed = false;
            return SYS_EIO;
        }
    }
    auto status = self->session->onPointerDown(0, x, y, 10.0f, 10.0f);
    if (!status.isOk()) {
        std::lock_guard<std::mutex> guard(self->display_mutex);
        if (self->pressed.exchange(false)) display_feature(9, 0);
    }
    return result(status);
}

extern "C" int u_hardware_biometry_pointerUp(UHardwareBiometry self)
{
    if (!self || !self->session) return SYS_ENOENT;
    {
        std::lock_guard<std::mutex> guard(self->display_mutex);
        if (!self->pressed.exchange(false)) return SYS_OK;
        display_feature(9, 0);
    }
    return result(self->session->onPointerUp(0));
}

extern "C" int u_hardware_biometry_uiReady(UHardwareBiometry self)
{
    if (!self || !self->session || !self->operation || !self->pressed) return SYS_EBUSY;
    return result(self->session->onUiReady());
}
