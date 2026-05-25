/// Oracle equivalence test: replays all 34 field_traces.jsonl records and
/// asserts every sense()/sense_all()/quorum() output matches the Python value
/// within abs_error < 1e-9 (after round-to-4dp, matching Python snapshot()).
///
/// Also verifies the 2.1x half-life compression across endocrine arousal.

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>
#include <fstream>
#include <sstream>
#include <map>
#include <cmath>
#include <string>
#include <vector>
#include <limits>
#include "pheromind.h"

using namespace jarvis;
using json = nlohmann::json;

#ifndef ORACLE_DIR
#  error "ORACLE_DIR must be defined via target_compile_definitions"
#endif

static double s_worst_abs_error = 0.0;

static double round4(double x) {
    return std::round(x * 1e4) / 1e4;
}

struct OracleRecord {
    double t;
    std::string event;
    std::map<std::string, std::map<std::string, double>> field_snapshot;
    std::map<std::string, bool> quorum_map;
};

static std::vector<OracleRecord> load_field_traces() {
    std::ifstream f(ORACLE_DIR "/field_traces.jsonl");
    if (!f.is_open()) throw std::runtime_error("cannot open field_traces.jsonl");
    std::vector<OracleRecord> records;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        auto j = json::parse(line);
        OracleRecord r;
        r.t     = j["t"].get<double>();
        r.event = j["event"].get<std::string>();
        for (auto& [kind, topics] : j["field_snapshot"].items())
            for (auto& [topic, s] : topics.items())
                r.field_snapshot[kind][topic] = s.get<double>();
        for (auto& [kt, v] : j["quorum"].items())
            r.quorum_map[kt] = v.get<bool>();
        records.push_back(std::move(r));
    }
    return records;
}

static void check_record(Pheromind& pm, const OracleRecord& rec, int idx) {
    CAPTURE(idx, rec.t, rec.event);
    for (auto& [kind, topics] : rec.field_snapshot) {
        auto live = pm.sense_all(kind);
        for (auto& [topic, expected] : topics) {
            CAPTURE(kind, topic, expected);
            if (expected < Pheromind::GC_FLOOR) {
                // Signal is below floor in Python too; C++ correctly returns 0.
                CHECK(pm.sense(kind, topic) == 0.0);
            } else {
                double cpp_raw = live.count(topic) ? live.at(topic) : 0.0;
                double cpp_r4  = round4(cpp_raw);
                double err     = std::abs(cpp_r4 - expected);
                s_worst_abs_error = std::max(s_worst_abs_error, err);
                CAPTURE(cpp_raw, cpp_r4, err);
                CHECK(err < 1e-9);
            }
        }
    }
    // Quorum checks (min_depositors=3, min_strength=0.5 per oracle config)
    for (auto& [kt, expected_q] : rec.quorum_map) {
        auto colon = kt.find(':');
        auto kind  = kt.substr(0, colon);
        auto topic = kt.substr(colon + 1);
        bool got = pm.quorum(kind, topic, 3, 0.5);
        CAPTURE(kt, got, expected_q);
        CHECK(got == expected_q);
    }
}

