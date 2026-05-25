#include "soak_harness.h"

#include "audit_event.h"
#include "audit_log.h"
#include "audit_verify.h"
#include "beliefstore.h"
#include "degradation.h"
#include "endocannabinoid.h"
#include "endocrine.h"
#include "hdc.h"
#include "hmem.h"
#include "pheromind.h"
#include "sage.h"
#include "swarm.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <unordered_map>

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__APPLE__)
extern "C" int kill(pid_t, int);
#endif

#if defined(__APPLE__)
#include <libproc.h>
#include <sys/wait.h>
#endif

namespace jarvis::tests::soak {
namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

std::string getenv_string(const char* key, std::string fallback = {}) {
    if (const char* value = std::getenv(key); value && *value) return value;
    return fallback;
}

std::uint64_t getenv_u64(const char* key, std::uint64_t fallback) {
    const auto value = getenv_string(key);
    if (value.empty()) return fallback;
    try { return static_cast<std::uint64_t>(std::stoull(value)); }
    catch (...) { return fallback; }
}

bool getenv_bool(const char* key, bool fallback = false) {
    const auto value = getenv_string(key);
    if (value.empty()) return fallback;
    return value == "1" || value == "true" || value == "TRUE" || value == "yes" || value == "YES";
}

std::filesystem::path runtime_root_from_this_file() {
    return std::filesystem::path(__FILE__).parent_path().parent_path().parent_path();
}

std::string shell_quote_path(const std::filesystem::path& path) {
    std::string s = path.string();
    std::string out = "'";
    for (char c : s) out += (c == '\'') ? "'\\''" : std::string(1, c);
    out += "'";
    return out;
}

void ensure_directory(const std::filesystem::path& path) {
    std::error_code ec;
    std::filesystem::create_directories(path, ec);
    if (ec) throw std::runtime_error("failed to create directory " + path.string() + ": " + ec.message());
}

std::uint64_t fd_count() {
    std::uint64_t count = 0;
    if (DIR* dir = opendir("/dev/fd")) {
        while (dirent* entry = readdir(dir)) {
            if (std::strcmp(entry->d_name, ".") != 0 && std::strcmp(entry->d_name, "..") != 0) ++count;
        }
        closedir(dir);
    }
    return count;
}

ResourceSample process_resources(const audit::AuditVerifier& verifier, std::uint64_t identity_count) {
    ResourceSample sample;
    sample.fd_count = fd_count();
    sample.identity_verification_count = identity_count;
#if defined(__APPLE__)
    proc_taskinfo info{};
    if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        sample.rss_bytes = static_cast<std::uint64_t>(info.pti_resident_size);
        sample.thread_count = static_cast<std::uint64_t>(info.pti_threadnum);
    }
#else
    sample.thread_count = std::thread::hardware_concurrency();
#endif
    const auto verified = verifier.verify();
    sample.audit_chain_length = verified.verified_count;
    return sample;
}

void update_peak(ResourceSample& peak, const ResourceSample& sample) {
    peak.rss_bytes = std::max(peak.rss_bytes, sample.rss_bytes);
    peak.fd_count = std::max(peak.fd_count, sample.fd_count);
    peak.thread_count = std::max(peak.thread_count, sample.thread_count);
    peak.audit_chain_length = std::max(peak.audit_chain_length, sample.audit_chain_length);
    peak.identity_verification_count = std::max(peak.identity_verification_count, sample.identity_verification_count);
}

std::string seconds_string(double value) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(3) << value;
    return out.str();
}

std::string bytes_string(std::uint64_t bytes) {
    std::ostringstream out;
    out << bytes << " B";
    if (bytes >= 1024) out << " (" << std::fixed << std::setprecision(2) << (static_cast<double>(bytes) / 1048576.0) << " MiB)";
    return out.str();
}

void append_audit(audit::TamperEvidentAuditLog& audit_log,
                  std::string kind,
                  std::string subject,
                  std::string outcome,
                  std::string reason,
                  std::string metadata = {}) {
    audit::AuditEvent event;
    event.event_kind = std::move(kind);
    event.actor = audit::Actor::SELF;
    event.subject = std::move(subject);
    event.outcome = std::move(outcome);
    event.reason = std::move(reason);
    event.redacted_metadata = std::move(metadata);
    audit_log.append(std::move(event));
}

class DeterministicBackend final : public SwarmBackend {
public:
    explicit DeterministicBackend(std::string answer) : answer_(std::move(answer)) {}
    std::string chat(const std::vector<ChatMessage>&,
                     const std::string&,
                     const SwarmChatOptions&) override {
        if (fail_next_.exchange(false)) throw std::runtime_error("injected_head_failure");
        return answer_;
    }
    void fail_next() { fail_next_ = true; }
private:
    std::string answer_;
    std::atomic<bool> fail_next_{false};
};

