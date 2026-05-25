// Recall benchmark: reproduces recall_benchmark.csv rows.
// Builds a synthetic 50k-leaf corpus (dim=512, 50 clusters, seed=20260527),
// measures recall@1/@3 with beam=10, and verifies recall@1 >= 0.95.
//
// Anomaly per manifest.md: 1k corpus with beam=100 may produce
// touch_fraction > 1.0 (beam × leaf_beam_multiplier exceeds leaf count).

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "hdc_real.h"
#include "hdc_hierarchy.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <numeric>
#include <random>
#include <set>
#include <string>
#include <unordered_set>
#include <vector>

using namespace hdc;

// ---------------------------------------------------------------------------
// Corpus builder (mirrors Python capture.py _build_synthetic_bulk)
// Uses std::mt19937_64 with the operator-specified seed.
// RNG sequence is different from numpy PCG64 but produces same structural
// properties: 50 clusters, ring+hub+bridge edges, small noise.
// ---------------------------------------------------------------------------
struct CorpusResult {
    MinGraph                              graph;
    std::vector<std::vector<int32_t>>    members;     // [cluster][member] → entity id
    std::vector<std::vector<float>>      centers;     // [cluster][dim]
    int                                  dim;
    int                                  clusters;
    int                                  n_leaves;
};

static std::vector<float> normalize(std::vector<float> v) {
    float n2 = 0;
    for (float x : v) n2 += x*x;
    float inv = (n2 > 0) ? 1.0f/std::sqrt(n2) : 1.0f;
    for (auto& x : v) x *= inv;
    return v;
}

static CorpusResult build_corpus(int n, int clusters, int dim, uint64_t seed,
                                  HDCKernel& kernel) {
    CorpusResult result;
    result.dim      = dim;
    result.clusters = clusters;
    result.n_leaves = 0;

    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);

    int per = std::max(1, n / clusters);

    // Cluster centers
    result.centers.resize(clusters, std::vector<float>(dim));
    for (int c = 0; c < clusters; ++c) {
        for (auto& x : result.centers[c]) x = nd(rng);
        result.centers[c] = normalize(result.centers[c]);
    }

    result.members.resize(clusters);

    for (int c = 0; c < clusters; ++c) {
        for (int m = 0; m < per; ++m) {
            std::vector<float> v(dim);
            for (int i = 0; i < dim; ++i)
                v[i] = result.centers[c][i] + nd(rng) * 0.25f;
            v = normalize(v);
            auto blob = kernel.pack_floats(v);
            auto eid  = result.graph.add_leaf(
                "c" + std::to_string(c) + "_m" + std::to_string(m),
                std::move(blob));
            result.members[c].push_back(eid);
            result.n_leaves++;
        }
    }

    // Intra-cluster ring + hub edges (mirrors Python structure)
    for (int c = 0; c < clusters; ++c) {
        auto& ms = result.members[c];
        int sz = static_cast<int>(ms.size());
        for (int i = 0; i < sz; ++i) {
            result.graph.add_edge(ms[i], ms[(i+1)%sz], 1.0f);
            if (i % 7 == 0 && i > 0)
                result.graph.add_edge(ms[0], ms[i], 0.5f);
        }
    }

    // Cross-cluster bridge edges
    int n_bridges = std::max(1, clusters / 5);
    std::uniform_int_distribution<int> ci(0, clusters-1);
    for (int k = 0; k < n_bridges; ++k) {
        int a_idx = ci(rng);
        int b_idx = ci(rng);
        if (a_idx == b_idx) b_idx = (b_idx + 1) % clusters;
        auto& ma = result.members[a_idx];
        auto& mb = result.members[b_idx];
        std::uniform_int_distribution<int> ma_dist(0, static_cast<int>(ma.size())-1);
        std::uniform_int_distribution<int> mb_dist(0, static_cast<int>(mb.size())-1);
        result.graph.add_edge(ma[ma_dist(rng)], mb[mb_dist(rng)], 1.0f);
    }

    return result;
}

