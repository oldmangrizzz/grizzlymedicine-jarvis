// corpus_seed_generator.cpp — Build-time utility: generates binary fuzz seed corpus
//                             from oracle endocrine trace CSVs.
//
// This is a BUILD-TIME TOOL ONLY.  It is NOT part of the JARVIS runtime.
// It is compiled and run once during the build to populate corpus/ subdirectories
// with interesting initial inputs for the libFuzzer / AFL++ fuzz targets.
//
// Binary wire format: array of FuzzEvent (16 bytes each).
// See fuzz_common.h for the full field layout and kind enum.
//
// Usage (invoked automatically by CMake as a POST_BUILD step):
//   gen_fuzz_seeds <endocrine_corpus_dir> <endocannabinoid_corpus_dir> \
//                  <endocrine_trace.csv> <endocannabinoid_trace.csv>
//
// Each "scenario" writes one .bin seed file.  Scenarios are:
//   1. Single-event mutations extracted from oracle spike rows
//   2. Multi-event "scenario" sequences representing interesting oracle flows

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

// ── Wire format (must match fuzz_common.h exactly) ───────────────────────────

enum class FuzzEventKind : uint8_t {
    STIMULUS           = 0,
    ON_THREAT          = 1,
    ON_SUCCESS         = 2,
    ON_DEADLINE        = 3,
    ON_REST            = 4,
    READ_LEVELS        = 5,
    ECS_REGULATE       = 6,
    ECS_PROCESS_TRAUMA = 7,
};

#pragma pack(push, 1)
struct FuzzEvent {
    uint8_t kind;
    uint8_t clock_ds;   // deciseconds; 0..255 → 0.0..25.5 s
    uint8_t flags;      // bit 0: intend_to_process
    uint8_t _pad;
    float   arg1;
    float   arg2;
    float   arg3;
};
#pragma pack(pop)

static_assert(sizeof(FuzzEvent) == 16, "FuzzEvent layout mismatch");

// ── Helpers ───────────────────────────────────────────────────────────────────

static FuzzEvent make_stimulus(float cortisol, float dopamine, float adrenaline,
                                uint8_t clock_ds = 0) {
    FuzzEvent e{};
    e.kind     = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
    e.clock_ds = clock_ds;
    e.arg1     = cortisol;
    e.arg2     = dopamine;
    e.arg3     = adrenaline;
    return e;
}

static FuzzEvent make_appraisal(FuzzEventKind kind, float arg,
                                 uint8_t clock_ds = 0) {
    FuzzEvent e{};
    e.kind     = static_cast<uint8_t>(kind);
    e.clock_ds = clock_ds;
    e.arg1     = arg;
    return e;
}

static FuzzEvent make_rest(uint8_t clock_ds = 0) {
    FuzzEvent e{};
    e.kind     = static_cast<uint8_t>(FuzzEventKind::ON_REST);
    e.clock_ds = clock_ds;
    return e;
}

static FuzzEvent make_ecs_regulate(uint8_t clock_ds = 0) {
    FuzzEvent e{};
    e.kind     = static_cast<uint8_t>(FuzzEventKind::ECS_REGULATE);
    e.clock_ds = clock_ds;
    return e;
}

static FuzzEvent make_ecs_trauma(float charge, bool intend, uint8_t clock_ds = 0) {
    FuzzEvent e{};
    e.kind     = static_cast<uint8_t>(FuzzEventKind::ECS_PROCESS_TRAUMA);
    e.clock_ds = clock_ds;
    e.flags    = intend ? 0x01u : 0x00u;
    e.arg1     = charge;
    return e;
}

// Advance clock by `seconds`; splits into ceil(seconds/25.5) events
// of READ_LEVELS (no mutation, just time advance).
static void push_time_advance(std::vector<FuzzEvent>& evts, double seconds) {
    while (seconds > 0.0) {
        double step = (seconds > 25.5) ? 25.5 : seconds;
        FuzzEvent e{};
        e.kind     = static_cast<uint8_t>(FuzzEventKind::READ_LEVELS);
        e.clock_ds = static_cast<uint8_t>(step * 10.0 + 0.5);  // round
        evts.push_back(e);
        seconds -= step;
    }
}

static void write_seed(const std::filesystem::path& dir,
                        const std::string& name,
                        const std::vector<FuzzEvent>& events) {
    std::filesystem::create_directories(dir);
    auto path = dir / (name + ".bin");
    std::ofstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "gen_fuzz_seeds: failed to open %s\n",
                     path.string().c_str());
        return;
    }
    f.write(reinterpret_cast<const char*>(events.data()),
            static_cast<std::streamsize>(events.size() * sizeof(FuzzEvent)));
    std::fprintf(stdout, "  wrote %s (%zu events)\n",
                 path.string().c_str(), events.size());
}

