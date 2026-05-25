#include "memory_security.h"

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <system_error>

#include <sodium.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

namespace jarvis::security::memory {
namespace {

bool env_enabled(const char* name) {
    const char* value = std::getenv(name);
    if (!value) return false;
    return std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0 ||
           std::strcmp(value, "TRUE") == 0 || std::strcmp(value, "yes") == 0 ||
           std::strcmp(value, "YES") == 0;
}

struct StartupGuard {
    StartupGuard() {
        ensure_sodium_initialized();
        (void)suppress_core_dumps_at_startup();
    }
};

const StartupGuard kStartupGuard{};

std::string run_readonly_command(const char* command) {
    std::array<char, 256> buf{};
    std::string out;
    FILE* pipe = ::popen(command, "r");
    if (!pipe) return "unknown: popen failed";
    while (std::fgets(buf.data(), static_cast<int>(buf.size()), pipe)) out += buf.data();
    const int status = ::pclose(pipe);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    if (status == -1) return "unknown: command close failed";
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return out.empty() ? "unknown: no output" : out;
    return out.empty() ? "unknown: fdesetup unavailable or not permitted" : out;
}

} // namespace

void ensure_sodium_initialized() {
    static const int init = ::sodium_init();
    if (init < 0) throw std::runtime_error("libsodium initialization failed");
}

CoreDumpState suppress_core_dumps_at_startup() {
    if (env_enabled("JARVIS_ALLOW_CORE_DUMPS")) {
        return {core_dump_limit_is_zero(), true, "operator override: JARVIS_ALLOW_CORE_DUMPS is set"};
    }
    rlimit lim{};
    lim.rlim_cur = 0;
    lim.rlim_max = 0;
    if (::setrlimit(RLIMIT_CORE, &lim) != 0) {
        return {false, false, std::string("setrlimit(RLIMIT_CORE) failed: ") + std::strerror(errno)};
    }
    return {core_dump_limit_is_zero(), false, "RLIMIT_CORE=0"};
}

bool core_dump_limit_is_zero() noexcept {
    rlimit lim{};
    if (::getrlimit(RLIMIT_CORE, &lim) != 0) return false;
    return lim.rlim_cur == 0;
}

std::string filevault_status() {
#ifdef __APPLE__
    return run_readonly_command("/usr/bin/fdesetup status 2>&1");
#else
    return "not macOS: FileVault not applicable";
#endif
}

void lock_no_swap(void* ptr, std::size_t len) {
    if (!ptr || len == 0) return;
    ensure_sodium_initialized();
    if (::sodium_mlock(ptr, len) != 0) {
        throw std::system_error(errno, std::generic_category(), "sodium_mlock failed");
    }
}

void unlock_no_swap(void* ptr, std::size_t len) noexcept {
    if (!ptr || len == 0) return;
    (void)::sodium_munlock(ptr, len);
}

void secure_zero(void* ptr, std::size_t len) noexcept {
    if (!ptr || len == 0) return;
    ::sodium_memzero(ptr, len);
}

bool is_lockable_for_tests(void* ptr, std::size_t len) noexcept {
    if (!ptr || len == 0) return true;
    ensure_sodium_initialized();
    if (::sodium_mlock(ptr, len) != 0) return false;
    (void)::sodium_munlock(ptr, len);
    return true;
}

LockedBytes::LockedBytes(std::size_t size) { resize(size); }

LockedBytes::~LockedBytes() { reset(); }

LockedBytes::LockedBytes(LockedBytes&& other) noexcept
    : data_(other.data_), size_(other.size_) {
    other.data_ = nullptr;
    other.size_ = 0;
}

LockedBytes& LockedBytes::operator=(LockedBytes&& other) noexcept {
    if (this != &other) {
        reset();
        data_ = other.data_;
        size_ = other.size_;
        other.data_ = nullptr;
        other.size_ = 0;
    }
    return *this;
}

void LockedBytes::resize(std::size_t size) {
    if (size == size_) return;
    reset();
    if (size == 0) return;
    ensure_sodium_initialized();
    void* raw = ::sodium_malloc(size);
    if (!raw) throw std::bad_alloc();
    data_ = static_cast<std::uint8_t*>(raw);
    size_ = size;
    lock_no_swap(data_, size_);
}

void LockedBytes::assign(std::span<const std::uint8_t> bytes) {
    resize(bytes.size());
    if (!bytes.empty()) std::memcpy(data_, bytes.data(), bytes.size());
}

void LockedBytes::clear() noexcept { reset(); }

void LockedBytes::reset() noexcept {
    if (!data_) return;
    secure_zero(data_, size_);
    ::sodium_free(data_);
    data_ = nullptr;
    size_ = 0;
}

} // namespace jarvis::security::memory
