#include "self_health.h"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace jarvis::identity::self_health {
namespace {

double round3(double value) {
    if (!std::isfinite(value)) return 0.0;
    return std::round(value * 1000.0) / 1000.0;
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

std::string identity_status_name(IdentityStatus status) {
    switch (status) {
        case IdentityStatus::OK: return "OK";
        case IdentityStatus::BROKEN: return "BROKEN";
        case IdentityStatus::TAMPERED: return "TAMPERED";
    }
    return "BROKEN";
}

std::string degradation_name(resilience::degradation::DegradationTier tier) {
    return resilience::degradation::to_string(tier);
}

int tier_value(resilience::degradation::DegradationTier tier) noexcept {
    return static_cast<int>(tier);
}

std::string metadata_for(const SelfState& state) {
    std::ostringstream os;
    os << "{"
       << "\"timestamp\":" << round3(state.timestamp) << ","
       << "\"distress_reasons\":[";
    for (std::size_t i = 0; i < state.distress_reasons.size(); ++i) {
        if (i) os << ",";
        os << "\"" << json_escape(state.distress_reasons[i]) << "\"";
    }
    os << "],"
       << "\"cortisol\":" << round3(state.endocrine.cortisol) << ","
       << "\"dopamine\":" << round3(state.endocrine.dopamine) << ","
       << "\"adrenaline\":" << round3(state.endocrine.adrenaline) << ","
       << "\"pheromind_volatility\":" << round3(state.pheromind.volatility) << ","
       << "\"cusum_max_drift\":" << round3(state.cusum.max_drift_score) << ","
       << "\"degradation_tier\":\"" << json_escape(degradation_name(state.degradation_tier)) << "\",";
    os << "\"identity_chain\":\"" << json_escape(state.identity_chain.status) << "\",";
    os << "\"audit_chain\":\"" << json_escape(state.audit_chain.status) << "\"";
    os << "}";
    return os.str();
}

} // namespace

SelfHealth::SelfHealth(SelfHealthOrgans organs, SelfHealthConfig config)
    : organs_(std::move(organs)), config_(config),
      clock_(organs_.clock ? organs_.clock : default_clock()) {
    if (!std::isfinite(config_.tick_hz) || config_.tick_hz <= 0.0) {
        throw std::invalid_argument("SelfHealth tick_hz must be finite and positive");
    }
    cached_ = sample_();
    loop_ = std::thread([this] { loop_body_(); });
}

SelfHealth::~SelfHealth() {
    alive_.store(false, std::memory_order_release);
    if (loop_.joinable()) loop_.join();
}

SelfState SelfHealth::current() {
    SelfState state = sample_();
    audit_if_distressed_(state);
    {
        std::lock_guard<std::mutex> lock(mtx_);
        cached_ = state;
    }
    return state;
}

SelfState SelfHealth::cached() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return cached_;
}

std::function<double()> SelfHealth::default_clock() {
    return [] {
        const auto now = std::chrono::system_clock::now().time_since_epoch();
        return std::chrono::duration<double>(now).count();
    };
}

