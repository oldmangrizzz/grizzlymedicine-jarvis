#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "cusum.h"

#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <vector>

using jarvis::identity::operator_attestation::AttestationStatus;
using jarvis::monitoring::cusum::CUSUMPersistenceError;
using jarvis::monitoring::cusum::Detector;
using jarvis::monitoring::cusum::OperatorAttestation;
using jarvis::monitoring::cusum::Parameters;
using jarvis::monitoring::cusum::ResetAttestationError;
using jarvis::monitoring::cusum::ScorecardMonitor;
using jarvis::monitoring::cusum::extract_voice_features;
using jarvis::monitoring::cusum::round_to;
using jarvis::monitoring::cusum::wilson_interval;
using Catch::Approx;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; CUSUM tests must not write to ~/.jarvis.
#endif

static std::filesystem::path artifact_dir(const std::string& name) {
    std::filesystem::path dir = std::filesystem::path(TEST_ARTIFACT_DIR) / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

static std::filesystem::path challenge_store_path(const std::string& name) {
    return artifact_dir(name) / "consumed_challenges.jsonl";
}

static std::filesystem::path drift_store_path(const std::filesystem::path& dir) {
    return dir / "state" / "cusum_drift.jsonl";
}

static std::vector<std::string> read_lines(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<std::string> lines;
    std::string line;
    while (std::getline(in, line)) lines.push_back(line);
    return lines;
}

static void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xC5);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

static OperatorAttestation reset_verdict(std::string organ = "voice",
                                         std::string operation = "cusum_reset",
                                         std::string challenge = "challenge-1",
                                         std::int64_t issued_at = 0) {
    if (issued_at == 0) {
        using namespace std::chrono;
        issued_at = duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
    }
    return OperatorAttestation{AttestationStatus::valid, "operator_attestation_valid", operation, organ, challenge, issued_at};
}

TEST_CASE("no-drift remains quiet for canonical sir-bearing turns", "[cusum]") {
    Detector detector;
    for (int i = 1; i <= 15; ++i) {
        auto step = detector.observe(1.0, static_cast<double>(i), "voice");
        REQUIRE(step.cumulative == Approx(0.0).margin(1e-12));
        REQUIRE_FALSE(step.threshold_crossed);
    }
}

TEST_CASE("slow-drift accumulates only after sustained low sir-rate", "[cusum]") {
    Detector detector;
    std::vector<double> series{1,1,1,1,1,1,1,0,1,0,1,0,0,0,0};
    int first_alert = 0;
    for (std::size_t i = 0; i < series.size(); ++i) {
        auto step = detector.observe(series[i], static_cast<double>(i + 1), "voice");
        if (step.threshold_crossed && first_alert == 0) first_alert = static_cast<int>(i + 1);
    }
    REQUIRE(first_alert == 13);
    REQUIRE(round_to(detector.cumulative(), 4) == Approx(8.3723));
}

TEST_CASE("fast-drift fires within two shifted turns", "[cusum]") {
    Detector detector;
    std::vector<double> series{1,1,1,0,0,0};
    int first_alert = 0;
    for (std::size_t i = 0; i < series.size(); ++i) {
        auto step = detector.observe(series[i], static_cast<double>(i + 1), "voice");
        if (step.threshold_crossed && first_alert == 0) first_alert = static_cast<int>(i + 1);
    }
    REQUIRE(first_alert == 5);
}

TEST_CASE("recovery reset clears accumulator and subsequent canonical turns stay quiet", "[cusum]") {
    Detector detector;
    for (int i = 1; i <= 6; ++i) {
        detector.observe(0.0, static_cast<double>(i), "voice");
    }
    REQUIRE(detector.cumulative() > 3.0);
    jarvis::monitoring::cusum::ConsumedChallengeStore store(challenge_store_path("detector_reset"));
    REQUIRE_THROWS_AS(detector.reset("voice", OperatorAttestation{AttestationStatus::invalid_signature, "missing_valid_signature"}, store), ResetAttestationError);
    detector.reset("voice", reset_verdict("voice", "cusum_reset", "detector-reset-1"), store);
    for (int i = 7; i <= 15; ++i) {
        auto step = detector.observe(1.0, static_cast<double>(i), "voice");
        REQUIRE(step.cumulative == Approx(0.0).margin(1e-12));
        REQUIRE_FALSE(step.threshold_crossed);
    }
}

TEST_CASE("false-positive resistance: isolated misses decay back to zero", "[cusum]") {
    Detector detector;
    std::vector<double> series{1,1,0,1,1,1,0,1,1,1,0,1,1};
    for (std::size_t i = 0; i < series.size(); ++i) {
        auto step = detector.observe(series[i], static_cast<double>(i + 1), "voice");
        REQUIRE_FALSE(step.threshold_crossed);
    }
    REQUIRE(detector.cumulative() == Approx(0.0).margin(1e-12));
}

