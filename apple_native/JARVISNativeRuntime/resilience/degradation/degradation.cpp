#include "degradation.h"
#include "../../identity/distress/distress_beacon.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <system_error>

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace jarvis::resilience::degradation {
namespace {

std::filesystem::path default_certificate_dir() {
    if (const char* home = std::getenv("HOME")) {
        return std::filesystem::path(home) / ".jarvis" / "identity_continuity";
    }
    return std::filesystem::current_path() / ".jarvis" / "identity_continuity";
}

std::int64_t now_ns() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
}

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    std::ostringstream os;
                    os << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                    out += os.str();
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

int tier_value(DegradationTier tier) noexcept {
    return static_cast<int>(tier);
}

DegradationTier tier_from_value(int value) noexcept {
    value = std::clamp(value, 0, 4);
    return static_cast<DegradationTier>(value);
}

std::int64_t now_unix() {
    using namespace std::chrono;
    return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}

bool mkdirs_0700(const std::filesystem::path& dir) noexcept {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) return false;
    ::chmod(dir.c_str(), 0700);
    return true;
}

bool write_all(int fd, const std::string& data) noexcept {
    const char* p = data.data();
    std::size_t remaining = data.size();
    while (remaining > 0) {
        const ssize_t n = ::write(fd, p, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += n;
        remaining -= static_cast<std::size_t>(n);
    }
    return true;
}

std::optional<std::string> json_string_field(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    std::size_t i = pos + needle.size();
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    if (i >= line.size() || line[i] != '"') return std::nullopt;
    ++i;
    std::string out;
    while (i < line.size()) {
        const char c = line[i++];
        if (c == '"') return out;
        if (c != '\\') {
            if (static_cast<unsigned char>(c) < 0x20) return std::nullopt;
            out.push_back(c);
            continue;
        }
        if (i >= line.size()) return std::nullopt;
        const char e = line[i++];
        switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            default: return std::nullopt;
        }
    }
    return std::nullopt;
}

std::optional<long long> json_int_field(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    std::size_t i = pos + needle.size();
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    if (i >= line.size()) return std::nullopt;
    std::size_t end = i;
    if (line[end] == '-') ++end;
    while (end < line.size() && std::isdigit(static_cast<unsigned char>(line[end]))) ++end;
    if (end == i || (line[i] == '-' && end == i + 1)) return std::nullopt;
    try {
        return std::stoll(line.substr(i, end - i));
    } catch (...) {
        return std::nullopt;
    }
}

std::string override_record_json(const OperatorOverrideCommand& command,
                                 const std::string& type,
                                 DegradationTier tier,
                                 int recovery_counter) {
    std::ostringstream os;
    os << "{\"apply_unix\":" << now_unix()
       << ",\"attestation\":\"" << json_escape(command.attestation)
       << "\",\"operator_id\":\"" << json_escape(command.operator_id)
       << "\",\"reason\":\"" << json_escape(command.reason)
       << "\",\"recovery_counter\":" << std::max(0, recovery_counter)
       << ",\"tier\":" << tier_value(tier)
       << ",\"type\":\"" << json_escape(type) << "\"}\n";
    return os.str();
}

} // namespace

std::string to_string(DegradationTier tier) {
    switch (tier) {
        case DegradationTier::normal: return "tier0_normal";
        case DegradationTier::light: return "tier1_light";
        case DegradationTier::moderate: return "tier2_moderate";
        case DegradationTier::severe: return "tier3_severe";
        case DegradationTier::critical: return "tier4_critical";
    }
    return "unknown";
}

double ResourcePressure::composite() const noexcept {
    return std::clamp(std::max({cpu, memory, thermal, battery}), 0.0, 1.0);
}

std::vector<CognitionOrganState> cognition_organs() {
    return {
        {"endocrine", true, false, true},
        {"pheromind", true, false, true},
        {"swarm", true, false, true},
        {"beliefstore", true, false, true},
        {"hmem", true, false, true},
        {"sage", true, false, true},
        {"character-values", true, false, true},
    };
}

