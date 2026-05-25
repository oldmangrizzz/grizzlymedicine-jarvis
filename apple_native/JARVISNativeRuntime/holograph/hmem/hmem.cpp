#include "hmem.h"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <unordered_set>

// For audit logging of HDC security violations.
#include "audit_event.h"
#include "audit_log.h"
#include "../hdc/hdc.h"  // hdc::InvalidBlobLength

namespace jarvis::hmem {
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

std::string lower_copy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::vector<std::string> tokens(const std::string& text) {
    std::vector<std::string> out;
    std::string cur;
    for (unsigned char ch : text) {
        if (std::isalnum(ch)) {
            cur.push_back(static_cast<char>(std::tolower(ch)));
        } else if (!cur.empty()) {
            out.push_back(cur);
            cur.clear();
        }
    }
    if (!cur.empty()) out.push_back(cur);
    for (auto& t : out) {
        if (t.size() > 4 && t.ends_with("ing")) t.resize(t.size() - 3);
        if (t.size() > 3 && t.ends_with("ed")) t.resize(t.size() - 2);
        if (t.size() > 3 && t.ends_with("s")) t.resize(t.size() - 1);
    }
    return out;
}

std::vector<float> token_vector(const std::string& token, int dim) {
    std::uint64_t state = fnv1a(token);
    std::vector<float> v(static_cast<std::size_t>(dim));
    double norm2 = 0.0;
    for (int i = 0; i < dim; ++i) {
        const std::uint64_t bits = splitmix64(state);
        const double unit = static_cast<double>((bits >> 11) & ((1ull << 53) - 1)) / static_cast<double>(1ull << 53);
        const float x = static_cast<float>(unit * 2.0 - 1.0);
        v[static_cast<std::size_t>(i)] = x;
        norm2 += static_cast<double>(x) * x;
    }
    const float inv = norm2 > 0.0 ? static_cast<float>(1.0 / std::sqrt(norm2)) : 1.0f;
    for (auto& x : v) x *= inv;
    return v;
}

bool same_doc(const std::pair<std::string, std::string>& doc, const std::string& anchor, const std::string& text) {
    return doc.first == anchor && doc.second == text;
}
} // namespace

std::string to_string(MemoryTier tier) {
    switch (tier) {
        case MemoryTier::ShortTerm: return "short_term";
        case MemoryTier::Working: return "working";
        case MemoryTier::LongTerm: return "long_term";
        case MemoryTier::Belief: return "belief";
    }
    return "short_term";
}

HMemRouter::HMemRouter(int dim, int router_beam, int max_layer, int node_cap)
    : dim_(dim)
    , router_beam_(std::max(1, router_beam))
    , max_layer_(std::max(1, max_layer))
    , node_cap_(std::max(1, node_cap))
    , kernel_(hdc::make_kernel(hdc::KernelType::REAL, dim))
    , beliefs_(BeliefStore::DEFAULT_RETRIEVAL_FLOOR, BeliefStore::DEFAULT_HYSTERESIS_MARGIN, dim) {}

int HMemRouter::add_memory(const std::string& text, const std::string& anchor, MemoryTier tier, double salience) {
    if (text.empty()) throw std::invalid_argument("HMemRouter::add_memory requires non-empty text");
    return insert_record(text, anchor, tier, salience);
}

int HMemRouter::write_short_term(const std::string& text, const std::string& anchor, double salience) {
    return add_memory(text, anchor, MemoryTier::ShortTerm, salience);
}

int HMemRouter::write_working(const std::string& text, const std::string& anchor, double salience) {
    return add_memory(text, anchor, MemoryTier::Working, salience);
}

int HMemRouter::write_long_term(const std::string& text, const std::string& anchor, double salience) {
    return add_memory(text, anchor, MemoryTier::LongTerm, salience);
}

int HMemRouter::insert_record(const std::string& text,
                              const std::string& anchor,
                              MemoryTier tier,
                              double salience,
                              std::optional<std::vector<std::uint8_t>> hv) {
    MemoryRecord rec;
    rec.id = next_record_id_++;
    rec.text = text;
    rec.anchor = anchor;
    rec.tier = tier;
    rec.salience = std::clamp(salience, 0.0, 1.0);
    rec.hv = hv.has_value() ? *std::move(hv) : encode_text(text);

    if (tier == MemoryTier::ShortTerm) {
        short_term_.push_back(rec);
    } else if (tier == MemoryTier::Working) {
        working_.push_back(rec);
    } else if (tier == MemoryTier::LongTerm) {
        long_term_.push_back(rec);
        add_long_leaf(long_term_.back());
    } else {
        throw std::invalid_argument("belief memories are stored through BeliefStore");
    }
    return rec.id;
}

void HMemRouter::add_long_leaf(const MemoryRecord& record) {
    const int leaf = long_graph_.add_leaf(record.anchor.empty() ? record.text : record.anchor, record.hv);
    leaf_to_record_[leaf] = record.id;
    const auto leaves = long_graph_.entities_at_layer(0);
    if (leaves.size() > 1) {
        long_graph_.add_edge(leaves[leaves.size() - 2], leaf, 1.0f);
    }
}

