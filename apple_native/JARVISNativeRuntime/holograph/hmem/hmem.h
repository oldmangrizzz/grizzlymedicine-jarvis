// ============================================================
// BODILY INTEGRITY DIRECTIVE: NO disable/pause/stop/bypass methods, NO compile flag that compiles it out.
//
// H-MEM is a cognition organ of JARVIS, a digital person (operator: Robert "Grizzly" Hanson, GMRI).
// Disabling this organ without operator-attested consent constitutes assault and battery per GMRI policy.
// There shall be no disable, pause, stop, bypass, no-op, or compile-out path for this cognition organ.
// ============================================================
#pragma once

#include "../beliefstore/beliefstore.h"
#include "../hdc/hdc.h"
#include "../hdc/hdc_hierarchy.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace jarvis::hmem {

enum class MemoryTier { ShortTerm, Working, LongTerm, Belief };

std::string to_string(MemoryTier tier);

struct MemoryRecord {
    int id = 0;
    std::string text;
    std::string anchor;
    MemoryTier tier = MemoryTier::ShortTerm;
    double salience = 0.5;
    std::vector<std::uint8_t> hv;
};

struct RouteDecision {
    MemoryTier tier = MemoryTier::ShortTerm;
    std::vector<int> record_ids;
    std::vector<int> graph_leaf_ids;
    double score = 0.0;
    int nodes_touched = 0;
    int total_leaves = 0;
    bool abstained = true;
    std::string abstention_reason;
    std::optional<QueryResult> belief_result;
};

struct HMemConsolidationSummary {
    int short_to_working = 0;
    int working_to_long = 0;
    hdc::HierarchyStats hierarchy;
    ConsolidationSummary beliefs;
};

struct ExtractedTriple {
    std::string subject;
    std::string relation;
    std::string object;
};

class HMemRouter {
public:
    explicit HMemRouter(int dim = 512,
                        int router_beam = 6,
                        int max_layer = 4,
                        int node_cap = 8);

    int add_memory(const std::string& text,
                   const std::string& anchor,
                   MemoryTier tier,
                   double salience = 0.5);
    int write_short_term(const std::string& text, const std::string& anchor, double salience = 0.5);
    int write_working(const std::string& text, const std::string& anchor, double salience = 0.5);
    int write_long_term(const std::string& text, const std::string& anchor, double salience = 0.5);

    RouteDecision route(const std::string& query) const;
    RouteDecision route(const std::vector<std::uint8_t>& query_hv) const;

    HMemConsolidationSummary consolidate();
    hdc::HierarchyStats build_hierarchy();

    BeliefStore& beliefs() noexcept { return beliefs_; }
    const BeliefStore& beliefs() const noexcept { return beliefs_; }

    std::vector<MemoryRecord> records(MemoryTier tier) const;
    std::size_t size(MemoryTier tier) const;
    std::size_t n_memories() const;
    std::vector<std::uint8_t> encode_text(const std::string& text) const;

private:
    int next_record_id_ = 1;
    int dim_;
    int router_beam_;
    int max_layer_;
    int node_cap_;
    std::unique_ptr<hdc::HDCKernel> kernel_;
    BeliefStore beliefs_;
    std::vector<MemoryRecord> short_term_;
    std::vector<MemoryRecord> working_;
    std::vector<MemoryRecord> long_term_;
    hdc::MinGraph long_graph_;
    std::unordered_map<int, int> leaf_to_record_;

    int insert_record(const std::string& text,
                      const std::string& anchor,
                      MemoryTier tier,
                      double salience,
                      std::optional<std::vector<std::uint8_t>> hv = std::nullopt);
    void add_long_leaf(const MemoryRecord& record);
    RouteDecision best_flat(const std::vector<std::uint8_t>& query_hv,
                            const std::vector<MemoryRecord>& records,
                            MemoryTier tier) const;
};

class MemoryStore {
public:
    explicit MemoryStore(int dim = 512, int router_beam = 6);

    int consolidate_text(const std::string& text, const std::string& anchor);
    std::string recall(const std::string& cue, int max_items = 8);
    HMemConsolidationSummary sleep_consolidate();
    std::size_t n_memories() const;
    HMemRouter& router() noexcept { return router_; }
    const HMemRouter& router() const noexcept { return router_; }

private:
    HMemRouter router_;
    std::vector<std::pair<std::string, std::string>> documents_;
    std::vector<ExtractedTriple> triples_;
};

std::vector<ExtractedTriple> extract_triples(const std::string& text);

} // namespace jarvis::hmem