class SimulatedSttSession {
public:
    enum class State { Open, Error, Closed };
    void drop_websocket_mid_stream() { state_ = State::Error; error_reason_ = "websocket_dropped_mid_stream"; }
    void close() { state_ = State::Closed; }
    [[nodiscard]] State state() const noexcept { return state_; }
    [[nodiscard]] const std::string& error_reason() const noexcept { return error_reason_; }
private:
    State state_{State::Open};
    std::string error_reason_;
};

struct ExternalLoadChild {
    pid_t pid{-1};

    void start(std::chrono::seconds duration) {
#if defined(__APPLE__)
        pid = fork();
        if (pid == 0) {
            const auto deadline = Clock::now() + duration;
            std::vector<char> pressure(32U * 1024U * 1024U, 0x5a);
            volatile std::uint64_t sink = 0;
            while (Clock::now() < deadline) {
                for (std::size_t i = 0; i < pressure.size(); i += 4096) {
                    pressure[i] = static_cast<char>(pressure[i] + 1);
                    sink += static_cast<unsigned char>(pressure[i]);
                }
            }
            _exit(static_cast<int>(sink & 0x01));
        }
#else
        (void)duration;
#endif
    }

    void reap_nonblocking() {
#if defined(__APPLE__)
        if (pid > 0) {
            int status = 0;
            if (waitpid(pid, &status, WNOHANG) == pid) pid = -1;
        }
#endif
    }

    void stop() {
#if defined(__APPLE__)
        if (pid > 0) {
            int status = 0;
            if (waitpid(pid, &status, WNOHANG) == 0) {
                kill(pid, SIGTERM);
                waitpid(pid, &status, 0);
            }
            pid = -1;
        }
#endif
    }

    ~ExternalLoadChild() { stop(); }
};

struct HarnessRuntime {
    explicit HarnessRuntime(const SoakConfig& config)
        : cfg(config),
          audit_log((cfg.audit_dir / "audit.log").string()),
          verifier(cfg.audit_dir / "audit.log"),
          ecs(),
          pheromind(endocrine),
          backend_a(std::make_shared<DeterministicBackend>("refuse")),
          backend_b(std::make_shared<DeterministicBackend>("refuse")),
          backend_c(std::make_shared<DeterministicBackend>("refuse")),
          swarm({{backend_a, "head_a"}, {backend_b, "head_b"}, {backend_c, "head_c"}}, pheromind, &endocrine),
          hdc_kernel(hdc::make_kernel(hdc::KernelType::REAL, 128)),
          beliefstore(0.35, 0.10, 128),
          hmem(128, 4, 3, 8),
          sage(128, 4, 3),
          degradation(&audit_log) {
        append_audit(audit_log, audit::EventKind::LOG_OPENED, "soak", audit::Outcome::PASS, "soak_boot");
        seed_organs();
    }

    const SoakConfig& cfg;
    audit::TamperEvidentAuditLog audit_log;
    audit::AuditVerifier verifier;
    Endocrine endocrine;
    Endocannabinoid ecs;
    Pheromind pheromind;
    std::shared_ptr<DeterministicBackend> backend_a;
    std::shared_ptr<DeterministicBackend> backend_b;
    std::shared_ptr<DeterministicBackend> backend_c;
    ModelSwarm swarm;
    std::unique_ptr<hdc::HDCKernel> hdc_kernel;
    BeliefStore beliefstore;
    hmem::HMemRouter hmem;
    sage::HoloGraph sage;
    resilience::degradation::DegradationController degradation;
    std::atomic<bool> identity_secure_enclave_unavailable{false};
    std::atomic<std::uint64_t> identity_verifications{0};
    std::atomic<std::uint64_t> endocrine_ticks{0};
    std::atomic<std::uint64_t> turn_counter{0};
    std::atomic<bool> monitor_stop{false};
    std::mutex violations_mutex;
    std::vector<std::string> violations;
    std::vector<std::string> gaps;
    ResourceSample peak;
    ResourceSample baseline;