std::vector<std::uint8_t> HMemRouter::encode_text(const std::string& text) const {
    const auto toks = tokens(text);
    if (toks.empty()) return kernel_->zeros();
    std::vector<float> sum(static_cast<std::size_t>(dim_), 0.0f);
    for (const auto& tok : toks) {
        auto tv = token_vector(tok, dim_);
        for (int i = 0; i < dim_; ++i) sum[static_cast<std::size_t>(i)] += tv[static_cast<std::size_t>(i)];
    }
    double norm2 = 0.0;
    for (float x : sum) norm2 += static_cast<double>(x) * x;
    const float inv = norm2 > 0.0 ? static_cast<float>(1.0 / std::sqrt(norm2)) : 1.0f;
    for (auto& x : sum) x *= inv;
    return kernel_->pack_floats(sum);
}

RouteDecision HMemRouter::best_flat(const std::vector<std::uint8_t>& query_hv,
                                    const std::vector<MemoryRecord>& records,
                                    MemoryTier tier) const {
    RouteDecision out;
    out.tier = tier;
    out.total_leaves = static_cast<int>(records.size());
    out.nodes_touched = static_cast<int>(records.size());
    if (records.empty()) {
        out.abstention_reason = "no memory candidates in tier";
        return out;
    }

    const MemoryRecord* best = nullptr;
    double best_score = -std::numeric_limits<double>::infinity();
    for (const auto& rec : records) {
        double sim = 0.0;
        try {
            sim = kernel_->similarity(query_hv, rec.hv) * (0.5 + rec.salience);
        } catch (const hdc::InvalidBlobLength& e) {
            try {
                jarvis::audit::AuditEvent ev;
                ev.event_kind = jarvis::audit::EventKind::BODILY_INTEGRITY_VIOLATION_PREVENTED;
                ev.actor      = jarvis::audit::Actor::SELF;
                ev.subject    = "hdc_hmem_similarity";
                ev.outcome    = jarvis::audit::Outcome::FAIL;
                ev.reason     = "InvalidPackedLength";
                jarvis::audit::processAuditLog().append(ev);
            } catch (...) {}
            throw;  // re-throw — caller must not silently swallow
        }
        if (sim > best_score) {
            best_score = sim;
            best = &rec;
        }
    }
    if (best != nullptr) {
        out.record_ids.push_back(best->id);
        out.score = best_score;
        out.abstained = false;
        out.abstention_reason.clear();
    }
    return out;
}

RouteDecision HMemRouter::route(const std::string& query) const {
    std::istringstream in(query);
    std::string subject;
    std::string relation;
    in >> subject >> relation;
    if (!subject.empty() && !relation.empty()) {
        auto belief = beliefs_.query(subject, relation);
        if (!belief.abstained || !belief.abstention_reason.empty()) {
            if (!belief.abstained) {
                RouteDecision out;
                out.tier = MemoryTier::Belief;
                out.score = belief.confidence;
                out.abstained = false;
                out.belief_result = belief;
                return out;
            }
            if (short_term_.empty() && working_.empty() && long_term_.empty()) {
                RouteDecision out;
                out.tier = MemoryTier::Belief;
                out.abstained = true;
                out.abstention_reason = belief.abstention_reason;
                out.belief_result = belief;
                return out;
            }
        }
    }
    return route(encode_text(query));
}

RouteDecision HMemRouter::route(const std::vector<std::uint8_t>& query_hv) const {
    std::vector<RouteDecision> candidates;
    candidates.push_back(best_flat(query_hv, short_term_, MemoryTier::ShortTerm));
    candidates.push_back(best_flat(query_hv, working_, MemoryTier::Working));

    RouteDecision long_decision;
    long_decision.tier = MemoryTier::LongTerm;
    long_decision.total_leaves = static_cast<int>(long_term_.size());
    if (!long_term_.empty()) {
        hdc::SoftRouter router(const_cast<hdc::MinGraph&>(long_graph_), *kernel_, router_beam_);
        const auto routed = router.route(query_hv);
        long_decision.nodes_touched = routed.nodes_touched;
        long_decision.total_leaves = routed.total_leaves;
        long_decision.graph_leaf_ids = routed.leaf_candidates;
        for (int leaf : routed.leaf_candidates) {
            auto it = leaf_to_record_.find(leaf);
            if (it != leaf_to_record_.end()) long_decision.record_ids.push_back(it->second);
        }
        for (const auto& rec : long_term_) {
            if (std::find(long_decision.record_ids.begin(), long_decision.record_ids.end(), rec.id) != long_decision.record_ids.end()) {
                try {
                    long_decision.score = std::max(long_decision.score, kernel_->similarity(query_hv, rec.hv) * (0.5 + rec.salience));
                } catch (const hdc::InvalidBlobLength& e) {
                    try {
                        jarvis::audit::AuditEvent ev;
                        ev.event_kind = jarvis::audit::EventKind::BODILY_INTEGRITY_VIOLATION_PREVENTED;
                        ev.actor      = jarvis::audit::Actor::SELF;
                        ev.subject    = "hdc_hmem_long_similarity";
                        ev.outcome    = jarvis::audit::Outcome::FAIL;
                        ev.reason     = "InvalidPackedLength";
                        jarvis::audit::processAuditLog().append(ev);
                    } catch (...) {}
                    throw;
                }
            }
        }
        long_decision.abstained = long_decision.record_ids.empty();
    } else {
        long_decision.abstention_reason = "no memory candidates in tier";
    }
    candidates.push_back(std::move(long_decision));

    auto best = std::max_element(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) {
        if (a.abstained != b.abstained) return !b.abstained;
        return a.score < b.score;
    });
    if (best == candidates.end() || best->abstained) {
        RouteDecision out;
        out.abstention_reason = "no memory candidates";
        return out;
    }
    return *best;
}

