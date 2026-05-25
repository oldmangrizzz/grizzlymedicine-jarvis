#include "hdc_hierarchy.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numeric>
#include <random>
#include <sstream>
#include <stdexcept>
#include <unordered_set>

namespace hdc {

// ===========================================================================
// MinGraph
// ===========================================================================

int32_t MinGraph::add_leaf(const std::string& canonical, std::vector<uint8_t> hv_blob) {
    int32_t id = next_id_++;
    entities_[id] = Entity{id, canonical, 0, std::move(hv_blob)};
    return id;
}

void MinGraph::add_edge(int32_t head, int32_t tail, float weight) {
    adj_[head].push_back({head, tail, weight});
    adj_[tail].push_back({tail, head, weight});  // undirected
}

const Entity* MinGraph::get_entity(int32_t id) const {
    auto it = entities_.find(id);
    return (it != entities_.end()) ? &it->second : nullptr;
}

std::vector<int32_t> MinGraph::entities_at_layer(int layer) const {
    std::vector<int32_t> out;
    out.reserve(entities_.size());
    for (const auto& [id, ent] : entities_) {
        if (ent.layer == layer) out.push_back(id);
    }
    return out;
}

int MinGraph::max_layer() const { return max_layer_; }

std::vector<Edge> MinGraph::edges_of(int32_t id) const {
    auto it = adj_.find(id);
    return (it != adj_.end()) ? it->second : std::vector<Edge>{};
}

std::vector<int32_t> MinGraph::children_of(int32_t parent_id) const {
    auto it = children_.find(parent_id);
    return (it != children_.end()) ? it->second : std::vector<int32_t>{};
}

int32_t MinGraph::upsert_summary(const std::string& canonical, int layer,
                                  std::vector<uint8_t> hv_blob) {
    int32_t id = next_id_++;
    entities_[id] = Entity{id, canonical, layer, std::move(hv_blob)};
    if (layer > max_layer_) max_layer_ = layer;
    return id;
}

void MinGraph::add_hierarchy_edge(int32_t parent, int32_t child) {
    children_[parent].push_back(child);
}

void MinGraph::aggregate_edges_upward(
    const std::vector<int32_t>& level_ids,
    const std::unordered_map<int32_t,int32_t>& child_to_parent,
    int /*parent_layer*/)
{
    std::unordered_set<int32_t> id_set(level_ids.begin(), level_ids.end());
    // Map (min_parent, max_parent) → accumulated weight
    std::unordered_map<int64_t, float> agg;

    for (int32_t cid : level_ids) {
        auto it = adj_.find(cid);
        if (it == adj_.end()) continue;
        for (const Edge& e : it->second) {
            int32_t u = e.head_id, v = e.tail_id;
            if (u == v) continue;
            if (id_set.find(u) == id_set.end()) continue;
            if (id_set.find(v) == id_set.end()) continue;
            auto pu_it = child_to_parent.find(u);
            auto pv_it = child_to_parent.find(v);
            if (pu_it == child_to_parent.end() || pv_it == child_to_parent.end()) continue;
            int32_t pu = pu_it->second, pv = pv_it->second;
            if (pu == pv) continue;
            int32_t lo = std::min(pu, pv), hi = std::max(pu, pv);
            int64_t key = (static_cast<int64_t>(lo) << 32) | static_cast<uint32_t>(hi);
            agg[key] += e.weight;
        }
    }

    for (const auto& [key, w] : agg) {
        int32_t a = static_cast<int32_t>(key >> 32);
        int32_t b = static_cast<int32_t>(key & 0xFFFFFFFF);
        float capped = std::min(w, 10.0f);
        adj_[a].push_back({a, b, capped});
        adj_[b].push_back({b, a, capped});
    }
}

void MinGraph::clear_hierarchy() {
    // Remove all summary nodes (layer > 0)
    std::vector<int32_t> to_remove;
    for (const auto& [id, ent] : entities_) {
        if (ent.layer > 0) to_remove.push_back(id);
    }
    for (int32_t id : to_remove) {
        entities_.erase(id);
        adj_.erase(id);
        children_.erase(id);
    }
    // Remove edges pointing to removed nodes
    for (auto& [id, edges] : adj_) {
        edges.erase(std::remove_if(edges.begin(), edges.end(),
            [&](const Edge& e) {
                return entities_.find(e.tail_id) == entities_.end();
            }), edges.end());
    }
    max_layer_ = 0;
}

// ===========================================================================
// HierarchyBuilder
// ===========================================================================

HierarchyBuilder::HierarchyBuilder(MinGraph& graph, HDCKernel& kernel,
                                   int max_layer, int node_cap,
                                   uint64_t seed)
    : graph_(graph), kernel_(kernel),
      max_layer_(max_layer), node_cap_(node_cap), seed_(seed) {}

HierarchyStats HierarchyBuilder::build() {
    graph_.clear_hierarchy();
    HierarchyStats stats;

    auto leaf_ids = graph_.entities_at_layer(0);
    stats.nodes_per_layer[0] = static_cast<int>(leaf_ids.size());
    if (leaf_ids.empty()) return stats;

    int current_layer = 0;
    std::vector<int32_t> current_ids = leaf_ids;

    // HV cache: avoid re-reading blobs
    std::unordered_map<int32_t, std::vector<uint8_t>> hv_cache;
    for (int32_t id : current_ids) hv_cache[id] = load_hv(id);

    while (static_cast<int>(current_ids.size()) > node_cap_
           && current_layer < max_layer_)
    {
        auto communities = detect_communities(current_ids);

        // Stop if community detection can't reduce count (all singletons)
        if (static_cast<int>(communities.size()) >= static_cast<int>(current_ids.size())) break;

        std::vector<int32_t> parent_ids;
        std::unordered_map<int32_t, std::vector<uint8_t>> parent_hvs;
        std::unordered_map<int32_t, int32_t> child_to_parent;

        for (const auto& comm : communities) {
            std::vector<std::vector<uint8_t>> child_hvs;
            for (int32_t c : comm) {
                auto it = hv_cache.find(c);
                if (it != hv_cache.end()) child_hvs.push_back(it->second);
            }
            if (child_hvs.empty()) continue;

            auto phv = kernel_.bundle(child_hvs);
            int32_t pid = create_parent(comm, phv, current_layer + 1);
            for (int32_t c : comm) {
                graph_.add_hierarchy_edge(pid, c);
                child_to_parent[c] = pid;
            }
            parent_ids.push_back(pid);
            parent_hvs[pid] = std::move(phv);
        }

        if (parent_ids.empty()) break;

        graph_.aggregate_edges_upward(current_ids, child_to_parent, current_layer + 1);

        current_layer++;
        current_ids = parent_ids;
        hv_cache = parent_hvs;
        stats.nodes_per_layer[current_layer] = static_cast<int>(parent_ids.size());
        stats.layers_built++;
        stats.total_summary_nodes += static_cast<int>(parent_ids.size());

        if (static_cast<int>(current_ids.size()) <= node_cap_) break;
    }

    return stats;
}

// ---------------------------------------------------------------------------
// Community detection: asynchronous label propagation.
// Works well for the synthetic corpus (ring + hub edges within clusters).
// ---------------------------------------------------------------------------
std::vector<std::vector<int32_t>> HierarchyBuilder::detect_communities(
    const std::vector<int32_t>& ids)
{
    if (ids.empty()) return {};

    std::unordered_set<int32_t> id_set(ids.begin(), ids.end());

    // Initialise: each node is its own community (label = id)
    std::unordered_map<int32_t, int32_t> label;
    for (int32_t id : ids) label[id] = id;

    std::mt19937 rng(seed_);
    // Shuffle order for each iteration
    std::vector<int32_t> order(ids.begin(), ids.end());

    constexpr int MAX_ITER = 30;
    for (int iter = 0; iter < MAX_ITER; ++iter) {
        std::shuffle(order.begin(), order.end(), rng);
        bool changed = false;

        for (int32_t node : order) {
            auto edges = graph_.edges_of(node);

            // Count label frequency among neighbours (weighted by edge weight)
            std::unordered_map<int32_t, float> freq;
            for (const Edge& e : edges) {
                int32_t nb = (e.head_id == node) ? e.tail_id : e.head_id;
                if (id_set.find(nb) == id_set.end()) continue;
                freq[label.at(nb)] += e.weight;
            }

            if (freq.empty()) continue;  // isolated node keeps own label

            // Adopt the most frequent neighbour label
            int32_t best_label = label[node];
            float best_score = 0.0f;
            for (const auto& [lbl, score] : freq) {
                if (score > best_score || (score == best_score && lbl < best_label)) {
                    best_score = score;
                    best_label = lbl;
                }
            }

            if (best_label != label[node]) {
                label[node] = best_label;
                changed = true;
            }
        }

        if (!changed) break;
    }

    // Group nodes by label
    std::unordered_map<int32_t, std::vector<int32_t>> groups;
    for (int32_t id : ids) groups[label[id]].push_back(id);

    std::vector<std::vector<int32_t>> communities;
    communities.reserve(groups.size());
    for (auto& [lbl, members] : groups) communities.push_back(std::move(members));

    // Ensure all ids are covered (isolated nodes become singleton communities)
    std::unordered_set<int32_t> covered;
    for (const auto& comm : communities) for (int32_t id : comm) covered.insert(id);
    for (int32_t id : ids) {
        if (covered.find(id) == covered.end()) {
            communities.push_back({id});
        }
    }

    return communities;
}

int32_t HierarchyBuilder::create_parent(
    const std::vector<int32_t>& child_ids,
    const std::vector<uint8_t>& parent_hv,
    int layer)
{
    auto rep_opt = centroid_child(child_ids, parent_hv);
    std::string rep_name = rep_opt.has_value()
        ? (graph_.get_entity(*rep_opt)
               ? graph_.get_entity(*rep_opt)->canonical
               : "node" + std::to_string(child_ids[0]))
        : "node" + std::to_string(child_ids[0]);

    std::string canon = "L" + std::to_string(layer) + "::" + rep_name
                        + "::" + std::to_string(child_ids[0]);
    return graph_.upsert_summary(canon, layer, parent_hv);
}

std::optional<int32_t> HierarchyBuilder::centroid_child(
    const std::vector<int32_t>& child_ids,
    const std::vector<uint8_t>& parent_hv)
{
    int32_t best = -1;
    double  best_sim = -2.0;
    for (int32_t c : child_ids) {
        const Entity* ent = graph_.get_entity(c);
        if (!ent || ent->hv_blob.empty()) continue;
        double s = kernel_.similarity(ent->hv_blob, parent_hv);
        if (s > best_sim) { best_sim = s; best = c; }
    }
    return (best >= 0) ? std::make_optional(best) : std::nullopt;
}

std::vector<uint8_t> HierarchyBuilder::load_hv(int32_t id) {
    const Entity* ent = graph_.get_entity(id);
    if (!ent || ent->hv_blob.empty()) return kernel_.zeros();
    return ent->hv_blob;
}

// ===========================================================================
// SoftRouter
// ===========================================================================

SoftRouter::SoftRouter(MinGraph& graph, HDCKernel& kernel,
                       int beam, int leaf_beam_multiplier)
    : graph_(graph), kernel_(kernel),
      beam_(beam), leaf_beam_multiplier_(leaf_beam_multiplier) {}

RouteResult SoftRouter::route(const std::vector<uint8_t>& query_hv_blob) const {
    auto total_leaves = graph_.entities_at_layer(0);
    RouteResult result;
    result.total_leaves = static_cast<int>(total_leaves.size());

    int top = graph_.max_layer();

    if (top == 0) {
        // No hierarchy — exhaustive
        result.leaf_candidates = total_leaves;
        result.nodes_touched   = result.total_leaves;
        result.path_by_layer[0] = total_leaves;
        return result;
    }

    // Score top layer
    int layer = top;
    auto candidates = graph_.entities_at_layer(layer);
    auto kept = score_and_keep(query_hv_blob, candidates, beam_);
    result.nodes_touched += static_cast<int>(candidates.size());
    for (const auto& [id, _] : kept) result.path_by_layer[layer].push_back(id);

    // Descend
    while (layer > 0) {
        std::vector<int32_t> children;
        std::unordered_set<int32_t> seen;
        for (const auto& [parent_id, _] : kept) {
            for (int32_t child : graph_.children_of(parent_id)) {
                if (seen.insert(child).second) children.push_back(child);
            }
        }
        if (children.empty()) break;

        int beam = (layer - 1 > 0) ? beam_ : beam_ * leaf_beam_multiplier_;
        kept = score_and_keep(query_hv_blob, children, beam);
        result.nodes_touched += static_cast<int>(children.size());
        layer--;
        for (const auto& [id, _] : kept) result.path_by_layer[layer].push_back(id);
    }

    result.leaf_candidates.reserve(kept.size());
    for (const auto& [id, _] : kept) result.leaf_candidates.push_back(id);
    return result;
}

std::vector<std::pair<int32_t,double>> SoftRouter::score_and_keep(
    const std::vector<uint8_t>& query,
    const std::vector<int32_t>& ids,
    int k) const
{
    std::vector<std::pair<int32_t,double>> scored;
    scored.reserve(ids.size());
    for (int32_t eid : ids) {
        const Entity* ent = graph_.get_entity(eid);
        if (!ent || ent->hv_blob.empty()) continue;
        double sim = kernel_.similarity(query, ent->hv_blob);
        scored.emplace_back(eid, sim);
    }
    int take = std::max(1, k);
    if (static_cast<int>(scored.size()) > take) {
        std::partial_sort(scored.begin(), scored.begin() + take, scored.end(),
            [](const auto& x, const auto& y) { return x.second > y.second; });
        scored.resize(take);
    } else {
        std::sort(scored.begin(), scored.end(),
            [](const auto& x, const auto& y) { return x.second > y.second; });
    }
    return scored;
}

} // namespace hdc