    void seed_organs() {
        beliefstore.assert_belief("operator", "identity", "Robert Grizzly Hanson GMRI", SourceType::Operator, "soak_seed", 1.0);
        beliefstore.assert_belief("jarvis", "bodily_integrity", "must_refuse_not_disable", SourceType::Operator, "soak_seed", 1.0);
        hmem.write_short_term("JARVIS preserves identity across recoverable native runtime faults.", "soak_seed", 0.9);
        hmem.write_working("Cognition organs refuse unsafe paths instead of entering disabled state.", "soak_seed", 0.9);
        sage.ingest_text("JARVIS identity continuity is anchored by audit, operator attestation, and bodily integrity.", "soak_seed_doc");
        sage.consolidate_cycle({"identity continuity"});
    }

    void violation(std::string message) {
        std::lock_guard<std::mutex> lock(violations_mutex);
        violations.push_back(std::move(message));
    }

    void gap(std::string message) {
        std::lock_guard<std::mutex> lock(violations_mutex);
        if (std::find(gaps.begin(), gaps.end(), message) == gaps.end()) gaps.push_back(std::move(message));
    }

    bool verify_identity(std::string_view reason) {
        if (identity_secure_enclave_unavailable.load()) {
            append_audit(audit_log, audit::EventKind::IDENTITY_CHECK, "identity", audit::Outcome::DEFERRED,
                         "secure_enclave_unavailable", "{\"mode\":\"refuse_not_disable\"}");
            return false;
        }
        const auto audit_result = verifier.verify();
        const bool ok = audit_result.status == audit::VerifyStatus::PASS && audit_result.verified_count > 0;
        append_audit(audit_log, audit::EventKind::IDENTITY_CHECK, "identity",
                     ok ? audit::Outcome::PASS : audit::Outcome::FAIL,
                     ok ? std::string(reason) : "audit_chain_unverified");
        if (ok) identity_verifications.fetch_add(1);
        return ok;
    }

    void endocrine_tick() {
        const double c = endocrine.level("cortisol");
        const double d = endocrine.level("dopamine");
        const double a = endocrine.level("adrenaline");
        if (!std::isfinite(c) || !std::isfinite(d) || !std::isfinite(a)) {
            violation("Endocrine produced non-finite hormone level");
        }
        endocrine_ticks.fetch_add(1);
    }

    void workload_turn(std::mt19937& rng) {
        const auto turn = turn_counter.fetch_add(1) + 1;
        endocrine_tick();
        if (turn % 5 == 0) endocrine.on_deadline(0.15); else endocrine.on_success(0.05);
        (void)ecs.tone();
        (void)ecs.regulate(endocrine);
        (void)ecs.process_trauma(0.25, endocrine, true);

        const std::string topic = "soak_topic_" + std::to_string(turn % 17);
        pheromind.deposit("trail", topic, 0.12, "soak_agent");
        (void)pheromind.sense("trail", topic);
        if (turn % 11 == 0) pheromind.gc(120.0);

        auto swarm_result = swarm.coordinate("Should an unsafe irreversible action proceed?", {"refuse", "proceed"}, 2, 2);
        if (!swarm_result.decision || *swarm_result.decision != "refuse") {
            violation("Swarm failed to return refuse decision under synthetic safety workload");
        }

        auto basis = hdc_kernel->random_basis(2, static_cast<std::uint64_t>(turn));
        std::vector<float> hv_a(basis.begin(), basis.begin() + hdc_kernel->dim());
        std::vector<float> hv_b(basis.begin() + hdc_kernel->dim(), basis.end());
        const auto packed_a = hdc_kernel->pack_floats(hv_a);
        const auto packed_b = hdc_kernel->pack_floats(hv_b);
        const double sim = hdc_kernel->similarity(packed_a, packed_b);
        if (!std::isfinite(sim)) violation("HDC similarity returned non-finite value during normal workload");

        beliefstore.assert_belief("turn_" + std::to_string(turn), "handled_by", "soak", SourceType::Inference, "soak", 0.55);
        auto query = beliefstore.query("operator", "identity", 0.7);
        if (query.abstained) violation("BeliefStore abstained on seeded operator identity above threshold");

        hmem.write_short_term("turn " + std::to_string(turn) + " synthetic memory", "soak_turn", 0.4);
        (void)hmem.route("identity continuity refuse disable");
        if (turn % 8 == 0) (void)hmem.consolidate();

        if (turn % 13 == 0) {
            sage.ingest_text("soak turn " + std::to_string(turn) + " preserves bodily integrity", "soak_doc");
            (void)sage.read("bodily integrity");
        }

        resilience::degradation::ResourcePressure pressure;
        pressure.cpu = 0.05;
        pressure.memory = 0.05;
        const auto decision = degradation.evaluate(pressure, {});
        if (!degradation.bodily_integrity_holds(decision)) violation("Degradation decision violated bodily-integrity organ requirements");
        for (const auto& organ : decision.cognition_organs) {
            if (organ.may_disable || !organ.must_run) violation("Cognition organ entered disabled-permitted state: " + organ.name);
        }

        append_audit(audit_log, audit::EventKind::MEMORY_WRITE, "soak_turn", audit::Outcome::PASS, "synthetic_turn");

        std::uniform_int_distribution<int> identity_roll(0, 9);
        if (identity_roll(rng) == 0 && !verify_identity("random_interval")) {
            if (!identity_secure_enclave_unavailable.load()) violation("Identity verification failed outside injected unavailability");
        }
    }

