#include "oracle_loader.h"
#include "endocrine.h"
#include "endocannabinoid.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using jarvis::Endocrine;
using jarvis::Endocannabinoid;
using jarvis::oracle::CsvRow;

#ifndef JARVIS_ORACLE_ROOT
#define JARVIS_ORACLE_ROOT "/Users/rbhanson/research/oracle"
#endif
#ifndef JARVIS_REGRESSION_OUTPUT_DIR
#define JARVIS_REGRESSION_OUTPUT_DIR "."
#endif
#ifndef JARVIS_REGRESSION_ENDOCRINE_ABS_TOL
#define JARVIS_REGRESSION_ENDOCRINE_ABS_TOL 1e-9
#endif
#ifndef JARVIS_REGRESSION_ECS_ABS_TOL
#define JARVIS_REGRESSION_ECS_ABS_TOL 1e-9
#endif
#ifndef JARVIS_REGRESSION_ECS_RAW_ABS_TOL
#define JARVIS_REGRESSION_ECS_RAW_ABS_TOL 1e-6
#endif
#ifndef JARVIS_REGRESSION_HDC_ABS_TOL
#define JARVIS_REGRESSION_HDC_ABS_TOL 0
#endif

struct DetClock {
    double t = 0.0;
};

struct Failure {
    std::string field;
    std::string context;
    double expected = 0.0;
    double actual = 0.0;
    double drift = 0.0;
    double threshold = 0.0;
};

struct OrganResult {
    std::string organ;
    std::string oracle_dir;
    std::string cpp_subject;
    std::string status;
    std::string reason;
    int cases = 0;
    int failures = 0;
    double worst_drift = 0.0;
    double threshold = 0.0;
    std::vector<Failure> details;
};

static std::string json_escape(const std::string& s) {
    std::ostringstream o;
    for (char c : s) {
        switch (c) {
            case '\\': o << "\\\\"; break;
            case '"': o << "\\\""; break;
            case '\n': o << "\\n"; break;
            case '\r': o << "\\r"; break;
            case '\t': o << "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    o << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                      << static_cast<int>(static_cast<unsigned char>(c));
                } else {
                    o << c;
                }
        }
    }
    return o.str();
}

static bool present(const fs::path& p) { return fs::exists(p); }

static void record_compare(OrganResult& result, const std::string& field,
                           const std::string& context, double expected,
                           double actual, double threshold) {
    if (std::isnan(expected)) return;
    const double drift = std::abs(expected - actual);
    result.worst_drift = std::max(result.worst_drift, drift);
    if (drift > threshold) {
        ++result.failures;
        result.details.push_back({field, context, expected, actual, drift, threshold});
    }
}

static double value_after_token(const std::string& ev, const std::string& token, double missing = 0.0) {
    const auto pos = ev.find(token);
    if (pos == std::string::npos) return missing;
    std::string rest = ev.substr(pos + token.size());
    size_t end = 0;
    if (end < rest.size() && (rest[end] == '-' || rest[end] == '+')) ++end;
    while (end < rest.size() && (std::isdigit(static_cast<unsigned char>(rest[end])) || rest[end] == '.')) ++end;
    if (end == 0 || (end == 1 && (rest[0] == '-' || rest[0] == '+'))) return missing;
    return std::stod(rest.substr(0, end));
}

static bool has_token(const std::string& s, const std::string& token) {
    return s.find(token) != std::string::npos;
}

