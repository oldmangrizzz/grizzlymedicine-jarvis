/// Oracle equivalence test: loads Python-generated trace CSVs from
/// /Users/rbhanson/research/oracle/endocrine/ and asserts that the C++
/// trajectory matches Python's to 1e-9 absolute tolerance at every recorded
/// timestamp.  Tau-checkpoint sanity tests are also included.
///
/// Tested columns (endocrine): cortisol, dopamine, adrenaline → 1e-9
///                              field_volatility (4dp) → 1e-9
/// Tested columns (ECS):       tone, cortisol, adrenaline → 1e-9
///                              aea, ag (stored 6dp in oracle) → 1e-6
///                              released_2ag, charge_before/after,
///                              recalled_intensity (4dp) → 1e-9 (both round4)
///                              processed, within_window → exact bool

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "endocrine.h"
#include "endocannabinoid.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace jarvis;

#ifndef ORACLE_DIR
#define ORACLE_DIR "/Users/rbhanson/research/oracle/endocrine"
#endif

static const char* kEndoCSV = ORACLE_DIR "/endocrine_trace.csv";
static const char* kEcsCSV  = ORACLE_DIR "/endocannabinoid_trace.csv";

static constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();

// ---- CSV helpers ----

static std::vector<std::string> split_csv_line(const std::string& line) {
    std::vector<std::string> fields;
    std::stringstream ss(line);
    std::string field;
    while (std::getline(ss, field, ',')) {
        fields.push_back(field);
    }
    return fields;
}

static double parse_double(const std::string& s) {
    if (s.empty()) return kNaN;
    return std::stod(s);
}

static bool parse_bool(const std::string& s) {
    return s == "True" || s == "true" || s == "1";
}

// ---- Mock clock (injectable, deterministic) ----

struct DetClock {
    double t = 0.0;
    double operator()() const { return t; }
};

// ---- Endocrine oracle row ----

struct EndoRow {
    double      t;
    std::string event;
    double      cortisol;
    double      dopamine;
    double      adrenaline;
    double      field_volatility;
};

static std::vector<EndoRow> load_endo_csv(const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) { FAIL("Cannot open oracle CSV: " + std::string(path)); }
    REQUIRE(f.is_open());
    std::string line;
    std::getline(f, line); // skip header
    std::vector<EndoRow> rows;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        auto fs = split_csv_line(line);
        EndoRow r;
        r.t               = parse_double(fs[0]);
        r.event           = fs[1];
        r.cortisol        = parse_double(fs[2]);
        r.dopamine        = parse_double(fs[3]);
        r.adrenaline      = parse_double(fs[4]);
        r.field_volatility = parse_double(fs[5]);
        rows.push_back(r);
    }
    return rows;
}

// ---- ECS oracle row ----

struct EcsRow {
    double      t;
    std::string event;
    double      aea;
    double      ag;
    double      tone;
    bool        within_window_val;
    bool        within_window_present;
    double      cortisol;
    double      adrenaline;
    double      released_2ag;
    double      charge_before;
    double      charge_after;
    double      recalled_intensity;
    bool        processed_val;
    bool        processed_present;
};

static std::vector<EcsRow> load_ecs_csv(const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) { FAIL("Cannot open oracle CSV: " + std::string(path)); }
    REQUIRE(f.is_open());
    std::string line;
    std::getline(f, line); // skip header
    std::vector<EcsRow> rows;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        auto fs = split_csv_line(line);
        // pad to 14 columns
        while (fs.size() < 14) fs.push_back("");
        EcsRow r;
        r.t             = parse_double(fs[0]);
        r.event         = fs[1];
        r.aea           = parse_double(fs[2]);
        r.ag            = parse_double(fs[3]);
        r.tone          = parse_double(fs[4]);
        r.within_window_present = !fs[5].empty();
        r.within_window_val = r.within_window_present ? parse_bool(fs[5]) : false;
        r.cortisol       = parse_double(fs[6]);
        r.adrenaline     = parse_double(fs[7]);
        r.released_2ag   = parse_double(fs[8]);
        r.charge_before  = parse_double(fs[9]);
        r.charge_after   = parse_double(fs[10]);
        r.recalled_intensity = parse_double(fs[11]);
        r.processed_present = !fs[12].empty();
        r.processed_val  = r.processed_present ? parse_bool(fs[12]) : false;
        rows.push_back(r);
    }
    return rows;
}

