#include "beliefstore_persistence.h"

#include "audit_event.h"
#include "audit_log.h"

#include <sqlcipher/sqlite3.h>
#include <sodium.h>

#include <array>
#include <cerrno>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include <span>
#include <stdexcept>
#include <utility>

#if __has_include("JARVISSecureEnclaveBridge.h")
#include "JARVISSecureEnclaveBridge.h"
#define JARVIS_HAS_SE_BRIDGE 1
#else
#define JARVIS_HAS_SE_BRIDGE 0
#endif

extern "C" int sqlite3_key(sqlite3* db, const void* pKey, int nKey);
extern "C" int sqlite3_rekey(sqlite3* db, const void* pKey, int nKey);

namespace jarvis {
namespace {

constexpr std::size_t kSqlCipherKeyBytes = 32;

std::string json_escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

void exec_sql(sqlite3* db, const char* sql) {
    char* err = nullptr;
    const int rc = sqlite3_exec(db, sql, nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        std::string msg = err ? err : sqlite3_errmsg(db);
        sqlite3_free(err);
        throw std::runtime_error(std::string("SQLCipher exec failed: ") + msg);
    }
}

void bind_text(sqlite3_stmt* stmt, int index, const std::string& value) {
    if (sqlite3_bind_text(stmt, index, value.c_str(), static_cast<int>(value.size()), SQLITE_TRANSIENT) != SQLITE_OK) {
        throw std::runtime_error("SQLCipher bind_text failed");
    }
}

void bind_blob(sqlite3_stmt* stmt, int index, const std::vector<std::uint8_t>& value) {
    if (sqlite3_bind_blob(stmt, index, value.data(), static_cast<int>(value.size()), SQLITE_TRANSIENT) != SQLITE_OK) {
        throw std::runtime_error("SQLCipher bind_blob failed");
    }
}

std::filesystem::path default_audit_log_path(const std::filesystem::path& db_path) {
    return db_path.string() + ".audit";
}

std::filesystem::path default_audit_key_path(const std::filesystem::path& db_path) {
    return db_path.string() + ".audit.key";
}

std::array<unsigned char, crypto_hash_sha256_BYTES> sha256_bytes(std::string_view value) {
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(), reinterpret_cast<const unsigned char*>(value.data()),
                       static_cast<unsigned long long>(value.size()));
    return digest;
}

std::string hex_encode(std::span<const unsigned char> bytes) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (auto b : bytes) {
        out.push_back(hex[(b >> 4) & 0x0f]);
        out.push_back(hex[b & 0x0f]);
    }
    return out;
}

std::string sqlite_error(sqlite3* db) {
    return db ? sqlite3_errmsg(db) : "database handle is null";
}

void chmod_if_exists_0600(const std::filesystem::path& path) {
    if (path.empty() || !std::filesystem::exists(path)) return;
    if (::chmod(path.string().c_str(), S_IRUSR | S_IWUSR) != 0) {
        throw std::runtime_error("BeliefStore chmod 0600 failed for " + path.string() + ": " + std::strerror(errno));
    }
}

void secure_sqlite_file_modes(const std::filesystem::path& db_path) {
    chmod_if_exists_0600(db_path);
    chmod_if_exists_0600(db_path.string() + "-wal");
    chmod_if_exists_0600(db_path.string() + "-shm");
}

} // namespace

BeliefStorePersistenceConfig BeliefStorePersistenceConfig::secure_enclave_sqlcipher(
    std::filesystem::path database_path,
    std::filesystem::path audit_log_path,
    std::filesystem::path audit_key_path,
    std::string secure_enclave_key_tag) {
    BeliefStorePersistenceConfig cfg;
    cfg.database_path = std::move(database_path);
    cfg.audit_log_path = std::move(audit_log_path);
    cfg.audit_key_path = std::move(audit_key_path);
    cfg.key_provider = [path = cfg.database_path, tag = std::move(secure_enclave_key_tag), audit = cfg.audit_log_path]() {
        return derive_beliefstore_key_from_secure_enclave(path, tag, audit);
    };
    return cfg;
}

