#include <catch2/catch_test_macros.hpp>

#include "beliefstore.h"
#include "beliefstore_persistence.h"
#include "audit_log.h"

#include <array>
#include <atomic>
#include <filesystem>
#include <sodium.h>

#include <string>
#include <thread>
#include <utility>
#include <vector>

using jarvis::BeliefStore;
using jarvis::BeliefStorePersistenceConfig;
using jarvis::BeliefStoreRotationAttestation;
using jarvis::SourceType;

namespace {

std::filesystem::path artifact_dir() { return TEST_ARTIFACT_DIR; }

void remove_artifacts(const std::filesystem::path& base) {
    std::filesystem::remove(base);
    std::filesystem::remove(base.string() + ".audit");
    std::filesystem::remove(base.string() + ".audit.key");
}

jarvis::security::memory::LockedBytes locked_key(std::string label) {
    jarvis::security::memory::ensure_sodium_initialized();
    jarvis::security::memory::LockedBytes key(32);
    crypto_generichash(key.data(), key.size(),
                       reinterpret_cast<const unsigned char*>(label.data()), label.size(),
                       nullptr, 0);
    return key;
}

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

BeliefStorePersistenceConfig config_for(const std::filesystem::path& db, std::string label) {
    install_test_audit_key();
    BeliefStorePersistenceConfig cfg;
    cfg.database_path = db;
    cfg.audit_log_path = db.string() + ".audit";
    cfg.audit_key_path = db.string() + ".audit.key";
    cfg.key_provider = [label = std::move(label)] { return locked_key(label); };
    return cfg;
}

bool audit_has_reason(const std::filesystem::path& db, const std::string& reason) {
    install_test_audit_key();
    jarvis::audit::TamperEvidentAuditLog log(db.string() + ".audit");
    REQUIRE(log.verify_chain());
    for (const auto& event : log) {
        if (event.reason == reason) return true;
    }
    return false;
}

} // namespace

TEST_CASE("BeliefStore SQLCipher opens with the correct key and reloads encrypted beliefs", "[beliefstore][sqlcipher]") {
    const auto db = artifact_dir() / "beliefstore_correct_key.db";
    remove_artifacts(db);
    {
        BeliefStore store(config_for(db, "correct-key"));
        REQUIRE(store.assert_belief("operator", "callsign", "Grizzly", SourceType::Operator) == 1);
        REQUIRE(store.recall("operator", "callsign") == "Grizzly");
    }
    {
        BeliefStore reopened(config_for(db, "correct-key"));
        REQUIRE(reopened.recall("operator", "callsign") == "Grizzly");
        REQUIRE(reopened.size() == 1);
    }
    REQUIRE(audit_has_reason(db, "beliefstore_sqlcipher_opened"));
    REQUIRE(audit_has_reason(db, "beliefstore_sqlcipher_closed"));
}

TEST_CASE("BeliefStore SQLCipher refuses to open with the wrong key", "[beliefstore][sqlcipher]") {
    const auto db = artifact_dir() / "beliefstore_wrong_key.db";
    remove_artifacts(db);
    {
        BeliefStore store(config_for(db, "wrong-key-original"));
        store.assert_belief("sky", "color", "blue", SourceType::Operator);
    }
    REQUIRE_THROWS_AS(BeliefStore(config_for(db, "wrong-key-attempt")), std::runtime_error);
}

TEST_CASE("BeliefStore SQLCipher rotates key only with operator attestation and preserves data", "[beliefstore][sqlcipher][rotation]") {
    const auto db = artifact_dir() / "beliefstore_rotation.db";
    remove_artifacts(db);
    {
        BeliefStore store(config_for(db, "rotation-original"));
        store.assert_belief("mars", "color", "red", SourceType::Document);
        REQUIRE_THROWS_AS(store.rotate_persistence_key(locked_key("rotation-denied"), {false, "missing"}), std::runtime_error);
        REQUIRE(store.recall("mars", "color") == "red");
        store.rotate_persistence_key(locked_key("rotation-new"), BeliefStoreRotationAttestation{true, "test-attestation"});
    }
    REQUIRE_THROWS_AS(BeliefStore(config_for(db, "rotation-original")), std::runtime_error);
    {
        BeliefStore reopened(config_for(db, "rotation-new"));
        REQUIRE(reopened.recall("mars", "color") == "red");
    }
    REQUIRE(audit_has_reason(db, "beliefstore_rotation_denied_no_operator_attestation"));
    REQUIRE(audit_has_reason(db, "beliefstore_sqlcipher_rotated"));
}

TEST_CASE("BeliefStore SQLCipher zeroizes locked key material on close", "[beliefstore][sqlcipher][zeroize]") {
    const auto db = artifact_dir() / "beliefstore_zeroize.db";
    remove_artifacts(db);
    BeliefStore store(config_for(db, "zeroize-key"));
    store.assert_belief("key", "state", "locked", SourceType::Operator);
    store.close_persistence();
    REQUIRE(store.persistence_key_zeroized_on_close_for_test());
}

TEST_CASE("BeliefStore SQLCipher serializes concurrent readers and writers without SQLITE_BUSY leaks", "[beliefstore][sqlcipher][concurrency]") {
    const auto db = artifact_dir() / "beliefstore_concurrent.db";
    remove_artifacts(db);
    BeliefStore store(config_for(db, "concurrency-key"));
    std::atomic<bool> failed{false};
    std::vector<std::thread> threads;
    for (int writer = 0; writer < 4; ++writer) {
        threads.emplace_back([&store, &failed, writer] {
            try {
                for (int i = 0; i < 25; ++i) {
                    store.assert_belief("subject-" + std::to_string(writer) + "-" + std::to_string(i),
                                        "relation",
                                        "object",
                                        SourceType::Operator);
                }
            } catch (const std::exception& e) {
                if (std::string(e.what()).find("SQLITE_BUSY") != std::string::npos ||
                    std::string(e.what()).find("database is locked") != std::string::npos) {
                    failed = true;
                }
                failed = true;
            }
        });
    }
    for (int reader = 0; reader < 4; ++reader) {
        threads.emplace_back([&store, &failed] {
            try {
                for (int i = 0; i < 100; ++i) {
                    (void)store.recall("subject-0-0", "relation");
                }
            } catch (const std::exception&) {
                failed = true;
            }
        });
    }
    for (auto& thread : threads) thread.join();
    REQUIRE_FALSE(failed.load());
    REQUIRE(store.size() == 100);
}

TEST_CASE("BeliefStore SQLCipher database, WAL, and SHM are owner-only", "[beliefstore][sqlcipher][permissions]") {
    const auto db = artifact_dir() / "beliefstore_permissions.db";
    remove_artifacts(db);
    {
        BeliefStore store(config_for(db, "permissions-key"));
        REQUIRE(store.assert_belief("operator", "permission", "0600", SourceType::Operator) == 1);
    }
    for (const auto& path : {db, std::filesystem::path(db.string() + "-wal"), std::filesystem::path(db.string() + "-shm")}) {
        if (!std::filesystem::exists(path)) continue;
        struct stat st {};
        REQUIRE(::stat(path.string().c_str(), &st) == 0);
        REQUIRE((st.st_mode & 0077) == 0);
    }
}
