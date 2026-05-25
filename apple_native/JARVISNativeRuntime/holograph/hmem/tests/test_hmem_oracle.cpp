#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include "hmem.h"
#include "hdc_real.h"
#include "hdc_hierarchy.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <numeric>
#include <random>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using json = nlohmann::json;
using jarvis::BeliefStore;
using jarvis::SourceType;
using jarvis::hmem::MemoryStore;
using namespace hdc;

namespace {
struct CorpusResult {
    MinGraph graph;
    std::vector<std::vector<int32_t>> members;
    std::vector<std::vector<float>> centers;
    int n_leaves = 0;
};

std::vector<float> normalize(std::vector<float> v) {
    float n2 = 0.0f;
    for (float x : v) n2 += x * x;
    const float inv = n2 > 0.0f ? 1.0f / std::sqrt(n2) : 1.0f;
    for (auto& x : v) x *= inv;
    return v;
}

CorpusResult build_corpus(int n, int clusters, int dim, std::uint64_t seed, HDCKernel& kernel) {
    CorpusResult result;
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    const int per = std::max(1, n / clusters);

    result.centers.resize(static_cast<std::size_t>(clusters), std::vector<float>(static_cast<std::size_t>(dim)));
    result.members.resize(static_cast<std::size_t>(clusters));
    for (int c = 0; c < clusters; ++c) {
        for (auto& x : result.centers[static_cast<std::size_t>(c)]) x = nd(rng);
        result.centers[static_cast<std::size_t>(c)] = normalize(result.centers[static_cast<std::size_t>(c)]);
        for (int m = 0; m < per; ++m) {
            std::vector<float> v(static_cast<std::size_t>(dim));
            for (int i = 0; i < dim; ++i) v[static_cast<std::size_t>(i)] = result.centers[static_cast<std::size_t>(c)][static_cast<std::size_t>(i)] + nd(rng) * 0.25f;
            v = normalize(v);
            const int32_t eid = result.graph.add_leaf("c" + std::to_string(c) + "_m" + std::to_string(m), kernel.pack_floats(v));
            result.members[static_cast<std::size_t>(c)].push_back(eid);
            ++result.n_leaves;
        }
    }

    for (int c = 0; c < clusters; ++c) {
        auto& ms = result.members[static_cast<std::size_t>(c)];
        const int sz = static_cast<int>(ms.size());
        for (int i = 0; i < sz; ++i) {
            result.graph.add_edge(ms[static_cast<std::size_t>(i)], ms[static_cast<std::size_t>((i + 1) % sz)], 1.0f);
            if (i % 7 == 0 && i > 0) result.graph.add_edge(ms[0], ms[static_cast<std::size_t>(i)], 0.5f);
        }
    }

    const int n_bridges = std::max(1, clusters / 5);
    std::uniform_int_distribution<int> ci(0, clusters - 1);
    for (int k = 0; k < n_bridges; ++k) {
        int a = ci(rng);
        int b = ci(rng);
        if (a == b) b = (b + 1) % clusters;
        auto& ma = result.members[static_cast<std::size_t>(a)];
        auto& mb = result.members[static_cast<std::size_t>(b)];
        std::uniform_int_distribution<int> mai(0, static_cast<int>(ma.size()) - 1);
        std::uniform_int_distribution<int> mbi(0, static_cast<int>(mb.size()) - 1);
        result.graph.add_edge(ma[static_cast<std::size_t>(mai(rng))], mb[static_cast<std::size_t>(mbi(rng))], 1.0f);
    }
    return result;
}

std::vector<int32_t> oracle_topk(MinGraph& graph, HDCKernel& kernel, const std::vector<std::uint8_t>& query, int k) {
    auto leaves = graph.entities_at_layer(0);
    std::vector<std::pair<int32_t, double>> scored;
    scored.reserve(leaves.size());
    for (int32_t id : leaves) {
        const auto* ent = graph.get_entity(id);
        if (ent != nullptr) scored.emplace_back(id, kernel.similarity(query, ent->hv_blob));
    }
    const int take = std::min(k, static_cast<int>(scored.size()));
    std::partial_sort(scored.begin(), scored.begin() + take, scored.end(), [](const auto& a, const auto& b) {
        return a.second > b.second;
    });
    std::vector<int32_t> out;
    for (int i = 0; i < take; ++i) out.push_back(scored[static_cast<std::size_t>(i)].first);
    return out;
}

struct BenchResult {
    double recall1 = 0.0;
    double recall3 = 0.0;
    double recall5 = 0.0;
    double recall10 = 0.0;
    double touch = 0.0;
};

BenchResult run_routes(CorpusResult& corpus, HDCKernel& kernel, int clusters, int beam, std::uint64_t query_seed) {
    std::mt19937_64 rng(query_seed);
    std::uniform_int_distribution<int> cdist(0, clusters - 1);
    SoftRouter router(corpus.graph, kernel, beam);
    int h1 = 0, h3 = 0, h5 = 0, h10 = 0;
    double touch = 0.0;
    constexpr int n_queries = 30;
    for (int qi = 0; qi < n_queries; ++qi) {
        const int c = cdist(rng);
        auto& ms = corpus.members[static_cast<std::size_t>(c)];
        std::uniform_int_distribution<int> mdist(0, static_cast<int>(ms.size()) - 1);
        const auto* ent = corpus.graph.get_entity(ms[static_cast<std::size_t>(mdist(rng))]);
        REQUIRE(ent != nullptr);
        const auto query = ent->hv_blob;
        const auto o1 = oracle_topk(corpus.graph, kernel, query, 1);
        const auto o3 = oracle_topk(corpus.graph, kernel, query, 3);
        const auto o5 = oracle_topk(corpus.graph, kernel, query, 5);
        const auto o10 = oracle_topk(corpus.graph, kernel, query, 10);
        const auto routed = router.route(query);
        const std::unordered_set<int32_t> cands(routed.leaf_candidates.begin(), routed.leaf_candidates.end());
        auto hit = [&](const auto& oracle) { return std::any_of(oracle.begin(), oracle.end(), [&](int32_t id) { return cands.contains(id); }); };
        if (hit(o1)) ++h1;
        if (hit(o3)) ++h3;
        if (hit(o5)) ++h5;
        if (hit(o10)) ++h10;
        touch += routed.touch_fraction();
    }
    return {h1 / 30.0, h3 / 30.0, h5 / 30.0, h10 / 30.0, touch / 30.0};
}

std::vector<json> load_records() {
    const std::filesystem::path path = std::filesystem::path(HMEM_ORACLE_DIR) / "api_traces.jsonl";
    std::ifstream in(path);
    REQUIRE(in.good());
    std::vector<json> records;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto rec = json::parse(line);
        const std::string section = rec.value("section", "");
        if (section == "hmem_routing" || section == "consolidate") records.push_back(std::move(rec));
    }
    return records;
}
} // namespace

