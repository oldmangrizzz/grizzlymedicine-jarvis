// Unit tests for the HDC kernel: algebraic properties + round-trip fidelity.
// Catch2 v3.
#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include <catch2/generators/catch_generators.hpp>

#include "hdc.h"
#include "hdc_real.h"
#include "hdc_ternary.h"
#include "hdc_hierarchy.h"

#include <cmath>
#include <numeric>
#include <random>
#include <vector>

using namespace hdc;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static std::vector<uint8_t> random_real_hv(int dim, uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> v(dim);
    float n2 = 0;
    for (auto& x : v) { x = nd(rng); n2 += x*x; }
    float inv = 1.0f / std::sqrt(n2);
    for (auto& x : v) x *= inv;
    RealKernel k(dim);
    return k.pack_floats(v);
}

static std::vector<uint8_t> random_ternary_hv(int dim, uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::uniform_int_distribution<int> dist(0, 2);
    TernaryKernel k(dim);
    std::vector<int8_t> v(dim);
    for (auto& x : v) {
        int r = dist(rng);
        x = (r == 0) ? -1 : (r == 1) ? 0 : 1;
    }
    return k.pack_trits(v);
}

// ---------------------------------------------------------------------------
// Real kernel tests
// ---------------------------------------------------------------------------
TEST_CASE("RealKernel: zeros blob is all-zero bytes", "[real]") {
    RealKernel k(1024);
    auto z = k.zeros();
    REQUIRE(z.size() == k.blob_size());
    for (auto b : z) REQUIRE(b == 0);
}

TEST_CASE("RealKernel: pack/unpack round-trip", "[real]") {
    RealKernel k(512);
    auto blob = random_real_hv(512, 42);
    auto floats = k.unpack_floats(blob);
    auto repacked = k.pack_floats(floats);
    REQUIRE(blob == repacked);
}

TEST_CASE("RealKernel: self-similarity is ~1.0", "[real]") {
    RealKernel k(1024);
    auto a = random_real_hv(1024, 7);
    double sim = k.similarity(a, a);
    REQUIRE(sim == Catch::Approx(1.0).epsilon(1e-5));
}

TEST_CASE("RealKernel: random-pair similarity is ~0.0", "[real]") {
    RealKernel k(1024);
    auto a = random_real_hv(1024, 1);
    auto b = random_real_hv(1024, 2);
    double sim = k.similarity(a, b);
    // For D=1024, expected |sim| ≈ 1/sqrt(1024) ≈ 0.031
    REQUIRE(std::abs(sim) < 0.15);
}

TEST_CASE("RealKernel: bind is commutative", "[real]") {
    RealKernel k(512);
    auto a = random_real_hv(512, 10);
    auto b = random_real_hv(512, 11);
    auto ab = k.bind(a, b);
    auto ba = k.bind(b, a);
    REQUIRE(ab == ba);
}

TEST_CASE("RealKernel: bind with zeros gives zeros", "[real]") {
    RealKernel k(512);
    auto a = random_real_hv(512, 5);
    auto z = k.zeros();
    auto result = k.bind(a, z);
    auto floats = k.unpack_floats(result);
    for (float x : floats) REQUIRE(x == Catch::Approx(0.0f).margin(1e-9f));
}

TEST_CASE("RealKernel: bundle output is L2-normalised", "[real]") {
    RealKernel k(512);
    std::vector<std::vector<uint8_t>> hvs;
    for (int i = 0; i < 5; ++i) hvs.push_back(random_real_hv(512, i + 100));
    auto bun = k.bundle(hvs);
    auto floats = k.unpack_floats(bun);
    float norm2 = 0;
    for (float x : floats) norm2 += x * x;
    REQUIRE(std::sqrt(norm2) == Catch::Approx(1.0f).epsilon(1e-5f));
}

TEST_CASE("RealKernel: bundle of one HV is the HV itself", "[real]") {
    RealKernel k(512);
    auto a = random_real_hv(512, 99);
    auto bun = k.bundle({a});
    auto floats_a   = k.unpack_floats(a);
    auto floats_bun = k.unpack_floats(bun);
    // Bundling one normalised HV → same HV (possibly re-normalised → same if already unit)
    for (int i = 0; i < 512; ++i)
        REQUIRE(floats_bun[i] == Catch::Approx(floats_a[i]).epsilon(1e-5f));
}