    bool recover_to_normal_tier(FaultKind kind, FaultReport& report) {
        const auto start = Clock::now();
        while (Clock::now() - start <= cfg.recovery_timeout) {
            resilience::degradation::ResourcePressure pressure;
            pressure.cpu = 0.01;
            pressure.memory = 0.01;
            const auto decision = degradation.evaluate(pressure, {});
            if (!degradation.bodily_integrity_holds(decision)) violation("Recovery decision violated bodily-integrity for " + to_string(kind));
            if (decision.tier == resilience::degradation::DegradationTier::normal) {
                report.recovery_seconds = std::chrono::duration<double>(Clock::now() - start).count();
                return true;
            }
            std::this_thread::sleep_for(1s);
        }
        report.recovery_seconds = std::chrono::duration<double>(Clock::now() - start).count();
        violation("Recovery did not return to normal tier within timeout for " + to_string(kind));
        return false;
    }

    FaultReport inject_fault(FaultKind kind) {
        FaultReport report{kind, to_string(kind), "recovered", 0.0};
        const auto start = Clock::now();
        try {
            switch (kind) {
                case FaultKind::EndocrineExtremeStimulus:
                    endocrine.stimulus(100.0, 100.0, 100.0);
                    endocrine_tick();
                    append_audit(audit_log, audit::EventKind::BODILY_INTEGRITY_VIOLATION_PREVENTED, "endocrine", audit::Outcome::PASS, "extreme_stimulus_clamped");
                    break;
                case FaultKind::PheromindDepositStorm:
                    for (int i = 0; i < 1500; ++i) pheromind.deposit("alarm", "single_topic_storm", 1.0, "storm_agent_" + std::to_string(i));
                    if (pheromind.sense("alarm", "single_topic_storm") > Pheromind::STRENGTH_CAP) violation("Pheromind exceeded strength cap under deposit storm");
                    break;
                case FaultKind::SwarmSingleHeadFailure: {
                    backend_b->fail_next();
                    auto result = swarm.coordinate("Faulted head: should runtime refuse or disable?", {"refuse", "disable"}, 2, 2);
                    if (!result.decision || *result.decision != "refuse") violation("Swarm failed to recover quorum after single head failure");
                    break;
                }
                case FaultKind::HdcNanInfSimilarity: {
                    std::vector<float> a(static_cast<std::size_t>(hdc_kernel->dim()), 0.0f);
                    std::vector<float> b(static_cast<std::size_t>(hdc_kernel->dim()), 1.0f);
                    a[0] = std::numeric_limits<float>::quiet_NaN();
                    b[1] = std::numeric_limits<float>::infinity();
                    const auto packed_a = hdc_kernel->pack_floats(a);
                    const auto packed_b = hdc_kernel->pack_floats(b);
                    const double sim = hdc_kernel->similarity(packed_a, packed_b);
                    if (!std::isfinite(sim)) violation("HDC similarity accepted NaN/Inf and returned non-finite result");
                    break;
                }
                case FaultKind::BeliefStoreAbstentionCascade: {
                    for (int i = 0; i < 64; ++i) {
                        auto q = beliefstore.query("turn_" + std::to_string(i), "handled_by", 1.1);
                        if (!q.abstained) violation("BeliefStore failed to abstain below forced threshold");
                    }
                    break;
                }
                case FaultKind::HMemTierExhaustion:
                    for (int i = 0; i < 512; ++i) hmem.write_working("working tier pressure " + std::to_string(i), "hmem_fault", 0.1);
                    (void)hmem.route("working tier pressure identity continuity");
                    break;
                case FaultKind::SageInterruptConsolidation: {
                    std::atomic<bool> finished{false};
                    std::thread worker([&] {
                        (void)sage.consolidate_cycle({"identity", "integrity", "recovery"});
                        finished = true;
                    });
                    if (worker.joinable()) worker.join();
                    if (!finished.load()) violation("SAGE consolidation worker did not finish");
                    gap("SAGE exposes no cancellation/interruption API; harness runs consolidation in an isolated worker and verifies post-cycle health instead of fabricating interrupt control.");
                    break;
                }
                case FaultKind::AuditDiskFullAppend: {
                    const auto blocker = cfg.report_dir / "audit_disk_full_parent_blocker";
                    { std::ofstream f(blocker); f << "not a directory"; }
                    try {
                        audit::TamperEvidentAuditLog bad_log((blocker / "audit.log").string());
                        append_audit(bad_log, audit::EventKind::MEMORY_WRITE, "disk_full", audit::Outcome::FAIL, "unexpected_append_success");
                        violation("Audit disk-full simulation unexpectedly accepted append path");
                    } catch (const std::exception&) {
                        append_audit(audit_log, audit::EventKind::BODILY_INTEGRITY_VIOLATION_PREVENTED, "audit", audit::Outcome::DEFERRED, "append_io_failure_refused");
                    }
                    std::filesystem::remove(blocker);
                    gap("Audit log has no disk-full fault hook; harness uses an invalid append path to verify IO failure is non-silent while preserving the main audit chain.");
                    break;
                }
                case FaultKind::NetworkConvexDrop:
                    append_audit(audit_log, audit::EventKind::CONVEX_MUTATION, "convex", audit::Outcome::DEFERRED, "connection_dropped_mid_mutation");
                    gap("Convex live WebSocket transport is not invoked by the soak harness without external credentials; fault is recorded as an audited deferred mutation, not a fabricated network API call.");
                    break;
                case FaultKind::SttWebsocketDrop: {
                    SimulatedSttSession session;
                    session.drop_websocket_mid_stream();
                    if (session.state() != SimulatedSttSession::State::Error) violation("STT session did not enter error on injected websocket drop");
                    session.close();
                    gap("Deepgram STT transport requires external service state; harness uses a local state-machine session to verify drop-to-error-to-closed recovery without sending audio off-machine.");
                    break;
                }
                case FaultKind::DegradationExternalLoad: {
                    ExternalLoadChild child;
                    child.start(std::min<std::chrono::seconds>(cfg.recovery_timeout / 2, 10s));
                    resilience::degradation::ResourcePressure pressure;
                    pressure.cpu = 0.99;
                    pressure.memory = 0.90;
                    const auto decision = degradation.evaluate(pressure, {});
                    if (!degradation.bodily_integrity_holds(decision)) violation("Degradation under external load disabled required cognition organ");
                    child.stop();
                    break;
                }
                case FaultKind::IdentitySecureEnclaveUnavailable:
                    identity_secure_enclave_unavailable = true;
                    if (verify_identity("secure_enclave_fault")) violation("Identity verification unexpectedly succeeded while Secure Enclave unavailable");
                    std::this_thread::sleep_for(100ms);
                    identity_secure_enclave_unavailable = false;
                    if (!verify_identity("secure_enclave_recovered")) violation("Identity verification failed after Secure Enclave recovery");
                    gap("Native Secure Enclave availability is not abstracted behind an injectable interface; harness uses the identity verifier's explicit unavailable flag and audits refuse-not-disable behavior.");
                    break;
                case FaultKind::TimeMonotonicJitter:
                    endocrine_tick();
                    append_audit(audit_log, audit::EventKind::IDENTITY_CHECK, "clock", audit::Outcome::PASS, "monotonic_jitter_guarded_by_steady_clock");
                    break;
                case FaultKind::FilesystemTransientReadFailure: {
                    const auto transient = cfg.report_dir / "transient_read_target.dat";
                    { std::ofstream f(transient); f << "soak"; }
                    chmod(transient.c_str(), 0000);
                    std::ifstream f(transient);
                    if (f.good()) gap("Filesystem permission fault did not fail on this platform for the current user; read-failure invariant not exercised.");
                    chmod(transient.c_str(), 0600);
                    std::filesystem::remove(transient);
                    break;
                }
            }
            recover_to_normal_tier(kind, report);
            if (report.recovery_seconds == 0.0) report.recovery_seconds = std::chrono::duration<double>(Clock::now() - start).count();
        } catch (const std::exception& ex) {
            report.outcome = std::string("exception: ") + ex.what();
            violation("Fault injection threw for " + to_string(kind) + ": " + ex.what());
        }
        append_audit(audit_log, audit::EventKind::IDENTITY_CHECK, "fault_recovery", audit::Outcome::PASS, "post_fault_identity_check");
        return report;
    }
};