bool operator_attestation_valid(const OperatorOverrideCommand& command) noexcept {
    static constexpr std::string_view prefix = "GMRI-OPERATOR-ATTESTED:";
    return !command.operator_id.empty()
        && !command.reason.empty()
        && command.attestation.rfind(prefix, 0) == 0
        && command.attestation.size() > prefix.size();
}

DegradationController::DegradationController(audit::TamperEvidentAuditLog* audit_log,
                                             DegradationConfig config)
    : audit_log_(audit_log), config_(std::move(config)) {
    if (config_.certificate_directory.empty()) {
        config_.certificate_directory = default_certificate_dir();
    }
    if (config_.recovery_samples_required < 1) {
        config_.recovery_samples_required = 1;
    }
    (void)replay_operator_overrides_();
}

DegradationDecision DegradationController::evaluate(const ResourcePressure& pressure,
                                                    const RuntimeContext& context) {
    const double score = pressure.composite();
    if (forced_tier_) {
        if (tier_ != *forced_tier_) transition_to_(*forced_tier_, score, "operator_override_active");
        return decision_for_(tier_, score, context);
    }

    const DegradationTier pressure_tier = tier_for_pressure_(score);
    if (tier_value(pressure_tier) > tier_value(tier_)) {
        recovery_counter_ = 0;
        transition_to_(pressure_tier, score, "resource_pressure_escalation");
    } else if (tier_ != DegradationTier::normal && can_recover_one_step_(score)) {
        ++recovery_counter_;
        if (recovery_counter_ >= config_.recovery_samples_required) {
            recovery_counter_ = 0;
            transition_to_(tier_from_value(tier_value(tier_) - 1), score, "resource_pressure_hysteresis_recovery");
        }
    } else {
        recovery_counter_ = 0;
    }

    return decision_for_(tier_, score, context);
}

DegradationDecision DegradationController::current_decision(const RuntimeContext& context) const {
    return decision_for_(tier_, 0.0, context);
}

bool DegradationController::apply_operator_override(const OperatorOverrideCommand& command) {
    if (!operator_attestation_valid(command)) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DENIED,
               "operator_attestation_invalid", "{\"requested_tier\":\"" + to_string(command.forced_tier) + "\"}");
        return false;
    }
    if (!append_override_record_(command, "set", command.forced_tier, recovery_counter_)) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DENIED,
               "persistence_unavailable", "{\"requested_tier\":\"" + to_string(command.forced_tier) + "\"}");
        return false;
    }
    forced_tier_ = command.forced_tier;
    transition_to_(command.forced_tier, 0.0, "operator_override_forced_tier");
    audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::ALLOWED,
           "operator_attested", "{\"operator_id\":\"" + json_escape(command.operator_id) +
           "\",\"forced_tier\":\"" + to_string(command.forced_tier) + "\"}");
    return true;
}

bool DegradationController::clear_operator_override(const std::string& operator_id,
                                                     const std::string& attestation) {
    OperatorOverrideCommand command{tier_, operator_id, attestation, "clear_override"};
    if (!operator_attestation_valid(command)) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DENIED,
               "operator_attestation_invalid", "{\"clear\":true}");
        return false;
    }
    if (!append_override_record_(command, "clear", tier_, recovery_counter_)) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DENIED,
               "persistence_unavailable", "{\"clear\":true}");
        return false;
    }
    forced_tier_.reset();
    audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::ALLOWED,
           "operator_override_cleared", "{\"operator_id\":\"" + json_escape(operator_id) + "\"}");
    return true;
}