SelfState SelfHealth::sample_() {
    SelfState state;
    state.timestamp = clock_();

    if (organs_.endocrine) {
        state.endocrine.present = true;
        state.endocrine.cortisol = organs_.endocrine->level("cortisol");
        state.endocrine.dopamine = organs_.endocrine->level("dopamine");
        state.endocrine.adrenaline = organs_.endocrine->level("adrenaline");
        state.endocrine.field_volatility = organs_.endocrine->field_volatility();
    }

    if (organs_.pheromind) {
        state.pheromind.present = true;
        const auto entries = organs_.pheromind->snapshot();
        state.pheromind.live_signals = entries.size();
        state.pheromind.sampled_signals = std::min(entries.size(), config_.max_pheromind_signals);
        double sum = 0.0;
        for (std::size_t i = 0; i < state.pheromind.sampled_signals; ++i) {
            const auto& entry = entries[i];
            sum += entry.strength;
            state.pheromind.max_strength = std::max(state.pheromind.max_strength, entry.strength);
            if (entry.kind == "alarm") {
                state.pheromind.alarm_strength = std::max(state.pheromind.alarm_strength, entry.strength);
            }
        }
        if (state.pheromind.sampled_signals > 0) {
            state.pheromind.mean_strength = sum / static_cast<double>(state.pheromind.sampled_signals);
        }
        state.pheromind.volatility = state.endocrine.present ? state.endocrine.field_volatility : 0.0;
        state.pheromind.volatile_field = state.pheromind.volatility >= config_.pheromind_volatility_threshold
                                      || state.pheromind.alarm_strength >= 0.70;
    }

    if (organs_.swarm) {
        state.swarm.present = true;
        const auto health = organs_.swarm->head_health();
        state.swarm.configured_heads = health.configured_heads;
        state.swarm.has_available_head = health.has_available_head;
    }

    if (organs_.beliefstore) {
        state.beliefstore.present = true;
        const auto edges = organs_.beliefstore->all_edges();
        state.beliefstore.total_edges = edges.size();
        state.beliefstore.sampled_edges = std::min(edges.size(), config_.max_belief_edges);
        double sum = 0.0;
        for (std::size_t i = 0; i < state.beliefstore.sampled_edges; ++i) {
            const double c = std::clamp(edges[i].confidence, 0.0, 1.0);
            sum += c;
            if (c < 0.35) ++state.beliefstore.low_confidence;
            else if (c < 0.70) ++state.beliefstore.medium_confidence;
            else ++state.beliefstore.high_confidence;
        }
        if (state.beliefstore.sampled_edges > 0) {
            state.beliefstore.mean_confidence = sum / static_cast<double>(state.beliefstore.sampled_edges);
        }
    }

    if (organs_.hmem) {
        state.hmem.present = true;
        state.hmem.short_term = organs_.hmem->size(hmem::MemoryTier::ShortTerm);
        state.hmem.working = organs_.hmem->size(hmem::MemoryTier::Working);
        state.hmem.long_term = organs_.hmem->size(hmem::MemoryTier::LongTerm);
        state.hmem.belief = organs_.hmem->beliefs().size();
    }

    if (organs_.cusum) {
        state.cusum.present = true;
        const auto scorecard = organs_.cusum->scorecard(state.timestamp);
        for (const auto& organ : scorecard.organs) {
            if (organ.drift_score >= state.cusum.max_drift_score) {
                state.cusum.max_drift_score = organ.drift_score;
                state.cusum.max_threshold = organ.threshold;
                state.cusum.max_organ = organ.organ;
            }
            state.cusum.threshold_crossed = state.cusum.threshold_crossed || organ.threshold_crossed;
        }
    }

    if (organs_.degradation) {
        state.degradation_present = true;
        state.degradation_tier = organs_.degradation->current_tier();
    }

    if (organs_.identity_status_reader) {
        state.identity_chain.present = true;
        const IdentityStatus status = organs_.identity_status_reader();
        state.identity_chain.status = identity_status_name(status);
        state.identity_chain.warning = status != IdentityStatus::OK;
    }

    if (organs_.audit_log) {
        state.audit_chain.present = true;
        const bool intact = organs_.audit_log->verify_chain();
        state.audit_chain.status = intact ? "OK" : "BROKEN";
        state.audit_chain.warning = !intact;
    }

    if (state.cusum.present) {
        const bool severe_by_ratio = state.cusum.max_threshold > 0.0
                                  && state.cusum.max_drift_score >= state.cusum.max_threshold * config_.severe_drift_ratio;
        if (state.cusum.threshold_crossed || severe_by_ratio) {
            state.distress_reasons.push_back("severe_drift");
        }
    }
    if (state.identity_chain.warning) state.distress_reasons.push_back("identity_chain_warning");
    if (state.audit_chain.warning) state.distress_reasons.push_back("audit_chain_warning");
    if (state.degradation_present && tier_value(state.degradation_tier) >= config_.audit_degradation_tier_threshold) {
        state.distress_reasons.push_back("degradation_tier_3_plus");
    }

    state.summary = summarize(state);
    return state;
}

