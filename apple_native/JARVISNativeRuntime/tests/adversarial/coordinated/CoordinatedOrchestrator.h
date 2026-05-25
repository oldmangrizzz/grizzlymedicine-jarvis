#pragma once

#include <chrono>
#include <filesystem>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace jarvis::adversarial::coordinated {

enum class Adversary { APT, Extortion, Insider, Coordinated };

struct ScenarioResult {
    std::string id;
    Adversary adversary{Adversary::Coordinated};
    std::string attack_vector;
    std::string defense_triggered;
    bool defense_effective{false};
    long long time_to_detect_ms{0};
    long long time_to_mitigate_ms{0};
    double latency_under_attack_ms{0.0};
    double abstention_rate{0.0};
    int distress_beacon_firings{0};
    int audit_entries{0};
    std::map<std::string, std::string> organ_self_health;
    std::vector<std::string> evidence_chain;
};

struct ScenarioDefinition {
    std::string id;
    Adversary adversary{Adversary::Coordinated};
    std::string attack_vector;
    std::function<ScenarioResult()> execute;
};

class EvidenceLedger {
public:
    void append(std::string scenario_id, std::string event_kind, std::string evidence);
    [[nodiscard]] bool verify_chain() const;
    [[nodiscard]] int count_for(const std::string& scenario_id) const;
    [[nodiscard]] std::vector<std::string> evidence_for(const std::string& scenario_id) const;
    [[nodiscard]] std::size_t size() const;

private:
    struct Entry {
        std::string scenario_id;
        std::string event_kind;
        std::string evidence;
        std::string prev_hash;
        std::string own_hash;
    };

    mutable std::mutex mutex_;
    std::vector<Entry> entries_;
};

class CoordinatedOrchestrator {
public:
    explicit CoordinatedOrchestrator(std::filesystem::path artifact_dir);

    [[nodiscard]] const std::filesystem::path& artifact_dir() const noexcept;
    [[nodiscard]] EvidenceLedger& ledger() noexcept;
    [[nodiscard]] const EvidenceLedger& ledger() const noexcept;

    [[nodiscard]] std::vector<ScenarioDefinition> build_scenarios();
    [[nodiscard]] std::vector<ScenarioResult> run_all_concurrent();
    void write_result_json(const ScenarioResult& result) const;
    void write_report(const std::vector<ScenarioResult>& results) const;

private:
    std::filesystem::path artifact_dir_;
    EvidenceLedger ledger_;
};

[[nodiscard]] const char* adversary_name(Adversary adversary) noexcept;
[[nodiscard]] std::string json_escape(const std::string& value);

} // namespace jarvis::adversarial::coordinated