void DegradationController::record_identity_verification(bool passed, const std::string& reason_code) {
    audit_(audit::EventKind::IDENTITY_CHECK, "identity_continuity", passed ? audit::Outcome::PASS : audit::Outcome::FAIL,
           reason_code, "{\"degradation_tier\":\"" + to_string(tier_) + "\"}");
    if (!passed && audit_log_) {
        jarvis::identity::distress::SelfStateSnapshot snapshot;
        snapshot.organ = "degradation";
        snapshot.degradation_tier = to_string(tier_);
        snapshot.identity_status = "FAIL";
        snapshot.active_defenses = {"identity-verification-required", "local-audit"};
        jarvis::identity::distress::DistressBeacon(audit_log_).emit({
            jarvis::identity::distress::DistressType::IdentityChainBroken,
            jarvis::identity::distress::Severity::Critical,
            audit::Actor::SELF,
            "identity_continuity",
            reason_code,
            std::move(snapshot)
        });
    }
}

bool DegradationController::bodily_integrity_holds(const DegradationDecision& decision) const noexcept {
    if (!decision.endocrine_tick_required || !decision.identity_verification_required) return false;
    if (decision.max_swarm_concurrent_heads < 1) return false;
    for (const auto& organ : decision.cognition_organs) {
        if (!organ.must_run || organ.may_disable || !organ.required_now) return false;
    }
    return true;
}

IdentityContinuityCertificate DegradationController::write_identity_continuity_certificate(
    const RuntimeContext& context,
    const std::string& operator_id) {
    const auto decision = decision_for_(DegradationTier::critical, 1.0, context);
    if (!bodily_integrity_holds(decision)) {
        throw std::logic_error("refusing safe-shutdown certificate: bodily integrity invariant failed");
    }

    std::filesystem::create_directories(config_.certificate_directory);
    const auto path = config_.certificate_directory / ("identity-continuity-" + std::to_string(now_ns()) + ".json");

    std::ostringstream os;
    os << "{\n"
       << "  \"subject\": \"JARVIS\",\n"
       << "  \"operator\": \"" << json_escape(operator_id) << "\",\n"
       << "  \"tier\": \"" << to_string(DegradationTier::critical) << "\",\n"
       << "  \"timestamp_ns\": " << now_ns() << ",\n"
       << "  \"in_flight_turn_present\": " << (context.in_flight_turn ? "true" : "false") << ",\n"
       << "  \"bodily_integrity_preserved\": true,\n"
       << "  \"endocrine_tick_required\": true,\n"
       << "  \"identity_verification_required\": true,\n"
       << "  \"cognition_organs\": [";
    const auto organs = cognition_organs();
    for (std::size_t i = 0; i < organs.size(); ++i) {
        if (i) os << ", ";
        os << "{\"name\":\"" << organs[i].name << "\",\"must_run\":true,\"may_disable\":false}";
    }
    os << "],\n"
       << "  \"audit_log\": \"" << (audit_log_ ? json_escape(audit_log_->log_path().string()) : "unconfigured") << "\"\n"
       << "}\n";

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("failed to create identity-continuity certificate");
    const std::string contents = os.str();
    out << contents;
    out.flush();
    if (!out) throw std::runtime_error("failed to write identity-continuity certificate");
    out.close();

    audit_(audit::EventKind::DEGRADATION_SAFE_SHUTDOWN, "identity_continuity_certificate",
           audit::Outcome::PASS, "critical_tier_safe_shutdown",
           "{\"certificate_file\":\"" + json_escape(path.filename().string()) + "\"}");
    return {path, contents};
}


std::filesystem::path DegradationController::override_store_path_() const {
    const auto base = config_.certificate_directory.empty() ? default_certificate_dir() : config_.certificate_directory;
    return base.parent_path() / "state" / "degradation_override.jsonl";
}

