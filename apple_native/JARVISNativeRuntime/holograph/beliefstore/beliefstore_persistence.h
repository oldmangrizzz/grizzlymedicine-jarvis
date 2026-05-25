#pragma once

#include "beliefstore.h"
#include "memory_security.h"

#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace jarvis {

struct BeliefStorePersistenceConfig {
    std::filesystem::path database_path;
    std::filesystem::path audit_log_path;
    std::filesystem::path audit_key_path;
    std::function<security::memory::LockedBytes()> key_provider;

    [[nodiscard]] static BeliefStorePersistenceConfig secure_enclave_sqlcipher(
        std::filesystem::path database_path,
        std::filesystem::path audit_log_path = {},
        std::filesystem::path audit_key_path = {},
        std::string secure_enclave_key_tag = "org.gmri.jarvis.beliefstore.sqlcipher");
};

struct BeliefStoreRotationAttestation {
    bool operator_attested{false};
    std::string attestation_id;
};

class BeliefStoreEncryptedPersistence {
public:
    explicit BeliefStoreEncryptedPersistence(BeliefStorePersistenceConfig config);
    ~BeliefStoreEncryptedPersistence();

    BeliefStoreEncryptedPersistence(const BeliefStoreEncryptedPersistence&) = delete;
    BeliefStoreEncryptedPersistence& operator=(const BeliefStoreEncryptedPersistence&) = delete;

    [[nodiscard]] std::vector<BeliefEdge> load_edges();
    void save_edges(const std::vector<BeliefEdge>& edges, int next_edge_id);
    void rotate_key(security::memory::LockedBytes new_key,
                    const BeliefStoreRotationAttestation& attestation);
    void close();

    [[nodiscard]] const std::filesystem::path& database_path() const noexcept { return database_path_; }
    [[nodiscard]] bool key_zeroized_on_close_for_test() const noexcept { return key_zeroized_on_close_; }

private:
    void open();
    void require_sqlcipher();
    void ensure_schema();
    void audit(const std::string& outcome,
               const std::string& reason,
               const std::string& metadata = "");

    std::filesystem::path database_path_;
    std::filesystem::path audit_log_path_;
    std::filesystem::path audit_key_path_;
    security::memory::LockedBytes key_;
    mutable std::mutex persistence_mutex_;
    void* db_{nullptr};
    bool opened_{false};
    bool key_zeroized_on_close_{false};
};

security::memory::LockedBytes derive_beliefstore_key_from_secure_enclave(
    const std::filesystem::path& database_path,
    const std::string& key_tag,
    const std::filesystem::path& audit_log_path = {});

} // namespace jarvis
