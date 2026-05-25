#include "degradation.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <sys/sysctl.h>
#else
#include <unistd.h>
#endif

namespace jarvis::resilience::degradation {
namespace {

#ifdef __APPLE__

std::optional<std::array<std::uint64_t, 4>> read_cpu_ticks() {
    host_cpu_load_info_data_t info{};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    const kern_return_t kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                             reinterpret_cast<host_info_t>(&info), &count);
    if (kr != KERN_SUCCESS) return std::nullopt;
    return std::array<std::uint64_t, 4>{
        info.cpu_ticks[CPU_STATE_USER],
        info.cpu_ticks[CPU_STATE_SYSTEM],
        info.cpu_ticks[CPU_STATE_IDLE],
        info.cpu_ticks[CPU_STATE_NICE],
    };
}

double read_memory_pressure() {
    vm_statistics64_data_t vm{};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&vm), &count) != KERN_SUCCESS) {
        return 0.0;
    }
    vm_size_t page_size = 0;
    if (host_page_size(mach_host_self(), &page_size) != KERN_SUCCESS || page_size == 0) return 0.0;

    std::uint64_t total_bytes = 0;
    size_t total_size = sizeof(total_bytes);
    if (sysctlbyname("hw.memsize", &total_bytes, &total_size, nullptr, 0) != 0 || total_bytes == 0) return 0.0;

    const std::uint64_t used_pages = static_cast<std::uint64_t>(vm.active_count)
        + static_cast<std::uint64_t>(vm.inactive_count)
        + static_cast<std::uint64_t>(vm.wire_count)
        + static_cast<std::uint64_t>(vm.compressor_page_count);
    const long double used_bytes = static_cast<long double>(used_pages) * static_cast<long double>(page_size);
    return std::clamp(static_cast<double>(used_bytes / static_cast<long double>(total_bytes)), 0.0, 1.0);
}

double read_thermal_pressure() {
    int level = 0;
    size_t size = sizeof(level);
    if (sysctlbyname("machdep.xcpm.cpu_thermal_level", &level, &size, nullptr, 0) == 0) {
        return std::clamp(static_cast<double>(level) / 100.0, 0.0, 1.0);
    }
    if (sysctlbyname("kern.thermal_pressure", &level, &size, nullptr, 0) == 0) {
        return std::clamp(static_cast<double>(level) / 100.0, 0.0, 1.0);
    }
    return 0.0;
}

void read_battery(ResourcePressure& pressure) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return;
    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (!sources) {
        CFRelease(info);
        return;
    }

    const CFIndex count = CFArrayGetCount(sources);
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, i);
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, source);
        if (!desc) continue;

        CFStringRef state = static_cast<CFStringRef>(CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey)));
        if (state && CFStringCompare(state, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) {
            pressure.on_battery = true;
        }

        int current = 0;
        int max = 0;
        CFNumberRef current_ref = static_cast<CFNumberRef>(CFDictionaryGetValue(desc, CFSTR(kIOPSCurrentCapacityKey)));
        CFNumberRef max_ref = static_cast<CFNumberRef>(CFDictionaryGetValue(desc, CFSTR(kIOPSMaxCapacityKey)));
        if (current_ref && max_ref
            && CFNumberGetValue(current_ref, kCFNumberIntType, &current)
            && CFNumberGetValue(max_ref, kCFNumberIntType, &max)
            && max > 0) {
            pressure.battery_percent = std::clamp(static_cast<double>(current) / static_cast<double>(max), 0.0, 1.0);
        }
    }

    CFRelease(sources);
    CFRelease(info);

    if (pressure.on_battery) {
        if (pressure.battery_percent <= 0.05) pressure.battery = 1.0;
        else if (pressure.battery_percent <= 0.10) pressure.battery = 0.90;
        else if (pressure.battery_percent <= 0.20) pressure.battery = 0.70;
        else pressure.battery = 0.0;
    }
}

#else

double read_memory_pressure() {
    const long pages = sysconf(_SC_PHYS_PAGES);
    const long available = sysconf(_SC_AVPHYS_PAGES);
    if (pages <= 0 || available < 0) return 0.0;
    return std::clamp(1.0 - (static_cast<double>(available) / static_cast<double>(pages)), 0.0, 1.0);
}

#endif

} // namespace

ResourcePressure ResourcePressureMonitor::sample() {
    ResourcePressure pressure;
    pressure.timestamp = std::chrono::system_clock::now();

#ifdef __APPLE__
    if (const auto ticks = read_cpu_ticks()) {
        if (previous_cpu_ticks_) {
            const std::uint64_t user = (*ticks)[0] - (*previous_cpu_ticks_)[0];
            const std::uint64_t system = (*ticks)[1] - (*previous_cpu_ticks_)[1];
            const std::uint64_t idle = (*ticks)[2] - (*previous_cpu_ticks_)[2];
            const std::uint64_t nice = (*ticks)[3] - (*previous_cpu_ticks_)[3];
            const std::uint64_t total = user + system + idle + nice;
            if (total > 0) {
                pressure.cpu = std::clamp(static_cast<double>(user + system + nice) / static_cast<double>(total), 0.0, 1.0);
            }
        }
        previous_cpu_ticks_ = *ticks;
    }
    pressure.memory = read_memory_pressure();
    pressure.thermal = read_thermal_pressure();
    read_battery(pressure);
#else
    pressure.memory = read_memory_pressure();
#endif

    return pressure;
}

} // namespace jarvis::resilience::degradation
