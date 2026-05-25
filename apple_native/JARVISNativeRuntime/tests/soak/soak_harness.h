#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace jarvis::tests::soak {

enum class FaultKind {
    EndocrineExtremeStimulus,
    PheromindDepositStorm,
    SwarmSingleHeadFailure,
    HdcNanInfSimilarity,
    BeliefStoreAbstentionCascade,
    HMemTierExhaustion,
    SageInterruptConsolidation,
    AuditDiskFullAppend,
    NetworkConvexDrop,
    SttWebsocketDrop,
    DegradationExternalLoad,
    IdentitySecureEnclaveUnavailable,
    TimeMonotonicJitter,
    FilesystemTransientReadFailure,
};

struct SoakConfig {
    std::chrono::seconds duration{3600};
    std::chrono::seconds max_duration{86400};
    std::chrono::seconds min_turn_cadence{5};
    std::chrono::seconds max_turn_cadence{30};
    std::chrono::seconds burst_turn_cadence{1};
    std::chrono::seconds fault_interval{300};
    std::chrono::seconds monitor_interval{1};
    std::chrono::seconds recovery_timeout{60};
    std::uint64_t max_rss_growth_bytes{256ULL * 1024ULL * 1024ULL};
    std::uint64_t max_fd_growth{64};
    std::uint64_t max_thread_growth{64};
    std::filesystem::path report_dir;
    std::filesystem::path audit_dir;
    bool require_operator_attestation_for_long_run{true};
    bool operator_attested_long_run{false};
    bool fail_on_gap{false};
    unsigned int seed{0x474d5249U};
};

struct ResourceSample {
    std::uint64_t rss_bytes{0};
    std::uint64_t fd_count{0};
    std::uint64_t thread_count{0};
    std::uint64_t audit_chain_length{0};
    std::uint64_t identity_verification_count{0};
};

struct FaultReport {
    FaultKind kind;
    std::string name;
    std::string outcome;
    double recovery_seconds{0.0};
};

struct SoakResult {
    bool passed{false};
    bool completed{false};
    std::chrono::seconds requested_duration{0};
    std::chrono::milliseconds elapsed{0};
    ResourceSample baseline;
    ResourceSample peak;
    std::uint64_t turns{0};
    std::uint64_t endocrine_ticks{0};
    std::uint64_t identity_verifications{0};
    std::uint64_t audit_chain_length{0};
    std::vector<FaultReport> faults;
    std::vector<std::string> invariant_violations;
    std::vector<std::string> gaps;
    std::filesystem::path operator_report_path;
    std::filesystem::path gaps_path;
};

[[nodiscard]] std::string to_string(FaultKind kind);
[[nodiscard]] SoakConfig config_from_environment(int argc = 0, char** argv = nullptr);
[[nodiscard]] SoakResult run_soak(const SoakConfig& config);
void write_reports(const SoakResult& result, const SoakConfig& config);

} // namespace jarvis::tests::soak