// ---- helper: extract value after prefix token in event name ----

static double extract_suffix_value(const std::string& ev, const std::string& prefix) {
    auto pos = ev.find(prefix);
    if (pos == std::string::npos) return kNaN;
    return std::stod(ev.substr(pos + prefix.size()));
}

// ---- apply endocrine event ----

static void apply_endo_event(Endocrine& endo, const std::string& ev) {
    auto has = [&](const std::string& tok) {
        return ev.find(tok) != std::string::npos;
    };
    // Read value after token (returns double; handles leading minus in value)
    auto val_after = [&](const std::string& tok) -> double {
        auto p = ev.find(tok);
        if (p == std::string::npos) return 0.0;
        std::string rest = ev.substr(p + tok.size());
        // Read until first non-numeric character (allows leading '-')
        size_t end = 0;
        if (!rest.empty() && (rest[0] == '-' || rest[0] == '+')) end = 1;
        while (end < rest.size() && (std::isdigit(rest[end]) || rest[end] == '.')) ++end;
        return std::stod(rest.substr(0, end));
    };

    // on_rest: exact string only (not "on_rest_post")
    if (ev == "on_rest") { endo.on_rest(); return; }

    // Appraisals: only match when event name ends with a digit
    bool ends_digit = !ev.empty() && std::isdigit(static_cast<unsigned char>(ev.back()));
    if (ends_digit) {
        if (has("on_threat_") && ev.find("on_threat_") == 0) {
            endo.on_threat(val_after("on_threat_")); return;
        }
        if (has("on_success_") && ev.find("on_success_") == 0) {
            endo.on_success(val_after("on_success_")); return;
        }
        if (has("on_deadline_") && ev.find("on_deadline_") == 0) {
            endo.on_deadline(val_after("on_deadline_")); return;
        }
    }

    // multi_spike_c+N_d+N_a+N
    if (has("multi_spike_c")) {
        auto parse_part = [&](const std::string& tag) -> double {
            auto p = ev.find(tag);
            if (p == std::string::npos) return 0.0;
            return val_after(tag);
        };
        endo.stimulus(parse_part("_c+"), parse_part("_d+"), parse_part("_a+"));
        return;
    }

    // Single-hormone spikes (ceiling spike uses same token "spike_+")
    if (has("spike_+")) {
        double v = val_after("spike_+");
        if (has("cortisol"))   { endo.stimulus(v, 0.0, 0.0); return; }
        if (has("dopamine"))   { endo.stimulus(0.0, v, 0.0); return; }
        if (has("adrenaline")) { endo.stimulus(0.0, 0.0, v); return; }
    }

    // Suppressions: value after "suppress_" includes the minus sign
    if (has("suppress_")) {
        double v = val_after("suppress_");  // e.g. val_after reads "-1.50" → -1.50
        if (has("cortisol"))   { endo.stimulus(v, 0.0, 0.0); return; }
        if (has("dopamine"))   { endo.stimulus(0.0, v, 0.0); return; }
        if (has("adrenaline")) { endo.stimulus(0.0, 0.0, v); return; }
    }

    // Otherwise: read-only event — no state change
}

// ============================================================
// TEST: Endocrine oracle
// ============================================================