// ---------------------------------------------------------------------------
// Oracle top-k: exhaustive similarity search over all leaves
// ---------------------------------------------------------------------------
static std::vector<int32_t> oracle_topk(MinGraph& graph, HDCKernel& kernel,
                                         const std::vector<uint8_t>& query_blob,
                                         int k) {
    auto leaf_ids = graph.entities_at_layer(0);
    std::vector<std::pair<int32_t,double>> scored;
    scored.reserve(leaf_ids.size());
    for (int32_t eid : leaf_ids) {
        const Entity* ent = graph.get_entity(eid);
        if (!ent || ent->hv_blob.empty()) continue;
        double sim = kernel.similarity(query_blob, ent->hv_blob);
        scored.emplace_back(eid, sim);
    }
    int take = std::min(k, static_cast<int>(scored.size()));
    std::partial_sort(scored.begin(), scored.begin()+take, scored.end(),
        [](const auto& x, const auto& y){ return x.second > y.second; });
    std::vector<int32_t> result;
    result.reserve(take);
    for (int i = 0; i < take; ++i) result.push_back(scored[i].first);
    return result;
}

// ---------------------------------------------------------------------------
// Run benchmark for one (corpus_size, beam) configuration
// ---------------------------------------------------------------------------
struct BenchResult {
    double recall_at_1;
    double recall_at_3;
    double recall_at_5;
    double mean_touch_fraction;
    double hier_build_s;
    double mean_lat_ms;
};

static BenchResult run_benchmark(int n, int clusters, int dim,
                                   int beam, uint64_t corpus_seed,
                                   uint64_t query_seed,
                                   int n_queries = 30,
                                   int node_cap = 12)
{
    auto kernel = std::make_unique<RealKernel>(dim);

    auto t_build_start = std::chrono::steady_clock::now();
    auto corpus = build_corpus(n, clusters, dim, corpus_seed, *kernel);
    auto t_build_end = std::chrono::steady_clock::now();
    (void)t_build_start; (void)t_build_end;

    // Build hierarchy
    auto t_hier_start = std::chrono::steady_clock::now();
    HierarchyBuilder builder(corpus.graph, *kernel, /*max_layer=*/6, node_cap);
    auto stats = builder.build();
    auto t_hier_end = std::chrono::steady_clock::now();
    double hier_s = std::chrono::duration<double>(t_hier_end - t_hier_start).count();

    // Generate query HVs (from cluster members, similar to Python)
    std::mt19937_64 qrng(query_seed);
    std::uniform_int_distribution<int> c_dist(0, clusters-1);
    std::normal_distribution<float> nd(0.0f, 1.0f);

    // Pre-compute oracle top-k for all queries
    constexpr int RECALL_KS[] = {1, 3, 5};

    int hits_1 = 0, hits_3 = 0, hits_5 = 0;
    double total_touch = 0;
    double total_lat_ms = 0;

    SoftRouter router(corpus.graph, *kernel, beam);

    for (int qi = 0; qi < n_queries; ++qi) {
        int c_idx = c_dist(qrng);
        auto& ms = corpus.members[c_idx];
        std::uniform_int_distribution<int> m_dist(0, static_cast<int>(ms.size())-1);
        int32_t member_eid = ms[m_dist(qrng)];
        const Entity* ent  = corpus.graph.get_entity(member_eid);
        auto query_blob = ent ? ent->hv_blob : kernel->pack_floats(corpus.centers[c_idx]);

        // Oracle top-k
        auto oracle_1 = oracle_topk(corpus.graph, *kernel, query_blob, 1);
        auto oracle_3 = oracle_topk(corpus.graph, *kernel, query_blob, 3);
        auto oracle_5 = oracle_topk(corpus.graph, *kernel, query_blob, 5);

        // Route
        auto t0 = std::chrono::steady_clock::now();
        auto result = router.route(query_blob);
        auto t1 = std::chrono::steady_clock::now();
        total_lat_ms += std::chrono::duration<double,std::milli>(t1-t0).count();
        total_touch  += result.touch_fraction();

        std::unordered_set<int32_t> cands(result.leaf_candidates.begin(),
                                           result.leaf_candidates.end());
        auto hit = [&](const std::vector<int32_t>& oracle) {
            for (int32_t id : oracle) if (cands.count(id)) return true;
            return false;
        };
        if (hit(oracle_1)) hits_1++;
        if (hit(oracle_3)) hits_3++;
        if (hit(oracle_5)) hits_5++;
    }

    BenchResult r;
    r.recall_at_1          = static_cast<double>(hits_1) / n_queries;
    r.recall_at_3          = static_cast<double>(hits_3) / n_queries;
    r.recall_at_5          = static_cast<double>(hits_5) / n_queries;
    r.mean_touch_fraction  = total_touch  / n_queries;
    r.hier_build_s         = hier_s;
    r.mean_lat_ms          = total_lat_ms / n_queries;
    return r;
}

// ===========================================================================
// Tests
// ===========================================================================