BeliefStoreEncryptedPersistence::BeliefStoreEncryptedPersistence(BeliefStorePersistenceConfig config)
    : database_path_(std::move(config.database_path)),
      audit_log_path_(config.audit_log_path.empty() ? default_audit_log_path(database_path_) : std::move(config.audit_log_path)),
      audit_key_path_(config.audit_key_path.empty() ? default_audit_key_path(database_path_) : std::move(config.audit_key_path)) {
    if (database_path_.empty()) throw std::invalid_argument("BeliefStore SQLCipher database path is required");
    if (!config.key_provider) throw std::invalid_argument("BeliefStore SQLCipher key provider is required");
    key_ = config.key_provider();
    if (key_.size() != kSqlCipherKeyBytes) {
        throw std::invalid_argument("BeliefStore SQLCipher key provider must return exactly 32 locked bytes");
    }
    open();
}

BeliefStoreEncryptedPersistence::~BeliefStoreEncryptedPersistence() { close(); }

void BeliefStoreEncryptedPersistence::open() {
    if (opened_) return;
    if (!database_path_.parent_path().empty()) std::filesystem::create_directories(database_path_.parent_path());
    sqlite3* raw = nullptr;
    const mode_t prior_umask = ::umask(0077);
    const int open_rc = sqlite3_open(database_path_.string().c_str(), &raw);
    ::umask(prior_umask);
    if (open_rc != SQLITE_OK) {
        std::string msg = sqlite_error(raw);
        if (raw) sqlite3_close(raw);
        throw std::runtime_error("SQLCipher open failed: " + msg);
    }
    db_ = raw;
    secure_sqlite_file_modes(database_path_);
    if (sqlite3_busy_timeout(static_cast<sqlite3*>(db_), 5000) != SQLITE_OK) {
        std::string msg = sqlite_error(static_cast<sqlite3*>(db_));
        close();
        throw std::runtime_error("SQLCipher busy_timeout failed: " + msg);
    }
    if (sqlite3_key(static_cast<sqlite3*>(db_), key_.data(), static_cast<int>(key_.size())) != SQLITE_OK) {
        std::string msg = sqlite_error(static_cast<sqlite3*>(db_));
        close();
        throw std::runtime_error("SQLCipher keying failed: " + msg);
    }
    key_.clear();
    try {
        require_sqlcipher();
        exec_sql(static_cast<sqlite3*>(db_), "PRAGMA journal_mode=WAL;");
        ensure_schema();
        secure_sqlite_file_modes(database_path_);
        opened_ = true;
        audit(jarvis::audit::Outcome::ALLOWED, "beliefstore_sqlcipher_opened",
              std::string("{\"db_path_sha256\":\"") + hex_encode(sha256_bytes(database_path_.string())) + "\"}");
    } catch (...) {
        close();
        throw;
    }
}

void BeliefStoreEncryptedPersistence::require_sqlcipher() {
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(static_cast<sqlite3*>(db_), "PRAGMA cipher_version;", -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("SQLCipher unavailable: PRAGMA cipher_version failed; install Homebrew sqlcipher and rebuild");
    }
    const int rc = sqlite3_step(stmt);
    const unsigned char* text = (rc == SQLITE_ROW) ? sqlite3_column_text(stmt, 0) : nullptr;
    const bool ok = text && std::strlen(reinterpret_cast<const char*>(text)) > 0;
    sqlite3_finalize(stmt);
    if (!ok) throw std::runtime_error("SQLCipher unavailable: linked sqlite does not report cipher_version");
}

void BeliefStoreEncryptedPersistence::ensure_schema() {
    exec_sql(static_cast<sqlite3*>(db_), "PRAGMA foreign_keys=ON;");
    exec_sql(static_cast<sqlite3*>(db_),
        "CREATE TABLE IF NOT EXISTS beliefstore_meta ("
        "key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS belief_edges ("
        "id INTEGER PRIMARY KEY NOT NULL,"
        "subject TEXT NOT NULL,"
        "relation TEXT NOT NULL,"
        "object TEXT NOT NULL,"
        "source_type TEXT NOT NULL,"
        "source_ref TEXT NOT NULL,"
        "confidence REAL NOT NULL,"
        "quarantined INTEGER NOT NULL,"
        "provenance_class TEXT NOT NULL,"
        "charge REAL NOT NULL,"
        "revised_at REAL NOT NULL,"
        "tuple_hv BLOB NOT NULL);"
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_belief_edges_triple "
        "ON belief_edges(subject, relation, object);"
        "INSERT OR IGNORE INTO beliefstore_meta(key, value) VALUES('schema_version', '1');");
}