TEST_CASE("Oracle: endocrine trajectory matches Python to 1e-9", "[oracle][endocrine]") {
    auto rows = load_endo_csv(kEndoCSV);
    REQUIRE(!rows.empty());

    DetClock clk;
    Endocrine endo([&clk]{ return clk.t; });

    double worst_c = 0, worst_d = 0, worst_a = 0, worst_fv = 0;
    int row_idx = 0;

    for (auto& row : rows) {
        ++row_idx;
        // Advance clock (never go backwards)
        if (row.t >= clk.t) clk.t = row.t;

        // Apply operation
        apply_endo_event(endo, row.event);

        // Read state — matches Python capture order
        double c  = endo.level("cortisol");
        double d  = endo.level("dopamine");
        double a  = endo.level("adrenaline");
        double fv = endo.field_volatility();

        double ec  = std::abs(c  - row.cortisol);
        double ed  = std::abs(d  - row.dopamine);
        double ea  = std::abs(a  - row.adrenaline);
        double efv = std::abs(fv - row.field_volatility);

        worst_c  = std::max(worst_c,  ec);
        worst_d  = std::max(worst_d,  ed);
        worst_a  = std::max(worst_a,  ea);
        worst_fv = std::max(worst_fv, efv);

        INFO("Row " << row_idx << " t=" << row.t << " event=" << row.event);
        CHECK(ec  < 1e-9);
        CHECK(ed  < 1e-9);
        CHECK(ea  < 1e-9);
        CHECK(efv < 1e-9);
    }

    double overall_worst = std::max({worst_c, worst_d, worst_a, worst_fv});
    std::cout << "[endocrine oracle] rows=" << rows.size()
              << "  worst_abs_error=" << overall_worst
              << "  (c=" << worst_c << " d=" << worst_d
              << " a=" << worst_a << " fv=" << worst_fv << ")\n";
}

// ============================================================
// TEST: Endocrine tau-checkpoint sanity
// ============================================================

TEST_CASE("Oracle: tau-checkpoint sanity (from oracle manifest)", "[oracle][tau]") {
    // cortisol: baseline=0.20, spike→0.70, at t=90: expected = 0.20 + 0.50*exp(-1)
    {
        DetClock clk; clk.t = 0.0;
        Endocrine e([&clk]{ return clk.t; });
        e.stimulus(0.50, 0.0, 0.0);
        clk.t = 90.0;
        double expected = 0.20 + 0.50 * std::exp(-1.0);
        double got = e.level("cortisol");
        CHECK(std::abs(got - expected) < 1e-9);
    }
    // dopamine
    {
        DetClock clk; clk.t = 0.0;
        Endocrine e([&clk]{ return clk.t; });
        e.stimulus(0.0, 0.50, 0.0);
        clk.t = 60.0;
        double expected = 0.30 + 0.50 * std::exp(-1.0);
        double got = e.level("dopamine");
        CHECK(std::abs(got - expected) < 1e-9);
    }
    // adrenaline
    {
        DetClock clk; clk.t = 0.0;
        Endocrine e([&clk]{ return clk.t; });
        e.stimulus(0.0, 0.0, 0.50);
        clk.t = 30.0;
        double expected = 0.10 + 0.50 * std::exp(-1.0);
        double got = e.level("adrenaline");
        CHECK(std::abs(got - expected) < 1e-9);
    }
}

// ============================================================
// ECS oracle helpers
// ============================================================

/// Apply ECS CSV event.  Returns regulate result if this was a regulate event,
/// and trauma result if this was a process_trauma event (otherwise both are default-init).
struct EcsEventResult {
    bool                              did_regulate = false;
    Endocannabinoid::RegulationResult reg{};
    bool                              did_trauma   = false;
    Endocannabinoid::TraumaResult     trauma{};
};

