#pragma once
// Minimal in-memory hierarchy builder and soft router for the recall benchmark.
// This is the HDC-only port of Python's hierarchy/builder.py + hierarchy/router.py.
// No SQLite; no NetworkX. Scope: recall benchmark only.
//
// Operator invariant: no disable/bypass flag. Memory is bodily.

#include "hdc.h"
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace hdc {

// ---------------------------------------------------------------------------
// Entity & Edge
// ---------------------------------------------------------------------------
struct Entity {
    int32_t     id;
    std::string canonical;
    int         layer;          // 0 = leaf, >0 = summary
    std::vector<uint8_t> hv_blob;
};

struct Edge {
    int32_t head_id;
    int32_t tail_id;
    float   weight;
};

// ---------------------------------------------------------------------------
// MinGraph — in-memory graph substrate (replaces GraphSubstrate for the
// benchmark; holds only what the hierarchy builder and router need).
// ---------------------------------------------------------------------------
class MinGraph {
public:
    /// Add a leaf entity with its pre-packed HV blob.
    int32_t add_leaf(const std::string& canonical, std::vector<uint8_t> hv_blob);

    /// Add an edge between two entities.
    void add_edge(int32_t head, int32_t tail, float weight = 1.0f);

    /// Get entity by id (nullptr if not found).
    const Entity* get_entity(int32_t id) const;

    /// All entity ids at a given layer.
    std::vector<int32_t> entities_at_layer(int layer) const;

    /// Maximum layer index present.
    int max_layer() const;

    /// Edges of a node (both directions for undirected traversal).
    std::vector<Edge> edges_of(int32_t id) const;

    /// Children of a summary node.
    std::vector<int32_t> children_of(int32_t parent_id) const;

    /// Upsert a summary entity and return its id.
    int32_t upsert_summary(const std::string& canonical, int layer,
                           std::vector<uint8_t> hv_blob);

    /// Record hierarchy parent→child link.
    void add_hierarchy_edge(int32_t parent, int32_t child);

    /// Aggregate edges upward: for cross-edges among level_ids, create weighted
    /// edges between their parents.
    void aggregate_edges_upward(
        const std::vector<int32_t>& level_ids,
        const std::unordered_map<int32_t,int32_t>& child_to_parent,
        int parent_layer);

    /// Remove all summary nodes and hierarchy edges.
    void clear_hierarchy();

    size_t entity_count() const { return entities_.size(); }

private:
    int32_t next_id_ = 1;
    std::unordered_map<int32_t, Entity>                 entities_;
    std::unordered_map<int32_t, std::vector<Edge>>      adj_;   // id → edges
    std::unordered_map<int32_t, std::vector<int32_t>>   children_; // parent→children
    int max_layer_ = 0;
};

// ---------------------------------------------------------------------------
// HierarchyStats
// ---------------------------------------------------------------------------
struct HierarchyStats {
    int                            layers_built      = 0;
    int                            total_summary_nodes = 0;
    std::unordered_map<int,int>    nodes_per_layer;
};

// ---------------------------------------------------------------------------
// HierarchyBuilder
// Mirrors Python HierarchyBuilder using label-propagation community detection.
// ---------------------------------------------------------------------------
class HierarchyBuilder {
public:
    HierarchyBuilder(MinGraph& graph, HDCKernel& kernel,
                     int max_layer = 4, int node_cap = 8,
                     uint64_t seed = 0);

    HierarchyStats build();

private:
    MinGraph&   graph_;
    HDCKernel&  kernel_;
    int         max_layer_;
    int         node_cap_;
    uint64_t    seed_;

    // Community detection via asynchronous label propagation.
    std::vector<std::vector<int32_t>> detect_communities(
        const std::vector<int32_t>& ids);

    int32_t create_parent(
        const std::vector<int32_t>& child_ids,
        const std::vector<uint8_t>& parent_hv,
        int layer);

    std::optional<int32_t> centroid_child(
        const std::vector<int32_t>& child_ids,
        const std::vector<uint8_t>& parent_hv);

    std::vector<uint8_t> load_hv(int32_t id);
};

// ---------------------------------------------------------------------------
// RouteResult
// ---------------------------------------------------------------------------
struct RouteResult {
    std::vector<int32_t>                  leaf_candidates;
    int                                   nodes_touched = 0;
    int                                   total_leaves  = 0;
    std::unordered_map<int,std::vector<int32_t>> path_by_layer;

    double touch_fraction() const {
        return (total_leaves > 0)
            ? static_cast<double>(nodes_touched) / static_cast<double>(total_leaves)
            : 1.0;
    }
};

// ---------------------------------------------------------------------------
// SoftRouter — beam-search top-down routing through the hierarchy.
// Mirrors Python SoftRouter exactly (beam, leaf_beam_multiplier=4).
// ---------------------------------------------------------------------------
class SoftRouter {
public:
    SoftRouter(MinGraph& graph, HDCKernel& kernel,
               int beam = 3, int leaf_beam_multiplier = 4);

    RouteResult route(const std::vector<uint8_t>& query_hv_blob) const;

private:
    MinGraph&   graph_;
    HDCKernel&  kernel_;
    int         beam_;
    int         leaf_beam_multiplier_;

    // Returns top-k (id, similarity) pairs from candidates.
    std::vector<std::pair<int32_t,double>> score_and_keep(
        const std::vector<uint8_t>& query,
        const std::vector<int32_t>& ids,
        int k) const;
};

} // namespace hdc