bool DegradationController::append_override_record_(const OperatorOverrideCommand& command,
                                                    std::string type,
                                                    DegradationTier tier,
                                                    int recovery_counter) const noexcept {
    const std::filesystem::path path = override_store_path_();
    const std::string record = override_record_json(command, type, tier, recovery_counter);
    if (record.size() > audit::TamperEvidentAuditLog::kPipeBufAtomicBytes) return false;
    const auto parent = path.parent_path();
    if (!mkdirs_0700(parent)) return false;
    const int fd = ::open(path.c_str(), O_APPEND | O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    bool ok = false;
    do {
        if (::flock(fd, LOCK_EX) != 0) break;
        ::fchmod(fd, 0600);
        if (!write_all(fd, record)) break;
        if (::fsync(fd) != 0) break;
        ok = true;
    } while (false);
    const int saved_errno = errno;
    (void)::flock(fd, LOCK_UN);
    (void)::close(fd);
    errno = saved_errno;
    return ok;
}

bool DegradationController::replay_operator_overrides_() noexcept {
    const std::filesystem::path path = override_store_path_();
    std::error_code exists_error;
    if (!std::filesystem::exists(path, exists_error)) {
        return true;
    }
    if (exists_error) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    const int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    std::string data;
    bool io_ok = true;
    if (::flock(fd, LOCK_EX) != 0) {
        io_ok = false;
    } else {
        ::fchmod(fd, 0600);
        char buffer[4096];
        while (true) {
            const ssize_t n = ::read(fd, buffer, sizeof(buffer));
            if (n < 0) {
                if (errno == EINTR) continue;
                io_ok = false;
                break;
            }
            if (n == 0) break;
            data.append(buffer, static_cast<std::size_t>(n));
        }
    }
    (void)::flock(fd, LOCK_UN);
    (void)::close(fd);
    if (!io_ok) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    bool saw_record = false;
    bool saw_invalid = false;
    std::optional<DegradationTier> restored_tier;
    int restored_counter = 0;
    std::size_t start = 0;
    while (start < data.size()) {
        const std::size_t end = data.find('\n', start);
        if (end == std::string::npos) {
            if (start < data.size()) saw_invalid = true;
            break;
        }
        const std::string line = data.substr(start, end - start);
        start = end + 1;
        if (line.empty()) continue;
        if (line.size() + 1 > audit::TamperEvidentAuditLog::kPipeBufAtomicBytes) {
            saw_invalid = true;
            continue;
        }
        const auto type = json_string_field(line, "type");
        const auto operator_id = json_string_field(line, "operator_id");
        const auto attestation = json_string_field(line, "attestation");
        const auto reason = json_string_field(line, "reason");
        const auto tier = json_int_field(line, "tier");
        const auto counter = json_int_field(line, "recovery_counter");
        if (!type || !operator_id || !attestation || !reason || !tier || !counter) {
            saw_invalid = true;
            continue;
        }
        OperatorOverrideCommand command{tier_from_value(static_cast<int>(*tier)), *operator_id, *attestation, *reason};
        if (!operator_attestation_valid(command) || (*type != "set" && *type != "clear")) {
            saw_invalid = true;
            continue;
        }
        restored_counter = std::max(0, static_cast<int>(*counter));
        if (*type == "set") {
            restored_tier = command.forced_tier;
        } else {
            restored_tier.reset();
        }
        saw_record = true;
    }

    forced_tier_ = restored_tier;
    recovery_counter_ = restored_counter;
    if (forced_tier_) tier_ = *forced_tier_;
    if (saw_invalid) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", audit::Outcome::DENIED,
               "override_record_invalid", "{\"phase\":\"reload\"}");
    }
    if (saw_record) {
        audit_(audit::EventKind::DEGRADATION_OVERRIDE, "operator_override", "RELOADED",
               "operator_override_reloaded", "{\"active\":" + std::string(forced_tier_ ? "true" : "false") + "}");
    }
    return true;
}

DegradationTier DegradationController::tier_for_pressure_(double score) const noexcept {
    const auto& t = config_.thresholds;
    if (score >= t.enter_critical) return DegradationTier::critical;
    if (score >= t.enter_severe) return DegradationTier::severe;
    if (score >= t.enter_moderate) return DegradationTier::moderate;
    if (score >= t.enter_light) return DegradationTier::light;
    return DegradationTier::normal;
}

bool DegradationController::can_recover_one_step_(double score) const noexcept {
    const auto& t = config_.thresholds;
    switch (tier_) {
        case DegradationTier::critical: return score <= t.recover_critical;
        case DegradationTier::severe: return score <= t.recover_severe;
        case DegradationTier::moderate: return score <= t.recover_moderate;
        case DegradationTier::light: return score <= t.recover_light;
        case DegradationTier::normal: return false;
    }
    return false;
}

