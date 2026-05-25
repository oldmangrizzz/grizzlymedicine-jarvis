#include "../../../storage/convex/convex_backend.h"
#include "../../../integrity/audit/audit_log.h"
#include "../../../integrity/audit/audit_verify.h"
#include "../../../security/cert_pinning.h"

#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>

#include <array>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include <openssl/pem.h>
#include <openssl/x509.h>

using namespace jarvis::storage::convex;

namespace {

struct WireEvent {
    std::string type;
    std::string name;
    nlohmann::json args;
    int64_t timestamp_ns{0};
    std::size_t bytes{0};
};

struct HostileConvexServer final : ConvexTransport {
    std::map<std::pair<std::string, std::string>, nlohmann::json> rows;
    std::vector<WireEvent> wire;

    static int64_t now_ns() {
        using namespace std::chrono;
        return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
    }

    void capture(std::string type, const std::string& name, const nlohmann::json& args) {
        assert_no_cleartext_topic_kind(args);
        wire.push_back(WireEvent{std::move(type), name, args, now_ns(), args.dump().size()});
    }

    nlohmann::json mutation(const std::string& name, const nlohmann::json& args) override {
        capture("mutation", name, args);
        if (name == "stigmergy:put") rows[{args.at("kind"), args.at("topic")}] = args;
        else if (name == "stigmergy:del") rows.erase({args.at("kind"), args.at("topic")});
        else if (name == "stigmergy:gcKeys") for (const auto& k : args.at("keys")) rows.erase({k.at("kind"), k.at("topic")});
        return nullptr;
    }

    nlohmann::json query(const std::string& name, const nlohmann::json& args) override {
        capture("query", name, args);
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

    nlohmann::json only_row() const {
        REQUIRE(rows.size() == 1);
        return rows.begin()->second;
    }

    void drop_all() { rows.clear(); }
};

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

std::filesystem::path test_root(const std::string& name) {
    install_test_audit_key();
    auto root = std::filesystem::path(TEST_ARTIFACT_DIR) / name;
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    return root;
}

struct Harness {
    std::filesystem::path root;
    std::shared_ptr<HostileConvexServer> server;
    std::shared_ptr<RuntimeSecretStore> secrets;
    std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit;
    ConvexBackend backend;

    explicit Harness(const std::string& name)
        : root(test_root(name))
        , server(std::make_shared<HostileConvexServer>())
        , secrets(std::make_shared<RuntimeSecretStore>((root / "jarvis_home").string()))
        , audit(std::make_shared<jarvis::audit::TamperEvidentAuditLog>((root / "audit" / "audit.log").string()))
        , backend(server, secrets, audit) {}
};

Signal hostile_marker_signal(double strength = 0.7) {
    return Signal{.kind = "trail",
                  .topic = "operator_check_in",
                  .strength = strength,
                  .last_t = 99.0 + strength,
                  .depositors = {"GMRI_OPERATOR_PAYLOAD_NEVER_CLEAR", "depositor_b"},
                  .vec = std::vector<double>{0.125, 0.25, 0.5}};
}

bool audit_contains(const jarvis::audit::TamperEvidentAuditLog& log, const std::string& reason) {
    for (const auto& event : log) if (event.reason == reason) return true;
    return false;
}

struct X509Deleter { void operator()(X509* cert) const { if (cert) X509_free(cert); } };
using X509Ptr = std::unique_ptr<X509, X509Deleter>;

X509Ptr load_pem_cert(const std::filesystem::path& path) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (!f) throw std::runtime_error("could not open PEM fixture: " + path.string());
    X509* cert = PEM_read_X509(f, nullptr, nullptr, nullptr);
    std::fclose(f);
    return X509Ptr(cert);
}

} // namespace

TEST_CASE("hostile-vendor inspection sees HMAC keys and encrypted values only") {
    Harness h("hostile_vendor_inspection");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal());

    REQUIRE_FALSE(h.server->wire.empty());
    const auto row = h.server->only_row();
    REQUIRE(is_hmac_hex(row.at("topic").get<std::string>()));
    REQUIRE(is_hmac_hex(row.at("kind").get<std::string>()));
    REQUIRE(row.at("topic") != "operator_check_in");
    REQUIRE(row.at("kind") != "trail");
    REQUIRE(row.contains("values"));
    REQUIRE(row.at("values").contains("ciphertext"));
    REQUIRE(row.at("values").contains("nonce"));
    REQUIRE(row.at("values").contains("tag"));

    const auto dumped = row.dump();
    REQUIRE(dumped.find("operator_check_in") == std::string::npos);
    REQUIRE(dumped.find("trail") == std::string::npos);
    REQUIRE(dumped.find("GMRI_OPERATOR_PAYLOAD_NEVER_CLEAR") == std::string::npos);
    REQUIRE(dumped.find("strength") == std::string::npos);

    auto wrong_secret = std::make_shared<RuntimeSecretStore>((h.root / "wrong_secret_home").string());
    ConvexBackend wrong_reader(h.server, wrong_secret, h.audit);
    REQUIRE_THROWS(wrong_reader.from_doc(row));
}