std::vector<BeliefEdge> BeliefStoreEncryptedPersistence::load_edges() {
    std::lock_guard<std::mutex> lock(persistence_mutex_);
    sqlite3_stmt* stmt = nullptr;
    const char* sql = "SELECT id, subject, relation, object, source_type, source_ref, confidence, "
                      "quarantined, provenance_class, charge, revised_at, tuple_hv "
                      "FROM belief_edges ORDER BY id ASC;";
    if (sqlite3_prepare_v2(static_cast<sqlite3*>(db_), sql, -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("SQLCipher load prepare failed: " + sqlite_error(static_cast<sqlite3*>(db_)));
    }
    std::vector<BeliefEdge> edges;
    while (true) {
        const int rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            std::string msg = sqlite_error(static_cast<sqlite3*>(db_));
            sqlite3_finalize(stmt);
            throw std::runtime_error("SQLCipher load failed: " + msg);
        }
        BeliefEdge edge;
        edge.id = sqlite3_column_int(stmt, 0);
        edge.subject = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        edge.relation = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 2));
        edge.object = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 3));
        edge.source_type = source_type_from_string(reinterpret_cast<const char*>(sqlite3_column_text(stmt, 4)));
        edge.source_ref = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 5));
        edge.confidence = sqlite3_column_double(stmt, 6);
        edge.quarantined = sqlite3_column_int(stmt, 7) != 0;
        edge.provenance_class = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 8));
        edge.charge = sqlite3_column_double(stmt, 9);
        edge.revised_at = sqlite3_column_double(stmt, 10);
        const auto* blob = static_cast<const std::uint8_t*>(sqlite3_column_blob(stmt, 11));
        const int bytes = sqlite3_column_bytes(stmt, 11);
        if (blob && bytes > 0) edge.tuple_hv.assign(blob, blob + bytes);
        edges.push_back(std::move(edge));
    }
    sqlite3_finalize(stmt);
    return edges;
}

void BeliefStoreEncryptedPersistence::save_edges(const std::vector<BeliefEdge>& edges, int next_edge_id) {
    std::lock_guard<std::mutex> lock(persistence_mutex_);
    exec_sql(static_cast<sqlite3*>(db_), "BEGIN IMMEDIATE;");
    try {
        exec_sql(static_cast<sqlite3*>(db_), "DELETE FROM belief_edges;");
        const std::string meta_sql = "INSERT OR REPLACE INTO beliefstore_meta(key, value) VALUES('next_edge_id', '"
            + std::to_string(next_edge_id) + "');";
        exec_sql(static_cast<sqlite3*>(db_), meta_sql.c_str());
        sqlite3_stmt* stmt = nullptr;
        const char* sql = "INSERT INTO belief_edges(id, subject, relation, object, source_type, source_ref, "
                          "confidence, quarantined, provenance_class, charge, revised_at, tuple_hv) "
                          "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);";
        if (sqlite3_prepare_v2(static_cast<sqlite3*>(db_), sql, -1, &stmt, nullptr) != SQLITE_OK) {
            throw std::runtime_error("SQLCipher save prepare failed: " + sqlite_error(static_cast<sqlite3*>(db_)));
        }
        for (const auto& edge : edges) {
            sqlite3_bind_int(stmt, 1, edge.id);
            bind_text(stmt, 2, edge.subject);
            bind_text(stmt, 3, edge.relation);
            bind_text(stmt, 4, edge.object);
            bind_text(stmt, 5, to_string(edge.source_type));
            bind_text(stmt, 6, edge.source_ref);
            sqlite3_bind_double(stmt, 7, edge.confidence);
            sqlite3_bind_int(stmt, 8, edge.quarantined ? 1 : 0);
            bind_text(stmt, 9, edge.provenance_class);
            sqlite3_bind_double(stmt, 10, edge.charge);
            sqlite3_bind_double(stmt, 11, edge.revised_at);
            bind_blob(stmt, 12, edge.tuple_hv);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                std::string msg = sqlite_error(static_cast<sqlite3*>(db_));
                sqlite3_finalize(stmt);
                throw std::runtime_error("SQLCipher save failed: " + msg);
            }
            sqlite3_reset(stmt);
            sqlite3_clear_bindings(stmt);
        }
        sqlite3_finalize(stmt);
        exec_sql(static_cast<sqlite3*>(db_), "COMMIT;");
    } catch (...) {
        (void)sqlite3_exec(static_cast<sqlite3*>(db_), "ROLLBACK;", nullptr, nullptr, nullptr);
        throw;
    }
}