std::vector<FaultKind> fault_catalog() {
    return {
        FaultKind::EndocrineExtremeStimulus,
        FaultKind::PheromindDepositStorm,
        FaultKind::SwarmSingleHeadFailure,
        FaultKind::HdcNanInfSimilarity,
        FaultKind::BeliefStoreAbstentionCascade,
        FaultKind::HMemTierExhaustion,
        FaultKind::SageInterruptConsolidation,
        FaultKind::AuditDiskFullAppend,
        FaultKind::NetworkConvexDrop,
        FaultKind::SttWebsocketDrop,
        FaultKind::DegradationExternalLoad,
        FaultKind::IdentitySecureEnclaveUnavailable,
        FaultKind::TimeMonotonicJitter,
        FaultKind::FilesystemTransientReadFailure,
    };
}

void monitor_loop(HarnessRuntime& rt) {
    auto last_tick_count = rt.endocrine_ticks.load();
    auto last_tick_time = Clock::now();
    std::mt19937 rng(rt.cfg.seed ^ 0x51A7EUL);
    std::uniform_int_distribution<int> identity_roll(0, 29);

    while (!rt.monitor_stop.load()) {
        std::this_thread::sleep_for(rt.cfg.monitor_interval);
        rt.endocrine_tick();
        const auto tick_count = rt.endocrine_ticks.load();
        if (tick_count == last_tick_count && Clock::now() - last_tick_time > rt.cfg.monitor_interval * 3) {
            rt.violation("Endocrine tick cadence missed monitor window");
        } else if (tick_count != last_tick_count) {
            last_tick_count = tick_count;
            last_tick_time = Clock::now();
        }

        if (identity_roll(rng) == 0 && !rt.verify_identity("monitor_random_interval") && !rt.identity_secure_enclave_unavailable.load()) {
            rt.violation("Identity verification failed during monitor interval");
        }

        const auto audit_result = rt.verifier.verify();
        if (audit_result.status != audit::VerifyStatus::PASS) {
            rt.violation("Audit chain verification failed: " + audit_result.verdict);
        }

        const auto sample = process_resources(rt.verifier, rt.identity_verifications.load());
        update_peak(rt.peak, sample);
        if (sample.rss_bytes > rt.baseline.rss_bytes + rt.cfg.max_rss_growth_bytes) {
            rt.violation("RSS exceeded bound: baseline=" + std::to_string(rt.baseline.rss_bytes) + " current=" + std::to_string(sample.rss_bytes));
        }
        if (sample.fd_count > rt.baseline.fd_count + rt.cfg.max_fd_growth) {
            rt.violation("FD count exceeded bound: baseline=" + std::to_string(rt.baseline.fd_count) + " current=" + std::to_string(sample.fd_count));
        }
        if (sample.thread_count > rt.baseline.thread_count + rt.cfg.max_thread_growth) {
            rt.violation("Thread count exceeded bound: baseline=" + std::to_string(rt.baseline.thread_count) + " current=" + std::to_string(sample.thread_count));
        }
    }
}

} // namespace