static EcsEventResult apply_ecs_event(Endocannabinoid& ecs, Endocrine& endo,
                                      const EcsRow& row) {
    const std::string& ev = row.event;
    EcsEventResult res;

    auto has    = [&](const std::string& tok) { return ev.find(tok) != std::string::npos; };
    auto starts = [&](const std::string& tok) { return ev.find(tok) == 0; };

    // Helper: read a numeric value starting at the char after 'tok' in ev.
    // Handles leading minus sign; stops at first non-numeric char.
    auto num_after = [&](const std::string& tok) -> double {
        auto p = ev.find(tok);
        if (p == std::string::npos) return 0.0;
        std::string rest = ev.substr(p + tok.size());
        size_t i = 0;
        if (!rest.empty() && (rest[0] == '-' || rest[0] == '+')) i = 1;
        while (i < rest.size() && (std::isdigit(static_cast<unsigned char>(rest[i])) ||
                                   rest[i] == '.'))
            ++i;
        return std::stod(rest.substr(0, i));
    };

    // ---- regulate ----
    if (starts("regulate") || has("enter_window_regulate")) {
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        return res;
    }

    // ---- endocrine appraisals (endo.on_threat via ECS CSV) ----
    if (has("endo_on_threat_") || has("flood_force_threat_")) {
        double v = num_after("_threat_");
        endo.on_threat(v);
        return res;
    }

    // ---- direct endocrine stimulus: high_stress_spike_cN_aN ----
    if (has("high_stress_spike_c")) {
        // Extract c=N and a=N
        double dc = 0.0, da = 0.0;
        auto pc = ev.find("_c");
        if (pc != std::string::npos) {
            size_t end = ev.find('_', pc + 2);
            dc = std::stod(ev.substr(pc + 2,
                           (end == std::string::npos ? ev.size() : end) - pc - 2));
        }
        auto pa = ev.find("_a");
        if (pa != std::string::npos) {
            da = std::stod(ev.substr(pa + 2));
        }
        endo.stimulus(dc, 0.0, da);
        return res;
    }

    // ---- I1 safe extinction: regulate first to maintain window, then process ----
    if (has("I1_safe_extinction")) {
        double charge = row.charge_before;
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(charge, endo, true);
        return res;
    }

    // ---- recall-only IN window: also regulates first, then process (intend=false) ----
    if (has("recall_only_in_window")) {
        double charge = row.charge_before;
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(charge, endo, false);
        return res;
    }

    // ---- process_trauma without prior regulate (flooded or recall-only-flooded) ----
    if (has("I2_flooded_trauma") || has("recall_only_flooded")) {
        bool intend = !has("intend_False");
        double charge = row.charge_before;
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(charge, endo, intend);
        return res;
    }

    // ---- read-only ----
    return res;
}

// ============================================================
// TEST: ECS oracle
// ============================================================

TEST_CASE("Oracle: ECS trajectory matches Python to 1e-9 (tone/cortisol/adrenaline)", "[oracle][ecs]") {
    auto rows = load_ecs_csv(kEcsCSV);
    REQUIRE(!rows.empty());

    DetClock clk;
    auto fn = [&clk]{ return clk.t; };
    Endocrine       endo(fn);
    Endocannabinoid ecs(fn);

    double worst_tone = 0, worst_c = 0, worst_a = 0;
    double worst_aea  = 0, worst_ag  = 0;
    double worst_r2ag = 0, worst_cb = 0, worst_ca = 0, worst_ri = 0;
    int    row_idx = 0;

    for (auto& row : rows) {
        ++row_idx;
        // Always set clock to row's time, matching Python oracle's set_ec(t) — even for
        // the backward-time t=740 row (after t=900). Python's _decay clamps dt to 0 so
        // no negative decay occurs, but timestamps ARE updated to the new (lower) time,
        // which affects the next forward-time row's dt computation.
        clk.t = row.t;

        auto res = apply_ecs_event(ecs, endo, row);

        // ---- sync state (matches Python capture order) ----
        // 1. tone() decays aea/ag to current time
        double tone_v = ecs.tone();
        // 2. raw aea/ag (post-decay stored values)
        double aea_v  = ecs.aea_raw();
        double ag_v   = ecs.ag_raw();
        // 3. within_window reads cortisol (updating its timestamp)
        bool   win    = ecs.within_window(endo);
        // 4. cortisol (dt=0 after within_window)
        double c_v    = endo.level("cortisol");
        // 5. adrenaline
        double a_v    = endo.level("adrenaline");

        INFO("Row " << row_idx << " t=" << row.t << " event=" << row.event);

        // ---- tone (full precision) ----
        if (!std::isnan(row.tone)) {
            double e = std::abs(tone_v - row.tone);
            worst_tone = std::max(worst_tone, e);
            CHECK(e < 1e-9);
        }

        // ---- aea/ag (stored at ~6dp precision in oracle) ----
        if (!std::isnan(row.aea)) {
            double e = std::abs(aea_v - row.aea);
            worst_aea = std::max(worst_aea, e);
            CHECK(e < 1e-6);
        }
        if (!std::isnan(row.ag)) {
            double e = std::abs(ag_v - row.ag);
            worst_ag = std::max(worst_ag, e);
            CHECK(e < 1e-6);
        }

        // ---- within_window (boolean exact) ----
        if (row.within_window_present) {
            CHECK(win == row.within_window_val);
        }

        // ---- cortisol/adrenaline (full precision) ----
        if (!std::isnan(row.cortisol)) {
            double e = std::abs(c_v - row.cortisol);
            worst_c = std::max(worst_c, e);
            CHECK(e < 1e-9);
        }
        if (!std::isnan(row.adrenaline)) {
            double e = std::abs(a_v - row.adrenaline);
            worst_a = std::max(worst_a, e);
            CHECK(e < 1e-9);
        }

        // ---- regulate return values ----
        if (res.did_regulate) {
            if (!std::isnan(row.released_2ag)) {
                double e = std::abs(res.reg.released_2ag - row.released_2ag);
                worst_r2ag = std::max(worst_r2ag, e);
                CHECK(e < 1e-9);
            }
        }

        // ---- process_trauma return values ----
        if (res.did_trauma) {
            if (!std::isnan(row.charge_before)) {
                double e = std::abs(res.trauma.charge_before - row.charge_before);
                worst_cb = std::max(worst_cb, e);
                CHECK(e < 1e-9);
            }
            if (!std::isnan(row.charge_after)) {
                double e = std::abs(res.trauma.charge_after - row.charge_after);
                worst_ca = std::max(worst_ca, e);
                CHECK(e < 1e-9);
            }
            if (!std::isnan(row.recalled_intensity)) {
                double e = std::abs(res.trauma.recalled_intensity - row.recalled_intensity);
                worst_ri = std::max(worst_ri, e);
                CHECK(e < 1e-9);
            }
            if (row.processed_present) {
                CHECK(res.trauma.processed == row.processed_val);
            }
        }
    }

    double worst_full_prec = std::max({worst_tone, worst_c, worst_a,
                                        worst_r2ag, worst_cb, worst_ca, worst_ri});
    std::cout << "[ECS oracle] rows=" << rows.size()
              << "  worst_full_prec=" << worst_full_prec
              << "  (tone=" << worst_tone
              << " c=" << worst_c << " a=" << worst_a << ")"
              << "  worst_aea=" << worst_aea << " worst_ag=" << worst_ag << "\n";
}