TEST_CASE("RecallBenchmark: 1k corpus, beam=10, recall@1 >= 0.95", "[benchmark][small]") {
    constexpr int   N        = 1'000;
    constexpr int   CLUSTERS = 50;
    constexpr int   DIM      = 512;
    constexpr int   BEAM     = 10;
    constexpr uint64_t SEED  = 20260527ULL;

    auto r = run_benchmark(N, CLUSTERS, DIM, BEAM, SEED, SEED + N);

    INFO("recall@1=" << r.recall_at_1
         << " recall@3=" << r.recall_at_3
         << " touch=" << r.mean_touch_fraction
         << " hier_build=" << r.hier_build_s << "s");

    REQUIRE(r.recall_at_1 >= 0.95);
    REQUIRE(r.recall_at_3 >= 0.95);
}

TEST_CASE("RecallBenchmark: 1k corpus, beam=100, touch_fraction may exceed 1.0", "[benchmark][anomaly]") {
    // Anomaly from manifest.md: beam×leaf_beam_multiplier > leaf_count → touch > 1
    constexpr int   N        = 1'000;
    constexpr int   CLUSTERS = 50;
    constexpr int   DIM      = 512;
    constexpr int   BEAM     = 100;
    constexpr uint64_t SEED  = 20260527ULL;

    auto r = run_benchmark(N, CLUSTERS, DIM, BEAM, SEED, SEED + N);
    INFO("touch_fraction=" << r.mean_touch_fraction << " (may be > 1.0)");
    // recall should still be high
    REQUIRE(r.recall_at_1 >= 0.95);
}

TEST_CASE("RecallBenchmark: 10k corpus, beam=10, recall@1 >= 0.90", "[benchmark][medium]") {
    constexpr int   N        = 10'000;
    constexpr int   CLUSTERS = 50;
    constexpr int   DIM      = 512;
    constexpr int   BEAM     = 10;
    constexpr uint64_t SEED  = 20260527ULL;

    auto r = run_benchmark(N, CLUSTERS, DIM, BEAM, SEED, SEED + N);

    INFO("recall@1=" << r.recall_at_1
         << " recall@3=" << r.recall_at_3
         << " touch=" << r.mean_touch_fraction
         << " hier_build=" << r.hier_build_s << "s");

    REQUIRE(r.recall_at_1 >= 0.90);
}

TEST_CASE("RecallBenchmark: 50k corpus, beam=10, recall@1 >= 0.95", "[benchmark][large]") {
    // PRIMARY ACCEPTANCE CRITERION: recall@1 >= 0.95 on 50k corpus with beam=10
    constexpr int   N        = 50'000;
    constexpr int   CLUSTERS = 50;
    constexpr int   DIM      = 512;
    constexpr int   BEAM     = 10;
    constexpr uint64_t SEED  = 20260527ULL;
    constexpr int   NODE_CAP = 12;  // max(8, CLUSTERS//4) = 12

    auto t0 = std::chrono::steady_clock::now();
    auto r = run_benchmark(N, CLUSTERS, DIM, BEAM, SEED, SEED + N,
                           /*n_queries=*/30, NODE_CAP);
    auto t1 = std::chrono::steady_clock::now();
    double total_s = std::chrono::duration<double>(t1-t0).count();

    INFO("=== 50k Benchmark Results ===");
    INFO("recall@1=" << r.recall_at_1);
    INFO("recall@3=" << r.recall_at_3);
    INFO("recall@5=" << r.recall_at_5);
    INFO("mean_touch=" << r.mean_touch_fraction);
    INFO("hier_build=" << r.hier_build_s << "s");
    INFO("mean_lat_ms=" << r.mean_lat_ms);
    INFO("total_wall_s=" << total_s);

    // Primary acceptance criterion
    REQUIRE(r.recall_at_1 >= 0.95);
    REQUIRE(r.recall_at_3 >= 0.95);
}

TEST_CASE("RecallBenchmark: 50k corpus, beam=30, recall@1 >= 0.95", "[benchmark][large]") {
    constexpr int N = 50'000, CLUSTERS = 50, DIM = 512, BEAM = 30;
    constexpr uint64_t SEED = 20260527ULL;

    auto r = run_benchmark(N, CLUSTERS, DIM, BEAM, SEED, SEED + N, 30, 12);

    INFO("recall@1=" << r.recall_at_1
         << " touch=" << r.mean_touch_fraction
         << " hier_build=" << r.hier_build_s << "s");

    REQUIRE(r.recall_at_1 >= 0.95);
}