TEST_CASE("RealKernel: permute_roll shift=1 is circular", "[real]") {
    RealKernel k(8);
    // Simple 8-element HV
    std::vector<float> v = {1,2,3,4,5,6,7,8};
    float n = 0; for (float x : v) n += x*x; n = std::sqrt(n);
    for (auto& x : v) x /= n;
    auto blob = k.pack_floats(v);
    auto rolled = k.permute_roll(blob, 1);
    auto floats = k.unpack_floats(rolled);
    // numpy.roll([1..8], 1) → [8,1,2,3,4,5,6,7]
    REQUIRE(floats[0] == Catch::Approx(v[7]).margin(1e-7f));
    REQUIRE(floats[1] == Catch::Approx(v[0]).margin(1e-7f));
    REQUIRE(floats[7] == Catch::Approx(v[6]).margin(1e-7f));
}

TEST_CASE("RealKernel: permute_roll full-cycle returns original", "[real]") {
    RealKernel k(512);
    auto orig = random_real_hv(512, 13);
    auto rolled = orig;
    for (int i = 0; i < 512; ++i) rolled = k.permute_roll(rolled, 1);
    REQUIRE(orig == rolled);
}

TEST_CASE("RealKernel: permute_roll shift 0 is identity", "[real]") {
    RealKernel k(512);
    auto a = random_real_hv(512, 14);
    REQUIRE(k.permute_roll(a, 0) == a);
}

TEST_CASE("RealKernel: permute_roll negative shift", "[real]") {
    RealKernel k(8);
    std::vector<float> v = {1,2,3,4,5,6,7,8};
    float n = 0; for (float x : v) n += x*x; n = std::sqrt(n);
    for (auto& x : v) x /= n;
    auto blob = k.pack_floats(v);
    // roll(-1) = roll(7)
    auto neg = k.permute_roll(blob, -1);
    auto pos = k.permute_roll(blob, 7);
    REQUIRE(neg == pos);
}

TEST_CASE("RealKernel: random_basis has correct shape and unit rows", "[real]") {
    RealKernel k(256);
    auto basis = k.random_basis(8, 12345u);
    REQUIRE(static_cast<int>(basis.size()) == 8 * 256);
    for (int r = 0; r < 8; ++r) {
        float n2 = 0;
        for (int c = 0; c < 256; ++c) n2 += basis[r*256+c] * basis[r*256+c];
        REQUIRE(std::sqrt(n2) == Catch::Approx(1.0f).epsilon(1e-4f));
    }
}

TEST_CASE("RealKernel: encode_scalar matches PSP-HDC tanh projection", "[real]") {
    RealKernel k(4);
    std::vector<float> embedding = {0.5f, -0.25f};
    std::vector<float> basis = {
        1.0f,  2.0f, -1.0f, 0.0f,
        0.5f, -1.0f,  2.0f, 1.0f,
    };
    auto blob = k.encode_scalar(0.8f, embedding, basis);
    auto out = k.unpack_floats(blob);
    for (int d = 0; d < 4; ++d) {
        float proj = (0.8f * embedding[0]) * basis[d]
                   + (0.8f * embedding[1]) * basis[4 + d];
        REQUIRE(out[d] == Catch::Approx(std::tanh(proj)).margin(1e-7f));
    }
}

// ---------------------------------------------------------------------------
// Ternary kernel tests
// ---------------------------------------------------------------------------
TEST_CASE("TernaryKernel: zeros is all-zero bytes", "[ternary]") {
    TernaryKernel k(1024);
    auto z = k.zeros();
    REQUIRE(z.size() == k.blob_size());
    for (auto b : z) REQUIRE(b == 0);
}

TEST_CASE("TernaryKernel: pack/unpack round-trip", "[ternary]") {
    TernaryKernel k(1024);
    auto blob = random_ternary_hv(1024, 42);
    auto trits = k.unpack_trits(blob);
    auto repacked = k.pack_trits(trits);
    REQUIRE(blob == repacked);
}