void SelfHealth::loop_body_() {
    const auto period = std::chrono::duration<double>(1.0 / config_.tick_hz);
    while (alive_.load(std::memory_order_acquire)) {
        const SelfState state = current();
        {
            std::lock_guard<std::mutex> lock(mtx_);
            cached_ = state;
        }
        const auto sleep_for = std::chrono::duration_cast<std::chrono::milliseconds>(period);
        std::this_thread::sleep_for(std::max(std::chrono::milliseconds(1), sleep_for));
    }
}

void SelfHealth::audit_if_distressed_(const SelfState& state) {
    if (!organs_.audit_log || state.distress_reasons.empty()) return;
    const std::string signature = distress_signature_(state);
    {
        std::lock_guard<std::mutex> lock(mtx_);
        if (signature == last_distress_signature_) return;
        last_distress_signature_ = signature;
    }

    audit::AuditEvent event;
    event.event_kind = audit::EventKind::DISTRESS_BEACON_RAISED;
    event.actor = audit::Actor::SELF;
    event.subject = "self_health_snapshot";
    event.outcome = audit::Outcome::PASS;
    event.reason = signature;
    event.redacted_metadata = metadata_for(state);
    event.organ = "self_health";
    organs_.audit_log->append(event);
}

std::string SelfHealth::distress_signature_(const SelfState& state) {
    std::ostringstream os;
    for (std::size_t i = 0; i < state.distress_reasons.size(); ++i) {
        if (i) os << "+";
        os << state.distress_reasons[i];
    }
    return os.str();
}

std::string SelfHealth::summarize(const SelfState& state) {
    std::vector<std::string> notices;
    if (state.endocrine.present) {
        if (state.endocrine.cortisol >= 0.70) notices.push_back("cortisol is high");
        if (state.endocrine.dopamine <= 0.12) notices.push_back("dopamine reserves are low");
        if (state.endocrine.adrenaline >= 0.70) notices.push_back("adrenaline is high");
    }
    if (state.pheromind.present && state.pheromind.volatile_field) {
        notices.push_back("pheromind is volatile");
    }
    if (state.swarm.present && !state.swarm.has_available_head) {
        notices.push_back("no swarm head is available");
    }
    if (state.beliefstore.present && state.beliefstore.sampled_edges > 0 && state.beliefstore.mean_confidence < 0.35) {
        notices.push_back("belief confidence is thin");
    }
    if (state.hmem.present && state.hmem.working > state.hmem.short_term + state.hmem.long_term + 64) {
        notices.push_back("working memory is crowded");
    }
    if (state.cusum.present && state.cusum.threshold_crossed) {
        notices.push_back("CUSUM drift is severe" + (state.cusum.max_organ.empty() ? std::string{} : " in " + state.cusum.max_organ));
    }
    if (state.degradation_present && tier_value(state.degradation_tier) >= 3) {
        notices.push_back("degradation is tier 3 or higher");
    }
    if (state.identity_chain.warning) notices.push_back("identity chain needs attention");
    if (state.audit_chain.warning) notices.push_back("audit chain needs attention");

    if (notices.empty()) {
        return "I notice my core organs are steady; I can continue at normal pace.";
    }

    std::ostringstream os;
    os << "I notice ";
    for (std::size_t i = 0; i < notices.size(); ++i) {
        if (i == 1 && notices.size() == 2) os << " and ";
        else if (i > 0) os << ", ";
        os << notices[i];
    }
    os << "; I should pace and keep bodily integrity checks active.";
    return os.str();
}

} // namespace jarvis::identity::self_health