TEST_CASE("H-MEM matches H-MEM-relevant oracle traces", "[hmem][oracle]") {
    auto records = load_records();
    REQUIRE(records.size() == 21);

    std::unordered_map<int, json> route_expect;
    std::unordered_map<int, json> build_expect;
    int consolidate_matched = 0;
    MemoryStore store(512, 6);

    for (const auto& rec : records) {
        const std::string section = rec.at("section").get<std::string>();
        const std::string fn = rec.at("function").get<std::string>();
        const auto& args = rec.at("args");
        const auto& ret = rec.at("retval");
        if (section == "hmem_routing" && fn == "build_hierarchy") {
            build_expect[args.at("n").get<int>()] = rec;
        } else if (section == "hmem_routing" && fn == "SoftRouter.route") {
            route_expect[args.at("n").get<int>() * 1000 + args.at("beam").get<int>()] = rec;
        } else if (section == "consolidate" && fn == "consolidate") {
            REQUIRE(store.consolidate_text(args.at("text").get<std::string>(), args.at("anchor").get<std::string>()) == ret.at("triples_written").get<int>());
            ++consolidate_matched;
        } else if (section == "consolidate" && fn == "MemoryStore.n_memories") {
            REQUIRE(store.n_memories() == ret.get<std::size_t>());
            ++consolidate_matched;
        } else if (section == "consolidate" && fn == "recall") {
            REQUIRE(store.recall(args.at("cue").get<std::string>(), args.at("max_items").get<int>()) == ret.at("context_block").get<std::string>());
            ++consolidate_matched;
        } else if (section == "consolidate" && fn == "consolidate__idempotency") {
            REQUIRE(store.consolidate_text(args.at("text").get<std::string>(), args.at("anchor").get<std::string>()) == ret.at("triples_written").get<int>());
            ++consolidate_matched;
        } else if (section == "consolidate" && fn == "BeliefStore.consolidate__sleep_boundary") {
            BeliefStore beliefs;
            beliefs.assert_belief("sector", "threat", "low", SourceType::Document, "", 0.55, false);
            beliefs.assert_belief("sector", "threat", "medium", SourceType::Document, "", 0.60, false);
            beliefs.assert_belief("sector", "threat", "high", SourceType::Document, "", 0.80, false);
            REQUIRE(beliefs.recall("sector", "threat") == ret.at("pre_recall").get<std::string>());
            auto summary = beliefs.consolidate();
            REQUIRE(beliefs.recall("sector", "threat") == ret.at("post_recall").get<std::string>());
            REQUIRE(summary.contradictions_resolved == ret.at("result").at("contradictions_resolved").get<int>());
            REQUIRE(summary.quarantined_aged == ret.at("result").at("quarantined_aged").get<int>());
            ++consolidate_matched;
        }
    }
    REQUIRE(consolidate_matched == 9);

    int routing_matched = 0;
    for (int n : {1000, 10000, 50000}) {
        REQUIRE(build_expect.contains(n));
        const auto& brec = build_expect.at(n);
        const auto& args = brec.at("args");
        const int clusters = args.at("clusters").get<int>();
        const int dim = args.at("dim").get<int>();
        const int node_cap = args.at("node_cap").get<int>();
        const int max_layer = args.at("max_layer").get<int>();
        RealKernel kernel(dim);
        auto corpus = build_corpus(n, clusters, dim, 20260527ull, kernel);
        HierarchyBuilder builder(corpus.graph, kernel, max_layer, node_cap);
        auto stats = builder.build();
        REQUIRE(stats.nodes_per_layer[0] == corpus.n_leaves);
        REQUIRE(stats.layers_built >= 1);
        REQUIRE(stats.layers_built <= max_layer);
        REQUIRE(stats.total_summary_nodes > 0);
        ++routing_matched;

        for (int beam : {10, 30, 100}) {
            REQUIRE(route_expect.contains(n * 1000 + beam));
            const auto expected = route_expect.at(n * 1000 + beam).at("retval");
            const auto got = run_routes(corpus, kernel, clusters, beam, 20260527ull + static_cast<std::uint64_t>(n));
            INFO("n=" << n << " beam=" << beam << " recall1=" << got.recall1 << " touch=" << got.touch);
            REQUIRE(got.recall1 + 0.067 >= expected.at("recall@1").get<double>());
            REQUIRE(got.recall3 + 0.067 >= expected.at("recall@3").get<double>());
            REQUIRE(got.recall5 + 0.067 >= expected.at("recall@5").get<double>());
            REQUIRE(got.recall10 + 0.067 >= expected.at("recall@10").get<double>());
            REQUIRE(got.touch <= std::max(1.20, expected.at("mean_touch_fraction").get<double>() + 0.35));
            ++routing_matched;
        }
    }
    REQUIRE(routing_matched == 12);
}
