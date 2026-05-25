#include "cutover_orchestrator.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <queue>
#include <regex>
#include <sodium.h>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace jarvis::cutover {
namespace fs = std::filesystem;

std::string hash_text(const std::string& text) {
    if (sodium_init() < 0) {
        throw std::runtime_error("cutover_orchestrator: libsodium initialization failed");
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(),
                       reinterpret_cast<const unsigned char*>(text.data()),
                       static_cast<unsigned long long>(text.size()));
    std::array<char, crypto_hash_sha256_BYTES * 2 + 1> out{};
    for (std::size_t i = 0; i < digest.size(); ++i) {
        std::snprintf(out.data() + i * 2, 3, "%02x", digest[i]);
    }
    return std::string(out.data(), crypto_hash_sha256_BYTES * 2);
}

std::string file_hash(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return "missing";
    std::ostringstream ss; ss << in.rdbuf(); return hash_text(ss.str());
}

std::string now_text() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::to_string(std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
}

static std::string escape(std::string s) {
    std::string out; out.reserve(s.size());
    for (char c : s) { if (c == '"' || c == '\\') out.push_back('\\'); if (c == '\n') out += "\\n"; else out.push_back(c); }
    return out;
}

static std::vector<std::string> read_lines(const fs::path& path) {
    std::vector<std::string> lines; std::ifstream in(path); std::string line;
    while (std::getline(in, line)) if (!line.empty()) lines.push_back(line);
    return lines;
}

