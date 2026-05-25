#pragma once

#include "shadow_router.h"

#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace jarvis::cutover {

struct OrganPlan {
    std::string name;
    std::filesystem::path native_binary;
    std::string python_endpoint;
    std::string native_endpoint;
    std::vector<std::string> dependencies;
};

struct CutoverPlan {
    std::vector<OrganPlan> organs;
    int shadow_window_seconds{60};
};

struct RuntimePaths {
    std::filesystem::path state_root{".jarvis_cutover_state"};
    std::filesystem::path baseline_root{"../../_baseline"};
    std::filesystem::path native_root{"../JARVISNativeRuntime"};
    std::filesystem::path migration_tool{"../migration/build/jarvis-migrate"};
    std::filesystem::path voice_safetensors{"../JARVISNativeRuntime/voice/tts/coreml/models/voice_state.bin"};
};

enum class StepStatus { ok, aborted, would_run };

struct StepResult {
    StepStatus status{StepStatus::ok};
    std::string organ;
    std::string step;
    std::string reason;
};

struct CutoverResult {
    bool ok{true};
    std::vector<StepResult> steps;
    std::vector<std::string> promoted_organs;
};

class AuditChain {
public:
    explicit AuditChain(std::filesystem::path path);
    void append(const std::string& kind, const std::string& organ, const std::string& outcome, const std::string& metadata);
    [[nodiscard]] bool verify() const;
    [[nodiscard]] std::filesystem::path path() const { return path_; }
private:
    std::filesystem::path path_;
};

class ContinuityLedger {
public:
    explicit ContinuityLedger(std::filesystem::path path);
    void append_promotion(const std::string& organ, const std::string& predecessor, const std::string& successor, const std::string& attestation_hash);
    [[nodiscard]] bool verify() const;
    [[nodiscard]] std::filesystem::path path() const { return path_; }
private:
    std::filesystem::path path_;
};

class CutoverOrchestrator {
public:
    CutoverOrchestrator(CutoverPlan plan, RuntimePaths paths);

    [[nodiscard]] std::vector<OrganPlan> dependency_order() const;
    [[nodiscard]] std::vector<std::string> dependency_order_names() const;
    [[nodiscard]] bool has_cycle() const;

    CutoverResult dry_run();
    CutoverResult execute(bool auto_attest, std::string initial_attestation_token, int shadow_seconds_override = -1);
    StepResult rollback(const std::string& organ, bool due_to_divergence);

    void set_synthetic_divergence(const std::string& organ, bool enabled);
    void set_require_existing_binary(bool required) { require_existing_binary_ = required; }
    void set_shadow_request_count(int count) { shadow_request_count_ = count; }

    [[nodiscard]] bool audit_chain_ok() const;
    [[nodiscard]] bool continuity_chain_ok() const;
    [[nodiscard]] bool voice_hash_unchanged() const;

private:
    StepResult preflight_(const OrganPlan& organ, bool dry_run);
    StepResult quiesce_(const OrganPlan& organ, bool dry_run);
    StepResult snapshot_(const OrganPlan& organ, bool dry_run);
    StepResult shadow_and_promote_(const OrganPlan& organ, bool dry_run, const std::string& attestation_token, int shadow_seconds);
    void distress_(const std::string& organ, const std::string& reason);
    bool attest_(const std::string& token, const std::string& organ, const std::string& step);
    void record_step_(std::vector<StepResult>& steps, StepResult step, bool& ok);
    std::filesystem::path organ_state_path_(const std::string& organ) const;

    CutoverPlan plan_;
    RuntimePaths paths_;
    mutable AuditChain audit_;
    mutable ContinuityLedger continuity_;
    std::map<std::string, bool> synthetic_divergence_;
    bool require_existing_binary_{true};
    int shadow_request_count_{3};
    std::string initial_voice_hash_;
};

CutoverPlan load_plan_file(const std::filesystem::path& path);
std::map<std::string, shadow::EquivalenceTolerance> load_tolerances(const std::filesystem::path& path);
std::string file_hash(const std::filesystem::path& path);
std::string hash_text(const std::string& text);
std::string now_text();

} // namespace jarvis::cutover
