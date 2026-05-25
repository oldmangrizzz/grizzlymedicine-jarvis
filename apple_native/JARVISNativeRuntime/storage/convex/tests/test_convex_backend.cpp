#include "../convex_backend.h"
#include "../convex_websocket.h"
#include "../../../integrity/audit/audit_log.h"
#include "../../../security/cert_pinning.h"
#include "../../../security/egress/egress_allowlist.h"

#include <catch2/catch_test_macros.hpp>
#include <array>
#include <filesystem>
#include <fstream>
#include <map>

using namespace jarvis::storage::convex;

namespace {

struct MockConvexServer final : ConvexTransport {
    std::map<std::pair<std::string, std::string>, nlohmann::json> rows;
    std::vector<nlohmann::json> transmitted;

    nlohmann::json mutation(const std::string& name, const nlohmann::json& args) override {
        assert_no_cleartext_topic_kind(args);
        transmitted.push_back({{"type", "mutation"}, {"name", name}, {"args", args}});
        if (name == "stigmergy:put") rows[{args.at("kind"), args.at("topic")}] = args;
        else if (name == "stigmergy:del") rows.erase({args.at("kind"), args.at("topic")});
        else if (name == "stigmergy:gcKeys") for (const auto& k : args.at("keys")) rows.erase({k.at("kind"), k.at("topic")});
        return nullptr;
    }

    nlohmann::json query(const std::string& name, const nlohmann::json& args) override {
        assert_no_cleartext_topic_kind(args);
        transmitted.push_back({{"type", "query"}, {"name", name}, {"args", args}});
        if (name == "stigmergy:get") {
            auto it = rows.find({args.at("kind"), args.at("topic")});
            return it == rows.end() ? nlohmann::json(nullptr) : it->second;
        }
        if (name == "stigmergy:all") {
            nlohmann::json out = nlohmann::json::array();
            for (const auto& [_, row] : rows) out.push_back(row);
            return out;
        }
        return nullptr;
    }
};

std::shared_ptr<RuntimeSecretStore> test_secrets() {
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / "jarvis_home";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    // Ceremony pre-issue: secret() requires an existing file; tests use a fixed key.
    std::vector<unsigned char> fixed_key(32, 0x42);
    RuntimeSecretStore::issue_from_ceremony(root.string(), fixed_key);
    return std::make_shared<RuntimeSecretStore>(root.string());
}

std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> test_audit() {
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / "audit";
    std::filesystem::create_directories(root);
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
    return std::make_shared<jarvis::audit::TamperEvidentAuditLog>((root / "audit.log").string());
}

Signal make_signal() {
    return Signal{.kind = "trail", .topic = "operator_check_in", .strength = 0.7, .last_t = 99.0,
                  .depositors = {"a1", "a2"}, .vec = std::vector<double>{0.1, 0.2}};
}

} // namespace

TEST_CASE("to_doc hashes topic and kind and writes local index") {
    auto server = std::make_shared<MockConvexServer>();
    auto secrets = test_secrets();
    ConvexBackend backend(server, secrets, test_audit());
    auto doc = backend.to_doc(make_signal());

    REQUIRE(doc.at("topic") != "operator_check_in");
    REQUIRE(doc.at("kind") != "trail");
    REQUIRE(is_hmac_hex(doc.at("topic").get<std::string>()));
    REQUIRE(is_hmac_hex(doc.at("kind").get<std::string>()));
    REQUIRE(doc.contains("values"));
    REQUIRE(doc.at("values").contains("ciphertext"));
    REQUIRE(doc.contains("sig"));
    REQUIRE(doc.dump().find("strength") == std::string::npos);
    REQUIRE(doc.dump().find("depositors") == std::string::npos);
    REQUIRE(secrets->lookup_topic(doc.at("topic")).value() == "operator_check_in");
    REQUIRE(secrets->lookup_topic(doc.at("kind")).value() == "trail");

    auto secret_path = std::filesystem::path(secrets->jarvis_home()) / "runtime_secret.key";
    REQUIRE(std::filesystem::exists(secret_path));
    REQUIRE((std::filesystem::status(secret_path).permissions() & std::filesystem::perms::group_read) == std::filesystem::perms::none);
}

