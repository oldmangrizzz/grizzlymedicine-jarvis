#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "cusum.h"
#include <nlohmann/json.hpp>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using jarvis::identity::operator_attestation::AttestationStatus;
using jarvis::monitoring::cusum::Detector;
using jarvis::monitoring::cusum::OperatorAttestation;
using jarvis::monitoring::cusum::Parameters;
using jarvis::monitoring::cusum::ScorecardMonitor;
using jarvis::monitoring::cusum::extract_voice_features;
using jarvis::monitoring::cusum::round_to;
using jarvis::monitoring::cusum::sir_rate;
using jarvis::monitoring::cusum::wilson_interval;
using Catch::Approx;

namespace fs = std::filesystem;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; CUSUM oracle tests must not write to ~/.jarvis.
#endif

static std::int64_t now_seconds() {
    using namespace std::chrono;
    return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}

static OperatorAttestation reset_verdict(const std::string& challenge_id) {
    return OperatorAttestation{AttestationStatus::valid, "operator_attestation_valid", "cusum_reset", "voice", challenge_id + "-" + std::to_string(now_seconds()), now_seconds()};
}

static std::vector<nlohmann::json> read_jsonl(const fs::path& path) {
    std::ifstream in(path);
    REQUIRE(in.good());
    std::vector<nlohmann::json> rows;
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty()) rows.push_back(nlohmann::json::parse(line));
    }
    return rows;
}

TEST_CASE("oracle CUSUM curves replay exactly", "[oracle]") {
    const auto rows = read_jsonl(fs::path(DRIFT_ORACLE_DIR) / "cusum_curves.jsonl");
    REQUIRE(rows.size() == 4);

    int sessions_checked = 0;
    int turns_checked = 0;
    int alert_turns = 0;

    for (const auto& row : rows) {
        Parameters p{row.at("cusum_mu").get<double>(), row.at("cusum_sigma").get<double>(),
                     row.at("cusum_K").get<double>(), row.at("cusum_H").get<double>()};
        Detector detector(p);
        std::optional<int> first_alert;
        std::optional<int> reset_turn;

        for (const auto& turn : row.at("turns")) {
            const int turn_number = turn.at("turn").get<int>();
            const std::string text = turn.at("text").get<std::string>();
            const double observed_sir = sir_rate(text);
            REQUIRE(observed_sir == Approx(turn.at("sir_rate").get<double>()).margin(1e-12));

            const int sir_hits = observed_sir > 0.5 ? 1 : 0;
            auto ci = wilson_interval(sir_hits, 1);
            REQUIRE(round_to(ci.lo, 3) == Approx(turn.at("ci_lo").get<double>()).margin(1e-12));
            REQUIRE(round_to(ci.hi, 3) == Approx(turn.at("ci_hi").get<double>()).margin(1e-12));

            auto step = detector.observe(observed_sir, static_cast<double>(turn_number), "voice");
            bool alert = step.threshold_crossed;

            if (row.at("session_id").get<std::string>() == "S4-recovery" &&
                turn_number == 7) {
                const auto consumed_path = fs::path(TEST_ARTIFACT_DIR) / "oracle_detector_consumed.jsonl";
                fs::remove(consumed_path);
                jarvis::monitoring::cusum::ConsumedChallengeStore store(consumed_path);
                detector.reset("voice", reset_verdict("oracle-detector-reset"), store);
                step.cumulative = 0.0;
                alert = false;
                reset_turn = turn_number;
            }

            REQUIRE(round_to(step.cumulative, 4) == Approx(turn.at("cusum").get<double>()).margin(1e-12));
            REQUIRE(std::string(alert ? "alert" : "no-alert") == turn.at("decision").get<std::string>());
            if (alert && !first_alert.has_value()) first_alert = turn_number;
            ++turns_checked;
            if (alert) ++alert_turns;
        }

        if (row.at("first_alert_turn").is_null()) {
            REQUIRE_FALSE(first_alert.has_value());
        } else {
            REQUIRE(first_alert.has_value());
            REQUIRE(*first_alert == row.at("first_alert_turn").get<int>());
        }
        if (row.at("cusum_reset_turn").is_null()) {
            REQUIRE_FALSE(reset_turn.has_value());
        } else {
            REQUIRE(reset_turn.has_value());
            REQUIRE(*reset_turn == row.at("cusum_reset_turn").get<int>());
        }
        ++sessions_checked;
    }

    REQUIRE(sessions_checked == 4);
    REQUIRE(turns_checked == 60);
    REQUIRE(alert_turns == 19);
}

TEST_CASE("oracle scorecard records map to monitoring scorecards", "[oracle]") {
    const auto curves = read_jsonl(fs::path(DRIFT_ORACLE_DIR) / "cusum_curves.jsonl");
    const auto cards = read_jsonl(fs::path(DRIFT_ORACLE_DIR) / "scorecards.jsonl");
    REQUIRE(cards.size() == 4);

    std::unordered_map<std::string, nlohmann::json> curve_by_session;
    for (const auto& curve : curves) curve_by_session[curve.at("session_id").get<std::string>()] = curve;

    int cards_checked = 0;
    for (const auto& card : cards) {
        const std::string sid = card.at("session_id").get<std::string>();
        const auto& curve = curve_by_session.at(sid);

        const auto session_dir = fs::path(TEST_ARTIFACT_DIR) / (sid + "_scorecard");
        fs::remove_all(session_dir);
        fs::create_directories(session_dir);
        const auto consumed_path = session_dir / "consumed_challenges.jsonl";
        const auto drift_path = session_dir / "state" / "cusum_drift.jsonl";
        ScorecardMonitor monitor(Parameters{}, consumed_path, nullptr, drift_path);
        bool final_alert = false;
        for (const auto& turn : curve.at("turns")) {
            auto step = monitor.observe("voice", turn.at("sir_rate").get<double>(),
                                        static_cast<double>(turn.at("turn").get<int>()));
            final_alert = step.threshold_crossed;
            if (sid == "S4-recovery" && turn.at("turn").get<int>() == 7) {
                monitor.reset("voice", reset_verdict("oracle-monitor-reset-" + sid));
                final_alert = false;
            }
        }
        auto monitoring_card = monitor.scorecard(15.0);
        REQUIRE(monitoring_card.organs.size() == 1);
        REQUIRE(monitoring_card.organs[0].organ == "voice");
        REQUIRE(monitoring_card.organs[0].threshold == Approx(3.0));
        REQUIRE(monitoring_card.organs[0].threshold_crossed == final_alert);
        REQUIRE(monitoring_card.organs[0].timestamp == Approx(15.0));

        const double session_hdc = card.at("session_hdc_score").get<double>();
        const double threshold = card.at("hdc_threshold").get<double>();
        REQUIRE((session_hdc >= threshold) == card.at("in_character").get<bool>());

        std::vector<std::string> texts;
        for (const auto& turn : curve.at("turns")) texts.push_back(turn.at("text").get<std::string>());
        auto feats = extract_voice_features(texts);
        REQUIRE(feats.sir_rate == Approx(card.at("session_feats").at("sir_rate").get<double>()).margin(1e-12));
        REQUIRE(feats.quant_rate == Approx(card.at("session_feats").at("quant_rate").get<double>()).margin(1e-12));
        REQUIRE(feats.median_len == Approx(card.at("session_feats").at("median_len").get<double>()).margin(1e-12));
        ++cards_checked;
    }
    REQUIRE(cards_checked == 4);
}