void BeliefStoreEncryptedPersistence::rotate_key(security::memory::LockedBytes new_key,
                                                 const BeliefStoreRotationAttestation& attestation) {
    std::lock_guard<std::mutex> lock(persistence_mutex_);
    if (!attestation.operator_attested) {
        audit(jarvis::audit::Outcome::DENIED, "beliefstore_rotation_denied_no_operator_attestation");
        throw std::runtime_error("BeliefStore SQLCipher rekey requires operator attestation");
    }
    if (new_key.size() != kSqlCipherKeyBytes) throw std::invalid_argument("new SQLCipher key must be exactly 32 locked bytes");
    if (sqlite3_rekey(static_cast<sqlite3*>(db_), new_key.data(), static_cast<int>(new_key.size())) != SQLITE_OK) {
        audit(jarvis::audit::Outcome::FAIL, "beliefstore_rotation_failed");
        throw std::runtime_error("SQLCipher rekey failed: " + sqlite_error(static_cast<sqlite3*>(db_)));
    }
    new_key.clear();
    key_.clear();
    audit(jarvis::audit::Outcome::ALLOWED, "beliefstore_sqlcipher_rotated",
          std::string("{\"attestation_id\":\"") + json_escape(attestation.attestation_id) + "\"}");
}

void BeliefStoreEncryptedPersistence::close() {
    std::lock_guard<std::mutex> lock(persistence_mutex_);
    if (db_) {
        if (opened_) audit(jarvis::audit::Outcome::ALLOWED, "beliefstore_sqlcipher_closed");
        sqlite3_close(static_cast<sqlite3*>(db_));
        db_ = nullptr;
        opened_ = false;
    }
    key_.clear();
    key_zeroized_on_close_ = key_.empty();
}

void BeliefStoreEncryptedPersistence::audit(const std::string& outcome,
                                            const std::string& reason,
                                            const std::string& metadata) {
    (void)audit_key_path_;
    auto& log = jarvis::audit::processAuditLog(audit_log_path_.string());
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::MEMORY_WRITE;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "sha256:" + hex_encode(sha256_bytes(database_path_.string()));
    event.outcome = outcome;
    event.reason = reason;
    event.redacted_metadata = metadata;
    log.append(event);
}

security::memory::LockedBytes derive_beliefstore_key_from_secure_enclave(
    const std::filesystem::path& database_path,
    const std::string& key_tag,
    const std::filesystem::path& audit_log_path) {
    security::memory::ensure_sodium_initialized();
#if JARVIS_HAS_SE_BRIDGE
    const std::string challenge = "jarvis-beliefstore-sqlcipher-key-v1|" + database_path.string();
    char* signature_json = nullptr;
    char* error = nullptr;
    const bool ok = jarvis_se_sign_challenge(
        key_tag.c_str(),
        reinterpret_cast<const std::uint8_t*>(challenge.data()),
        challenge.size(),
        audit_log_path.empty() ? nullptr : audit_log_path.string().c_str(),
        &signature_json,
        &error);
    if (!ok) {
        std::string msg = error ? error : "unknown Secure Enclave bridge failure";
        if (error) jarvis_se_free(error);
        throw std::runtime_error("Secure Enclave BeliefStore key derivation failed: " + msg);
    }
    std::string material = signature_json ? signature_json : "";
    if (signature_json) jarvis_se_free(signature_json);
    material += "|" + challenge + "|" + key_tag;
    std::array<unsigned char, kSqlCipherKeyBytes> digest{};
    crypto_generichash(digest.data(), digest.size(),
                       reinterpret_cast<const unsigned char*>(material.data()), material.size(),
                       nullptr, 0);
    security::memory::secure_zero(material.data(), material.size());
    security::memory::LockedBytes key(kSqlCipherKeyBytes);
    std::memcpy(key.data(), digest.data(), digest.size());
    security::memory::secure_zero(digest.data(), digest.size());
    return key;
#else
    (void)database_path;
    (void)key_tag;
    (void)audit_log_path;
    throw std::runtime_error("Secure Enclave bridge header not available; build JARVISSecureEnclave and expose include/JARVISSecureEnclaveBridge.h");
#endif
}

} // namespace jarvis