TEST_CASE("mock Convex round trip never transmits cleartext topic or kind") {
    auto server = std::make_shared<MockConvexServer>();
    ConvexBackend backend(server, test_secrets(), test_audit());
    backend.put({"trail", "operator_check_in"}, make_signal());
    auto got = backend.get({"trail", "operator_check_in"});

    REQUIRE(got.has_value());
    REQUIRE(got->topic == "operator_check_in");
    REQUIRE(got->kind == "trail");
    REQUIRE(got->depositors == std::set<std::string>{"a1", "a2"});
    REQUIRE(got->vec.has_value());

    for (const auto& tx : server->transmitted) {
        const auto dumped = tx.dump();
        REQUIRE(dumped.find("operator_check_in") == std::string::npos);
        REQUIRE(dumped.find("trail") == std::string::npos);
        assert_no_cleartext_topic_kind(tx.at("args"));
    }
}

TEST_CASE("privacy gate fails loud on cleartext topic or kind") {
    REQUIRE_THROWS_AS(assert_no_cleartext_topic_kind({{"kind", "trail"}, {"topic", std::string(64, 'a')}}), std::runtime_error);
    REQUIRE_THROWS_AS(assert_no_cleartext_topic_kind({{"keys", {{{"kind", std::string(64, 'b')}, {"topic", "operator_check_in"}}}}}), std::runtime_error);
}

TEST_CASE("delete and gc use hashed keys") {
    auto server = std::make_shared<MockConvexServer>();
    ConvexBackend backend(server, test_secrets(), test_audit());
    backend.put({"trail", "operator_check_in"}, make_signal());
    backend.delete_key({"trail", "operator_check_in"});
    backend.gc_keys({{"trail", "operator_check_in"}, {"alarm", "route_b"}});
    for (const auto& tx : server->transmitted) assert_no_cleartext_topic_kind(tx.at("args"));
}

TEST_CASE("Convex endpoint is allowlisted and pinned for HTTPS and WSS") {
    REQUIRE(jarvis::security::egress::EgressAllowlist::global().is_allowed("fleet-goose-114.convex.cloud", 443));
    REQUIRE(jarvis::security::CertPinStore::global().is_pinned("fleet-goose-114.convex.cloud"));
    ConvexWebSocketProbe probe("wss://fleet-goose-114.convex.cloud/");
    REQUIRE(probe.host_is_allowed_and_pinned());
}

TEST_CASE("secret() throws RuntimeSecretMissingError when runtime_secret.key absent") {
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / "jarvis_home_absent";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    RuntimeSecretStore store(root.string());
    REQUIRE_THROWS_AS(store.secret(), RuntimeSecretMissingError);
}

TEST_CASE("issue_from_ceremony writes file and secret() returns same bytes") {
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / "jarvis_home_issue";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    std::vector<unsigned char> ceremony_key(32);
    for (int i = 0; i < 32; ++i) ceremony_key[static_cast<std::size_t>(i)] = static_cast<unsigned char>(i + 1);
    RuntimeSecretStore::issue_from_ceremony(root.string(), ceremony_key);
    auto path = root / "runtime_secret.key";
    REQUIRE(std::filesystem::exists(path));
    // Verify 0600 permissions (no group/other read).
    const auto perms = std::filesystem::status(path).permissions();
    REQUIRE((perms & std::filesystem::perms::group_read) == std::filesystem::perms::none);
    REQUIRE((perms & std::filesystem::perms::others_read) == std::filesystem::perms::none);
    RuntimeSecretStore store(root.string());
    const auto& loaded = store.secret();
    REQUIRE(loaded == ceremony_key);
}

TEST_CASE("issue_from_ceremony refuses overwrite on second call") {
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / "jarvis_home_overwrite";
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    std::vector<unsigned char> key(32, 0xAB);
    RuntimeSecretStore::issue_from_ceremony(root.string(), key);
    REQUIRE_THROWS_AS(RuntimeSecretStore::issue_from_ceremony(root.string(), key), std::runtime_error);
}