static void apply_endocrine_event(Endocrine& endo, const std::string& ev) {
    if (ev == "on_rest") { endo.on_rest(); return; }
    const bool ends_digit = !ev.empty() && std::isdigit(static_cast<unsigned char>(ev.back()));
    if (ends_digit && ev.rfind("on_threat_", 0) == 0) { endo.on_threat(value_after_token(ev, "on_threat_")); return; }
    if (ends_digit && ev.rfind("on_success_", 0) == 0) { endo.on_success(value_after_token(ev, "on_success_")); return; }
    if (ends_digit && ev.rfind("on_deadline_", 0) == 0) { endo.on_deadline(value_after_token(ev, "on_deadline_")); return; }
    if (has_token(ev, "multi_spike_c")) {
        endo.stimulus(value_after_token(ev, "_c+"), value_after_token(ev, "_d+"), value_after_token(ev, "_a+"));
        return;
    }
    if (has_token(ev, "spike_+")) {
        const double v = value_after_token(ev, "spike_+");
        if (has_token(ev, "cortisol")) { endo.stimulus(v, 0.0, 0.0); return; }
        if (has_token(ev, "dopamine")) { endo.stimulus(0.0, v, 0.0); return; }
        if (has_token(ev, "adrenaline")) { endo.stimulus(0.0, 0.0, v); return; }
    }
    if (has_token(ev, "suppress_")) {
        const double v = value_after_token(ev, "suppress_");
        if (has_token(ev, "cortisol")) { endo.stimulus(v, 0.0, 0.0); return; }
        if (has_token(ev, "dopamine")) { endo.stimulus(0.0, v, 0.0); return; }
        if (has_token(ev, "adrenaline")) { endo.stimulus(0.0, 0.0, v); return; }
    }
}

static OrganResult run_endocrine(const fs::path& oracle_dir) {
    OrganResult out;
    out.organ = "endocrine";
    out.oracle_dir = oracle_dir.string();
    out.cpp_subject = "jarvis_endocrine";
    out.status = "pass";
    out.threshold = JARVIS_REGRESSION_ENDOCRINE_ABS_TOL;

    const fs::path trace = oracle_dir / "endocrine_trace.csv";
    if (!present(trace)) {
        out.status = "fail";
        out.reason = "missing endocrine_trace.csv";
        out.failures = 1;
        return out;
    }

    DetClock clk;
    Endocrine endo([&clk] { return clk.t; });
    const auto rows = jarvis::oracle::load_csv(trace.string());
    out.cases = static_cast<int>(rows.size());

    int row_index = 0;
    for (const auto& row : rows) {
        ++row_index;
        const double t = row.get_double("t");
        if (!std::isnan(t) && t >= clk.t) clk.t = t;
        const std::string event = row.get("event");
        apply_endocrine_event(endo, event);

        const double c = endo.level("cortisol");
        const double d = endo.level("dopamine");
        const double a = endo.level("adrenaline");
        const double fv = endo.field_volatility();
        std::ostringstream ctx;
        ctx << "row=" << row_index << " t=" << t << " event=" << event;
        record_compare(out, "cortisol", ctx.str(), row.get_double("cortisol"), c, out.threshold);
        record_compare(out, "dopamine", ctx.str(), row.get_double("dopamine"), d, out.threshold);
        record_compare(out, "adrenaline", ctx.str(), row.get_double("adrenaline"), a, out.threshold);
        record_compare(out, "field_volatility", ctx.str(), row.get_double("field_volatility"), fv, out.threshold);
    }
    if (out.failures > 0) out.status = "fail";
    return out;
}

struct EcsEventResult {
    bool did_regulate = false;
    Endocannabinoid::RegulationResult reg{};
    bool did_trauma = false;
    Endocannabinoid::TraumaResult trauma{};
};

