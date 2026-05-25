#include "beliefstore.h"
#include "beliefstore_persistence.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cctype>
#include <functional>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <unordered_set>
#include <utility>

// For audit logging of HDC security violations.
#include "audit_event.h"
#include "audit_log.h"
#include "../hdc/hdc.h"  // hdc::InvalidBlobLength

namespace jarvis {
namespace {
constexpr std::uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr std::uint64_t FNV_PRIME = 1099511628211ull;

std::uint64_t fnv1a(const std::string& s) {
    std::uint64_t h = FNV_OFFSET;
    for (unsigned char c : s) {
        h ^= c;
        h *= FNV_PRIME;
    }
    return h;
}

std::uint64_t splitmix64(std::uint64_t& x) {
    x += 0x9e3779b97f4a7c15ull;
    std::uint64_t z = x;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

bool is_quarantine_on_assert(SourceType source) {
    return source == SourceType::Model;
}

std::string lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}
} // namespace

std::string to_string(SourceType source) {
    switch (source) {
        case SourceType::Operator: return "operator";
        case SourceType::Document: return "document";
        case SourceType::Inference: return "inference";
        case SourceType::Model: return "model";
    }
    return "inference";
}

SourceType source_type_from_string(const std::string& source) {
    const auto s = lower_copy(source);
    if (s == "operator") return SourceType::Operator;
    if (s == "document") return SourceType::Document;
    if (s == "inference") return SourceType::Inference;
    if (s == "model") return SourceType::Model;
    return SourceType::Inference;
}

BeliefStore::BeliefStore(double retrieval_floor, double hysteresis_margin, int hdc_dim)
    : retrieval_floor_(clamp01(retrieval_floor))
    , hysteresis_margin_(std::max(0.0, hysteresis_margin))
    , kernel_(hdc::make_kernel(hdc::KernelType::REAL, hdc_dim)) {}

BeliefStore::BeliefStore(BeliefStorePersistenceConfig persistence,
                         double retrieval_floor,
                         double hysteresis_margin,
                         int hdc_dim)
    : BeliefStore(retrieval_floor, hysteresis_margin, hdc_dim) {
    persistence_ = std::make_unique<BeliefStoreEncryptedPersistence>(std::move(persistence));
    load_persisted_edges();
}

BeliefStore::~BeliefStore() = default;

int BeliefStore::add(const Belief& belief) {
    return assert_belief(belief.subject, belief.relation, belief.object, belief.source_type,
                         belief.source_ref, belief.confidence, belief.quarantine,
                         belief.provenance_class, belief.charge);
}

int BeliefStore::assert_belief(const std::string& subject,
                               const std::string& relation,
                               const std::string& object,
                               const std::string& source_type,
                               const std::string& source_ref,
                               std::optional<double> confidence,
                               std::optional<bool> quarantine,
                               const std::string& provenance_class,
                               double charge) {
    return assert_belief(subject, relation, object, source_type_from_string(source_type),
                         source_ref, confidence, quarantine, provenance_class, charge);
}

int BeliefStore::assert_belief(const std::string& subject,
                               const std::string& relation,
                               const std::string& object,
                               SourceType source_type,
                               const std::string& source_ref,
                               std::optional<double> confidence,
                               std::optional<bool> quarantine,
                               const std::string& provenance_class,
                               double charge) {
    if (subject.empty() || relation.empty() || object.empty()) {
        throw std::invalid_argument("BeliefStore::assert_belief requires non-empty subject, relation, object");
    }
    const double conf = clamp01(confidence.value_or(default_confidence(source_type)));
    const bool q = quarantine.value_or(is_quarantine_on_assert(source_type));
    const auto hv = tuple_hv(subject, relation, object, source_type);
    const auto key = triple_key(subject, relation, object);

    std::unique_lock lock(mtx_);
    auto existing = triple_index_.find(key);
    if (existing != triple_index_.end()) {
        BeliefEdge& edge = edges_.at(static_cast<std::size_t>(existing->second));
        edge.source_type = source_type;
        edge.source_ref = source_ref;
        edge.confidence = conf;
        edge.quarantined = q;
        edge.provenance_class = provenance_class;
        edge.charge = clamp01(charge);
        edge.tuple_hv = hv;
        persist_locked();
        return edge.id;
    }

    BeliefEdge edge;
    edge.id = next_edge_id_++;
    edge.subject = subject;
    edge.relation = relation;
    edge.object = object;
    edge.source_type = source_type;
    edge.source_ref = source_ref;
    edge.confidence = conf;
    edge.quarantined = q;
    edge.provenance_class = provenance_class;
    edge.charge = clamp01(charge);
    edge.tuple_hv = hv;
    edges_.push_back(std::move(edge));
    triple_index_[key] = static_cast<int>(edges_.size() - 1);
    persist_locked();
    return edges_.back().id;
}

std::optional<std::string> BeliefStore::recall(const std::string& subject,
                                               const std::string& relation,
                                               std::optional<double> min_confidence) const {
    return query(subject, relation, min_confidence).result;
}

QueryResult BeliefStore::query(const std::string& prompt,
                               std::optional<double> min_confidence) const {
    std::istringstream in(prompt);
    std::string subject;
    std::string relation;
    in >> subject >> relation;
    if (subject.empty() || relation.empty()) {
        return {std::nullopt, std::nullopt, 0.0, true, "prompt must contain subject and relation"};
    }
    return query(subject, relation, min_confidence);
}

QueryResult BeliefStore::query(const std::string& subject,
                               const std::string& relation,
                               std::optional<double> min_confidence) const {
    const double floor = clamp01(min_confidence.value_or(retrieval_floor_));
    std::shared_lock lock(mtx_);
    const BeliefEdge* best = nullptr;
    for (const auto& edge : edges_) {
        if (edge.subject != subject || edge.relation != relation) continue;
        if (edge.quarantined || edge.provenance_class != "real") continue;
        if (edge.confidence < floor) continue;
        if (best == nullptr || score(edge) > score(*best)) best = &edge;
    }
    if (best == nullptr) {
        return {std::nullopt, std::nullopt, 0.0, true, "no active belief clears confidence/provenance filters"};
    }
    return {best->object, *best, best->confidence, false, ""};
}

std::vector<std::string> BeliefStore::recall_origin(const std::string& subject,
                                                    const std::string& relation) const {
    std::vector<std::string> out;
    std::shared_lock lock(mtx_);
    for (const auto& edge : edges_) {
        if (edge.subject == subject && edge.relation == relation && edge.provenance_class == "origin") {
            out.push_back(edge.object);
        }
    }
    return out;
}

std::vector<BeliefEdge> BeliefStore::recall_origin_detail(const std::string& subject,
                                                          const std::string& relation) const {
    std::vector<BeliefEdge> out;
    std::shared_lock lock(mtx_);
    for (const auto& edge : edges_) {
        if (edge.subject == subject && edge.relation == relation && edge.provenance_class == "origin") {
            out.push_back(edge);
        }
    }
    return out;
}

std::optional<BeliefEdge> BeliefStore::recall_detail(const std::string& subject,
                                                     const std::string& relation) const {
    const double floor = retrieval_floor_;
    std::shared_lock lock(mtx_);
    const BeliefEdge* best = nullptr;
    for (const auto& edge : edges_) {
        if (edge.subject != subject || edge.relation != relation) continue;
        if (edge.quarantined || edge.confidence < floor) continue;
        if (best == nullptr || score(edge) > score(*best)) best = &edge;
    }
    if (best == nullptr) return std::nullopt;
    return *best;
}

bool BeliefStore::set_charge(int edge_id, double charge) {
    std::unique_lock lock(mtx_);
    for (auto& edge : edges_) {
        if (edge.id == edge_id) {
            edge.charge = clamp01(charge);
            persist_locked();
            return true;
        }
    }
    return false;
}

RevisionRecord BeliefStore::revise(const std::string& subject,
                                    const std::string& relation,
                                    const std::string& new_object,
                                    const std::string& source_type,
                                    const std::string& source_ref,
                                    std::optional<double> confidence) {
    return revise(subject, relation, new_object, source_type_from_string(source_type), source_ref, confidence);
}

RevisionRecord BeliefStore::revise(const std::string& subject,
                                    const std::string& relation,
                                    const std::string& new_object,
                                    SourceType source_type,
                                    const std::string& source_ref,
                                    std::optional<double> confidence) {
    const double conf = clamp01(confidence.value_or(default_confidence(source_type)));
    const double new_score = score_for(source_type, conf);
    (void)new_score;

    std::vector<BeliefEdge> active;
    {
        std::shared_lock lock(mtx_);
        for (const auto& edge : edges_) {
            if (edge.subject == subject && edge.relation == relation && !edge.quarantined) {
                active.push_back(edge);
            }
        }
    }

    for (const auto& edge : active) {
        if (edge.object == new_object) {
            std::unique_lock lock(mtx_);
            for (auto& stored : edges_) {
                if (stored.id == edge.id) {
                    stored.confidence = std::min(1.0, std::max(stored.confidence, conf));
                    stored.source_type = source_type;
                    stored.tuple_hv = tuple_hv(stored.subject, stored.relation, stored.object, stored.source_type);
                    persist_locked();
                    return {subject, relation, new_object, false, {}, stored.id, "reinforced existing belief"};
                }
            }
        }
    }

    std::vector<BeliefEdge> conflicting;
    for (const auto& edge : active) {
        if (edge.object != new_object) conflicting.push_back(edge);
    }

    if (conflicting.empty()) {
        const bool q = is_quarantine_on_assert(source_type);
        const int eid = assert_belief(subject, relation, new_object, source_type, source_ref, conf, q);
        return {subject, relation, new_object, !q, {}, eid, "new belief, no conflict"};
    }

    const auto top_it = std::max_element(conflicting.begin(), conflicting.end(), [this](const auto& a, const auto& b) {
        return score(a) < score(b);
    });
    const int p_new = precedence(source_type);
    const int p_inc = precedence(top_it->source_type);
    const bool flip = (p_new > p_inc) || (p_new == p_inc && conf >= top_it->confidence - hysteresis_margin_);

    if (flip) {
        std::vector<int> demoted;
        const double ts = now_seconds();
        {
            std::unique_lock lock(mtx_);
            for (auto& stored : edges_) {
                if (stored.subject == subject && stored.relation == relation && !stored.quarantined && stored.object != new_object) {
                    stored.confidence = DEMOTED_CONFIDENCE;
                    stored.quarantined = true;
                    stored.revised_at = ts;
                    demoted.push_back(stored.id);
                }
            }
        }
        const int eid = assert_belief(subject, relation, new_object, source_type, source_ref, conf, false);
        return {subject, relation, new_object, true, demoted, eid,
                "new evidence cleared hysteresis; incumbent demoted"};
    }

    const int eid = assert_belief(subject, relation, new_object, source_type, source_ref, conf, true);
    return {subject, relation, new_object, false, {}, eid,
            "below hysteresis margin; held aside, active belief unchanged"};
}

bool BeliefStore::corroborate(const std::string& subject,
                              const std::string& relation,
                              const std::string& object,
                              const std::string& source_type) {
    return corroborate(subject, relation, object, source_type_from_string(source_type));
}

bool BeliefStore::corroborate(const std::string& subject,
                              const std::string& relation,
                              const std::string& object,
                              SourceType source_type) {
    const double promote_conf = default_confidence(source_type);
    bool changed = false;
    std::unique_lock lock(mtx_);
    for (auto& edge : edges_) {
        if (edge.subject != subject || edge.relation != relation || edge.object != object) continue;
        if (edge.quarantined) {
            edge.quarantined = false;
            edge.confidence = std::max(edge.confidence, promote_conf);
            if (precedence(source_type) > precedence(edge.source_type)) edge.source_type = source_type;
            edge.tuple_hv = tuple_hv(edge.subject, edge.relation, edge.object, edge.source_type);
            changed = true;
        } else {
            edge.confidence = std::min(1.0, edge.confidence + 0.1);
            changed = true;
        }
    }
    if (changed) persist_locked();
    return changed;
}

ConsolidationSummary BeliefStore::consolidate(std::optional<double>) {
    ConsolidationSummary summary;
    const double ts = now_seconds();
    std::unique_lock lock(mtx_);
    std::unordered_map<std::string, std::vector<std::size_t>> groups;
    for (std::size_t i = 0; i < edges_.size(); ++i) {
        const auto& edge = edges_[i];
        if (!edge.quarantined) groups[edge.subject + "\x1f" + edge.relation].push_back(i);
    }
    for (const auto& [_, idxs] : groups) {
        std::unordered_set<std::string> objs;
        for (auto idx : idxs) objs.insert(edges_[idx].object);
        if (objs.size() <= 1) continue;
        const auto keep_it = std::max_element(idxs.begin(), idxs.end(), [this](std::size_t a, std::size_t b) {
            return score(edges_[a]) < score(edges_[b]);
        });
        const std::size_t keep = *keep_it;
        for (auto idx : idxs) {
            if (idx == keep) continue;
            if (edges_[idx].object != edges_[keep].object) {
                edges_[idx].confidence = DEMOTED_CONFIDENCE;
                edges_[idx].quarantined = true;
                edges_[idx].revised_at = ts;
                ++summary.contradictions_resolved;
            }
        }
    }
    if (summary.contradictions_resolved > 0 || summary.quarantined_aged > 0) persist_locked();
    return summary;
}

std::vector<Contradiction> BeliefStore::detect_contradictions() const {
    std::shared_lock lock(mtx_);
    std::unordered_map<std::string, std::vector<BeliefEdge>> groups;
    for (const auto& edge : edges_) {
        if (!edge.quarantined) groups[edge.subject + "\x1f" + edge.relation].push_back(edge);
    }
    std::vector<Contradiction> out;
    for (const auto& [_, group] : groups) {
        std::unordered_set<std::string> objs;
        for (const auto& edge : group) objs.insert(edge.object);
        if (objs.size() > 1) out.push_back({group.front().subject, group.front().relation, group});
    }
    return out;
}

std::vector<BeliefEdge> BeliefStore::all_edges() const {
    std::shared_lock lock(mtx_);
    return edges_;
}

std::size_t BeliefStore::size() const {
    std::shared_lock lock(mtx_);
    return edges_.size();
}

void BeliefStore::rotate_persistence_key(security::memory::LockedBytes new_key,
                                         const BeliefStoreRotationAttestation& attestation) {
    if (!persistence_) throw std::runtime_error("BeliefStore persistence is not configured");
    persistence_->rotate_key(std::move(new_key), attestation);
}

void BeliefStore::close_persistence() {
    if (persistence_) persistence_->close();
}

bool BeliefStore::persistence_key_zeroized_on_close_for_test() const noexcept {
    return persistence_ && persistence_->key_zeroized_on_close_for_test();
}

void BeliefStore::load_persisted_edges() {
    if (!persistence_) return;
    auto loaded = persistence_->load_edges();
    std::unique_lock lock(mtx_);
    edges_.clear();
    triple_index_.clear();
    next_edge_id_ = 1;
    for (auto& edge : loaded) {
        edge.tuple_hv = tuple_hv(edge.subject, edge.relation, edge.object, edge.source_type);
        next_edge_id_ = std::max(next_edge_id_, edge.id + 1);
        triple_index_[triple_key(edge.subject, edge.relation, edge.object)] = static_cast<int>(edges_.size());
        edges_.push_back(std::move(edge));
    }
}

void BeliefStore::persist_locked() const {
    if (persistence_) persistence_->save_edges(edges_, next_edge_id_);
}

double BeliefStore::default_confidence(SourceType source) {
    switch (source) {
        case SourceType::Operator: return 0.95;
        case SourceType::Document: return 0.80;
        case SourceType::Inference: return 0.50;
        case SourceType::Model: return 0.20;
    }
    return 0.50;
}

int BeliefStore::precedence(SourceType source) {
    switch (source) {
        case SourceType::Operator: return 3;
        case SourceType::Document: return 2;
        case SourceType::Inference: return 1;
        case SourceType::Model: return 0;
    }
    return 1;
}

double BeliefStore::clamp01(double value) {
    if (!std::isfinite(value) || value <= 0.0) return 0.0;
    if (value >= 1.0) return 1.0;
    return value;
}

double BeliefStore::now_seconds() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration<double>(now).count();
}