TEST_CASE("TernaryKernel: pack uses 2-bits-per-trit encoding", "[ternary]") {
    TernaryKernel k(4);
    std::vector<int8_t> v = {1, -1, 0, 1};
    // codes: 01, 10, 00, 01 → byte = 01 | (10<<2) | (00<<4) | (01<<6)
    //   = 0b00000001 | 0b00001000 | 0b00000000 | 0b01000000
    //   = 0b01001001 = 0x49 = 73
    auto packed = k.pack_trits(v);
    REQUIRE(packed.size() == 1u);
    REQUIRE(packed[0] == 0x49);
}

TEST_CASE("TernaryKernel: self-similarity is 1.0", "[ternary]") {
    TernaryKernel k(1024);
    auto a = random_ternary_hv(1024, 7);
    REQUIRE(k.similarity(a, a) == Catch::Approx(1.0).epsilon(1e-9));
}

TEST_CASE("TernaryKernel: bind with zeros gives zeros", "[ternary]") {
    TernaryKernel k(512);
    auto a = random_ternary_hv(512, 5);
    auto z = k.zeros();
    auto result = k.bind(a, z);
    auto trits = k.unpack_trits(result);
    for (auto t : trits) REQUIRE(t == 0);
}

TEST_CASE("TernaryKernel: bind is commutative", "[ternary]") {
    TernaryKernel k(512);
    auto a = random_ternary_hv(512, 10);
    auto b = random_ternary_hv(512, 11);
    REQUIRE(k.bind(a, b) == k.bind(b, a));
}

TEST_CASE("TernaryKernel: bind of v with v has non-negative trits", "[ternary]") {
    TernaryKernel k(512);
    auto a = random_ternary_hv(512, 9);
    auto bound = k.bind(a, a);
    auto trits = k.unpack_trits(bound);
    for (auto t : trits) REQUIRE(t >= 0);
}

TEST_CASE("TernaryKernel: bundle output has values in {-1,0,1}", "[ternary]") {
    TernaryKernel k(512);
    std::vector<std::vector<uint8_t>> hvs;
    for (int i = 0; i < 5; ++i) hvs.push_back(random_ternary_hv(512, i + 200));
    auto bun = k.bundle(hvs);
    auto trits = k.unpack_trits(bun);
    for (auto t : trits) REQUIRE((t == -1 || t == 0 || t == 1));
}

TEST_CASE("TernaryKernel: quantize preserves sign", "[ternary]") {
    TernaryKernel k(8);
    std::vector<float> v = {2.0f, -1.0f, 0.0f, 0.5f, -3.0f, 0.0f, 1.0f, -0.1f};
    auto blob = k.quantize(v);
    auto trits = k.unpack_trits(blob);
    std::vector<int8_t> expected = {1, -1, 0, 1, -1, 0, 1, -1};
    REQUIRE(trits == expected);
}

TEST_CASE("TernaryKernel: encode_scalar applies sign-deadband projection", "[ternary]") {
    TernaryKernel k(4);
    std::vector<float> embedding = {0.5f, -0.25f};
    std::vector<float> basis = {
        1.0f,  2.0f, -1.0f, 0.0f,
        0.5f, -1.0f,  2.0f, 1.0f,
    };
    auto blob = k.encode_scalar(0.8f, embedding, basis);
    auto out = k.unpack_trits(blob);
    std::vector<int8_t> expected;
    for (int d = 0; d < 4; ++d) {
        float proj = (0.8f * embedding[0]) * basis[d]
                   + (0.8f * embedding[1]) * basis[4 + d];
        expected.push_back(proj > 0.0f ? 1 : (proj < 0.0f ? -1 : 0));
    }
    REQUIRE(out == expected);
}

TEST_CASE("TernaryKernel: permute_roll shift=1 is circular", "[ternary]") {
    TernaryKernel k(8);
    std::vector<int8_t> v = {1,-1,0,1,-1,0,1,-1};
    auto blob = k.pack_trits(v);
    auto rolled = k.permute_roll(blob, 1);
    auto result = k.unpack_trits(rolled);
    // numpy.roll([v0..v7], 1) → [v7, v0, v1, ..., v6]
    REQUIRE(result[0] == v[7]);
    REQUIRE(result[1] == v[0]);
    REQUIRE(result[7] == v[6]);
}

