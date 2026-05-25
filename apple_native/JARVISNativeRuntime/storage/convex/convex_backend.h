#pragma once

#include <array>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace jarvis::audit { class TamperEvidentAuditLog; }

namespace jarvis::storage::convex {

// Thrown by RuntimeSecretStore::secret() when runtime_secret.key is absent and
// no ceremony attestation has been issued. Silent regeneration is forbidden.
class RuntimeSecretMissingError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct Signal {
    std::string kind;
    std::string topic;
    double strength{0.0};
    double last_t{0.0};
    std::set<std::string> depositors;
    std::optional<std::vector<double>> vec;
};

class ConvexTransport {
public:
    virtual ~ConvexTransport() = default;
    virtual nlohmann::json mutation(const std::string& name, const nlohmann::json& args) = 0;
    virtual nlohmann::json query(const std::string& name, const nlohmann::json& args) = 0;
};

class RuntimeSecretStore {
public:
    RuntimeSecretStore();
    explicit RuntimeSecretStore(std::string jarvis_home);
    ~RuntimeSecretStore();

    // Ceremony-only issuance path. Writes secret_bytes (must be exactly 32 bytes)
    // to <jarvis_home>/runtime_secret.key using O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC +
    // write-loop + fsync. Throws if the file already exists (caller must delete
    // explicitly for intentional rotation) or if secret_bytes.size() != 32.
    // The C++ runtime never calls this; only the ceremony issues the file.
    static void issue_from_ceremony(const std::string& jarvis_home,
                                    const std::vector<unsigned char>& secret_bytes);

    [[nodiscard]] const std::vector<unsigned char>& secret();
    [[nodiscard]] std::string hmac_hex(const std::string& prefix, const std::string& value);
    [[nodiscard]] std::vector<unsigned char> derived_key(const std::string& label);
    [[nodiscard]] nlohmann::json encrypt_values(const std::string& kind_hash,
                                                const std::string& topic_hash,
                                                uint64_t version,
                                                const nlohmann::json& values);
    [[nodiscard]] nlohmann::json decrypt_values(const std::string& kind_hash,
                                                const std::string& topic_hash,
                                                uint64_t version,
                                                const nlohmann::json& envelope);
    [[nodiscard]] std::string sign_doc(const nlohmann::json& doc);
    [[nodiscard]] bool verify_doc_signature(const nlohmann::json& doc);
    [[nodiscard]] uint64_t next_local_version(const std::string& kind_hash, const std::string& topic_hash);
    [[nodiscard]] bool observe_remote_version(const std::string& kind_hash, const std::string& topic_hash, uint64_t version);
    void mark_expected(const std::string& kind_hash, const std::string& topic_hash);
    void clear_expected(const std::string& kind_hash, const std::string& topic_hash);
    [[nodiscard]] bool has_expected(const std::string& kind_hash, const std::string& topic_hash) const;
    void update_local_index(const std::string& hash, const std::string& plaintext);
    [[nodiscard]] std::optional<std::string> lookup_topic(const std::string& hash) const;
    [[nodiscard]] const std::string& jarvis_home() const noexcept { return jarvis_home_; }

private:
    void derived_key_into(const std::string& label, std::array<unsigned char, 32>& out);

    std::string jarvis_home_;
    std::vector<unsigned char> secret_;
};

class ConvexBackend {
public:
    explicit ConvexBackend(std::shared_ptr<ConvexTransport> transport,
                           std::shared_ptr<RuntimeSecretStore> secrets = nullptr,
                           std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log = nullptr);

    static ConvexBackend live(std::string url,
                              std::shared_ptr<RuntimeSecretStore> secrets = nullptr,
                              std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log = nullptr);

    void put(const std::pair<std::string, std::string>& key, const Signal& sig);
    [[nodiscard]] std::optional<Signal> get(const std::pair<std::string, std::string>& key);
    [[nodiscard]] std::vector<Signal> all();
    void delete_key(const std::pair<std::string, std::string>& key);
    void gc_keys(const std::vector<std::pair<std::string, std::string>>& keys);

    [[nodiscard]] nlohmann::json to_doc(const Signal& sig);
    [[nodiscard]] std::optional<Signal> from_doc(const nlohmann::json& doc);

private:
    [[nodiscard]] nlohmann::json hashed_key_args(const std::pair<std::string, std::string>& key);
    void audit_call(const char* operation, const char* outcome, const nlohmann::json& args);
    void audit_security_reject(const char* reason, const nlohmann::json& doc);

    std::shared_ptr<ConvexTransport> transport_;
    std::shared_ptr<RuntimeSecretStore> secrets_;
    std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log_;
};

class CurlConvexTransport final : public ConvexTransport {
public:
    explicit CurlConvexTransport(std::string url);
    ~CurlConvexTransport() override;

    nlohmann::json mutation(const std::string& name, const nlohmann::json& args) override;
    nlohmann::json query(const std::string& name, const nlohmann::json& args) override;

private:
    [[nodiscard]] nlohmann::json call(const std::string& endpoint,
                                      const std::string& name,
                                      const nlohmann::json& args);
    std::string url_;
    std::string host_;
};

[[nodiscard]] bool is_hmac_hex(std::string_view value) noexcept;
void assert_no_cleartext_topic_kind(const nlohmann::json& payload);

} // namespace jarvis::storage::convex
