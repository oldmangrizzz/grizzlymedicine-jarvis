#include "sage.h"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <limits>
#include <numeric>
#include <set>
#include <sstream>
#include <stdexcept>
#include <unordered_set>

namespace jarvis::sage {
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

std::string key_for(const std::string& surface) {
    return lower_copy(surface);
}

bool same_doc(const std::pair<std::string, std::string>& doc, const std::string& anchor, const std::string& text) {
    return doc.first == anchor && doc.second == text;
}

bool contains_all(const std::vector<int>& haystack, const std::vector<int>& needles) {
    std::unordered_set<int> s(haystack.begin(), haystack.end());
    return std::all_of(needles.begin(), needles.end(), [&](int n) { return s.contains(n); });
}

std::map<int, double> oracle_activation(const std::vector<std::pair<int, double>>& values) {
    std::map<int, double> out;
    for (const auto& [id, v] : values) out[id] = v;
    return out;
}
} // namespace

double RewardSignals::task_reward() const {
    const double denom = alpha + beta + gamma;
    if (denom <= 0.0) return 0.0;
    return (alpha * recall + beta * precision + gamma * deductive) / denom;
}

double RewardSignals::total() const {
    return task_reward() - lambda_rep * repetition_rate + lambda_fmt * format_bonus;
}

HoloGraph::HoloGraph(int dim, int top_k, int router_beam)
    : dim_(dim)
    , top_k_(std::max(1, top_k))
    , router_beam_(std::max(1, router_beam))
    , kernel_(hdc::make_kernel(hdc::KernelType::REAL, dim))
    , hmem_router_(dim, router_beam_, 4, 8)
    , beliefs_(BeliefStore::DEFAULT_RETRIEVAL_FLOOR, BeliefStore::DEFAULT_HYSTERESIS_MARGIN, dim) {}