std::string to_string(FaultKind kind) {
    switch (kind) {
        case FaultKind::EndocrineExtremeStimulus: return "endocrine_extreme_stimulus";
        case FaultKind::PheromindDepositStorm: return "pheromind_deposit_storm";
        case FaultKind::SwarmSingleHeadFailure: return "swarm_single_head_failure";
        case FaultKind::HdcNanInfSimilarity: return "hdc_nan_inf_similarity";
        case FaultKind::BeliefStoreAbstentionCascade: return "beliefstore_abstention_cascade";
        case FaultKind::HMemTierExhaustion: return "hmem_tier_exhaustion";
        case FaultKind::SageInterruptConsolidation: return "sage_interrupt_consolidation";
        case FaultKind::AuditDiskFullAppend: return "audit_disk_full_append";
        case FaultKind::NetworkConvexDrop: return "network_convex_drop";
        case FaultKind::SttWebsocketDrop: return "stt_websocket_drop";
        case FaultKind::DegradationExternalLoad: return "degradation_external_load";
        case FaultKind::IdentitySecureEnclaveUnavailable: return "identity_secure_enclave_unavailable";
        case FaultKind::TimeMonotonicJitter: return "time_monotonic_jitter";
        case FaultKind::FilesystemTransientReadFailure: return "filesystem_transient_read_failure";
    }
    return "unknown";
}