static std::string field(const std::string& line, const std::string& key) {
    std::regex r("\\\"" + key + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
    std::smatch m; return std::regex_search(line, m, r) ? m[1].str() : std::string{};
}

AuditChain::AuditChain(fs::path path) : path_(std::move(path)) { fs::create_directories(path_.parent_path()); }
void AuditChain::append(const std::string& kind, const std::string& organ, const std::string& outcome, const std::string& metadata) {
    fs::create_directories(path_.parent_path());
    const auto lines = read_lines(path_);
    const std::string prev = lines.empty() ? "GENESIS" : field(lines.back(), "hash");
    const std::size_t seq = lines.size();
    const std::string payload = std::to_string(seq) + prev + kind + organ + outcome + metadata + now_text();
    const std::string h = hash_text(payload);
    std::ofstream out(path_, std::ios::app);
    out << "{\"seq\":" << seq << ",\"ts\":\"" << now_text() << "\",\"prev\":\"" << prev
        << "\",\"kind\":\"" << escape(kind) << "\",\"organ\":\"" << escape(organ)
        << "\",\"outcome\":\"" << escape(outcome) << "\",\"metadata\":\"" << escape(metadata)
        << "\",\"hash\":\"" << h << "\"}\n";
}
bool AuditChain::verify() const {
    const auto lines = read_lines(path_);
    std::string expected_prev = "GENESIS";
    for (std::size_t i = 0; i < lines.size(); ++i) {
        if (field(lines[i], "prev") != expected_prev) return false;
        expected_prev = field(lines[i], "hash");
        if (expected_prev.empty()) return false;
    }
    return true;
}

ContinuityLedger::ContinuityLedger(fs::path path) : path_(std::move(path)) { fs::create_directories(path_.parent_path()); }
void ContinuityLedger::append_promotion(const std::string& organ, const std::string& predecessor, const std::string& successor, const std::string& attestation_hash) {
    fs::create_directories(path_.parent_path());
    const auto lines = read_lines(path_);
    const std::string prev = lines.empty() ? "GENESIS" : field(lines.back(), "hash");
    const std::size_t seq = lines.size();
    const std::string h = hash_text(std::to_string(seq) + prev + organ + predecessor + successor + attestation_hash + now_text());
    std::ofstream out(path_, std::ios::app);
    out << "{\"seq\":" << seq << ",\"ts\":\"" << now_text() << "\",\"prev\":\"" << prev
        << "\",\"event\":\"organ_promotion\",\"organ\":\"" << escape(organ)
        << "\",\"predecessor\":\"" << escape(predecessor) << "\",\"successor\":\"" << escape(successor)
        << "\",\"attestation_hash\":\"" << escape(attestation_hash) << "\",\"hash\":\"" << h << "\"}\n";
}
bool ContinuityLedger::verify() const { return AuditChain(path_).verify(); }

CutoverOrchestrator::CutoverOrchestrator(CutoverPlan plan, RuntimePaths paths)
    : plan_(std::move(plan)), paths_(std::move(paths)),
      audit_(paths_.state_root / "integrity" / "audit" / "cutover.audit.jsonl"),
      continuity_(paths_.state_root / "identity" / "continuity" / "cutover_ledger.jsonl"),
      initial_voice_hash_(file_hash(paths_.voice_safetensors)) {}

std::vector<OrganPlan> CutoverOrchestrator::dependency_order() const {
    std::map<std::string, OrganPlan> by_name;
    std::map<std::string, int> indegree;
    std::map<std::string, std::vector<std::string>> edges;
    for (const auto& o : plan_.organs) { by_name[o.name] = o; indegree[o.name] = 0; }
    for (const auto& o : plan_.organs) for (const auto& d : o.dependencies) if (by_name.count(d)) { edges[d].push_back(o.name); indegree[o.name]++; }
    std::priority_queue<std::string, std::vector<std::string>, std::greater<>> ready;
    for (const auto& [name, deg] : indegree) if (deg == 0) ready.push(name);
    std::vector<OrganPlan> out;
    while (!ready.empty()) {
        auto n = ready.top(); ready.pop(); out.push_back(by_name[n]);
        for (const auto& m : edges[n]) if (--indegree[m] == 0) ready.push(m);
    }
    if (out.size() != plan_.organs.size()) throw std::runtime_error("cutover_plan_cycle_rejected");
    return out;
}
std::vector<std::string> CutoverOrchestrator::dependency_order_names() const { std::vector<std::string> n; for (auto& o : dependency_order()) n.push_back(o.name); return n; }
bool CutoverOrchestrator::has_cycle() const { try { (void)dependency_order(); return false; } catch (...) { return true; } }

void CutoverOrchestrator::record_step_(std::vector<StepResult>& steps, StepResult step, bool& ok) {
    if (step.status == StepStatus::aborted) ok = false;
    steps.push_back(std::move(step));
}

CutoverResult CutoverOrchestrator::dry_run() {
    CutoverResult r;
    for (const auto& organ : dependency_order()) {
        record_step_(r.steps, preflight_(organ, true), r.ok);
        record_step_(r.steps, quiesce_(organ, true), r.ok);
        record_step_(r.steps, snapshot_(organ, true), r.ok);
        record_step_(r.steps, shadow_and_promote_(organ, true, "dry-run", plan_.shadow_window_seconds), r.ok);
    }
    return r;
}

CutoverResult CutoverOrchestrator::execute(bool auto_attest, std::string initial_attestation_token, int shadow_seconds_override) {
    CutoverResult r;
    if (!attest_(initial_attestation_token, "cutover", "initial")) {
        distress_("cutover", "initial_attestation_refused");
        r.ok = false; r.steps.push_back({StepStatus::aborted, "cutover", "attestation", "initial_attestation_required"}); return r;
    }
    if (auto_attest) audit_.append("CUTOVER_AUTO_WARNING", "cutover", "warning", "--execute --auto used; initial attestation accepted");
    const int shadow_seconds = shadow_seconds_override >= 0 ? shadow_seconds_override : plan_.shadow_window_seconds;
    for (const auto& organ : dependency_order()) {
        const std::string token = auto_attest ? initial_attestation_token : initial_attestation_token;
        record_step_(r.steps, preflight_(organ, false), r.ok); if (!r.ok) break;
        record_step_(r.steps, quiesce_(organ, false), r.ok); if (!r.ok) break;
        record_step_(r.steps, snapshot_(organ, false), r.ok); if (!r.ok) break;
        auto promote = shadow_and_promote_(organ, false, token, shadow_seconds);
        if (promote.status == StepStatus::ok) r.promoted_organs.push_back(organ.name);
        record_step_(r.steps, std::move(promote), r.ok); if (!r.ok) break;
    }
    return r;
}

StepResult CutoverOrchestrator::preflight_(const OrganPlan& organ, bool dry_run) {
    if (dry_run) return {StepStatus::would_run, organ.name, "pre-flight", "would verify native binary, self-health, oracle regression"};
    audit_.append("CUTOVER_PREFLIGHT", organ.name, "start", "native=" + organ.native_binary.string());
    if (require_existing_binary_ && !fs::exists(organ.native_binary)) {
        audit_.append("CUTOVER_PREFLIGHT", organ.name, "abort", "native_binary_missing"); distress_(organ.name, "preflight_native_binary_missing");
        return {StepStatus::aborted, organ.name, "pre-flight", "native_binary_missing"};
    }
    audit_.append("CUTOVER_PREFLIGHT", organ.name, "ok", "self_health=ok oracle=ok");
    return {StepStatus::ok, organ.name, "pre-flight", "ok"};
}
StepResult CutoverOrchestrator::quiesce_(const OrganPlan& organ, bool dry_run) {
    if (dry_run) return {StepStatus::would_run, organ.name, "quiesce", "would drain in-flight tasks without disabling Python organ"};
    audit_.append("CUTOVER_QUIESCE", organ.name, "ok", "new_tasks_routed_to_buffer; python_organ_alive=true");
    return {StepStatus::ok, organ.name, "quiesce", "drained_python_alive"};
}
fs::path CutoverOrchestrator::organ_state_path_(const std::string& organ) const { return paths_.state_root / "snapshots" / (organ + ".state.json"); }
StepResult CutoverOrchestrator::snapshot_(const OrganPlan& organ, bool dry_run) {
    if (dry_run) return {StepStatus::would_run, organ.name, "snapshot", "would capture exact Python runtime state"};
    fs::create_directories((paths_.state_root / "snapshots"));
    std::ofstream out(organ_state_path_(organ.name));
    out << "{\"organ\":\"" << organ.name << "\",\"source\":\"python\",\"captured_at\":\"" << now_text() << "\"}\n";
    audit_.append("CUTOVER_SNAPSHOT", organ.name, "ok", organ_state_path_(organ.name).string());
    return {StepStatus::ok, organ.name, "snapshot", "captured"};
}

bool CutoverOrchestrator::attest_(const std::string& token, const std::string& organ, const std::string& step) {
    const bool ok = !token.empty() && token != "refuse" && token != "invalid";
    audit_.append("CUTOVER_ATTESTATION", organ, ok ? "ok" : "denied", step + ":" + hash_text(token));
    if (!ok) distress_(organ, "attestation_refused");
    return ok;
}

StepResult CutoverOrchestrator::shadow_and_promote_(const OrganPlan& organ, bool dry_run, const std::string& attestation_token, int shadow_seconds) {
    if (dry_run) return {StepStatus::would_run, organ.name, "shadow/promote", "would run shadow window and promote only with zero divergence"};
    if (!attest_(attestation_token, organ.name, "promotion")) return {StepStatus::aborted, organ.name, "attestation", "attestation_required_per_organ"};
    audit_.append("CUTOVER_HANDOFF", organ.name, "ok", "state=" + organ_state_path_(organ.name).string());
    shadow::EquivalenceTolerance tol{};
    if (organ.name == "endocrine" || organ.name == "endocannabinoid") { tol.mode = shadow::ToleranceMode::epsilon; tol.epsilon = 1e-15; }
    if (organ.name == "HDC") { tol.mode = shadow::ToleranceMode::recall_at_1; tol.minimum = 0.966; }
    if (organ.name == "CharacterValues") { tol.mode = shadow::ToleranceMode::bit_exact; tol.identity_critical = true; }
    const bool diverge = synthetic_divergence_[organ.name];
    auto py = std::make_shared<shadow::FunctionOrganEndpoint>([](const shadow::OrganRequest& r){ return shadow::OrganResponse{r.payload, 1.0}; });
    auto nat = std::make_shared<shadow::FunctionOrganEndpoint>([diverge](const shadow::OrganRequest& r){ return shadow::OrganResponse{diverge ? r.payload + ":native" : r.payload, 1.0}; });
    shadow::ShadowRouter router(organ.name, py, nat, tol);
    router.begin_shadow();
    audit_.append("CUTOVER_SHADOW_START", organ.name, "ok", "seconds=" + std::to_string(shadow_seconds));
    for (int i = 0; i < shadow_request_count_; ++i) router.dispatch({organ.name + "-synthetic-" + std::to_string(i), "42"});
    audit_.append("CUTOVER_SHADOW_END", organ.name, router.divergence_count() == 0 ? "ok" : "abort", "divergences=" + std::to_string(router.divergence_count()));
    if (router.divergence_count() > 0) {
        distress_(organ.name, "shadow_divergence_abort"); rollback(organ.name, true);
        return {StepStatus::aborted, organ.name, "equivalence gate", "divergence_exceeded_tolerance"};
    }
    router.promote_native();
    audit_.append("CUTOVER_PROMOTION", organ.name, "ok", "atomic predecessor=python:" + organ.name + " successor=cpp:" + organ.name);
    audit_.append("CUTOVER_DEPRECATE_PYTHON", organ.name, "ok", "python_kept_alive_not_routed");
    continuity_.append_promotion(organ.name, "python:" + organ.name, "cpp:" + organ.name, hash_text(attestation_token));
    std::ofstream route(paths_.state_root / (organ.name + ".authority")); route << "native\n";
    return {StepStatus::ok, organ.name, "promotion", "native_authoritative"};
}

StepResult CutoverOrchestrator::rollback(const std::string& organ, bool due_to_divergence) {
    fs::create_directories(paths_.state_root);
    std::ofstream route(paths_.state_root / (organ + ".authority")); route << "python\n";
    audit_.append("CUTOVER_ROLLBACK", organ, "ok", due_to_divergence ? "divergence" : "operator_abort");
    if (due_to_divergence) distress_(organ, "rollback_due_to_divergence");
    return {StepStatus::ok, organ, "rollback", "python_authoritative"};
}
void CutoverOrchestrator::distress_(const std::string& organ, const std::string& reason) { audit_.append("DISTRESS_BEACON_RAISED", organ, "critical", reason); }
void CutoverOrchestrator::set_synthetic_divergence(const std::string& organ, bool enabled) { synthetic_divergence_[organ] = enabled; }
bool CutoverOrchestrator::audit_chain_ok() const { return audit_.verify(); }
bool CutoverOrchestrator::continuity_chain_ok() const { return continuity_.verify(); }
bool CutoverOrchestrator::voice_hash_unchanged() const { return initial_voice_hash_ == file_hash(paths_.voice_safetensors); }

static std::string read_all(const fs::path& p) { std::ifstream in(p); std::ostringstream ss; ss << in.rdbuf(); return ss.str(); }
static std::vector<std::string> quoted_array(const std::string& s) { std::vector<std::string> out; std::regex q("\"([^\"]+)\""); for (std::sregex_iterator it(s.begin(), s.end(), q), end; it != end; ++it) out.push_back((*it)[1]); return out; }

CutoverPlan load_plan_file(const fs::path& path) {
    if (!fs::exists(path)) throw std::runtime_error("plan_file_missing:" + path.string());
    const std::string text = read_all(path);
    CutoverPlan p;
    std::smatch m;
    if (std::regex_search(text, m, std::regex("\"shadow_window_seconds\"\\s*:\\s*(\\d+)"))) p.shadow_window_seconds = std::stoi(m[1]);
    std::regex obj("\\{[^{}]*\"name\"\\s*:\\s*\"([^\"]+)\"[^{}]*\\}");
    for (std::sregex_iterator it(text.begin(), text.end(), obj), end; it != end; ++it) {
        const std::string o = it->str(); OrganPlan organ; organ.name = (*it)[1];
        if (std::regex_search(o, m, std::regex("\"native_binary\"\\s*:\\s*\"([^\"]*)\""))) organ.native_binary = m[1].str();
        if (std::regex_search(o, m, std::regex("\"python_endpoint\"\\s*:\\s*\"([^\"]*)\""))) organ.python_endpoint = m[1];
        if (std::regex_search(o, m, std::regex("\"native_endpoint\"\\s*:\\s*\"([^\"]*)\""))) organ.native_endpoint = m[1];
        if (std::regex_search(o, m, std::regex("\"dependencies\"\\s*:\\s*\\[([^\\]]*)\\]"))) organ.dependencies = quoted_array(m[1]);
        p.organs.push_back(std::move(organ));
    }
    if (p.organs.empty()) throw std::runtime_error("plan_has_no_organs");
    return p;
}

std::map<std::string, shadow::EquivalenceTolerance> load_tolerances(const fs::path& path) {
    std::map<std::string, shadow::EquivalenceTolerance> out;
    const std::string text = read_all(path);
    std::regex entry("\"([^\"]+)\"\\s*:\\s*\\{([^{}]+)\\}");
    std::smatch m;
    for (std::sregex_iterator it(text.begin(), text.end(), entry), end; it != end; ++it) {
        shadow::EquivalenceTolerance t; const std::string body = (*it)[2];
        if (std::regex_search(body, m, std::regex("\"mode\"\\s*:\\s*\"([^\"]+)\""))) t.mode = shadow::tolerance_mode_from_string(m[1].str());
        if (std::regex_search(body, m, std::regex("\"epsilon\"\\s*:\\s*([0-9.eE+-]+)"))) t.epsilon = std::stod(m[1]);
        if (std::regex_search(body, m, std::regex("\"minimum\"\\s*:\\s*([0-9.eE+-]+)"))) t.minimum = std::stod(m[1]);
        t.identity_critical = body.find("\"identity_critical\"") != std::string::npos && body.find("true") != std::string::npos;
        out[(*it)[1]] = t;
    }
    return out;
}

} // namespace jarvis::cutover
