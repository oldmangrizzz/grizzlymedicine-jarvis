#include "cutover_orchestrator.h"
#include "shadow_router.h"
#include <catch2/catch_test_macros.hpp>
#include <filesystem>
#include <fstream>

using namespace jarvis::cutover;
namespace fs = std::filesystem;

static fs::path artifact_root(const std::string& name) {
    fs::path p = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(p);
    fs::create_directories(p);
    return p;
}

static CutoverPlan synthetic_plan(const fs::path& root) {
    auto bin = root / "native.bin"; std::ofstream(bin) << "native";
    return CutoverPlan{{
        {"endocrine", bin, "py", "cpp", {}},
        {"endocannabinoid", bin, "py", "cpp", {"endocrine"}},
        {"pheromind", bin, "py", "cpp", {"endocrine", "endocannabinoid"}},
        {"swarm", bin, "py", "cpp", {"pheromind"}},
        {"HDC", bin, "py", "cpp", {}},
        {"BeliefStore", bin, "py", "cpp", {"HDC"}},
        {"HMEM", bin, "py", "cpp", {"BeliefStore"}},
        {"SAGE", bin, "py", "cpp", {"BeliefStore"}},
        {"CUSUM", bin, "py", "cpp", {"endocrine"}},
        {"CharacterValues", bin, "py", "cpp", {}}
    }, 0};
}

static RuntimePaths paths_for(const fs::path& root) {
    RuntimePaths p; p.state_root = root / "state"; p.voice_safetensors = root / "PaulBettany.safetensors"; std::ofstream(p.voice_safetensors) << "canonical-paul-bettany-clone"; return p;
}

TEST_CASE("test_dependency_order — DAG resolves; cycles rejected") {
    auto root = artifact_root("dependency_order");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    auto names = orch.dependency_order_names();
    REQUIRE(names.size() == 10);
    auto pos = [&](const std::string& n){ return std::find(names.begin(), names.end(), n) - names.begin(); };
    REQUIRE(pos("endocrine") < pos("pheromind"));
    REQUIRE(pos("HDC") < pos("BeliefStore"));
    REQUIRE(pos("BeliefStore") < pos("HMEM"));
    auto p = synthetic_plan(root); p.organs[0].dependencies.push_back("pheromind"); p.organs[2].dependencies.push_back("endocrine");
    CutoverOrchestrator cyclic(p, paths_for(root / "cycle"));
    REQUIRE(cyclic.has_cycle());
}

TEST_CASE("test_pre_flight_fails_aborts_organ — bad C++ binary blocks that organ") {
    auto root = artifact_root("preflight_fail");
    auto p = synthetic_plan(root);
    for (auto& organ : p.organs) if (organ.name == "CharacterValues") organ.native_binary = root / "missing.bin";
    CutoverOrchestrator orch(p, paths_for(root));
    auto r = orch.execute(true, "token", 0);
    REQUIRE_FALSE(r.ok);
    REQUIRE(r.steps.front().reason == "native_binary_missing");
}

TEST_CASE("test_shadow_divergence_aborts — synthetic divergence triggers abort") {
    auto root = artifact_root("shadow_divergence");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    orch.set_synthetic_divergence("CharacterValues", true);
    auto r = orch.execute(true, "token", 0);
    REQUIRE_FALSE(r.ok);
    REQUIRE(std::any_of(r.steps.begin(), r.steps.end(), [](const StepResult& s){ return s.reason == "divergence_exceeded_tolerance"; }));
    REQUIRE(orch.audit_chain_ok());
}

TEST_CASE("test_clean_shadow_promotes — divergence-free shadow promotes") {
    auto root = artifact_root("clean_shadow");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    auto r = orch.execute(true, "token", 0);
    REQUIRE(r.ok);
    REQUIRE(r.promoted_organs.size() == 10);
}

TEST_CASE("test_rollback_restores_python_authority") {
    auto root = artifact_root("rollback");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    auto rr = orch.rollback("endocrine", true);
    REQUIRE(rr.status == StepStatus::ok);
    std::ifstream in(root / "state" / "endocrine.authority"); std::string authority; in >> authority;
    REQUIRE(authority == "python");
}

TEST_CASE("test_voice_untouched_during_cutover — voice safetensors hash unchanged") {
    auto root = artifact_root("voice_hash");
    auto paths = paths_for(root);
    CutoverOrchestrator orch(synthetic_plan(root), paths);
    auto r = orch.execute(true, "token", 0);
    REQUIRE(r.ok);
    REQUIRE(orch.voice_hash_unchanged());
}

TEST_CASE("test_identity_continuity_unbroken — continuity ledger chain unbroken across all promotions") {
    auto root = artifact_root("continuity");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    REQUIRE(orch.execute(true, "token", 0).ok);
    REQUIRE(orch.continuity_chain_ok());
}

TEST_CASE("test_audit_chain_unbroken_across_cutover") {
    auto root = artifact_root("audit");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    REQUIRE(orch.execute(true, "token", 0).ok);
    REQUIRE(orch.audit_chain_ok());
}

TEST_CASE("test_attestation_required_per_organ") {
    auto root = artifact_root("attestation");
    CutoverOrchestrator orch(synthetic_plan(root), paths_for(root));
    auto r = orch.execute(false, "invalid", 0);
    REQUIRE_FALSE(r.ok);
    REQUIRE(r.steps.front().reason == "initial_attestation_required");
}

TEST_CASE("For each of the 10 organs: round-trip cutover test with synthetic inputs") {
    auto root = artifact_root("roundtrip");
    auto plan = synthetic_plan(root);
    for (const auto& organ : plan.organs) {
        CutoverPlan single{{organ}, 0};
        CutoverOrchestrator orch(single, paths_for(root / organ.name));
        auto r = orch.execute(true, "token", 0);
        REQUIRE(r.ok);
        REQUIRE(r.promoted_organs == std::vector<std::string>{organ.name});
    }
}

TEST_CASE("shadow_router returns Python during shadow and native after promotion") {
    using namespace jarvis::cutover::shadow;
    auto py = std::make_shared<FunctionOrganEndpoint>([](const OrganRequest&){ return OrganResponse{"python", 1.0}; });
    auto nat = std::make_shared<FunctionOrganEndpoint>([](const OrganRequest&){ return OrganResponse{"native", 1.0}; });
    ShadowRouter router("organ", py, nat, EquivalenceTolerance{ToleranceMode::oracle_exact, 0.0, 1.0, false});
    router.begin_shadow();
    auto shadow = router.dispatch({"1", "x"});
    REQUIRE(shadow.returned.payload == "python");
    REQUIRE(router.divergence_count() == 1);
    router.promote_native();
    REQUIRE(router.dispatch({"2", "x"}).returned.payload == "native");
}