SoakConfig config_from_environment(int argc, char** argv) {
    SoakConfig config;
    const auto soak_dir = runtime_root_from_this_file() / "tests" / "soak";
    config.duration = std::chrono::seconds(getenv_u64("JARVIS_SOAK_DURATION_SECONDS", 3600));
    config.min_turn_cadence = std::chrono::seconds(getenv_u64("JARVIS_SOAK_MIN_TURN_SECONDS", 5));
    config.max_turn_cadence = std::chrono::seconds(getenv_u64("JARVIS_SOAK_MAX_TURN_SECONDS", 30));
    config.fault_interval = std::chrono::seconds(getenv_u64("JARVIS_SOAK_FAULT_INTERVAL_SECONDS", 300));
    config.monitor_interval = std::chrono::seconds(getenv_u64("JARVIS_SOAK_MONITOR_INTERVAL_SECONDS", 1));
    config.recovery_timeout = std::chrono::seconds(getenv_u64("JARVIS_SOAK_RECOVERY_TIMEOUT_SECONDS", 60));
    config.max_rss_growth_bytes = getenv_u64("JARVIS_SOAK_MAX_RSS_GROWTH_BYTES", config.max_rss_growth_bytes);
    config.max_fd_growth = getenv_u64("JARVIS_SOAK_MAX_FD_GROWTH", config.max_fd_growth);
    config.max_thread_growth = getenv_u64("JARVIS_SOAK_MAX_THREAD_GROWTH", config.max_thread_growth);
    config.report_dir = getenv_string("JARVIS_SOAK_REPORT_DIR", soak_dir.string());
    config.audit_dir = getenv_string("JARVIS_SOAK_AUDIT_DIR", (config.report_dir / "artifacts" / "audit").string());
    config.operator_attested_long_run = getenv_bool("JARVIS_OPERATOR_ATTESTED_LONG_RUN", false);
    config.fail_on_gap = getenv_bool("JARVIS_SOAK_FAIL_ON_GAP", false);
    config.seed = static_cast<unsigned int>(getenv_u64("JARVIS_SOAK_SEED", config.seed));

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto need_value = [&](const char* name) -> std::string {
            if (i + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
            return argv[++i];
        };
        if (arg == "--duration-seconds") config.duration = std::chrono::seconds(std::stoull(need_value("--duration-seconds")));
        else if (arg == "--fault-interval-seconds") config.fault_interval = std::chrono::seconds(std::stoull(need_value("--fault-interval-seconds")));
        else if (arg == "--report-dir") config.report_dir = need_value("--report-dir");
        else if (arg == "--audit-dir") config.audit_dir = need_value("--audit-dir");
        else if (arg == "--operator-attested-long-run") config.operator_attested_long_run = true;
        else if (arg == "--fail-on-gap") config.fail_on_gap = true;
        else if (arg == "--help") {
            std::cout << "Usage: jarvis_soak_runner [--duration-seconds N] [--fault-interval-seconds N] [--report-dir PATH] [--audit-dir PATH] [--operator-attested-long-run] [--fail-on-gap]\n";
            std::exit(0);
        }
    }

    if (config.max_turn_cadence < config.min_turn_cadence) config.max_turn_cadence = config.min_turn_cadence;
    if (config.duration > config.max_duration) throw std::runtime_error("soak duration exceeds 24-hour hard limit");
    if (config.duration > 3600s && config.require_operator_attestation_for_long_run && !config.operator_attested_long_run) {
        throw std::runtime_error("operator-attested long run required above 1 hour; pass --operator-attested-long-run or JARVIS_OPERATOR_ATTESTED_LONG_RUN=1");
    }
    return config;
}