std::string BeliefStore::triple_key(const std::string& subject,
                                    const std::string& relation,
                                    const std::string& object) {
    return subject + "\x1f" + relation + "\x1f" + object;
}

double BeliefStore::score(const BeliefEdge& edge) const {
    return score_for(edge.source_type, edge.confidence);
}

double BeliefStore::score_for(SourceType source, double confidence) const {
    return static_cast<double>(precedence(source)) + confidence;
}

std::vector<std::uint8_t> BeliefStore::token_hv(const std::string& token) const {
    std::vector<float> v(static_cast<std::size_t>(kernel_->dim()));
    std::uint64_t state = fnv1a(token);
    double norm2 = 0.0;
    for (auto& x : v) {
        const std::uint64_t bits = splitmix64(state);
        const double u = (static_cast<double>(bits >> 11) * (1.0 / 9007199254740992.0));
        x = static_cast<float>(2.0 * u - 1.0);
        norm2 += static_cast<double>(x) * static_cast<double>(x);
    }
    const float inv = norm2 > 0.0 ? static_cast<float>(1.0 / std::sqrt(norm2)) : 1.0f;
    for (auto& x : v) x *= inv;
    return kernel_->pack_floats(v);
}

std::vector<std::uint8_t> BeliefStore::tuple_hv(const std::string& subject,
                                                const std::string& relation,
                                                const std::string& object,
                                                SourceType source) const {
    try {
        const auto role_subject = token_hv("role:subject");
        const auto role_relation = token_hv("role:relation");
        const auto role_object = token_hv("role:object");
        const auto role_source = token_hv("role:source");
        const auto subj = kernel_->bind(role_subject, token_hv("subject:" + subject));
        const auto rel = kernel_->bind(role_relation, token_hv("relation:" + relation));
        const auto obj = kernel_->bind(role_object, token_hv("object:" + object));
        const auto src = kernel_->bind(role_source, token_hv("source:" + to_string(source)));
        const auto subj_rel = kernel_->bind(kernel_->permute_roll(subj, 1), rel);
        const auto obj_src = kernel_->bind(kernel_->permute_roll(obj, 2), src);
        return kernel_->bundle({subj_rel, obj_src});
    } catch (const hdc::InvalidBlobLength& e) {
        // §2 / AGENTS.md: never silently swallow a security organ rejection.
        try {
            jarvis::audit::AuditEvent ev;
            ev.event_kind = jarvis::audit::EventKind::BODILY_INTEGRITY_VIOLATION_PREVENTED;
            ev.actor      = jarvis::audit::Actor::SELF;
            ev.subject    = "hdc_tuple_hv";
            ev.outcome    = jarvis::audit::Outcome::FAIL;
            ev.reason     = "InvalidPackedLength";
            jarvis::audit::processAuditLog().append(ev);
        } catch (...) {}
        throw;  // re-throw — caller must not silently swallow
    }
}

} // namespace jarvis
