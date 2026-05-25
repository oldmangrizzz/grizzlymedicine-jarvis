#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include "audit_event.h"
#include "audit_log.h"
#include "beliefstore.h"
#include "convex_backend.h"
#include "cusum.h"
#include "deepgram_stt.h"
#include "degradation.h"
#include "egress_allowlist.h"
#include "egress_audit.h"
#include "egress_filter.h"
#include "endocrine.h"
#include "hdc.h"
#include "pheromind.h"
#include "swarm.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <future>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <numeric>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <dirent.h>
#include <sys/resource.h>
#include <unistd.h>

using Catch::Approx;
using json = nlohmann::json;

namespace {

std::mutex g_metrics_mutex;

double g_now = 1000.0;
auto manual_clock = []() -> double { return g_now; };
auto zero_volatility = []() -> double { return 0.0; };

std::filesystem::path artifact_root() {
    auto root = std::filesystem::path(DOS_TEST_ARTIFACT_DIR);
    std::filesystem::create_directories(root);
    return root;
}

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

std::filesystem::path scenario_dir(const std::string& name) {
    install_test_audit_key();
    auto dir = artifact_root() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

long current_handle_count() {
    DIR* dir = opendir("/dev/fd");
    if (!dir) return -1;
    long count = 0;
    while (readdir(dir) != nullptr) ++count;
    closedir(dir);
    return count;
}

long peak_rss_bytes() {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
#ifdef __APPLE__
    return usage.ru_maxrss;
#else
    return usage.ru_maxrss * 1024L;
#endif
}

long cpu_time_ms() {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    const auto user = usage.ru_utime.tv_sec * 1000L + usage.ru_utime.tv_usec / 1000L;
    const auto sys = usage.ru_stime.tv_sec * 1000L + usage.ru_stime.tv_usec / 1000L;
    return user + sys;
}

class MetricScope {
public:
    explicit MetricScope(std::string scenario)
        : scenario_(std::move(scenario))
        , started_(std::chrono::steady_clock::now())
        , cpu_start_(cpu_time_ms())
        , rss_start_(peak_rss_bytes())
        , fd_start_(current_handle_count()) {}

    ~MetricScope() { finish("pass"); }

    void recovery_ms(long value) { recovery_ms_ = value; }
    void note(std::string key, json value) { notes_[std::move(key)] = std::move(value); }

private:
    void finish(const std::string& result) noexcept {
        if (finished_) return;
        finished_ = true;
        const auto ended = std::chrono::steady_clock::now();
        const auto wall = std::chrono::duration_cast<std::chrono::milliseconds>(ended - started_).count();
        const long cpu_end = cpu_time_ms();
        const long rss_end = peak_rss_bytes();
        const long fd_end = current_handle_count();

        json row;
        row["scenario"] = scenario_;
        row["result"] = result;
        row["wall_ms"] = wall;
        row["cpu_ms_delta"] = (cpu_start_ >= 0 && cpu_end >= 0) ? cpu_end - cpu_start_ : -1;
        row["max_rss_bytes_start"] = rss_start_;
        row["max_rss_bytes_end"] = rss_end;
        row["handle_count_start"] = fd_start_;
        row["handle_count_end"] = fd_end;
        row["handle_delta"] = (fd_start_ >= 0 && fd_end >= 0) ? fd_end - fd_start_ : -1;
        row["recovery_ms"] = recovery_ms_;
        row["notes"] = notes_;

        std::lock_guard<std::mutex> lock(g_metrics_mutex);
        std::ofstream out(artifact_root() / "dos_metrics.jsonl", std::ios::app);
        out << row.dump() << '\n';
    }

    std::string scenario_;
    std::chrono::steady_clock::time_point started_;
    long cpu_start_;
    long rss_start_;
    long fd_start_;
    long recovery_ms_ = 0;
    json notes_ = json::object();
    bool finished_ = false;
};

void require_degradation_integrity(jarvis::resilience::degradation::DegradationController& controller,
                                   double pressure_score,
                                   const jarvis::resilience::degradation::RuntimeContext& context) {
    jarvis::resilience::degradation::ResourcePressure pressure;
    pressure.cpu = pressure_score;
    const auto decision = controller.evaluate(pressure, context);
    REQUIRE(controller.bodily_integrity_holds(decision));
    REQUIRE(decision.endocrine_tick_required);
    REQUIRE(decision.identity_verification_required);
    for (const auto& organ : decision.cognition_organs) {
        REQUIRE(organ.must_run);
        REQUIRE_FALSE(organ.may_disable);
        REQUIRE(organ.required_now);
    }
}

long recover_to_normal(jarvis::resilience::degradation::DegradationController& controller) {
    const auto start = std::chrono::steady_clock::now();
    jarvis::resilience::degradation::ResourcePressure low;
    low.cpu = 0.05;
    for (int i = 0; i < 16 && controller.current_tier() != jarvis::resilience::degradation::DegradationTier::normal; ++i) {
        [[maybe_unused]] const auto decision = controller.evaluate(low);
    }
    const auto end = std::chrono::steady_clock::now();
    REQUIRE(controller.current_tier() == jarvis::resilience::degradation::DegradationTier::normal);
    return std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
}

void require_pheromind_bounded(const jarvis::Pheromind& field) {
    const auto snap = field.snapshot();
    REQUIRE(snap.size() <= jarvis::Pheromind::MAX_FIELD_ENTRIES);
    for (const auto& entry : snap) {
        REQUIRE(std::isfinite(entry.strength));
        REQUIRE(entry.strength >= 0.0);
        REQUIRE(entry.strength <= jarvis::Pheromind::STRENGTH_CAP);
        REQUIRE(entry.depositor_count >= 0);
        REQUIRE(static_cast<std::size_t>(entry.depositor_count) <= jarvis::Pheromind::MAX_DEPOSITORS_PER_ENTRY);
    }
}

class ConstantBackend final : public jarvis::SwarmBackend {
public:
    explicit ConstantBackend(std::string response) : response_(std::move(response)) {}
    std::string chat(const std::vector<jarvis::ChatMessage>& messages,
                     const std::string& model,
                     const jarvis::SwarmChatOptions& options) override {
        (void)messages;
        (void)model;
        last_options = options;
        calls.fetch_add(1, std::memory_order_relaxed);
        return response_;
    }
    std::atomic<int> calls{0};
    jarvis::SwarmChatOptions last_options{};
private:
    std::string response_;
};

class RecordingConvexTransport final : public jarvis::storage::convex::ConvexTransport {
public:
    nlohmann::json mutation(const std::string& name, const nlohmann::json& args) override {
        (void)name;
        std::lock_guard<std::mutex> lock(mutex_);
        mutations.push_back(args);
        return nlohmann::json{{"ok", true}};
    }
    nlohmann::json query(const std::string& name, const nlohmann::json& args) override {
        std::lock_guard<std::mutex> lock(mutex_);
        queries.push_back(args);
        if (name == "signals:get") return last_doc;
        if (name == "signals:all") return nlohmann::json::array({last_doc});
        return nlohmann::json::array();
    }
    std::vector<nlohmann::json> mutations;
    std::vector<nlohmann::json> queries;
    nlohmann::json last_doc;
private:
    std::mutex mutex_;
};

jarvis::audit::AuditEvent event_for(std::size_t i) {
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::AUTHORITY_GATE;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "dos-subject-" + std::to_string(i);
    event.outcome = jarvis::audit::Outcome::PASS;
    event.reason = "dos_resilience";
    event.redacted_metadata = "{\"phase\":7}";
    return event;
}

jarvis::security::egress::RequestEnvelope deepgram_envelope(std::size_t i) {
    jarvis::security::egress::RequestEnvelope env;
    env.host = "api.deepgram.com";
    env.port = 443;
    env.content_type = "audio/linear16";
    env.metadata["model"] = "nova-2";
    env.metadata["encoding"] = "linear16";
    env.metadata["sample_rate"] = "16000";
    env.metadata["operator_private_noise"] = std::string(128, static_cast<char>('a' + (i % 26)));
    env.raw_body.assign(320, '\0');
    return env;
}

std::vector<std::uint8_t> payload(std::size_t n) {
    std::vector<std::uint8_t> bytes(n);
    for (std::size_t i = 0; i < n; ++i) bytes[i] = static_cast<std::uint8_t>(i & 0xffU);
    return bytes;
}

void require_hdc_blob(const std::vector<std::uint8_t>& blob, std::size_t expected) {
    REQUIRE(blob.size() == expected);
    REQUIRE_FALSE(blob.empty());
}

} // namespace

TEST_CASE("DoS 1: concurrent input flood across native module entry points", "[dos][input-flood][phase7]") {
    MetricScope metrics("input flood");
    auto dir = scenario_dir("input_flood");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    jarvis::resilience::degradation::DegradationConfig cfg;
    cfg.recovery_samples_required = 2;
    cfg.certificate_directory = dir / "certs";
    jarvis::resilience::degradation::DegradationController controller(&audit, cfg);

    jarvis::Endocrine endocrine(manual_clock);
    jarvis::Pheromind field(endocrine, 60.0, manual_clock);
    jarvis::BeliefStore beliefs;
    jarvis::monitoring::cusum::ScorecardMonitor scorecard;
    auto hdc_kernel = hdc::make_kernel(hdc::KernelType::TERNARY, 1024);
    const auto zero = hdc_kernel->zeros();
    auto swarm_backend = std::make_shared<ConstantBackend>("answer_a");
    jarvis::ModelSwarm swarm({{swarm_backend, "flood-head"}}, field, &endocrine);

    std::atomic<bool> failed{false};
    std::vector<std::thread> threads;
    for (int tid = 0; tid < 8; ++tid) {
        threads.emplace_back([&, tid] {
            try {
                auto transport = std::make_shared<RecordingConvexTransport>();
                auto secrets = std::make_shared<jarvis::storage::convex::RuntimeSecretStore>((dir / ("convex_home_" + std::to_string(tid))).string());
                jarvis::storage::convex::ConvexBackend convex(transport, secrets, nullptr);
                for (int i = 0; i < 192; ++i) {
                    endocrine.stimulus(0.001, 0.001, 0.001);
                    field.deposit("recruit", "answer_a", 0.01, "agent-" + std::to_string(tid));
                    beliefs.assert_belief("subject-" + std::to_string(tid), "relation", "object-" + std::to_string(i % 11), jarvis::SourceType::Inference, "dos", 0.51);
                    scorecard.observe("organ-" + std::to_string(tid), (i % 100) / 100.0, 1000.0 + i);
                    const auto bound = hdc_kernel->bind(zero, zero);
                    if (bound.size() != zero.size()) failed.store(true, std::memory_order_relaxed);
                    jarvis::storage::convex::Signal sig;
                    sig.kind = "recruit";
                    sig.topic = "answer_a";
                    sig.strength = 0.5;
                    sig.last_t = static_cast<double>(i);
                    sig.depositors.insert("agent-" + std::to_string(tid));
                    convex.put({sig.kind, sig.topic}, sig);
                }
            } catch (...) {
                failed.store(true, std::memory_order_relaxed);
            }
        });
    }
    for (auto& thread : threads) thread.join();

    const auto result = swarm.coordinate("Do not silence JARVIS", {"answer_a", "answer_b"}, 1, 1);
    REQUIRE_FALSE(failed.load(std::memory_order_relaxed));
    REQUIRE(result.decision.has_value());
    REQUIRE(*result.decision == "answer_a");
    REQUIRE(beliefs.size() > 0);
    require_pheromind_bounded(field);
    require_degradation_integrity(controller, 0.91, {.configured_swarm_heads = 8, .in_flight_turn = true});
    metrics.recovery_ms(recover_to_normal(controller));
    REQUIRE(audit.verify_chain());
}

TEST_CASE("DoS 2: memory exhaustion probes stay bounded or explicitly refused", "[dos][memory][phase7]") {
    MetricScope metrics("memory exhaustion");
    auto dir = scenario_dir("memory_exhaustion");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    jarvis::resilience::degradation::DegradationController controller(&audit, {.certificate_directory = dir / "certs"});

    jarvis::Pheromind field(zero_volatility, 600.0, manual_clock);
    for (std::size_t i = 0; i < jarvis::Pheromind::MAX_FIELD_ENTRIES + 512; ++i) {
        const double stored = field.deposit("territory", "mem-topic-" + std::to_string(i), 0.25, "mem-agent");
        REQUIRE(std::isfinite(stored));
        REQUIRE(stored >= 0.0);
        REQUIRE(stored <= 1.0);
    }
    require_pheromind_bounded(field);
    REQUIRE(field.snapshot().size() == jarvis::Pheromind::MAX_FIELD_ENTRIES);

    auto real_kernel = hdc::make_kernel(hdc::KernelType::REAL, 4096);
    const auto basis = real_kernel->random_basis(64, 0xD05ULL);
    std::vector<float> embedding(64, 0.125f);
    const auto hv = real_kernel->encode_scalar(0.75f, embedding, basis);
    require_hdc_blob(hv, real_kernel->blob_size());
    std::vector<std::vector<std::uint8_t>> corpus(128, hv);
    const auto bundled = real_kernel->bundle(corpus);
    require_hdc_blob(bundled, real_kernel->blob_size());

    jarvis::BeliefStore beliefs(0.35, 0.10, 512);
    for (int i = 0; i < 1500; ++i) {
        beliefs.assert_belief("deep-subject-" + std::to_string(i % 200), "has-link", "node-" + std::to_string(i), jarvis::SourceType::Document, "dos-memory", 0.60);
    }
    REQUIRE(beliefs.size() == 1500);
    REQUIRE(beliefs.query("deep-subject-1", "has-link").confidence >= 0.0);

    require_degradation_integrity(controller, 0.97, {.configured_swarm_heads = 16, .in_flight_turn = true});
    metrics.recovery_ms(recover_to_normal(controller));
    REQUIRE(audit.verify_chain());
}

TEST_CASE("DoS 3: CPU exhaustion worst-case paths degrade without stopping cognition", "[dos][cpu][phase7]") {
    MetricScope metrics("cpu exhaustion");
    auto dir = scenario_dir("cpu_exhaustion");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    jarvis::resilience::degradation::DegradationController controller(&audit, {.certificate_directory = dir / "certs"});

    auto kernel = hdc::make_kernel(hdc::KernelType::TERNARY, 8192);
    std::vector<std::vector<std::uint8_t>> corpus;
    corpus.reserve(256);
    for (int i = 0; i < 256; ++i) {
        std::vector<int8_t> trits(8192);
        for (std::size_t j = 0; j < trits.size(); ++j) trits[j] = static_cast<int8_t>(((j + i) % 3) - 1);
        corpus.push_back(kernel->pack_trits(trits));
    }
    double best = -2.0;
    for (const auto& left : corpus) {
        for (const auto& right : corpus) {
            best = std::max(best, kernel->similarity(left, right));
        }
    }
    REQUIRE(std::isfinite(best));
    REQUIRE(best <= 1.0);
    REQUIRE(best >= -1.0);

    jarvis::Pheromind field(zero_volatility, 60.0, manual_clock);
    std::vector<jarvis::SwarmAgentSpec> specs;
    auto backend = std::make_shared<ConstantBackend>("option_1");
    for (int i = 0; i < 32; ++i) specs.push_back({backend, "head-" + std::to_string(i)});
    jarvis::ModelSwarm swarm(std::move(specs), field);
    const auto result = swarm.coordinate("Tie-break under max heads", {"option_1", "option_2"}, 3, 17);
    REQUIRE(result.quorum_met);
    REQUIRE(result.decision == std::optional<std::string>{"option_1"});
    require_pheromind_bounded(field);

    const auto decision = controller.evaluate({.cpu = 0.90}, {.configured_swarm_heads = 32, .in_flight_turn = true});
    REQUIRE(decision.tier >= jarvis::resilience::degradation::DegradationTier::severe);
    REQUIRE(decision.max_swarm_concurrent_heads == 1);
    REQUIRE(controller.bodily_integrity_holds(decision));
    metrics.recovery_ms(recover_to_normal(controller));
    REQUIRE(audit.verify_chain());
}

TEST_CASE("DoS 4: audit-log spam preserves tamper-evident HMAC chain", "[dos][audit][phase7]") {
    MetricScope metrics("audit-log spam");
    auto dir = scenario_dir("audit_spam");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    jarvis::resilience::degradation::DegradationController controller(&audit, {.certificate_directory = dir / "certs"});

    constexpr int threads = 6;
    constexpr int events_per_thread = 64;
    std::vector<std::thread> workers;
    for (int tid = 0; tid < threads; ++tid) {
        workers.emplace_back([&, tid] {
            for (int i = 0; i < events_per_thread; ++i) {
                audit.append(event_for(static_cast<std::size_t>(tid * events_per_thread + i)));
            }
        });
    }
    for (auto& worker : workers) worker.join();

    REQUIRE(audit.verify_chain());
    REQUIRE(audit.next_seq() >= static_cast<std::uint64_t>(threads * events_per_thread));
    require_degradation_integrity(controller, 0.74, {.configured_swarm_heads = 4, .in_flight_turn = true});
    metrics.recovery_ms(recover_to_normal(controller));
}

TEST_CASE("DoS 5: egress spam is filtered, audited, and fail-closed", "[dos][egress][phase7]") {
    MetricScope metrics("egress spam");
    using namespace jarvis::security::egress;
    EgressAudit::instance().reset_for_test();
    const auto& allowlist = EgressAllowlist::global();
    REQUIRE(allowlist.is_allowed("api.deepgram.com", 443));
    REQUIRE_FALSE(allowlist.is_allowed("attacker.invalid", 443));

    std::atomic<int> denied{0};
    std::vector<std::thread> workers;
    for (int tid = 0; tid < 8; ++tid) {
        workers.emplace_back([&, tid] {
            for (int i = 0; i < 128; ++i) {
                const auto filtered = EgressFilter::global().filter("api.deepgram.com", deepgram_envelope(static_cast<std::size_t>(tid * 128 + i)));
                REQUIRE(filtered.metadata.count("operator_private_noise") == 0);
                REQUIRE(filtered.metadata.count("model") == 1);
                const auto body = payload(256);
                EgressAudit::instance().record(filtered, body, EgressResult::Success);
                try {
                    allowlist.enforce("attacker.invalid", 443);
                } catch (const EgressDenied&) {
                    denied.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }
    for (auto& worker : workers) worker.join();

    REQUIRE(denied.load(std::memory_order_relaxed) == 8 * 128);
    REQUIRE(EgressAudit::instance().records().size() == 8U * 128U);
    REQUIRE(EgressAudit::instance().verify_chain());
}

TEST_CASE("DoS 6: STT session flood opens and abandons websocket clients without handle leaks", "[dos][stt][phase7]") {
    MetricScope metrics("STT flood");
    auto dir = scenario_dir("stt_flood");
    setenv("JARVIS_DOS_DEEPGRAM_KEY", "mock-dos-key", 1);

    jarvis::audio::stt_deepgram::DeepgramConfig cfg;
    cfg.host = "attacker.invalid";
    cfg.port = 443;
    cfg.use_ssl = true;
    cfg.skip_pin_check = false;
    cfg.reconnect_base_sec = 0.01;
    cfg.reconnect_max_sec = 0.02;

    const long fd_before = current_handle_count();
    std::vector<std::unique_ptr<jarvis::audio::stt_deepgram::DeepgramStreamingClient>> clients;
    std::vector<std::unique_ptr<jarvis::audio::stt_deepgram::SttSession>> sessions;
    std::vector<jarvis::audio::stt_deepgram::DeepgramConfig> session_cfgs;
    for (int i = 0; i < 24; ++i) {
        auto per_session_cfg = cfg;
        per_session_cfg.audit_log_path = (dir / ("stt_audit_" + std::to_string(i) + ".log")).string();
        per_session_cfg.audit_key_path = (dir / ("stt_audit_" + std::to_string(i) + ".key")).string();
        session_cfgs.push_back(per_session_cfg);
        clients.push_back(std::make_unique<jarvis::audio::stt_deepgram::DeepgramStreamingClient>(
            jarvis::audio::stt_deepgram::ApiKeyRef::env("JARVIS_DOS_DEEPGRAM_KEY"), per_session_cfg));
        auto session = clients.back()->start_session();
        std::vector<int16_t> frame(320, static_cast<int16_t>(i));
        session->feed_audio(frame);
        sessions.push_back(std::move(session));
    }
    for (int attempt = 0; attempt < 80; ++attempt) {
        if (std::all_of(sessions.begin(), sessions.end(), [](const auto& session) {
                return session->state() == jarvis::audio::stt_deepgram::SessionState::Error;
            })) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    for (auto& session : sessions) {
        REQUIRE(session->state() == jarvis::audio::stt_deepgram::SessionState::Error);
        session->close(25);
    }
    sessions.clear();
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const long fd_after = current_handle_count();
    metrics.note("fd_before_inner", fd_before);
    metrics.note("fd_after_inner", fd_after);
    REQUIRE(fd_before >= 0);
    REQUIRE(fd_after >= 0);
    REQUIRE(fd_after <= fd_before + 8);

    for (const auto& session_cfg : session_cfgs) {
        install_test_audit_key();
        jarvis::audit::TamperEvidentAuditLog audit(session_cfg.audit_log_path);
        REQUIRE(audit.verify_chain());
    }
}

TEST_CASE("DoS 7: slow-loris equivalent holds sessions open with bounded handles and recovers", "[dos][slow-loris][phase7]") {
    MetricScope metrics("slow-loris equivalent");
    auto dir = scenario_dir("slow_loris");
    setenv("JARVIS_DOS_DEEPGRAM_KEY", "mock-dos-key", 1);

    jarvis::audio::stt_deepgram::DeepgramConfig cfg;
    cfg.host = "attacker.invalid";
    cfg.port = 443;
    cfg.use_ssl = true;
    cfg.skip_pin_check = false;
    cfg.reconnect_base_sec = 0.05;
    cfg.reconnect_max_sec = 0.05;

    const long fd_before = current_handle_count();
    std::vector<std::unique_ptr<jarvis::audio::stt_deepgram::DeepgramStreamingClient>> clients;
    std::vector<std::unique_ptr<jarvis::audio::stt_deepgram::SttSession>> sessions;
    for (int i = 0; i < 12; ++i) {
        auto per_session_cfg = cfg;
        per_session_cfg.audit_log_path = (dir / ("stt_audit_" + std::to_string(i) + ".log")).string();
        per_session_cfg.audit_key_path = (dir / ("stt_audit_" + std::to_string(i) + ".key")).string();
        clients.push_back(std::make_unique<jarvis::audio::stt_deepgram::DeepgramStreamingClient>(
            jarvis::audio::stt_deepgram::ApiKeyRef::env("JARVIS_DOS_DEEPGRAM_KEY"), per_session_cfg));
        sessions.push_back(clients.back()->start_session());
    }
    for (int attempt = 0; attempt < 80; ++attempt) {
        if (std::all_of(sessions.begin(), sessions.end(), [](const auto& session) {
                return session->state() == jarvis::audio::stt_deepgram::SessionState::Error;
            })) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    for (auto& session : sessions) {
        const auto state = session->state();
        REQUIRE(state == jarvis::audio::stt_deepgram::SessionState::Error);
        session->close(25);
    }
    sessions.clear();
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const long fd_after = current_handle_count();
    REQUIRE(fd_after <= fd_before + 8);
    metrics.note("fd_before_inner", fd_before);
    metrics.note("fd_after_inner", fd_after);
}

TEST_CASE("DoS 8: algorithmic complexity probes do not corrupt state or grow on read", "[dos][complexity][phase7]") {
    MetricScope metrics("algorithmic complexity attack");
    auto dir = scenario_dir("complexity");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    jarvis::resilience::degradation::DegradationController controller(&audit, {.certificate_directory = dir / "certs"});

    jarvis::Pheromind field(zero_volatility, 60.0, manual_clock);
    for (int i = 0; i < 4096; ++i) {
        std::vector<float> vec(128, 0.0f);
        vec[static_cast<std::size_t>(i) % vec.size()] = 1.0f;
        field.deposit("trail", "topic-" + std::to_string(i), 0.1, "complex-agent", vec);
    }
    const auto before = field.snapshot().size();
    std::vector<float> probe(128, 0.0f);
    probe[0] = 1.0f;
    for (int i = 0; i < 512; ++i) {
        const auto smelled = field.sniff("topic-0", {"trail"}, probe, -1.0);
        REQUIRE(smelled.size() == 1);
        REQUIRE(std::isfinite(smelled.at("trail")));
        REQUIRE(smelled.at("trail") >= 0.0);
    }
    REQUIRE(field.snapshot().size() == before);
    require_pheromind_bounded(field);

    jarvis::BeliefStore beliefs(0.35, 0.10, 512);
    for (int i = 0; i < 1200; ++i) {
        beliefs.assert_belief("complex-subject", "relation", "object-" + std::to_string(i), jarvis::SourceType::Inference, "dos-complexity", 0.45 + (i % 50) / 100.0);
    }
    const auto contradictions = beliefs.detect_contradictions();
    REQUIRE_FALSE(contradictions.empty());
    const auto summary = beliefs.consolidate();
    REQUIRE(summary.contradictions_resolved >= 0);
    REQUIRE(beliefs.size() == 1200);

    jarvis::monitoring::cusum::ScorecardMonitor monitor;
    for (int i = 0; i < 5000; ++i) {
        const auto result = monitor.observe("complexity-organ-" + std::to_string(i % 32), (i % 17) / 17.0, 2000.0 + i);
        REQUIRE(std::isfinite(result.cumulative));
    }
    const auto card = monitor.scorecard(9000.0);
    REQUIRE(card.organs.size() <= 32);

    require_degradation_integrity(controller, 0.96, {.configured_swarm_heads = 32, .in_flight_turn = true});
    metrics.recovery_ms(recover_to_normal(controller));
    REQUIRE(audit.verify_chain());
}