TEST_CASE("scorecard emits per-organ score threshold flag and timestamp", "[scorecard]") {
    auto dir = artifact_dir("scorecard_basic");
    ScorecardMonitor monitor(Parameters{}, dir / "consumed_challenges.jsonl", nullptr, drift_store_path(dir));
    monitor.observe("Swarm", 0.0, 100.0);
    monitor.observe("BeliefStore", 1.0, 101.0);
    monitor.observe("Endocrine", 0.0, 102.0);
    monitor.observe("Swarm", 0.0, 103.0);
    auto card = monitor.scorecard(104.0);

    REQUIRE(card.timestamp == Approx(104.0));
    REQUIRE(card.organs.size() == 3);

    bool saw_swarm = false;
    bool saw_belief = false;
    bool saw_endocrine = false;
    for (const auto& organ : card.organs) {
        REQUIRE(organ.threshold == Approx(3.0));
        if (organ.organ == "Swarm") {
            saw_swarm = true;
            REQUIRE(organ.drift_score > organ.threshold);
            REQUIRE(organ.threshold_crossed);
            REQUIRE(organ.timestamp == Approx(103.0));
        } else if (organ.organ == "BeliefStore") {
            saw_belief = true;
            REQUIRE(organ.drift_score == Approx(0.0).margin(1e-12));
            REQUIRE_FALSE(organ.threshold_crossed);
        } else if (organ.organ == "Endocrine") {
            saw_endocrine = true;
            REQUIRE_FALSE(organ.threshold_crossed);
        }
    }
    REQUIRE(saw_swarm);
    REQUIRE(saw_belief);
    REQUIRE(saw_endocrine);
}

TEST_CASE("CUSUM reset refuses stale, wrong operation, wrong subject, and replayed verdicts", "[cusum][security]") {
    using namespace std::chrono;
    const auto now = duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
    auto security_dir = artifact_dir("scorecard_security");
    ScorecardMonitor monitor(Parameters{}, security_dir / "consumed_challenges.jsonl", nullptr, drift_store_path(security_dir));
    monitor.observe("Swarm", 0.0, 100.0);
    monitor.observe("Swarm", 0.0, 101.0);

    REQUIRE_THROWS_AS(monitor.reset("Swarm", reset_verdict("Swarm", "cusum_reset", "stale", now - 301)), ResetAttestationError);
    REQUIRE_THROWS_AS(monitor.reset("Swarm", reset_verdict("Swarm", "cusum_reset", "future", now + 60)), ResetAttestationError);
    auto monotonic_future = reset_verdict("Swarm", "cusum_reset", "monotonic-future", now);
    monotonic_future.monotonic_at = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    REQUIRE_THROWS_AS(monitor.reset("Swarm", monotonic_future), ResetAttestationError);
    REQUIRE_THROWS_AS(monitor.reset("Swarm", reset_verdict("Swarm", "continuity_migration", "wrong-op")), ResetAttestationError);
    REQUIRE_THROWS_AS(monitor.reset("Swarm", reset_verdict("BeliefStore", "cusum_reset", "wrong-subject")), ResetAttestationError);

    auto reusable = reset_verdict("Swarm", "cusum_reset", "replay-once");
    monitor.reset("Swarm", reusable);
    REQUIRE_THROWS_AS(monitor.reset("Swarm", reusable), ResetAttestationError);
}