static EcsEventResult apply_ecs_event(Endocannabinoid& ecs, Endocrine& endo, const CsvRow& row) {
    const std::string ev = row.get("event");
    EcsEventResult res;
    auto starts = [&](const std::string& token) { return ev.rfind(token, 0) == 0; };

    if (starts("regulate") || has_token(ev, "enter_window_regulate")) {
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        return res;
    }
    if (has_token(ev, "endo_on_threat_") || has_token(ev, "flood_force_threat_")) {
        endo.on_threat(value_after_token(ev, "_threat_"));
        return res;
    }
    if (has_token(ev, "high_stress_spike_c")) {
        double dc = 0.0;
        double da = 0.0;
        const auto pc = ev.find("_c");
        if (pc != std::string::npos) {
            const size_t end = ev.find('_', pc + 2);
            dc = std::stod(ev.substr(pc + 2, (end == std::string::npos ? ev.size() : end) - pc - 2));
        }
        const auto pa = ev.find("_a");
        if (pa != std::string::npos) da = std::stod(ev.substr(pa + 2));
        endo.stimulus(dc, 0.0, da);
        return res;
    }
    if (has_token(ev, "I1_safe_extinction")) {
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(row.get_double("charge_before"), endo, true);
        return res;
    }
    if (has_token(ev, "recall_only_in_window")) {
        res.did_regulate = true;
        res.reg = ecs.regulate(endo);
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(row.get_double("charge_before"), endo, false);
        return res;
    }
    if (has_token(ev, "I2_flooded_trauma") || has_token(ev, "recall_only_flooded")) {
        res.did_trauma = true;
        res.trauma = ecs.process_trauma(row.get_double("charge_before"), endo, !has_token(ev, "intend_False"));
        return res;
    }
    return res;
}

static void record_bool(OrganResult& out, const std::string& field, const std::string& context, bool expected, bool actual) {
    if (expected != actual) {
        ++out.failures;
        out.details.push_back({field, context, expected ? 1.0 : 0.0, actual ? 1.0 : 0.0, 1.0, 0.0});
        out.worst_drift = std::max(out.worst_drift, 1.0);
    }
}

static OrganResult run_endocannabinoid(const fs::path& oracle_dir) {
    OrganResult out;
    out.organ = "endocannabinoid";
    out.oracle_dir = oracle_dir.string();
    out.cpp_subject = "jarvis_endocrine::Endocannabinoid";
    out.status = "pass";
    out.threshold = std::max(static_cast<double>(JARVIS_REGRESSION_ECS_ABS_TOL),
                             static_cast<double>(JARVIS_REGRESSION_ECS_RAW_ABS_TOL));

    const fs::path trace = oracle_dir / "endocannabinoid_trace.csv";
    if (!present(trace)) {
        out.status = "fail";
        out.reason = "missing endocannabinoid_trace.csv";
        out.failures = 1;
        return out;
    }

    DetClock clk;
    auto clock = [&clk] { return clk.t; };
    Endocrine endo(clock);
    Endocannabinoid ecs(clock);
    const auto rows = jarvis::oracle::load_csv(trace.string());
    out.cases = static_cast<int>(rows.size());

    int row_index = 0;
    for (const auto& row : rows) {
        ++row_index;
        clk.t = row.get_double("t");
        const auto event_result = apply_ecs_event(ecs, endo, row);

        const double tone = ecs.tone();
        const double aea = ecs.aea_raw();
        const double ag = ecs.ag_raw();
        const bool window = ecs.within_window(endo);
        const double c = endo.level("cortisol");
        const double a = endo.level("adrenaline");

        std::ostringstream ctx;
        ctx << "row=" << row_index << " t=" << row.get("t") << " event=" << row.get("event");
        record_compare(out, "tone", ctx.str(), row.get_double("tone"), tone, JARVIS_REGRESSION_ECS_ABS_TOL);
        record_compare(out, "aea", ctx.str(), row.get_double("aea"), aea, JARVIS_REGRESSION_ECS_RAW_ABS_TOL);
        record_compare(out, "ag", ctx.str(), row.get_double("ag"), ag, JARVIS_REGRESSION_ECS_RAW_ABS_TOL);
        if (row.has("within_window")) record_bool(out, "within_window", ctx.str(), row.get_bool("within_window"), window);
        record_compare(out, "cortisol", ctx.str(), row.get_double("cortisol"), c, JARVIS_REGRESSION_ECS_ABS_TOL);
        record_compare(out, "adrenaline", ctx.str(), row.get_double("adrenaline"), a, JARVIS_REGRESSION_ECS_ABS_TOL);
        if (event_result.did_regulate) {
            record_compare(out, "released_2ag", ctx.str(), row.get_double("released_2ag"), event_result.reg.released_2ag, JARVIS_REGRESSION_ECS_ABS_TOL);
        }
        if (event_result.did_trauma) {
            record_compare(out, "charge_before", ctx.str(), row.get_double("charge_before"), event_result.trauma.charge_before, JARVIS_REGRESSION_ECS_ABS_TOL);
            record_compare(out, "charge_after", ctx.str(), row.get_double("charge_after"), event_result.trauma.charge_after, JARVIS_REGRESSION_ECS_ABS_TOL);
            record_compare(out, "recalled_intensity", ctx.str(), row.get_double("recalled_intensity"), event_result.trauma.recalled_intensity, JARVIS_REGRESSION_ECS_ABS_TOL);
            if (row.has("processed")) record_bool(out, "processed", ctx.str(), row.get_bool("processed"), event_result.trauma.processed);
        }
    }
    if (out.failures > 0) out.status = "fail";
    return out;
}