// ── Oracle CSV parser ─────────────────────────────────────────────────────────
//
// Extracts (t, event_name) pairs from the oracle trace CSVs.
// Only mutation rows (spikes, appraisals) produce FuzzEvents; decay-check rows
// become READ_LEVELS with appropriate clock advances.

struct OracleRow {
    double      t;
    std::string event;
};

static std::vector<OracleRow> parse_oracle_csv(const std::string& path) {
    std::vector<OracleRow> rows;
    std::ifstream f(path);
    if (!f) {
        std::fprintf(stderr, "gen_fuzz_seeds: cannot open %s\n", path.c_str());
        return rows;
    }
    std::string line;
    std::getline(f, line);  // skip header
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        std::istringstream ss(line);
        std::string tok;
        std::getline(ss, tok, ',');
        double t = std::stod(tok);
        std::getline(ss, tok, ',');
        rows.push_back({t, tok});
    }
    return rows;
}

// Return true if str looks like a valid numeric token (+/-/digit prefix).
static bool looks_numeric(const std::string& s) {
    if (s.empty()) return false;
    char c = s[0];
    return (c == '+' || c == '-' || (c >= '0' && c <= '9'));
}

// Safe stof: returns nullopt if the string is not numeric.
static std::optional<float> safe_stof(const std::string& s) {
    if (!looks_numeric(s)) return std::nullopt;
    try { return std::stof(s); }
    catch (...) { return std::nullopt; }
}

// Map an oracle endocrine event name → FuzzEvent, given clock advance.
// Only rows that represent explicit mutations (spikes, suppresses, appraisals)
// are converted; decay-check / pre-spike commentary rows return nullopt.
static std::optional<FuzzEvent> oracle_endocrine_event(const std::string& ev,
                                                         uint8_t clock_ds) {
    FuzzEvent fe{};
    fe.clock_ds = clock_ds;
    fe._pad     = 0;
    fe.arg1 = fe.arg2 = fe.arg3 = 0.0f;

    // cortisol_spike_+X  or  ceil_cortisol_spike_+X
    // Guard: value must immediately follow the pattern and be numeric.
    auto cs = ev.find("cortisol_spike_");
    if (cs != std::string::npos) {
        auto val = safe_stof(ev.substr(cs + 15));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg1 = *val;
            return fe;
        }
    }
    auto ds = ev.find("dopamine_spike_");
    if (ds != std::string::npos) {
        auto val = safe_stof(ev.substr(ds + 15));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg2 = *val;
            return fe;
        }
    }
    auto as = ev.find("adrenaline_spike_");
    if (as != std::string::npos) {
        auto val = safe_stof(ev.substr(as + 17));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg3 = *val;
            return fe;
        }
    }
    // multi_spike_c+X_d+X_a+X
    if (ev.rfind("multi_spike_c", 0) == 0) {
        float c = 0, d = 0, a = 0;
        if (std::sscanf(ev.c_str(), "multi_spike_c%f_d%f_a%f", &c, &d, &a) == 3) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg1 = c; fe.arg2 = d; fe.arg3 = a;
            return fe;
        }
    }
    // suppress variants — must have numeric value after suffix
    auto css = ev.find("cortisol_suppress_");
    if (css != std::string::npos) {
        auto val = safe_stof(ev.substr(css + 18));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg1 = *val;
            return fe;
        }
    }
    auto dss = ev.find("dopamine_suppress_");
    if (dss != std::string::npos) {
        auto val = safe_stof(ev.substr(dss + 18));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg2 = *val;
            return fe;
        }
    }
    auto ass = ev.find("adrenaline_suppress_");
    if (ass != std::string::npos) {
        auto val = safe_stof(ev.substr(ass + 20));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::STIMULUS);
            fe.arg3 = *val;
            return fe;
        }
    }
    if (ev.rfind("on_threat_", 0) == 0) {
        auto val = safe_stof(ev.substr(10));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::ON_THREAT);
            fe.arg1 = *val;
            return fe;
        }
    }
    if (ev.rfind("on_success_", 0) == 0) {
        auto val = safe_stof(ev.substr(11));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::ON_SUCCESS);
            fe.arg1 = *val;
            return fe;
        }
    }
    if (ev.rfind("on_deadline_", 0) == 0) {
        auto val = safe_stof(ev.substr(12));
        if (val) {
            fe.kind = static_cast<uint8_t>(FuzzEventKind::ON_DEADLINE);
            fe.arg1 = *val;
            return fe;
        }
    }
    if (ev == "on_rest") {
        fe.kind = static_cast<uint8_t>(FuzzEventKind::ON_REST);
        return fe;
    }
    return std::nullopt;  // decay check / pre-spike commentary / read-only row
}