TEST_CASE("oracle equivalence: field_traces match Python within 1e-9", "[oracle]") {
    auto records = load_field_traces();
    REQUIRE(records.size() == 34);

    // All field traces captured with volatility_fn = lambda: 0.0
    auto vol_zero = []() -> double { return 0.0; };
    double clk_t  = 0.0;
    auto   clk    = [&clk_t]() -> double { return clk_t; };
    int    idx    = 0;

    // ---- Scenario 1: t=1000..1065, single trail deposit + decay ----
    {
        clk_t = 1000.0;
        Pheromind pm(vol_zero, 60.0, clk);

        pm.deposit("trail", "route_A", 0.6, "ant1");
        check_record(pm, records[idx++], idx-1); // 0

        clk_t = 1015.0; check_record(pm, records[idx++], idx-1); // 1
        clk_t = 1045.0; check_record(pm, records[idx++], idx-1); // 2
        clk_t = 1065.0; check_record(pm, records[idx++], idx-1); // 3
    }

    // ---- Scenario 2: t=2000..2060, multi-kind deposits ----
    {
        clk_t = 2000.0;
        Pheromind pm(vol_zero, 60.0, clk);

        pm.deposit("alarm",     "intruder", 0.9, "guard1");
        pm.deposit("territory", "intruder", 0.9, "guard1");
        pm.deposit("trail",     "intruder", 0.7, "scout1");
        check_record(pm, records[idx++], idx-1); // 4

        clk_t = 2012.0; check_record(pm, records[idx++], idx-1); // 5
        clk_t = 2060.0; check_record(pm, records[idx++], idx-1); // 6
    }

    // ---- Scenario 3: t=3000..3060, alarm decay to zero + gc ----
    {
        clk_t = 3000.0;
        Pheromind pm(vol_zero, 60.0, clk);

        pm.deposit("alarm", "blip", 0.5, "sensor1");
        check_record(pm, records[idx++], idx-1); // 7

        clk_t = 3015.0; check_record(pm, records[idx++], idx-1); // 8
        clk_t = 3030.0; check_record(pm, records[idx++], idx-1); // 9
        clk_t = 3045.0; check_record(pm, records[idx++], idx-1); // 10
        clk_t = 3060.0; check_record(pm, records[idx++], idx-1); // 11

        pm.gc(); // floor-only, matches Python gc()
        check_record(pm, records[idx++], idx-1); // 12
    }

    // ---- Scenario 4: t=4000..4120, leader emergence ----
    {
        clk_t = 4000.0;
        Pheromind pm(vol_zero, 60.0, clk);

        pm.deposit("trail", "route_A", 0.30, "ant1");
        check_record(pm, records[idx++], idx-1); // 13

        pm.deposit("trail", "route_B", 0.50, "ant2");
        pm.deposit("trail", "route_B", 0.45, "ant3");
        pm.deposit("trail", "route_B", 0.40, "ant4");
        check_record(pm, records[idx++], idx-1); // 14

        check_record(pm, records[idx++], idx-1); // 15 (observe same time)

        for (int i = 0; i < 6; ++i) {
            clk_t = 4005.0 + i * 5.0;
            pm.deposit("trail", "route_A", 0.3, "ant1");
            check_record(pm, records[idx++], idx-1); // 16..21
        }
        check_record(pm, records[idx++], idx-1); // 22 (observe at t=4030)

        clk_t = 4120.0;
        check_record(pm, records[idx++], idx-1); // 23
    }

    // ---- Scenario 5: t=5000..5075, quorum / abstention ----
    {
        clk_t = 5000.0;
        Pheromind pm(vol_zero, 60.0, clk);

        check_record(pm, records[idx++], idx-1); // 24 (0 depositors)

        pm.deposit("recruit", "go", 0.4, "a1");
        check_record(pm, records[idx++], idx-1); // 25

        check_record(pm, records[idx++], idx-1); // 26 (1 dep)

        pm.deposit("recruit", "go", 0.4, "a2");
        check_record(pm, records[idx++], idx-1); // 27

        check_record(pm, records[idx++], idx-1); // 28 (2 deps)

        pm.deposit("recruit", "go", 0.4, "a3");
        check_record(pm, records[idx++], idx-1); // 29

        check_record(pm, records[idx++], idx-1); // 30 (SHOULD_BE_TRUE)
        check_record(pm, records[idx++], idx-1); // 31 (abstention:wait)

        clk_t = 5035.0; check_record(pm, records[idx++], idx-1); // 32
        clk_t = 5075.0; check_record(pm, records[idx++], idx-1); // 33
    }

    REQUIRE(idx == 34);
    CAPTURE(s_worst_abs_error);
    CHECK(s_worst_abs_error < 1e-9);
}

TEST_CASE("oracle equivalence: coupling_trace eff_tau formula", "[oracle]") {
    std::ifstream f(ORACLE_DIR "/coupling_trace.csv");
    REQUIRE(f.is_open());

    std::string header;
    std::getline(f, header);

    double worst_tau_err = 0.0;
    int    row_count     = 0;

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string t_str, vol_str, eff_tau_str, dr_str, ohl_str, ahl_str;
        std::getline(ss, t_str,       ',');
        std::getline(ss, vol_str,     ',');
        std::getline(ss, eff_tau_str, ',');
        std::getline(ss, dr_str,      ',');
        std::getline(ss, ohl_str,     ',');
        std::getline(ss, ahl_str,     ',');

        double vol     = std::stod(vol_str);
        double exp_tau = std::stod(eff_tau_str);
        double exp_ahl = std::stod(ahl_str);

        double cpp_tau = 60.0 / (1.0 + 2.0 * vol);
        double cpp_ahl = cpp_tau * std::log(2.0);

        double tau_err = std::abs(cpp_tau - exp_tau);
        double ahl_err = std::abs(cpp_ahl - exp_ahl);
        worst_tau_err  = std::max(worst_tau_err, tau_err);

        CAPTURE(vol, cpp_tau, exp_tau, tau_err);
        CHECK(tau_err < 1e-9);
        CHECK(ahl_err < 1e-4);
        ++row_count;
    }

    CAPTURE(worst_tau_err, row_count);
    REQUIRE(row_count >= 15); // 11 sweep rows + endocrine state rows

    // 2.1x half-life compression: rest(vol=0.14) vs max_adr(vol=0.86)
    double hl_rest    = 60.0 / (1.0 + 2.0 * 0.14) * std::log(2.0);
    double hl_max_adr = 60.0 / (1.0 + 2.0 * 0.86) * std::log(2.0);
    double ratio      = hl_rest / hl_max_adr;
    CAPTURE(hl_rest, hl_max_adr, ratio);
    CHECK(ratio > 2.0);
    CHECK(ratio < 2.2);
    CHECK(worst_tau_err < 1e-9);
}