static OrganResult stub_result(const std::string& organ, const fs::path& oracle_dir,
                               const std::string& cpp_subject, const std::string& reason,
                               double threshold) {
    OrganResult out;
    out.organ = organ;
    out.oracle_dir = oracle_dir.string();
    out.cpp_subject = cpp_subject;
    out.status = "stub";
    out.reason = reason;
    out.threshold = threshold;
    return out;
}

static void write_json(const std::vector<OrganResult>& results, const fs::path& path) {
    std::ofstream f(path);
    f << std::setprecision(17);
    int passed = 0, failed = 0, stubbed = 0;
    for (const auto& r : results) {
        if (r.status == "pass") ++passed;
        else if (r.status == "fail") ++failed;
        else ++stubbed;
    }
    f << "{\n";
    f << "  \"schema\": \"jarvis.oracle_regression.v1\",\n";
    f << "  \"oracle_root\": \"" << json_escape(JARVIS_ORACLE_ROOT) << "\",\n";
    f << "  \"summary\": {\"passed\": " << passed << ", \"failed\": " << failed << ", \"stubbed\": " << stubbed << "},\n";
    f << "  \"thresholds\": {\n";
    f << "    \"endocrine_abs\": " << static_cast<double>(JARVIS_REGRESSION_ENDOCRINE_ABS_TOL) << ",\n";
    f << "    \"endocannabinoid_abs\": " << static_cast<double>(JARVIS_REGRESSION_ECS_ABS_TOL) << ",\n";
    f << "    \"endocannabinoid_raw_abs\": " << static_cast<double>(JARVIS_REGRESSION_ECS_RAW_ABS_TOL) << ",\n";
    f << "    \"hdc_abs\": " << static_cast<double>(JARVIS_REGRESSION_HDC_ABS_TOL) << "\n";
    f << "  },\n";
    f << "  \"organs\": [\n";
    for (size_t i = 0; i < results.size(); ++i) {
        const auto& r = results[i];
        f << "    {\n";
        f << "      \"organ\": \"" << json_escape(r.organ) << "\",\n";
        f << "      \"status\": \"" << json_escape(r.status) << "\",\n";
        f << "      \"oracle_dir\": \"" << json_escape(r.oracle_dir) << "\",\n";
        f << "      \"cpp_subject\": \"" << json_escape(r.cpp_subject) << "\",\n";
        f << "      \"cases\": " << r.cases << ",\n";
        f << "      \"failures\": " << r.failures << ",\n";
        f << "      \"worst_drift\": " << r.worst_drift << ",\n";
        f << "      \"threshold\": " << r.threshold << ",\n";
        f << "      \"reason\": \"" << json_escape(r.reason) << "\",\n";
        f << "      \"failure_details\": [";
        for (size_t j = 0; j < r.details.size(); ++j) {
            const auto& d = r.details[j];
            if (j) f << ",";
            f << "{\"field\":\"" << json_escape(d.field) << "\","
              << "\"context\":\"" << json_escape(d.context) << "\","
              << "\"expected\":" << d.expected << ","
              << "\"actual\":" << d.actual << ","
              << "\"drift\":" << d.drift << ","
              << "\"threshold\":" << d.threshold << "}";
        }
        f << "]\n";
        f << "    }" << (i + 1 == results.size() ? "" : ",") << "\n";
    }
    f << "  ]\n";
    f << "}\n";
}

