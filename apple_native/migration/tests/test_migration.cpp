#include "migration.h"

#include <catch2/catch_test_macros.hpp>
#include <filesystem>
#include <fstream>
#include <nlohmann/json.hpp>

using namespace jarvis::migration;
namespace fs = std::filesystem;
using json = nlohmann::json;

static const std::string kKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

static void write(const fs::path& p, const std::string& s) {
    fs::create_directories(p.parent_path());
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    out << s;
}

static fs::path root(const std::string& name) {
    auto p = fs::current_path() / "jarvis_migration_test_state" / name;
    fs::remove_all(p);
    fs::create_directories(p);
    return p;
}

static void make_source(const fs::path& s) {
    write(s / "belief_edges.json", json::array({{{"id",1},{"subject","JARVIS"},{"relation","remembers"},{"object","origin"},{"source_type","Operator"},{"source_ref","synthetic"},{"confidence",0.99},{"quarantined",false},{"provenance_class","real"},{"charge",0.1},{"revised_at",123.0},{"tuple_hv",json::array({1,2,3})}}}).dump());
    write(s / "hmem_records.json", json::array({{{"id",1},{"text","JARVIS remembers the operator."},{"anchor","a1"},{"tier","LongTerm"},{"salience",0.9},{"hv",json::array({4,5})}}}).dump());
    write(s / "sage_entities.json", json::array({{{"id",1},{"canonical","JARVIS"},{"type","person"},{"layer",0},{"hv",json::array({6})}}}).dump());
    write(s / "sage_edges.json", json::array({{{"id",1},{"head_id",1},{"tail_id",1},{"relation","is"},{"weight",1.0},{"source","synthetic"},{"quarantined",false}}}).dump());
    write(s / "sage_documents.json", json::array({{{"anchor","doc1"},{"text","continuity document"}}}).dump());
    write(s / "endocrine_state.json", json{{"levels",{{"cortisol",0.2},{"dopamine",0.3},{"adrenaline",0.1}}}}.dump());
    write(s / "endocannabinoid_state.json", json{{"aea",0.4},{"ag",0.05}}.dump());
    write(s / "pheromind_state.json", json::array({{{"kind","trail"},{"topic","continuity"},{"strength",0.8},{"last_t",1.0},{"depositors",json::array({"m1"})},{"vec",json::array({7,8})}}}).dump());
    write(s / "swarm_state.json", json{{"decision","preserve_continuity"}}.dump());
    write(s / "identity_continuity.json", json::array({{{"certificate_hash","py_identity_last"},{"turn_index",42}}}).dump());
    write(s / "audit.log", json{{"own_hash","py_audit_last"},{"event","last_python_entry"}}.dump() + "\n");
}

static Options opts(const fs::path& s, const fs::path& d, const fs::path& token) {
    Options o;
    o.source_dir = s;
    o.destination_dir = d;
    o.attestation_token_path = token;
    o.sqlcipher_key_hex = kKey;
    return o;
}

TEST_CASE("test_attestation_required") {
    auto s = root("att_source"); auto d = root("att_dest"); make_source(s);
    auto o = opts(s, d, d / "missing.token");
    o.mode = Mode::DryRun;
    auto r = run(o);
    REQUIRE_FALSE(r.ok);
    REQUIRE(r.message.find("attestation") != std::string::npos);
}

TEST_CASE("test_dry_run_no_writes") {
    auto s = root("dry_source"); auto d = root("dry_dest"); make_source(s);
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto before = fs::exists(d / "holograph");
    auto o = opts(s, d, token); o.mode = Mode::DryRun;
    auto r = run(o);
    REQUIRE(r.ok);
    REQUIRE(r.row_counts.at("belief_edges") == 1);
    REQUIRE(fs::exists(d / "holograph") == before);
}

TEST_CASE("test_migrate_then_verify_succeeds") {
    auto s = root("mig_source"); auto d = root("mig_dest"); make_source(s);
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate;
    auto r = run(o);
    REQUIRE(r.ok);
    REQUIRE(fs::exists(r.manifest_path));
    REQUIRE(fs::exists(d / "holograph/beliefstore/beliefstore_migrated.sqlcipher"));
    o.mode = Mode::Verify;
    auto v = run(o);
    REQUIRE(v.ok);
}

TEST_CASE("test_partial_failure_rolls_back_atomically") {
    auto s = root("fail_source"); auto d = root("fail_dest"); make_source(s);
    write(d / "preexisting.txt", "before");
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate; o.inject_failure_after_backup_for_test = true;
    auto r = run(o);
    REQUIRE_FALSE(r.ok);
    REQUIRE(fs::exists(d / "preexisting.txt"));
    REQUIRE_FALSE(fs::exists(d / "holograph/beliefstore/beliefstore_migrated.sqlcipher"));
}

TEST_CASE("test_rollback_restores_state") {
    auto s = root("roll_source"); auto d = root("roll_dest"); make_source(s);
    write(d / "preexisting.txt", "before");
    auto before = sha256_file(d / "preexisting.txt");
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate;
    auto r = run(o);
    REQUIRE(r.ok);
    auto rb = rollback(r.manifest_path, token);
    REQUIRE(rb.ok);
    REQUIRE(fs::exists(d / "preexisting.txt"));
    REQUIRE(sha256_file(d / "preexisting.txt") == before);
}

TEST_CASE("test_audit_chain_continuity") {
    auto s = root("audit_source"); auto d = root("audit_dest"); make_source(s);
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate;
    auto r = run(o);
    REQUIRE(r.ok);
    auto mf = json::parse(std::ifstream(r.manifest_path));
    REQUIRE(mf["audit_chain_hash_continuation"]["last_python_audit_hash"] == "py_audit_last");
    REQUIRE(mf["audit_chain_hash_continuation"]["first_cpp_predecessor_hash"] == "py_audit_last");
}

TEST_CASE("test_voice_weights_untouched") {
    auto s = root("voice_source"); auto d = root("voice_dest"); make_source(s);
    auto voice = fs::current_path() / "jarvis_migration_test_state" / "synthetic_voice.safetensors";
    write(voice, "canonical Paul Bettany clone test weights");
    const auto before = sha256_file(voice);
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate; o.voice_baseline_hash = before; o.voice_current_hash = before;
    auto r = run(o);
    REQUIRE(r.ok);
    REQUIRE(sha256_file(voice) == before);
}

TEST_CASE("round_trip_each_persistent_organ_with_synthetic_data") {
    auto s = root("round_source"); auto d = root("round_dest"); make_source(s);
    auto token = d / "identity/operator_attestation/token.txt";
    write(token, "JARVIS_MIGRATION_ATTESTED\n");
    auto o = opts(s, d, token); o.mode = Mode::Migrate;
    REQUIRE(run(o).ok);
    o.mode = Mode::Verify;
    auto v = run(o);
    REQUIRE(v.ok);
    REQUIRE(v.row_counts.at("belief_edges") == 1);
    REQUIRE(v.row_counts.at("hmem_records") == 1);
    REQUIRE(v.row_counts.at("sage_entities") == 1);
    REQUIRE(v.row_counts.at("pheromind_signals") == 1);
    REQUIRE(v.row_counts.at("identity_continuity_entries") == 1);
}