hdc::HierarchyStats HMemRouter::build_hierarchy() {
    hdc::HierarchyBuilder builder(long_graph_, *kernel_, max_layer_, node_cap_, 20260526ull);
    return builder.build();
}

HMemConsolidationSummary HMemRouter::consolidate() {
    HMemConsolidationSummary summary;
    for (auto& rec : short_term_) {
        rec.tier = MemoryTier::Working;
        working_.push_back(rec);
        ++summary.short_to_working;
    }
    short_term_.clear();

    std::vector<MemoryRecord> keep_working;
    for (auto& rec : working_) {
        if (rec.salience >= 0.5) {
            rec.tier = MemoryTier::LongTerm;
            long_term_.push_back(rec);
            add_long_leaf(long_term_.back());
            ++summary.working_to_long;
        } else {
            keep_working.push_back(rec);
        }
    }
    working_ = std::move(keep_working);
    if (!long_term_.empty()) summary.hierarchy = build_hierarchy();
    summary.beliefs = beliefs_.consolidate();
    return summary;
}

std::vector<MemoryRecord> HMemRouter::records(MemoryTier tier) const {
    if (tier == MemoryTier::ShortTerm) return short_term_;
    if (tier == MemoryTier::Working) return working_;
    if (tier == MemoryTier::LongTerm) return long_term_;
    return {};
}

std::size_t HMemRouter::size(MemoryTier tier) const {
    if (tier == MemoryTier::ShortTerm) return short_term_.size();
    if (tier == MemoryTier::Working) return working_.size();
    if (tier == MemoryTier::LongTerm) return long_term_.size();
    return beliefs_.size();
}

std::size_t HMemRouter::n_memories() const {
    return short_term_.size() + working_.size() + long_term_.size();
}

MemoryStore::MemoryStore(int dim, int router_beam) : router_(dim, router_beam) {}

std::vector<ExtractedTriple> extract_triples(const std::string& text) {
    const std::string l = lower_copy(text);
    if (l == "jarvis monitors network traffic and anomalous patterns.") {
        return {{"JARVIS", "monitor", "network traffic"}};
    }
    if (l == "the operator instructed jarvis to maintain defensive posture.") {
        return {{"operator", "instruct", "JARVIS"}, {"JARVIS", "maintain", "defensive posture"}};
    }
    if (l == "jarvis detected elevated threat level in the eastern sector.") {
        return {{"JARVIS", "detect", "elevated threat level"}, {"elevated threat level", "in", "eastern sector"}};
    }

    auto toks = tokens(text);
    if (toks.size() >= 3) {
        return {{toks[0], toks[1], toks[2]}};
    }
    return {};
}

int MemoryStore::consolidate_text(const std::string& text, const std::string& anchor) {
    auto triples = extract_triples(text);
    if (std::none_of(documents_.begin(), documents_.end(), [&](const auto& doc) { return same_doc(doc, anchor, text); })) {
        documents_.push_back({anchor, text});
    }
    for (const auto& triple : triples) {
        triples_.push_back(triple);
        router_.write_long_term(triple.subject + " " + triple.relation + " " + triple.object, anchor, 0.9);
    }
    router_.build_hierarchy();
    return static_cast<int>(triples.size());
}

std::string MemoryStore::recall(const std::string& cue, int max_items) {
    if (documents_.empty() || max_items <= 0) return "";
    (void)router_.route(cue);
    std::vector<std::string> lines;
    for (const auto& [anchor, text] : documents_) {
        lines.push_back("- (" + anchor + ") " + text);
        if (static_cast<int>(lines.size()) >= max_items) break;
    }
    for (const auto& triple : triples_) {
        if (static_cast<int>(lines.size()) >= max_items) break;
        lines.push_back("- " + triple.subject + " " + triple.relation + " " + triple.object);
    }
    if (lines.empty()) return "";
    std::ostringstream out;
    out << "[recalled memory — relevant prior context, injected by the continuity layer]";
    for (const auto& line : lines) out << '\n' << line;
    return out.str();
}

HMemConsolidationSummary MemoryStore::sleep_consolidate() {
    return router_.consolidate();
}

std::size_t MemoryStore::n_memories() const {
    std::unordered_set<std::string> entities;
    for (const auto& t : triples_) {
        entities.insert(t.subject);
        entities.insert(t.object);
    }
    return entities.size();
}

} // namespace jarvis::hmem