static void write_report(const std::vector<OrganResult>& results, const fs::path& path) {
    std::ofstream f(path);
    f << "JARVIS native runtime oracle regression report\n";
    f << "Oracle root: " << JARVIS_ORACLE_ROOT << "\n\n";
    for (const auto& r : results) {
        f << "- " << r.organ << ": " << r.status
          << " cases=" << r.cases
          << " failures=" << r.failures
          << " worst_drift=" << std::setprecision(17) << r.worst_drift
          << " threshold=" << r.threshold;
        if (!r.reason.empty()) f << " reason=" << r.reason;
        f << "\n";
        for (const auto& d : r.details) {
            f << "    * " << d.field << " " << d.context
              << " expected=" << d.expected
              << " actual=" << d.actual
              << " drift=" << d.drift
              << " threshold=" << d.threshold << "\n";
        }
    }
}

int main() {
    const fs::path oracle_root = JARVIS_ORACLE_ROOT;
    const fs::path output_dir = JARVIS_REGRESSION_OUTPUT_DIR;
    fs::create_directories(output_dir);

    std::vector<OrganResult> results;
    const fs::path endocrine_oracle = oracle_root / "endocrine";
    results.push_back(run_endocrine(endocrine_oracle));
    results.push_back(run_endocannabinoid(present(oracle_root / "endocannabinoid") ? (oracle_root / "endocannabinoid") : endocrine_oracle));

    results.push_back(stub_result("holograph", oracle_root / "holograph", "jarvis_hdc", "HoloGraph/HDC 153-suite stub: activate replay when HDC oracle adapter lands", JARVIS_REGRESSION_HDC_ABS_TOL));
    results.push_back(stub_result("pheromind", oracle_root / "pheromind", "jarvis_pheromind", "stub harness reserved for field_traces/coupling_trace replay", 1e-9));
    results.push_back(stub_result("swarm", oracle_root / "swarm", "jarvis_swarm", "stub harness reserved for 12 swarm decision fixtures", 0.0));
    results.push_back(stub_result("voice", oracle_root / "voice", "jarvis_voice", "stub harness reserved for 50 prompt/audio oracle set", 0.0));
    results.push_back(stub_result("loop", oracle_root / "loop", "jarvis_loop", "stub harness reserved for end-to-end loop replay", 0.0));
    results.push_back(stub_result("drift", oracle_root / "drift", "jarvis_drift", "stub harness reserved for drift oracle replay", 1e-9));
    results.push_back(stub_result("hmem", oracle_root / "holograph", "jarvis_hmem", "stub harness reserved for memory organ port", 0.0));
    results.push_back(stub_result("sage", oracle_root / "loop", "jarvis_sage", "stub harness reserved for reasoning organ port", 0.0));
    results.push_back(stub_result("character_values", oracle_root / "loop", "jarvis_character_values", "stub harness reserved for values organ port", 0.0));

    const fs::path json_path = output_dir / "regression_results.json";
    const fs::path report_path = output_dir / "regression_report.txt";
    write_json(results, json_path);
    write_report(results, report_path);

    int failures = 0;
    std::cout << "JARVIS oracle regression results\n";
    for (const auto& r : results) {
        std::cout << "  " << r.organ << ": " << r.status
                  << " cases=" << r.cases
                  << " failures=" << r.failures
                  << " worst_drift=" << std::setprecision(17) << r.worst_drift << "\n";
        if (r.status == "fail") ++failures;
    }
    std::cout << "JSON: " << json_path << "\n";
    std::cout << "Report: " << report_path << "\n";
    return failures == 0 ? 0 : 1;
}
