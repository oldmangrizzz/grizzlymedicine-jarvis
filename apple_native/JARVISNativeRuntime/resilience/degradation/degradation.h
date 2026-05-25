#pragma once

#include "../../integrity/audit/audit_log.h"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <system_error>
#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace jarvis::resilience::degradation {

enum class DegradationTier : int {
    normal = 0,
    light = 1,
    moderate = 2,
    severe = 3,
    critical = 4,
};

[[nodiscard]] std::string to_string(DegradationTier tier);

struct ResourcePressure {
    double cpu = 0.0;
    double memory = 0.0;
    double thermal = 0.0;
    double battery = 0.0;
    bool on_battery = false;
    double battery_percent = 1.0;
    std::chrono::system_clock::time_point timestamp = std::chrono::system_clock::now();

    [[nodiscard]] double composite() const noexcept;
};

class ResourcePressureMonitor {
public:
    ResourcePressureMonitor() = default;
    [[nodiscard]] ResourcePressure sample();

private:
    std::optional<std::array<std::uint64_t, 4>> previous_cpu_ticks_;
};

struct TierThresholds {
    double enter_light = 0.60;
    double enter_moderate = 0.74;
    double enter_severe = 0.88;
    double enter_critical = 0.96;

    double recover_light = 0.48;
    double recover_moderate = 0.62;
    double recover_severe = 0.78;
    double recover_critical = 0.90;
};

struct DegradationConfig {
    TierThresholds thresholds{};
    int recovery_samples_required = 3;
    std::filesystem::path certificate_directory;
};

struct RuntimeContext {
    std::size_t configured_swarm_heads = 1;
    bool voice_synthesis_in_active_turn = false;
    bool in_flight_turn = false;
};

struct CognitionOrganState {
    std::string name;
    bool must_run = true;
    bool may_disable = false;
    bool required_now = true;
};

struct DegradationDecision {
    DegradationTier tier = DegradationTier::normal;
    double pressure_score = 0.0;
    std::size_t max_swarm_concurrent_heads = 1;
    bool defer_noncritical_audit_flushes = false;
    bool voice_synthesis_allowed = true;
    bool network_calls_allowed = true;
    bool accept_new_turns = true;
    bool complete_in_flight_turn_only = false;
    bool operator_alert = false;
    bool emergency_safe_shutdown_required = false;
    bool endocrine_tick_required = true;
    bool identity_verification_required = true;
    std::vector<CognitionOrganState> cognition_organs;
};

struct OperatorOverrideCommand {
    DegradationTier forced_tier = DegradationTier::normal;
    std::string operator_id;
    std::string attestation;
    std::string reason;
};

struct IdentityContinuityCertificate {
    std::filesystem::path path;
    std::string contents;
};

class DegradationController {
public:
    explicit DegradationController(audit::TamperEvidentAuditLog* audit_log = nullptr,
                                   DegradationConfig config = {});

    [[nodiscard]] DegradationDecision evaluate(const ResourcePressure& pressure,
                                               const RuntimeContext& context = {});
    [[nodiscard]] DegradationDecision current_decision(const RuntimeContext& context = {}) const;
    [[nodiscard]] DegradationTier current_tier() const noexcept { return tier_; }

    bool apply_operator_override(const OperatorOverrideCommand& command);
    [[nodiscard]] bool clear_operator_override(const std::string& operator_id, const std::string& attestation);

    void record_identity_verification(bool passed, const std::string& reason_code = "scheduled_identity_check");
    [[nodiscard]] bool bodily_integrity_holds(const DegradationDecision& decision) const noexcept;

    [[nodiscard]] IdentityContinuityCertificate write_identity_continuity_certificate(
        const RuntimeContext& context,
        const std::string& operator_id = "system"
    );

private:
    audit::TamperEvidentAuditLog* audit_log_ = nullptr;
    DegradationConfig config_;
    DegradationTier tier_ = DegradationTier::normal;
    std::optional<DegradationTier> forced_tier_;
    int recovery_counter_ = 0;

    [[nodiscard]] DegradationTier tier_for_pressure_(double score) const noexcept;
    [[nodiscard]] bool can_recover_one_step_(double score) const noexcept;
    [[nodiscard]] DegradationDecision decision_for_(DegradationTier tier,
                                                    double score,
                                                    const RuntimeContext& context) const;
    void transition_to_(DegradationTier next, double score, const std::string& reason);
    [[nodiscard]] std::filesystem::path override_store_path_() const;
    [[nodiscard]] bool replay_operator_overrides_() noexcept;
    [[nodiscard]] bool append_override_record_(const OperatorOverrideCommand& command,
                                               std::string type,
                                               DegradationTier tier,
                                               int recovery_counter) const noexcept;
    void audit_(std::string kind, std::string subject, std::string outcome,
                std::string reason, std::string metadata = {}) const;
};

[[nodiscard]] std::vector<CognitionOrganState> cognition_organs();
[[nodiscard]] bool operator_attestation_valid(const OperatorOverrideCommand& command) noexcept;

} // namespace jarvis::resilience::degradation