// ============================================================
// TEST: AEA tau-checkpoint (2-AG fast phasic tau=20s)
// ============================================================

TEST_CASE("Oracle: 2-AG tau-checkpoint (AG_TAU=20s, spike+0.50 from base)", "[oracle][tau][ecs]") {
    DetClock clk; clk.t = 0.0;
    auto fn = [&clk]{ return clk.t; };
    Endocrine       endo(fn);
    Endocannabinoid ecs(fn);

    // Force ag to AG_BASE + 0.50 by directly triggering a spike that sets ag to ~0.55
    // We use regulate with controlled endo stress instead. Spike adrenaline to ~0.55+base
    // to drive release = 0.55 - tone, then ag = ag + 0.8*release.
    // Simpler: set up via on_threat so stress > tone by exactly 0.50/0.8 = 0.625 above tone.
    // tone_baseline = 0.295. stress needed = 0.295 + 0.625 = 0.920.
    // on_threat(1.0): cortisol=1.0, adrenaline=0.70 → stress=1.0.
    // release = max(0, 1.0 - 0.295) = 0.705. ag = 0.05 + 0.8*0.705 = 0.614. Not 0.55.
    //
    // Use direct stimulus to get exactly a known ag level.
    // Bypass: just record ag_synth after regulate and verify 1-tau decay.
    endo.on_threat(0.9);
    auto r = ecs.regulate(endo);
    double ag_synth = ecs.ag_raw();

    clk.t = 20.0; // advance exactly one AG_TAU

    ecs.tone(); // force decay
    double ag_1tau = ecs.ag_raw();

    double expected = Endocannabinoid::AG_BASE +
                      (ag_synth - Endocannabinoid::AG_BASE) * std::exp(-1.0);
    CHECK(std::abs(ag_1tau - expected) < 1e-9);
}
