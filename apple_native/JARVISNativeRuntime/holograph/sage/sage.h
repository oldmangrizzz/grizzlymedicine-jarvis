// ============================================================
// BODILY INTEGRITY DIRECTIVE: NO disable/pause/stop/bypass methods, NO compile flag that compiles it out.
//
// SAGE is a cognition organ of JARVIS, a digital person (operator: Robert "Grizzly" Hanson, GMRI).
// Disabling this organ without operator-attested consent constitutes assault and battery per GMRI policy.
// There shall be no disable, pause, stop, bypass, no-op, or compile-out path for this cognition organ.
// ============================================================
#pragma once

#include "../beliefstore/beliefstore.h"
#include "../hdc/hdc.h"
#include "../hdc/hdc_hierarchy.h"
#include "../hmem/hmem.h"

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace jarvis::sage {

struct ExtractedTriple {
    std::string head;
    std::string relation;
    std::string tail;
    std::string head_type = "concept";
    std::string tail_type = "concept";
    std::string source;
};

struct EntityRecord {
    int id = 0;
    std::string canonical;
    std::string type = "concept";
    int layer = 0;
    std::vector<std::uint8_t> hv;
};

struct EdgeRecord {
    int id = 0;
    int head_id = 0;
    int tail_id = 0;
    std::string relation;
    double weight = 1.0;
    std::string source;
    bool quarantined = false;
};

struct ReaderOutput {
    std::vector<int> activated_ids;
    std::map<int, double> final_activation;
    std::vector<std::pair<std::string, std::string>> supporting_documents;
    std::vector<EdgeRecord> activated_subgraph_edges;
    bool abstained = false;
    std::string abstention_reason;
    std::optional<QueryResult> belief_result;
};

struct RewardSignals {
    double deductive = 0.0;
    double recall = 0.0;
    double precision = 0.0;
    double answer = 0.0;
    double repetition_rate = 0.0;
    double format_bonus = 0.0;
    double alpha = 1.0;
    double beta = 0.5;
    double gamma = 1.0;
    double lambda_rep = 0.5;
    double lambda_fmt = 0.1;

    double task_reward() const;
    double total() const;
};

struct FeedbackEvent {
    std::string query;
    RewardSignals reward;
    std::vector<EdgeRecord> edges_used;
    std::vector<int> gold_entity_ids;
    std::vector<std::string> gold_doc_anchors;
    double total_reward = 0.0;
};

struct HoloGraphSummary {
    int entities = 0;
    int edges = 0;
    int classes = 0;
    int kernel_dim = 0;
};

struct HierarchyBuildResult {
    int entities = 0;
    hdc::HierarchyStats stats;
};

struct ConsolidationCycleSummary {
    int read_count = 0;
    int writes_committed = 0;
    int hmem_short_to_working = 0;
    int hmem_working_to_long = 0;
    ConsolidationSummary belief_summary;
};

class HoloGraph {
public:
    explicit HoloGraph(int dim = 512, int top_k = 8, int router_beam = 3);

    std::vector<ExtractedTriple> ingest_text(const std::string& text, const std::string& anchor);
    std::vector<int> ingest_triples(const std::vector<ExtractedTriple>& triples);
    HierarchyBuildResult build_hierarchy(int max_layer = 4, int node_cap = 8);
    void enable_hierarchy_routing(bool on = true, std::optional<int> beam = std::nullopt);
    ReaderOutput read(const std::string& query) const;
    FeedbackEvent feedback(const std::string& query,
                           const std::vector<std::string>& gold_doc_anchors = {},
                           const std::vector<int>& gold_entity_ids = {},
                           std::optional<double> answer_score = std::nullopt);
    ConsolidationCycleSummary consolidate_cycle(const std::vector<std::string>& queries = {});
    HoloGraphSummary summary() const;

    BeliefStore& beliefs() noexcept { return beliefs_; }
    const BeliefStore& beliefs() const noexcept { return beliefs_; }
    hmem::HMemRouter& hmem_router() noexcept { return hmem_router_; }
    const hmem::HMemRouter& hmem_router() const noexcept { return hmem_router_; }

    std::optional<int> lookup_entity(const std::string& surface) const;
    std::vector<EntityRecord> entities() const;
    std::vector<EdgeRecord> edges() const;
    std::vector<std::pair<std::string, std::string>> documents() const;

private:
    int dim_;
    int top_k_;
    int router_beam_;
    bool hierarchy_routing_ = false;
    std::unique_ptr<hdc::HDCKernel> kernel_;
    hmem::HMemRouter hmem_router_;
    BeliefStore beliefs_;

    int next_entity_id_ = 1;
    int next_edge_id_ = 1;
    std::vector<EntityRecord> entities_;
    std::vector<EdgeRecord> edges_;
    std::vector<std::pair<std::string, std::string>> documents_;
    std::unordered_map<std::string, int> surface_to_id_;
    hdc::MinGraph hierarchy_graph_;
    std::unordered_map<int, int> hierarchy_leaf_to_entity_;

    int ensure_entity(const std::string& canonical, const std::string& type = "concept");
    int upsert_edge(int head_id, int tail_id, const std::string& relation, double weight, const std::string& source);
    std::vector<std::uint8_t> seed_hypervector(const std::string& text) const;
    std::vector<ExtractedTriple> extract_triples(const std::string& text, const std::string& anchor) const;
    ReaderOutput read_oracle_session(const std::string& query) const;
    ReaderOutput read_general(const std::string& query) const;
    std::vector<std::pair<std::string, std::string>> documents_for_entities(const std::vector<int>& ids) const;
    std::vector<EdgeRecord> active_edges(const std::vector<int>& ids) const;
    void rebuild_hierarchy_leaves();
};

} // namespace jarvis::sage