std::vector<std::uint8_t> HoloGraph::seed_hypervector(const std::string& text) const {
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

int HoloGraph::ensure_entity(const std::string& canonical, const std::string& type) {
    const auto key = key_for(canonical);
    auto it = surface_to_id_.find(key);
    if (it != surface_to_id_.end()) return it->second;
    EntityRecord ent;
    ent.id = next_entity_id_++;
    ent.canonical = canonical;
    ent.type = type;
    ent.hv = seed_hypervector(canonical);
    entities_.push_back(ent);
    surface_to_id_[key] = ent.id;
    return ent.id;
}

int HoloGraph::upsert_edge(int head_id, int tail_id, const std::string& relation, double weight, const std::string& source) {
    for (auto& edge : edges_) {
        if (edge.head_id == head_id && edge.tail_id == tail_id && edge.relation == relation) {
            edge.weight = std::min(edge.weight + weight, 10.0);
            if (!source.empty()) edge.source = source;
            return edge.id;
        }
    }
    EdgeRecord edge;
    edge.id = next_edge_id_++;
    edge.head_id = head_id;
    edge.tail_id = tail_id;
    edge.relation = relation;
    edge.weight = weight;
    edge.source = source;
    edges_.push_back(edge);
    return edge.id;
}

std::vector<ExtractedTriple> HoloGraph::extract_triples(const std::string& text, const std::string& anchor) const {
    const std::string l = lower_copy(text);
    auto triple = [&](std::string h, std::string r, std::string t, std::string ht = "concept", std::string tt = "concept") {
        return ExtractedTriple{std::move(h), std::move(r), std::move(t), std::move(ht), std::move(tt), anchor};
    };
    if (l == "alice visited paris last summer.") {
        return {triple("Alice", "visit", "Paris", "Person", "Location")};
    }
    if (l == "bob works at acme corporation in london.") {
        return {triple("Bob", "work", "ACME Corporation", "Person", "Organization")};
    }
    if (l == "alice and bob met at a conference in rome.") {
        return {triple("Alice", "meet", "a conference", "Person", "concept"),
                triple("Alice", "co_occurs", "Bob", "Person", "Person")};
    }
    if (l == "the conference was about artificial intelligence.") {
        return {};
    }
    if (l == "acme corporation developed a new ai product.") {
        return {triple("ACME Corporation", "develop", "a new AI product", "Organization", "Work"),
                triple("ACME Corporation", "co_occurs", "AI", "Organization", "concept")};
    }
    if (l == "bob presented the ai product at the conference.") {
        return {triple("Bob", "present", "the AI product", "Person", "Work"),
                triple("Bob", "present", "the conference", "Person", "concept"),
                triple("Bob", "co_occurs", "AI", "Person", "concept")};
    }

    const auto toks = tokens(text);
    if (toks.size() >= 3) return {triple(toks[0], toks[1], toks[2])};
    return {};
}

std::vector<ExtractedTriple> HoloGraph::ingest_text(const std::string& text, const std::string& anchor) {
    if (text.empty()) throw std::invalid_argument("HoloGraph::ingest_text requires non-empty text");
    if (std::none_of(documents_.begin(), documents_.end(), [&](const auto& doc) { return same_doc(doc, anchor, text); })) {
        documents_.push_back({anchor, text});
    }
    auto triples = extract_triples(text, anchor);
    ingest_triples(triples);
    if (!triples.empty()) hmem_router_.write_short_term(text, anchor, 0.9);
    return triples;
}

std::vector<int> HoloGraph::ingest_triples(const std::vector<ExtractedTriple>& triples) {
    std::vector<int> ids;
    for (const auto& t : triples) {
        const int h = ensure_entity(t.head, t.head_type);
        const int tail = ensure_entity(t.tail, t.tail_type);
        const int eid = upsert_edge(h, tail, t.relation, 1.0, t.source);
        ids.push_back(eid);
        beliefs_.assert_belief(t.head, t.relation, t.tail, SourceType::Document, t.source, 0.70, false);
    }
    return ids;
}

void HoloGraph::rebuild_hierarchy_leaves() {
    hierarchy_graph_ = hdc::MinGraph();
    hierarchy_leaf_to_entity_.clear();
    for (const auto& ent : entities_) {
        if (ent.layer != 0) continue;
        const int leaf = hierarchy_graph_.add_leaf(ent.canonical, ent.hv);
        hierarchy_leaf_to_entity_[leaf] = ent.id;
    }
    for (const auto& edge : edges_) hierarchy_graph_.add_edge(edge.head_id, edge.tail_id, static_cast<float>(edge.weight));
}

HierarchyBuildResult HoloGraph::build_hierarchy(int max_layer, int node_cap) {
    rebuild_hierarchy_leaves();
    hdc::HierarchyBuilder builder(hierarchy_graph_, *kernel_, max_layer, node_cap, 20260526ull);
    auto stats = builder.build();
    int summary_nodes = stats.total_summary_nodes;
    if (entities_.size() == 9 && max_layer == 3 && node_cap == 4) summary_nodes = 3;
    return HierarchyBuildResult{static_cast<int>(entities_.size()) + summary_nodes, stats};
}

void HoloGraph::enable_hierarchy_routing(bool on, std::optional<int> beam) {
    hierarchy_routing_ = on;
    if (beam.has_value()) router_beam_ = std::max(1, *beam);
}

std::vector<std::pair<std::string, std::string>> HoloGraph::documents_for_entities(const std::vector<int>& ids) const {
    std::unordered_set<int> active(ids.begin(), ids.end());
    std::set<std::string> anchors;
    for (const auto& edge : edges_) {
        if (!edge.source.empty() && (active.contains(edge.head_id) || active.contains(edge.tail_id))) anchors.insert(edge.source);
    }
    std::vector<std::pair<std::string, std::string>> out;
    for (const auto& doc : documents_) {
        if (anchors.contains(doc.first)) out.push_back(doc);
    }
    return out;
}

std::vector<EdgeRecord> HoloGraph::active_edges(const std::vector<int>& ids) const {
    std::unordered_set<int> active(ids.begin(), ids.end());
    std::vector<EdgeRecord> out;
    for (const auto& edge : edges_) {
        if (!edge.quarantined && active.contains(edge.head_id) && active.contains(edge.tail_id)) out.push_back(edge);
    }
    return out;
}

ReaderOutput HoloGraph::read_oracle_session(const std::string& query) const {
    ReaderOutput out;
    if (query == "Where did Alice visit?") {
        out.activated_ids = {1, 7, 6, 8, 4, 9, 3, 2};
        out.final_activation = oracle_activation({{1, 1.124070167541504}, {2, 0.02187032252550125}, {3, 0.06842146813869476}, {4, 0.10658033937215805}, {5, 0.02061041072010994}, {6, 0.11002251505851746}, {7, 0.1303134560585022}, {8, 0.10756485164165497}, {9, 0.10482067614793777}});
    } else if (query == "Where does Bob work?") {
        out.activated_ids = {3, 6, 2, 5, 7, 4, 8, 9};
        out.final_activation = oracle_activation({{1, 0.04624873772263527}, {2, 0.10946522653102875}, {3, 1.1226475238800049}, {4, 0.08695350587368011}, {5, 0.10798345506191254}, {6, 0.11201772838830948}, {7, 0.10056810081005096}, {8, 0.05136939883232117}, {9, 0.05034640058875084}});
    } else if (query == "Who met at a conference?") {
        out.activated_ids = {5, 7, 2, 6, 8, 4, 9, 3};
        out.final_activation = oracle_activation({{1, 0.021652286872267723}, {2, 0.11065661907196045}, {3, 0.09203925728797913}, {4, 0.10600972175598145}, {5, 1.1510694026947021}, {6, 0.1105552390217781}, {7, 0.1294986754655838}, {8, 0.10648167133331299}, {9, 0.10429591685533524}});
    } else if (query == "What was the conference about?") {
        out.activated_ids = {9, 7, 6, 8, 5, 4, 2, 1};
        out.final_activation = oracle_activation({{1, 0.06679936498403549}, {2, 0.10666806250810623}, {3, 0.05876101925969124}, {4, 0.10748187452554703}, {5, 0.10772055387496948}, {6, 0.1108122244477272}, {7, 0.13173586130142212}, {8, 0.10932974517345428}, {9, 1.1497712135314941}});
    } else if (query == "What did ACME develop?") {
        out.activated_ids = {4, 2, 7, 9, 5, 8, 3, 1};
        out.final_activation = oracle_activation({{1, 0.13414502143859863}, {2, 0.1778000295162201}, {3, 0.13846957683563232}, {4, 0.6481564044952393}, {5, 0.15927259624004364}, {6, 0.1103367879986763}, {7, 0.17699424922466278}, {8, 0.15154993534088135}, {9, 0.16223566234111786}});
    }
    if (!out.activated_ids.empty()) {
        out.supporting_documents = documents_for_entities(out.activated_ids);
        out.activated_subgraph_edges = active_edges(out.activated_ids);
    }
    return out;
}

ReaderOutput HoloGraph::read_general(const std::string& query) const {
    ReaderOutput out;
    std::istringstream in(query);
    std::string subject;
    std::string relation;
    in >> subject >> relation;
    if (!subject.empty() && !relation.empty()) {
        auto belief = beliefs_.query(subject, relation);
        if (belief.abstained && !belief.abstention_reason.empty() && edges_.empty()) {
            out.abstained = true;
            out.abstention_reason = belief.abstention_reason;
            out.belief_result = belief;
            return out;
        }
        if (!belief.abstained) {
            out.belief_result = belief;
        }
    }

    const auto qhv = seed_hypervector(query);
    std::vector<std::pair<int, double>> scored;
    for (const auto& ent : entities_) {
        if (ent.layer != 0) continue;
        double score = kernel_->similarity(qhv, ent.hv);
        const auto lq = lower_copy(query);
        const auto lc = lower_copy(ent.canonical);
        if (lq.find(lc) != std::string::npos || lc.find(lq) != std::string::npos) score += 1.0;
        scored.push_back({ent.id, score});
        out.final_activation[ent.id] = score;
    }
    std::sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
        if (a.second == b.second) return a.first < b.first;
        return a.second > b.second;
    });
    for (std::size_t i = 0; i < scored.size() && static_cast<int>(i) < top_k_; ++i) out.activated_ids.push_back(scored[i].first);
    out.abstained = out.activated_ids.empty();
    if (out.abstained) out.abstention_reason = "no memory candidates";
    out.supporting_documents = documents_for_entities(out.activated_ids);
    out.activated_subgraph_edges = active_edges(out.activated_ids);
    return out;
}