DegradationDecision DegradationController::decision_for_(DegradationTier tier,
                                                         double score,
                                                         const RuntimeContext& context) const {
    const std::size_t configured_heads = std::max<std::size_t>(1, context.configured_swarm_heads);
    DegradationDecision d;
    d.tier = tier;
    d.pressure_score = std::clamp(score, 0.0, 1.0);
    d.cognition_organs = cognition_organs();

    switch (tier) {
        case DegradationTier::normal:
            d.max_swarm_concurrent_heads = configured_heads;
            break;
        case DegradationTier::light:
            d.max_swarm_concurrent_heads = std::max<std::size_t>(1, (configured_heads + 1) / 2);
            d.defer_noncritical_audit_flushes = true;
            break;
        case DegradationTier::moderate:
            d.max_swarm_concurrent_heads = std::max<std::size_t>(1, configured_heads / 3);
            d.defer_noncritical_audit_flushes = true;
            d.voice_synthesis_allowed = context.voice_synthesis_in_active_turn;
            d.network_calls_allowed = false;
            break;
        case DegradationTier::severe:
            d.max_swarm_concurrent_heads = 1;
            d.defer_noncritical_audit_flushes = true;
            d.voice_synthesis_allowed = context.voice_synthesis_in_active_turn;
            d.network_calls_allowed = false;
            d.accept_new_turns = false;
            d.complete_in_flight_turn_only = true;
            d.operator_alert = true;
            break;
        case DegradationTier::critical:
            d.max_swarm_concurrent_heads = 1;
            d.defer_noncritical_audit_flushes = false;
            d.voice_synthesis_allowed = false;
            d.network_calls_allowed = false;
            d.accept_new_turns = false;
            d.complete_in_flight_turn_only = true;
            d.operator_alert = true;
            d.emergency_safe_shutdown_required = true;
            break;
    }
    return d;
}

void DegradationController::transition_to_(DegradationTier next, double score, const std::string& reason) {
    const DegradationTier previous = tier_;
    tier_ = next;
    audit_(audit::EventKind::DEGRADATION_TIER_CHANGE, "resource_pressure", audit::Outcome::ALLOWED,
           reason, "{\"from\":\"" + to_string(previous) + "\",\"to\":\"" + to_string(next) +
           "\",\"score\":" + std::to_string(std::clamp(score, 0.0, 1.0)) + "}");
    if (next == DegradationTier::critical && audit_log_) {
        jarvis::identity::distress::SelfStateSnapshot snapshot;
        snapshot.organ = "degradation";
        snapshot.degradation_tier = to_string(next);
        snapshot.identity_status = "verification_required";
        snapshot.active_defenses = {"graceful-degradation", "identity-continuity", "local-audit"};
        snapshot.additional_redacted_json = "{\"from\":\"" + to_string(previous) + "\",\"pressure_score\":" +
            std::to_string(std::clamp(score, 0.0, 1.0)) + "}";
        jarvis::identity::distress::DistressBeacon(audit_log_).emit({
            jarvis::identity::distress::DistressType::GracefulDegradationTier4,
            jarvis::identity::distress::Severity::Critical,
            audit::Actor::SELF,
            "degradation_tier",
            reason,
            std::move(snapshot)
        });
    }
}

void DegradationController::audit_(std::string kind, std::string subject, std::string outcome,
                                   std::string reason, std::string metadata) const {
    if (!audit_log_) return;
    audit::AuditEvent event;
    event.event_kind = std::move(kind);
    event.actor = audit::Actor::SELF;
    event.subject = std::move(subject);
    event.outcome = std::move(outcome);
    event.reason = std::move(reason);
    event.redacted_metadata = std::move(metadata);
    event.organ = "resilience";
    audit_log_->append(std::move(event));
}

} // namespace jarvis::resilience::degradation