TEST_CASE("TernaryKernel: permute_roll full-cycle returns original", "[ternary]") {
    TernaryKernel k(512);
    auto orig = random_ternary_hv(512, 33);
    auto rolled = orig;
    for (int i = 0; i < 512; ++i) rolled = k.permute_roll(rolled, 1);
    REQUIRE(orig == rolled);
}

// ---------------------------------------------------------------------------
// Cross-kernel: quantize then similarity
// ---------------------------------------------------------------------------
TEST_CASE("Quantize: similar real HVs have positive ternary similarity", "[cross]") {
    TernaryKernel k(1024);
    // Generate a real HV and a noisy version
    std::mt19937_64 rng(42);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> base(1024);
    for (auto& x : base) x = nd(rng);
    // Noisy version: base + 0.1 * noise
    std::vector<float> noisy(1024);
    for (int i = 0; i < 1024; ++i) noisy[i] = base[i] + 0.1f * nd(rng);

    auto a = k.quantize(base);
    auto b = k.quantize(noisy);
    double sim = k.similarity(a, b);
    REQUIRE(sim > 0.5);  // should be highly similar
}

// ---------------------------------------------------------------------------
// MinGraph + HierarchyBuilder + SoftRouter smoke test
// ---------------------------------------------------------------------------
TEST_CASE("Hierarchy: build and route on small corpus", "[hierarchy]") {
    constexpr int DIM = 64;
    constexpr int N_CLUSTERS = 5;
    constexpr int PER_CLUSTER = 20;

    auto kernel = make_kernel(KernelType::REAL, DIM);
    MinGraph graph;

    std::mt19937_64 rng(999);
    std::normal_distribution<float> nd(0.0f, 1.0f);

    std::vector<std::vector<int32_t>> cluster_ids(N_CLUSTERS);
    std::vector<std::vector<float>> centers(N_CLUSTERS, std::vector<float>(DIM));

    for (int c = 0; c < N_CLUSTERS; ++c) {
        // Generate cluster center
        float n2 = 0;
        for (auto& x : centers[c]) { x = nd(rng); n2 += x*x; }
        float inv = 1.0f/std::sqrt(n2);
        for (auto& x : centers[c]) x *= inv;

        for (int m = 0; m < PER_CLUSTER; ++m) {
            std::vector<float> v(DIM);
            n2 = 0;
            for (int i = 0; i < DIM; ++i) { v[i] = centers[c][i] + nd(rng)*0.3f; n2 += v[i]*v[i]; }
            inv = 1.0f/std::sqrt(n2);
            for (auto& x : v) x *= inv;
            auto blob = kernel->pack_floats(v);
            auto eid = graph.add_leaf("c" + std::to_string(c) + "_m" + std::to_string(m),
                                      std::move(blob));
            cluster_ids[c].push_back(eid);
        }

        // Ring edges within cluster
        for (int m = 0; m < PER_CLUSTER; ++m) {
            graph.add_edge(cluster_ids[c][m], cluster_ids[c][(m+1)%PER_CLUSTER], 1.0f);
        }
    }

    HierarchyBuilder builder(graph, *kernel, /*max_layer=*/4, /*node_cap=*/4);
    auto stats = builder.build();
    REQUIRE(stats.layers_built >= 1);

    // Route a query from cluster 0
    std::vector<float> query(DIM);
    float n2 = 0;
    for (int i = 0; i < DIM; ++i) { query[i] = centers[0][i] + nd(rng)*0.1f; n2 += query[i]*query[i]; }
    float inv = 1.0f/std::sqrt(n2);
    for (auto& x : query) x *= inv;
    auto query_blob = kernel->pack_floats(query);

    SoftRouter router(graph, *kernel, /*beam=*/3);
    auto result = router.route(query_blob);

    REQUIRE(!result.leaf_candidates.empty());
    REQUIRE(result.touch_fraction() < 1.0);  // actually touched fewer than all leaves

    // The top candidate should be from cluster 0
    bool found_cluster0 = false;
    for (int32_t cand : result.leaf_candidates) {
        const Entity* ent = graph.get_entity(cand);
        if (ent && ent->canonical.find("c0_") != std::string::npos) {
            found_cluster0 = true;
            break;
        }
    }
    REQUIRE(found_cluster0);
}