// ── Endocrine seed generation ─────────────────────────────────────────────────

static void gen_endocrine_seeds(const std::filesystem::path& corpus_dir,
                                  const std::string& trace_csv) {
    std::fprintf(stdout, "Generating endocrine seeds → %s\n",
                 corpus_dir.string().c_str());

    // ── Scenario 1–N: one-event seeds from oracle mutation rows ──────────────
    const auto rows = parse_oracle_csv(trace_csv);
    int seed_idx = 0;
    for (const auto& row : rows) {
        auto maybe = oracle_endocrine_event(row.event, 0);
        if (!maybe) continue;
        std::vector<FuzzEvent> evts = {*maybe};
        write_seed(corpus_dir,
                   "oracle_" + std::to_string(seed_idx++) + "_" + row.event,
                   evts);
    }

    // ── Full oracle replay: entire trace as one seed ──────────────────────────
    {
        std::vector<FuzzEvent> evts;
        double t_prev = 0.0;
        for (const auto& row : rows) {
            double dt = row.t - t_prev;
            uint8_t clock_ds = static_cast<uint8_t>(
                std::min(255.0, dt * 10.0));
            t_prev = row.t;
            auto maybe = oracle_endocrine_event(row.event, clock_ds);
            if (maybe) {
                evts.push_back(*maybe);
            } else {
                // Decay-check row → emit a READ_LEVELS with the time advance.
                FuzzEvent re{};
                re.kind     = static_cast<uint8_t>(FuzzEventKind::READ_LEVELS);
                re.clock_ds = clock_ds;
                evts.push_back(re);
            }
        }
        write_seed(corpus_dir, "oracle_full_replay", evts);
    }

    // ── Hardcoded stress scenarios ────────────────────────────────────────────

    // Scenario: rapid-fire on_threat (no decay between spikes)
    {
        std::vector<FuzzEvent> evts;
        for (int i = 0; i < 16; ++i)
            evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 0.9f, 0));
        write_seed(corpus_dir, "rapid_fire_threat_16x", evts);
    }

    // Scenario: ceiling saturation — push all three to 1.0
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_stimulus(0.85f, 0.85f, 0.95f, 0));
        evts.push_back(make_stimulus(0.85f, 0.85f, 0.95f, 0));
        write_seed(corpus_dir, "ceil_saturation_all", evts);
    }

    // Scenario: floor suppression — suppress all to below baseline
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_stimulus(-1.5f, -1.5f, -0.5f, 0));
        write_seed(corpus_dir, "floor_suppress_all", evts);
    }

    // Scenario: threat → long decay → success → rest
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 0.8f, 0));
        push_time_advance(evts, 100.0);  // let cortisol decay ~40%
        evts.push_back(make_appraisal(FuzzEventKind::ON_SUCCESS, 0.9f, 0));
        push_time_advance(evts, 60.0);
        evts.push_back(make_rest(0));
        write_seed(corpus_dir, "threat_decay_success_rest", evts);
    }

    // Scenario: interleaved deadline and cortisol spikes
    {
        std::vector<FuzzEvent> evts;
        for (int i = 0; i < 5; ++i) {
            evts.push_back(make_appraisal(FuzzEventKind::ON_DEADLINE, 0.7f, 10));
            evts.push_back(make_stimulus(0.3f, 0.0f, 0.3f, 5));
        }
        write_seed(corpus_dir, "interleaved_deadline_stimulus", evts);
    }

    std::fprintf(stdout, "Endocrine seeds complete.\n\n");
}

// ── Endocannabinoid seed generation ──────────────────────────────────────────