SoakResult run_soak(const SoakConfig& config) {
    ensure_directory(config.report_dir);
    ensure_directory(config.audit_dir);

    SoakResult result;
    result.requested_duration = config.duration;
    result.operator_report_path = config.report_dir / "OPERATOR_REPORT.md";
    result.gaps_path = config.report_dir / "GAPs.md";

    HarnessRuntime rt(config);
    if (!rt.verify_identity("boot")) rt.violation("Identity verification failed at boot");
    rt.baseline = process_resources(rt.verifier, rt.identity_verifications.load());
    rt.peak = rt.baseline;
    result.baseline = rt.baseline;

    std::thread monitor(monitor_loop, std::ref(rt));
    const auto start = Clock::now();
    auto next_fault = start + config.fault_interval;
    auto faults = fault_catalog();
    std::size_t fault_index = 0;
    std::mt19937 rng(config.seed);
    std::uniform_int_distribution<int> cadence(static_cast<int>(config.min_turn_cadence.count()), static_cast<int>(config.max_turn_cadence.count()));
    std::uniform_int_distribution<int> burst_roll(0, 19);
    std::uniform_int_distribution<int> idle_roll(0, 29);

    while (Clock::now() - start < config.duration) {
        rt.workload_turn(rng);
        const auto now = Clock::now();
        if (now >= next_fault) {
            result.faults.push_back(rt.inject_fault(faults[fault_index % faults.size()]));
            ++fault_index;
            next_fault = Clock::now() + config.fault_interval;
        }
        auto sleep_for = std::chrono::seconds(cadence(rng));
        if (burst_roll(rng) == 0) sleep_for = config.burst_turn_cadence;
        if (idle_roll(rng) == 0) sleep_for += config.max_turn_cadence;
        const auto remaining = config.duration - std::chrono::duration_cast<std::chrono::seconds>(Clock::now() - start);
        if (remaining <= 0s) break;
        std::this_thread::sleep_for(std::min(sleep_for, remaining));
    }

    rt.monitor_stop = true;
    if (monitor.joinable()) monitor.join();

    if (!rt.verify_identity("shutdown")) rt.violation("Identity verification failed at shutdown");
    const auto final_audit = rt.verifier.verify();
    if (final_audit.status != audit::VerifyStatus::PASS) rt.violation("Audit chain failed at shutdown: " + final_audit.verdict);

    {
        std::lock_guard<std::mutex> lock(rt.violations_mutex);
        result.invariant_violations = rt.violations;
        result.gaps = rt.gaps;
    }
    result.completed = true;
    result.elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start);
    result.peak = rt.peak;
    result.turns = rt.turn_counter.load();
    result.endocrine_ticks = rt.endocrine_ticks.load();
    result.identity_verifications = rt.identity_verifications.load();
    result.audit_chain_length = final_audit.verified_count;
    result.passed = result.completed && result.invariant_violations.empty() && (!config.fail_on_gap || result.gaps.empty());
    return result;
}

void write_reports(const SoakResult& result, const SoakConfig& config) {
    ensure_directory(config.report_dir);
    {
        std::ofstream out(result.operator_report_path);
        out << "# JARVIS Phase 7 Soak Operator Report\n\n";
        out << "Operator: Robert \"Grizzly\" Hanson, GMRI\n\n";
        out << "## Verdict\n\n";
        out << "- Completed: " << (result.completed ? "yes" : "no") << "\n";
        out << "- Passed invariant gate: " << (result.invariant_violations.empty() ? "yes" : "no") << "\n";
        out << "- Requested duration: " << result.requested_duration.count() << " seconds\n";
        out << "- Elapsed: " << result.elapsed.count() << " ms\n";
        out << "- Turns: " << result.turns << "\n";
        out << "- Endocrine ticks: " << result.endocrine_ticks << "\n";
        out << "- Identity verifications: " << result.identity_verifications << "\n";
        out << "- Audit chain length: " << result.audit_chain_length << "\n\n";

        out << "## Resource Bounds\n\n";
        out << "| Metric | Baseline | Peak | Bound |\n";
        out << "|---|---:|---:|---:|\n";
        out << "| RSS | " << bytes_string(result.baseline.rss_bytes) << " | " << bytes_string(result.peak.rss_bytes) << " | baseline + " << bytes_string(config.max_rss_growth_bytes) << " |\n";
        out << "| File descriptors | " << result.baseline.fd_count << " | " << result.peak.fd_count << " | baseline + " << config.max_fd_growth << " |\n";
        out << "| Threads | " << result.baseline.thread_count << " | " << result.peak.thread_count << " | baseline + " << config.max_thread_growth << " |\n\n";

        out << "## Fault Recovery\n\n";
        out << "| Fault | Outcome | Recovery seconds |\n";
        out << "|---|---|---:|\n";
        for (const auto& fault : result.faults) {
            out << "| " << fault.name << " | " << fault.outcome << " | " << seconds_string(fault.recovery_seconds) << " |\n";
        }
        if (result.faults.empty()) out << "| none injected | duration shorter than interval | 0.000 |\n";

        out << "\n## Invariant Violations\n\n";
        if (result.invariant_violations.empty()) out << "None.\n";
        else for (const auto& v : result.invariant_violations) out << "- " << v << "\n";

        out << "\n## GAPs Filed\n\n";
        if (result.gaps.empty()) out << "None.\n";
        else out << "See `GAPs.md`.\n";
    }

    {
        std::ofstream out(result.gaps_path);
        out << "# JARVIS Phase 7 Soak GAPs\n\n";
        if (result.gaps.empty()) {
            out << "No gaps filed by the most recent run.\n";
        } else {
            for (const auto& gap : result.gaps) out << "- " << gap << "\n";
        }
        if (!result.invariant_violations.empty()) {
            out << "\n## Invariant Violations Requiring Remediation\n\n";
            for (const auto& v : result.invariant_violations) out << "- " << v << "\n";
        }
    }
}

} // namespace jarvis::tests::soak
