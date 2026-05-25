#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

namespace jarvis::security::memory {

struct CoreDumpState {
    bool suppressed{false};
    bool operator_override{false};
    std::string detail;
};

void ensure_sodium_initialized();
[[nodiscard]] CoreDumpState suppress_core_dumps_at_startup();
[[nodiscard]] bool core_dump_limit_is_zero() noexcept;
[[nodiscard]] std::string filevault_status();

void lock_no_swap(void* ptr, std::size_t len);
void unlock_no_swap(void* ptr, std::size_t len) noexcept;
void secure_zero(void* ptr, std::size_t len) noexcept;
[[nodiscard]] bool is_lockable_for_tests(void* ptr, std::size_t len) noexcept;

class LockedBytes {
public:
    LockedBytes() = default;
    explicit LockedBytes(std::size_t size);
    ~LockedBytes();

    LockedBytes(const LockedBytes&) = delete;
    LockedBytes& operator=(const LockedBytes&) = delete;
    LockedBytes(LockedBytes&& other) noexcept;
    LockedBytes& operator=(LockedBytes&& other) noexcept;

    void resize(std::size_t size);
    void assign(std::span<const std::uint8_t> bytes);
    void clear() noexcept;
    [[nodiscard]] std::uint8_t* data() noexcept { return data_; }
    [[nodiscard]] const std::uint8_t* data() const noexcept { return data_; }
    [[nodiscard]] std::size_t size() const noexcept { return size_; }
    [[nodiscard]] bool empty() const noexcept { return size_ == 0; }
    [[nodiscard]] std::span<std::uint8_t> span() noexcept { return {data_, size_}; }
    [[nodiscard]] std::span<const std::uint8_t> span() const noexcept { return {data_, size_}; }

private:
    void reset() noexcept;
    std::uint8_t* data_{nullptr};
    std::size_t size_{0};
};

} // namespace jarvis::security::memory