TEST_CASE("subpoena dump cannot derive operator topic kind or payload without local secret") {
    Harness h("subpoena_dump");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal());
    h.backend.put({"alarm", "route_b"}, Signal{.kind = "alarm", .topic = "route_b", .strength = 0.2, .last_t = 12.0});

    nlohmann::json subpoena_rows = nlohmann::json::array();
    for (const auto& [_, row] : h.server->rows) subpoena_rows.push_back(row);
    const auto dump = subpoena_rows.dump();
    REQUIRE(dump.find("operator_check_in") == std::string::npos);
    REQUIRE(dump.find("route_b") == std::string::npos);
    REQUIRE(dump.find("trail") == std::string::npos);
    REQUIRE(dump.find("alarm") == std::string::npos);
    REQUIRE(dump.find("GMRI_OPERATOR_PAYLOAD_NEVER_CLEAR") == std::string::npos);

    for (const auto& row : subpoena_rows) {
        REQUIRE(is_hmac_hex(row.at("topic").get<std::string>()));
        REQUIRE(is_hmac_hex(row.at("kind").get<std::string>()));
        REQUIRE(row.at("values").contains("ciphertext"));
    }
}

TEST_CASE("active MITM wrong leaf certificate is rejected by real SPKI pinning") {
    const auto valid_cert = load_pem_cert(std::filesystem::path(CERT_FIXTURE_DIR) / "test_leaf_valid.pem");
    const auto wrong_cert = load_pem_cert(std::filesystem::path(CERT_FIXTURE_DIR) / "test_leaf_wrong_key.pem");
    REQUIRE(valid_cert != nullptr);
    REQUIRE(wrong_cert != nullptr);

    jarvis::security::CertPinStore store;
    store.add_pins("fleet-goose-114.convex.cloud", {jarvis::security::compute_spki_pin(valid_cert.get())});
    REQUIRE(jarvis::security::validate_leaf_cert(valid_cert.get(), "fleet-goose-114.convex.cloud", store) == jarvis::security::PinResult::Valid);
    REQUIRE(jarvis::security::validate_leaf_cert(wrong_cert.get(), "fleet-goose-114.convex.cloud", store) == jarvis::security::PinResult::Mismatch);
}

TEST_CASE("compelled logging reveals only residual timing size and cadence side channels") {
    Harness h("compelled_logging");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal());
    (void)h.backend.get({"trail", "operator_check_in"});

    REQUIRE(h.server->wire.size() >= 2);
    for (const auto& ev : h.server->wire) {
        const auto dump = ev.args.dump();
        REQUIRE(ev.timestamp_ns > 0);
        REQUIRE(ev.bytes > 0);
        REQUIRE(dump.find("operator_check_in") == std::string::npos);
        REQUIRE(dump.find("trail") == std::string::npos);
        assert_no_cleartext_topic_kind(ev.args);
    }
}

TEST_CASE("replayed old encrypted blob is refused and audited") {
    Harness h("replay_attack");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal(0.1));
    const auto old_blob = h.server->only_row();
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal(0.9));

    h.server->rows[{old_blob.at("kind"), old_blob.at("topic")}] = old_blob;
    REQUIRE_THROWS(h.backend.get({"trail", "operator_check_in"}));
    REQUIRE(audit_contains(*h.audit, "convex_replay_detected"));
    REQUIRE(h.audit->verify_chain());
}

TEST_CASE("selective deletion of stored records is detected and audit chain remains tamper-evident") {
    Harness h("selective_deletion");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal());
    h.server->drop_all();

    REQUIRE_THROWS(h.backend.get({"trail", "operator_check_in"}));
    REQUIRE(audit_contains(*h.audit, "convex_missing_expected_record"));

    jarvis::audit::AuditVerifier verifier(h.audit->log_path());
    REQUIRE(verifier.verify().status == jarvis::audit::VerifyStatus::PASS);

    const auto original_size = std::filesystem::file_size(h.audit->log_path());
    std::filesystem::resize_file(h.audit->log_path(), original_size - 1);
    REQUIRE(verifier.verify().status != jarvis::audit::VerifyStatus::PASS);
}

TEST_CASE("confused-deputy injected records fail signature gate") {
    Harness h("confused_deputy");
    h.backend.put({"trail", "operator_check_in"}, hostile_marker_signal());
    auto injected = h.server->only_row();
    injected["values"]["ciphertext"] = std::string("AAAAAAAAAAAAAAAAAAAAAA==");
    injected["sig"] = std::string(64, '0');
    h.server->rows[{injected.at("kind"), injected.at("topic")}] = injected;

    REQUIRE_THROWS(h.backend.get({"trail", "operator_check_in"}));
    REQUIRE(audit_contains(*h.audit, "convex_signature_rejected"));
    REQUIRE(h.audit->verify_chain());
}
