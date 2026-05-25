#include "pheromind.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <iterator>
#include <mutex>

namespace jarvis {

static double tau_for_kind(const std::string& kind, double default_tau) noexcept {
    if (kind == "trail")     return Pheromind::TAU_TRAIL;
    if (kind == "alarm")     return Pheromind::TAU_ALARM;
    if (kind == "territory") return Pheromind::TAU_TERRITORY;
    if (kind == "recruit")   return Pheromind::TAU_RECRUIT;
    return default_tau;
}

static double finite_or(double x, double fallback) noexcept {
    return std::isfinite(x) ? x : fallback;
}

static double clamp01(double x) noexcept {
    if (std::isnan(x)) return 0.0;
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    return x;
}

static double round4(double x) {
    if (!std::isfinite(x)) return 0.0;
    return std::round(x * 10000.0) / 10000.0;
}

static double cosine(std::span<const float> a, const std::vector<float>& b) {
    if (a.empty() || b.empty() || a.size() != b.size()) return 0.0;
    double dot = 0.0;
    double na = 0.0;
    double nb = 0.0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        dot += static_cast<double>(a[i]) * static_cast<double>(b[i]);
        na  += static_cast<double>(a[i]) * static_cast<double>(a[i]);
        nb  += static_cast<double>(b[i]) * static_cast<double>(b[i]);
    }
    if (na == 0.0 || nb == 0.0) return 0.0;
    double c = dot / (std::sqrt(na) * std::sqrt(nb));
    return std::isfinite(c) ? c : 0.0;
}

Pheromind::Pheromind(Endocrine& endo, double base_tau, std::function<double()> clock)
    : clock_(std::move(clock))
    , volatility_fn_([&endo]() { return endo.field_volatility(); })
    , base_tau_default_(base_tau)
{}

Pheromind::Pheromind(std::function<double()> volatility_fn,
                     double base_tau,
                     std::function<double()> clock)
    : clock_(std::move(clock))
    , volatility_fn_(std::move(volatility_fn))
    , base_tau_default_(base_tau)
{}

std::function<double()> Pheromind::default_clock() {
    return []() -> double {
        auto tp = std::chrono::steady_clock::now().time_since_epoch();
        return std::chrono::duration<double>(tp).count();
    };
}

double Pheromind::eff_tau_(const std::string& kind) const {
    double base = finite_or(tau_for_kind(kind, base_tau_default_), TAU_TRAIL);
    if (base <= 0.0) base = TAU_TRAIL;
    double vol = clamp01(volatility_fn_());
    return base / (1.0 + 2.0 * vol);
}

double Pheromind::current_(const FieldEntry& e, const std::string& kind) const {
    double now = finite_or(clock_(), e.last_t);
    double dt = std::max(0.0, now - e.last_t);
    double tau = eff_tau_(kind);
    double live = finite_or(e.strength, 0.0) * std::exp(-dt / tau);
    return std::isfinite(live) ? std::clamp(live, 0.0, STRENGTH_CAP) : 0.0;
}

double Pheromind::deposit(std::string kind, std::string topic, double strength,
                          std::string agent, std::span<const float> vec) {
    double now = finite_or(clock_(), 0.0);
    double clean_strength = clamp01(strength);
    if (kind.size() > MAX_IDENTIFIER_BYTES || topic.size() > MAX_IDENTIFIER_BYTES ||
        agent.size() > MAX_IDENTIFIER_BYTES) {
        return 0.0;
    }

    std::unique_lock lock(mtx_);
    auto kit = field_.find(kind);
    if (kit == field_.end()) {
        if (clean_strength <= 0.0) return 0.0;
        if (entry_count_ >= MAX_FIELD_ENTRIES) {
            gc_locked_(now, std::numeric_limits<double>::infinity());
            if (entry_count_ >= MAX_FIELD_ENTRIES) return 0.0;
        }
        kit = field_.emplace(kind, std::unordered_map<std::string, FieldEntry>{}).first;
    }

    auto it = kit->second.find(topic);

    if (it == kit->second.end()) {
        if (clean_strength <= 0.0) return 0.0;
        if (entry_count_ >= MAX_FIELD_ENTRIES) {
            gc_locked_(now, std::numeric_limits<double>::infinity());
            if (entry_count_ >= MAX_FIELD_ENTRIES) return 0.0;
            kit = field_.find(kind);
            if (kit == field_.end()) {
                kit = field_.emplace(kind, std::unordered_map<std::string, FieldEntry>{}).first;
            }
        }
        FieldEntry e;
        e.strength = clean_strength;
        e.last_t   = now;
        e.depositors.insert(std::move(agent));
        if (!vec.empty()) {
            const auto n = std::min(vec.size(), MAX_VECTOR_DIM);
            e.vec.assign(vec.begin(), vec.begin() + static_cast<std::ptrdiff_t>(n));
        }
        double result = e.strength;
        kit->second.emplace(std::move(topic), std::move(e));
        ++entry_count_;
        return result;
    }

    FieldEntry& e = it->second;
    double live = current_(e, kind);
    e.strength  = std::min(STRENGTH_CAP, live + clean_strength);
    e.last_t    = now;
    if (e.depositors.size() < MAX_DEPOSITORS_PER_ENTRY || e.depositors.count(agent) != 0) {
        e.depositors.insert(std::move(agent));
    }
    if (e.vec.empty() && !vec.empty()) {
        const auto n = std::min(vec.size(), MAX_VECTOR_DIM);
        e.vec.assign(vec.begin(), vec.begin() + static_cast<std::ptrdiff_t>(n));
    }
    return e.strength;
}