TEST_CASE("consumed challenge store rejects forged chained lines", "[cusum][security]") {
    const auto path = challenge_store_path("forged_line");
    {
        jarvis::monitoring::cusum::ConsumedChallengeStore store(path);
        REQUIRE(store.consume(reset_verdict("voice", "cusum_reset", "forged-line-1")));
    }
    {
        std::fstream file(path, std::ios::in | std::ios::out);
        REQUIRE(file.good());
        std::string contents((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        const auto pos = contents.find("forged-line-1");
        REQUIRE(pos != std::string::npos);
        contents.replace(pos, std::string("forged-line-1").size(), "forged-line-2");
        file.close();
        std::ofstream out(path, std::ios::trunc);
        out << contents;
    }
    REQUIRE_THROWS_AS(jarvis::monitoring::cusum::ConsumedChallengeStore(path), ResetAttestationError);
}

TEST_CASE("feature helpers match Python formulas", "[features]") {
    auto ci = wilson_interval(1, 1);
    REQUIRE(round_to(ci.lo, 3) == Approx(0.207));
    REQUIRE(round_to(ci.hi, 3) == Approx(1.000));

    std::vector<std::string> texts{
        "Sir, power is at ninety-seven percent.",
        "No worries, I'm on it",
        "Shall I proceed, sir?"
    };
    auto feats = extract_voice_features(texts);
    REQUIRE(feats.sir_rate == Approx(2.0 / 3.0));
    REQUIRE(feats.quant_rate == Approx(1.0 / 3.0));
    REQUIRE(feats.median_len == Approx(5.0));
}


TEST_CASE("scorecard CUSUM drift persists across monitor restart", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_restart_restore");
    const auto consumed = dir / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    double restored = 0.0;
    {
        ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
        monitor.observe("Swarm", 0.0, 100.0);
        auto step = monitor.observe("Swarm", 0.0, 101.0);
        restored = step.cumulative;
        REQUIRE(restored > 0.0);
    }

    ScorecardMonitor restarted(Parameters{}, consumed, nullptr, drift);
    auto card = restarted.scorecard(102.0);
    REQUIRE(card.organs.size() == 1);
    REQUIRE(card.organs[0].organ == "Swarm");
    REQUIRE(card.organs[0].drift_score == Approx(restored));
    for (const auto& line : read_lines(drift)) {
        REQUIRE(line.size() + 1 <= jarvis::audit::TamperEvidentAuditLog::kPipeBufAtomicBytes);
    }
}

TEST_CASE("scorecard CUSUM reset persists and reloads as zero", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_reset_restore");
    const auto consumed = dir / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    {
        ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
        monitor.observe("Swarm", 0.0, 100.0);
        monitor.observe("Swarm", 0.0, 101.0);
        monitor.reset("Swarm", reset_verdict("Swarm", "cusum_reset", "reset-persist-1"));
        auto card = monitor.scorecard(102.0);
        REQUIRE(card.organs.size() == 1);
        REQUIRE(card.organs[0].drift_score == Approx(0.0));
    }

    ScorecardMonitor restarted(Parameters{}, consumed, nullptr, drift);
    auto card = restarted.scorecard(103.0);
    REQUIRE(card.organs.size() == 1);
    REQUIRE(card.organs[0].drift_score == Approx(0.0));
}

TEST_CASE("corrupt CUSUM drift jsonl line is skipped and audited during reload", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_reload_corrupt");
    install_test_audit_key();
    const auto consumed = dir / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    {
        ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
        monitor.observe("Swarm", 0.0, 100.0);
    }
    {
        std::ofstream out(drift, std::ios::binary | std::ios::app);
        out << "not-json\n";
    }

    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    ScorecardMonitor restarted(Parameters{}, consumed, &audit, drift);
    auto card = restarted.scorecard(101.0);
    REQUIRE(card.organs.size() == 1);
    REQUIRE(card.organs[0].drift_score > 0.0);
    REQUIRE(audit.verify_chain());

    bool saw_invalid = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::CUSUM_PERSISTENCE_DENIED &&
            event.reason == "drift_record_invalid") saw_invalid = true;
    }
    REQUIRE(saw_invalid);
}

TEST_CASE("CUSUM drift reload skips records after parameter config drift", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_config_drift");
    install_test_audit_key();
    const auto consumed = dir / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    {
        ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
        monitor.observe("Swarm", 0.0, 100.0);
    }

    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    Parameters changed{};
    changed.threshold = 7.0;
    ScorecardMonitor restarted(changed, consumed, &audit, drift);
    REQUIRE(restarted.scorecard(101.0).organs.empty());
    REQUIRE(audit.verify_chain());

    bool saw_config_drift = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::CUSUM_PERSISTENCE_DENIED &&
            event.reason == "config_drift_skip") saw_config_drift = true;
    }
    REQUIRE(saw_config_drift);
}

TEST_CASE("CUSUM observe persistence failure refuses in-memory mutation", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_observe_append_failure");
    const auto consumed = dir / "consumed" / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    {
        std::ofstream blocker(dir / "state", std::ios::binary | std::ios::trunc);
        blocker << "not a directory";
    }
    ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
    REQUIRE_THROWS_AS(monitor.observe("Swarm", 0.0, 100.0), CUSUMPersistenceError);
    REQUIRE(monitor.scorecard(101.0).organs.empty());
}

TEST_CASE("CUSUM reset persistence failure refuses reset and keeps cumulative", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_reset_append_failure");
    const auto consumed = dir / "consumed" / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    double before = 0.0;
    ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
    before = monitor.observe("Swarm", 0.0, 100.0).cumulative;
    REQUIRE(before > 0.0);
    std::filesystem::remove_all(dir / "state");
    {
        std::ofstream blocker(dir / "state", std::ios::binary | std::ios::trunc);
        blocker << "not a directory";
    }
    REQUIRE_THROWS_AS(monitor.reset("Swarm", reset_verdict("Swarm", "cusum_reset", "reset-fail-1")), CUSUMPersistenceError);
    auto card = monitor.scorecard(101.0);
    REQUIRE(card.organs.size() == 1);
    REQUIRE(card.organs[0].drift_score == Approx(before));
}

TEST_CASE("CUSUM drift records over PIPE_BUF are refused before mutation", "[cusum][persistence]") {
    auto dir = artifact_dir("drift_oversize_refused");
    const auto consumed = dir / "consumed_challenges.jsonl";
    const auto drift = drift_store_path(dir);
    ScorecardMonitor monitor(Parameters{}, consumed, nullptr, drift);
    const std::string huge_organ(600, 'x');
    REQUIRE_THROWS_AS(monitor.observe(huge_organ, 0.0, 100.0), CUSUMPersistenceError);
    REQUIRE(monitor.scorecard(101.0).organs.empty());
    REQUIRE_FALSE(std::filesystem::exists(drift));
}