static void gen_endocannabinoid_seeds(const std::filesystem::path& corpus_dir,
                                        const std::string& trace_csv) {
    std::fprintf(stdout, "Generating endocannabinoid seeds → %s\n",
                 corpus_dir.string().c_str());

    // ── Scenario 1: baseline regulate (no stress) ────────────────────────────
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_ecs_regulate(0));
        write_seed(corpus_dir, "baseline_regulate", evts);
    }

    // ── Scenario 2: threat 0.9 → regulate ───────────────────────────────────
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 0.9f, 0));
        evts.push_back(make_ecs_regulate(0));
        write_seed(corpus_dir, "threat_0.9_then_regulate", evts);
    }

    // ── Scenario 3: flooded — trauma OUTSIDE window (I2 guard) ──────────────
    {
        std::vector<FuzzEvent> evts;
        // Force cortisol to 1.0 (outside window: cortisol ≥ 0.6)
        evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 1.0f, 0));
        evts.push_back(make_ecs_trauma(0.8f, true, 0));  // should NOT process
        evts.push_back(make_ecs_trauma(0.8f, false, 0)); // recall-only
        write_seed(corpus_dir, "flooded_trauma_outside_window", evts);
    }

    // ── Scenario 4: trauma INSIDE window after decay ─────────────────────────
    // Cortisol must decay below 0.6 from spike of 1.0:
    //   0.6 = 0.2 + 0.8*exp(-t/90) → t ≈ 62.4 s
    {
        std::vector<FuzzEvent> evts;
        evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 1.0f, 0));
        push_time_advance(evts, 70.0);  // > 62.4 s; cortisol drops to ~0.57
        evts.push_back(make_ecs_regulate(0));             // boost tone
        evts.push_back(make_ecs_trauma(0.6f, true, 0));  // should process (I1 check)
        write_seed(corpus_dir, "trauma_inside_window", evts);
    }

    // ── Scenario 5: repeated regulate cycles (2-AG pump-up and decay) ────────
    {
        std::vector<FuzzEvent> evts;
        for (int i = 0; i < 8; ++i) {
            evts.push_back(make_appraisal(FuzzEventKind::ON_THREAT, 0.8f, 0));
            evts.push_back(make_ecs_regulate(0));
            push_time_advance(evts, 20.0);  // let 2-AG partially decay (τ=20s)
        }
        write_seed(corpus_dir, "regulate_pump_8_cycles", evts);
    }

    // ── Scenario 6: oracle full replay ───────────────────────────────────────
    {
        const auto rows = parse_oracle_csv(trace_csv);
        std::vector<FuzzEvent> evts;
        double t_prev = 0.0;

        for (const auto& row : rows) {
            double dt = row.t - t_prev;
            uint8_t cds = static_cast<uint8_t>(std::min(255.0, dt * 10.0));
            t_prev = row.t;

            const auto& ev = row.event;

            // Endocrine mutations carried through (drive coupled state)
            auto endo_maybe = oracle_endocrine_event(ev, cds);
            if (endo_maybe) { evts.push_back(*endo_maybe); continue; }

            // ECS events
            if (ev.rfind("regulate_", 0) == 0 ||
                ev.find("_regulate_") != std::string::npos) {
                evts.push_back(make_ecs_regulate(cds));
                continue;
            }
            if (ev.find("trauma_charge_") != std::string::npos) {
                float charge = 0.8f;
                std::sscanf(ev.c_str(), "%*[^_]_charge_%f", &charge);
                bool intend = (ev.find("intend_True") != std::string::npos);
                evts.push_back(make_ecs_trauma(charge, intend, cds));
                continue;
            }
            if (ev.find("recall_only") != std::string::npos) {
                evts.push_back(make_ecs_trauma(0.8f, false, cds));
                continue;
            }
            // Other rows: emit as READ_LEVELS with time advance
            FuzzEvent re{};
            re.kind     = static_cast<uint8_t>(FuzzEventKind::READ_LEVELS);
            re.clock_ds = cds;
            evts.push_back(re);
        }
        write_seed(corpus_dir, "oracle_full_replay", evts);
    }

    // ── Scenario 7: I1 stress — process_trauma at charge floor ───────────────
    {
        std::vector<FuzzEvent> evts;
        // Get into window first (start fresh, baseline tone ≥ 0.25, cortisol < 0.6)
        evts.push_back(make_ecs_regulate(0));
        evts.push_back(make_ecs_trauma(0.05f, true, 0));  // charge near CHARGE_FLOOR
        write_seed(corpus_dir, "i1_stress_near_charge_floor", evts);
    }

    std::fprintf(stdout, "Endocannabinoid seeds complete.\n\n");
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    if (argc < 5) {
        std::fprintf(stderr,
            "Usage: gen_fuzz_seeds <endocrine_corpus_dir> "
            "<endocannabinoid_corpus_dir> "
            "<endocrine_trace.csv> <endocannabinoid_trace.csv>\n");
        return 1;
    }

    const std::filesystem::path endocrine_dir     = argv[1];
    const std::filesystem::path endocannabinoid_dir = argv[2];
    const std::string            endocrine_csv     = argv[3];
    const std::string            endocannabinoid_csv = argv[4];

    gen_endocrine_seeds(endocrine_dir, endocrine_csv);
    gen_endocannabinoid_seeds(endocannabinoid_dir, endocannabinoid_csv);

    std::fprintf(stdout, "gen_fuzz_seeds: done.\n");
    return 0;
}