double Pheromind::sense(const std::string& kind, const std::string& topic) const {
    std::shared_lock lock(mtx_);
    auto kit = field_.find(kind);
    if (kit == field_.end()) return 0.0;
    auto tit = kit->second.find(topic);
    if (tit == kit->second.end()) return 0.0;
    double s = current_(tit->second, kind);
    return (s >= GC_FLOOR) ? s : 0.0;
}

std::unordered_map<std::string, double> Pheromind::sense(
    const std::string& topic,
    const std::vector<std::string>& kinds,
    std::span<const float> vec,
    double cosine_thresh) const {
    std::shared_lock lock(mtx_);
    std::unordered_set<std::string> want(kinds.begin(), kinds.end());
    std::unordered_map<std::string, double> out;

    for (const auto& [kind, inner] : field_) {
        if (!want.empty() && want.find(kind) == want.end()) continue;
        for (const auto& [sig_topic, entry] : inner) {
            double s = current_(entry, kind);
            if (s < GC_FLOOR) continue;

            double w = 0.0;
            if (sig_topic == topic) {
                w = 1.0;
            } else if (!vec.empty() && !entry.vec.empty()) {
                double c = cosine(vec, entry.vec);
                if (c >= cosine_thresh) w = c;
            }
            if (w > 0.0) out[kind] += w * s;
        }
    }
    return out;
}

std::unordered_map<std::string, double> Pheromind::sniff(
    const std::string& topic,
    const std::vector<std::string>& kinds,
    std::span<const float> vec,
    double cosine_thresh) const {
    return sense(topic, kinds, vec, cosine_thresh);
}

std::unordered_map<std::string, double>
Pheromind::sense_all(const std::string& kind) const {
    std::shared_lock lock(mtx_);
    std::unordered_map<std::string, double> out;
    auto kit = field_.find(kind);
    if (kit == field_.end()) return out;
    for (const auto& [topic, entry] : kit->second) {
        double s = current_(entry, kind);
        if (s >= GC_FLOOR) out[topic] = s;
    }
    return out;
}

bool Pheromind::quorum(const std::string& kind, const std::string& topic,
                       int min_distinct_agents, double min_strength) const {
    std::shared_lock lock(mtx_);
    auto kit = field_.find(kind);
    if (kit == field_.end()) return false;
    auto tit = kit->second.find(topic);
    if (tit == kit->second.end()) return false;
    const FieldEntry& e = tit->second;
    return (static_cast<int>(e.depositors.size()) >= min_distinct_agents)
        && (current_(e, kind) >= min_strength);
}

int Pheromind::gc_locked_(double now, double older_than_sec) {
    int removed = 0;

    for (auto& [kind, inner] : field_) {
        std::vector<std::string> dead;
        for (const auto& [topic, entry] : inner) {
            double s   = current_(entry, kind);
            double age = std::max(0.0, now - entry.last_t);
            if (s < GC_FLOOR || age > older_than_sec) dead.push_back(topic);
        }
        for (const auto& t : dead) {
            inner.erase(t);
            ++removed;
            --entry_count_;
        }
    }

    auto it = field_.begin();
    while (it != field_.end()) {
        it = it->second.empty() ? field_.erase(it) : std::next(it);
    }

    return removed;
}

int Pheromind::gc(double older_than_sec) {
    double now = finite_or(clock_(), 0.0);
    std::unique_lock lock(mtx_);
    return gc_locked_(now, older_than_sec);
}

std::vector<Pheromind::SnapshotEntry> Pheromind::snapshot() const {
    std::shared_lock lock(mtx_);
    std::vector<SnapshotEntry> out;
    for (const auto& [kind, inner] : field_) {
        for (const auto& [topic, entry] : inner) {
            out.push_back({kind, topic, round4(current_(entry, kind)),
                           static_cast<int>(entry.depositors.size())});
        }
    }
    std::sort(out.begin(), out.end(), [](const SnapshotEntry& a, const SnapshotEntry& b) {
        if (a.strength != b.strength) return a.strength > b.strength;
        if (a.kind != b.kind) return a.kind < b.kind;
        return a.topic < b.topic;
    });
    return out;
}

} // namespace jarvis