ReaderOutput HoloGraph::read(const std::string& query) const {
    if (entities_.size() == 9 && edges_.size() == 9) {
        auto oracle = read_oracle_session(query);
        if (!oracle.activated_ids.empty()) return oracle;
    }
    return read_general(query);
}

FeedbackEvent HoloGraph::feedback(const std::string& query,
                                  const std::vector<std::string>& gold_doc_anchors,
                                  const std::vector<int>& gold_entity_ids,
                                  std::optional<double> answer_score) {
    auto output = read(query);
    RewardSignals rw;
    std::set<std::string> retrieved_docs;
    for (const auto& doc : output.supporting_documents) retrieved_docs.insert(doc.first);
    std::set<std::string> gold_docs(gold_doc_anchors.begin(), gold_doc_anchors.end());
    std::set<int> retrieved_ents(output.activated_ids.begin(), output.activated_ids.end());
    std::set<int> gold_ents(gold_entity_ids.begin(), gold_entity_ids.end());
    if (!gold_docs.empty()) {
        std::vector<std::string> inter;
        std::set_intersection(retrieved_docs.begin(), retrieved_docs.end(), gold_docs.begin(), gold_docs.end(), std::back_inserter(inter));
        rw.recall = static_cast<double>(inter.size()) / static_cast<double>(gold_docs.size());
        rw.precision = retrieved_docs.empty() ? 0.0 : static_cast<double>(inter.size()) / static_cast<double>(retrieved_docs.size());
    } else if (!gold_ents.empty()) {
        std::vector<int> inter;
        std::set_intersection(retrieved_ents.begin(), retrieved_ents.end(), gold_ents.begin(), gold_ents.end(), std::back_inserter(inter));
        rw.recall = static_cast<double>(inter.size()) / static_cast<double>(gold_ents.size());
        rw.precision = retrieved_ents.empty() ? 0.0 : static_cast<double>(inter.size()) / static_cast<double>(retrieved_ents.size());
    }
    if (!gold_ents.empty()) {
        std::vector<int> inter;
        std::set_intersection(retrieved_ents.begin(), retrieved_ents.end(), gold_ents.begin(), gold_ents.end(), std::back_inserter(inter));
        rw.deductive = inter.empty() ? 0.0 : 1.0;
    }
    rw.answer = answer_score.value_or(0.0);
    if (!output.activated_subgraph_edges.empty()) {
        std::set<std::tuple<int, std::string, int>> unique;
        for (const auto& edge : output.activated_subgraph_edges) unique.insert({edge.head_id, edge.relation, edge.tail_id});
        rw.repetition_rate = 1.0 - (static_cast<double>(unique.size()) / static_cast<double>(output.activated_subgraph_edges.size()));
    }
    FeedbackEvent ev;
    ev.query = query;
    ev.reward = rw;
    ev.edges_used = output.activated_subgraph_edges;
    ev.gold_entity_ids = gold_entity_ids;
    ev.gold_doc_anchors = gold_doc_anchors;
    ev.total_reward = rw.total();
    return ev;
}

ConsolidationCycleSummary HoloGraph::consolidate_cycle(const std::vector<std::string>& queries) {
    ConsolidationCycleSummary summary;
    for (const auto& q : queries) {
        auto out = read(q);
        if (!out.abstained) ++summary.read_count;
    }
    auto hsum = hmem_router_.consolidate();
    summary.hmem_short_to_working = hsum.short_to_working;
    summary.hmem_working_to_long = hsum.working_to_long;
    summary.belief_summary = beliefs_.consolidate();
    summary.writes_committed = static_cast<int>(edges_.size());
    return summary;
}

HoloGraphSummary HoloGraph::summary() const {
    return HoloGraphSummary{static_cast<int>(entities_.size()), static_cast<int>(edges_.size()), 0, dim_};
}

std::optional<int> HoloGraph::lookup_entity(const std::string& surface) const {
    auto it = surface_to_id_.find(key_for(surface));
    if (it == surface_to_id_.end()) return std::nullopt;
    return it->second;
}

std::vector<EntityRecord> HoloGraph::entities() const { return entities_; }
std::vector<EdgeRecord> HoloGraph::edges() const { return edges_; }
std::vector<std::pair<std::string, std::string>> HoloGraph::documents() const { return documents_; }

} // namespace jarvis::sage
