#include "migration.h"

#include <nlohmann/json.hpp>
#include <sqlite3.h>

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <system_error>

extern "C" int sqlite3_key(sqlite3* db, const void* pKey, int nKey);

namespace jarvis::migration {
namespace {
using json = nlohmann::json;

struct Artifact {
    std::filesystem::path path;
    std::string rel;
    std::string sha256;
    std::uintmax_t size{0};
};

struct Dataset {
    std::vector<Artifact> artifacts;
    json belief_edges = json::array();
    json hmem_records = json::array();
    json sage_entities = json::array();
    json sage_edges = json::array();
    json sage_documents = json::array();
    json endocrine_state = json::object();
    json endocannabinoid_state = json::object();
    json pheromind_signals = json::array();
    json swarm_state = json::object();
    json identity_entries = json::array();
    std::string python_audit_head;
    std::string python_identity_head;
    std::map<std::string, std::uint64_t> counts;
};

std::string hex(const unsigned char* data, std::size_t len) {
    static constexpr char k[] = "0123456789abcdef";
    std::string out;
    out.reserve(len * 2);
    for (std::size_t i = 0; i < len; ++i) {
        out.push_back(k[(data[i] >> 4) & 0xf]);
        out.push_back(k[data[i] & 0xf]);
    }
    return out;
}

std::string now_stamp() {
    const auto now = std::chrono::system_clock::now();
    const auto tt = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    gmtime_r(&tt, &tm);
    std::ostringstream os;
    os << std::put_time(&tm, "%Y%m%dT%H%M%SZ");
    return os.str();
}

std::string read_text(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot read " + path.string());
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

void write_text_atomic(const std::filesystem::path& path, const std::string& body) {
    std::filesystem::create_directories(path.parent_path());
    const auto staged = path.string() + ".stage";
    {
        std::ofstream out(staged, std::ios::binary | std::ios::trunc);
        if (!out) throw std::runtime_error("cannot stage write " + staged);
        out << body;
        out.flush();
        if (!out) throw std::runtime_error("cannot flush staged write " + staged);
    }
    std::filesystem::rename(staged, path);
}

json read_json_if_exists(const std::filesystem::path& path, const json& fallback) {
    if (!std::filesystem::exists(path)) return fallback;
    try { return json::parse(read_text(path)); }
    catch (const std::exception& e) { throw std::runtime_error("invalid JSON in " + path.string() + ": " + e.what()); }
}

std::vector<unsigned char> hex_decode_key(const std::string& s) {
    if (s.size() != 64) throw std::runtime_error("SQLCipher key must be 64 hex characters / 32 bytes");
    std::vector<unsigned char> out(32);
    auto nib = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (std::size_t i = 0; i < out.size(); ++i) {
        const int a = nib(s[2*i]);
        const int b = nib(s[2*i + 1]);
        if (a < 0 || b < 0) throw std::runtime_error("SQLCipher key contains non-hex characters");
        out[i] = static_cast<unsigned char>((a << 4) | b);
    }
    return out;
}

void exec(sqlite3* db, const std::string& sql) {
    char* err = nullptr;
    const int rc = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        std::string msg = err ? err : sqlite3_errmsg(db);
        sqlite3_free(err);
        throw std::runtime_error("SQLCipher exec failed: " + msg + " SQL=" + sql);
    }
}

struct Db {
    sqlite3* db{nullptr};
    explicit Db(const std::filesystem::path& path, const std::string& key_hex) {
        std::filesystem::create_directories(path.parent_path());
        if (sqlite3_open(path.string().c_str(), &db) != SQLITE_OK) {
            std::string msg = db ? sqlite3_errmsg(db) : "null db";
            if (db) sqlite3_close(db);
            throw std::runtime_error("SQLCipher open failed: " + msg);
        }
        auto key = hex_decode_key(key_hex);
        if (sqlite3_key(db, key.data(), static_cast<int>(key.size())) != SQLITE_OK) throw std::runtime_error("SQLCipher keying failed");
        exec(db, "PRAGMA cipher_version;");
    }
    ~Db() { if (db) sqlite3_close(db); }
};

std::string sql_quote(const std::string& s) {
    std::string out = "'";
    for (char c : s) out += (c == '\'' ? "''" : std::string(1, c));
    out += "'";
    return out;
}

std::string jstr(const json& j, const char* key, const std::string& def = "") {
    if (!j.is_object() || !j.contains(key) || j.at(key).is_null()) return def;
    if (j.at(key).is_string()) return j.at(key).get<std::string>();
    return j.at(key).dump();
}

double jdbl(const json& j, const char* key, double def = 0.0) {
    if (!j.is_object() || !j.contains(key) || j.at(key).is_null()) return def;
    if (j.at(key).is_number()) return j.at(key).get<double>();
    return std::stod(j.at(key).get<std::string>());
}

int jint(const json& j, const char* key, int def = 0) {
    if (!j.is_object() || !j.contains(key) || j.at(key).is_null()) return def;
    if (j.at(key).is_number_integer()) return j.at(key).get<int>();
    return std::stoi(j.at(key).get<std::string>());
}

bool jbool(const json& j, const char* key, bool def = false) {
    if (!j.is_object() || !j.contains(key) || j.at(key).is_null()) return def;
    if (j.at(key).is_boolean()) return j.at(key).get<bool>();
    if (j.at(key).is_number_integer()) return j.at(key).get<int>() != 0;
    const auto s = j.at(key).get<std::string>();
    return s == "true" || s == "1";
}

std::string blob_hex_from_json(const json& j, const char* key) {
    if (!j.is_object() || !j.contains(key) || j.at(key).is_null()) return "";
    const auto& v = j.at(key);
    if (v.is_string()) return v.get<std::string>();
    if (v.is_array()) {
        std::vector<unsigned char> bytes;
        for (const auto& x : v) bytes.push_back(static_cast<unsigned char>(x.get<int>()));
        return hex(bytes.data(), bytes.size());
    }
    return sha256_text(v.dump());
}

void validate_fields(const json& rows, const std::set<std::string>& allowed, const std::string& organ) {
    for (const auto& row : rows) {
        if (!row.is_object()) throw std::runtime_error(organ + " row is not an object");
        for (auto it = row.begin(); it != row.end(); ++it) {
            if (!allowed.contains(it.key())) throw std::runtime_error("NO_MAPPING: " + organ + "." + it.key());
        }
    }
}

void require_attestation(const std::filesystem::path& token) {
    if (token.empty() || !std::filesystem::exists(token)) throw std::runtime_error("operator attestation token required; no --force path exists");
    if (path_contains_voice_root(token)) throw std::runtime_error("attestation token path may not enter _local_voice");
    const auto body = read_text(token);
    if (body.find("JARVIS_MIGRATION_ATTESTED") == std::string::npos) {
        throw std::runtime_error("operator attestation token invalid for JARVIS state migration");
    }
}

void ensure_voice_guard(const Options& o) {
    if (path_contains_voice_root(o.source_dir) || path_contains_voice_root(o.destination_dir) || path_contains_voice_root(o.manifest_path)) {
        throw std::runtime_error("CRITICAL_VOICE_INTEGRITY_VIOLATION: migration path enters _local_voice");
    }
    if (o.voice_baseline_hash && o.voice_current_hash && *o.voice_baseline_hash != *o.voice_current_hash) {
        throw std::runtime_error("CRITICAL_VOICE_INTEGRITY_VIOLATION: externally attested voice hash changed");
    }
}

void append_audit(const std::filesystem::path& dest, const std::string& reason, const std::string& predecessor, const json& metadata = json::object()) {
    const auto audit_dir = dest / "integrity" / "audit";
    std::filesystem::create_directories(audit_dir);
    const auto log = audit_dir / "migration.audit.jsonl";
    std::string prev = predecessor;
    if (prev.empty() && std::filesystem::exists(log)) {
        std::ifstream in(log);
        std::string line, last;
        while (std::getline(in, line)) if (!line.empty()) last = line;
        if (!last.empty()) prev = json::parse(last).value("own_hash", "");
    }
    json entry{{"version","jarvis-migration-audit-1"},{"actor","migration_runner"},{"subject","JARVIS_state_continuity"},{"outcome","ALLOWED"},{"reason",reason},{"prev_hash",prev},{"metadata",metadata},{"created_at",now_stamp()}};
    entry["own_hash"] = sha256_text(prev + entry.dump());
    std::ofstream out(log, std::ios::app);
    out << entry.dump() << "\n";
}

std::string last_json_hash_line(const std::filesystem::path& p) {
    if (!std::filesystem::exists(p)) return "";
    std::ifstream in(p);
    std::string line, last_hash;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        try {
            auto j = json::parse(line);
            for (const auto* key : {"own_hash", "hash", "chain_hash", "certificate_hash"}) {
                if (j.contains(key) && j.at(key).is_string()) last_hash = j.at(key).get<std::string>();
            }
        } catch (...) {}
    }
    return last_hash;
}

void load_sqlite_beliefs(const std::filesystem::path& p, Dataset& d) {
    sqlite3* db = nullptr;
    if (sqlite3_open_v2(p.string().c_str(), &db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) { if (db) sqlite3_close(db); return; }
    sqlite3_stmt* stmt = nullptr;
    const char* sql = "SELECT id,subject,relation,object,source_type,source_ref,confidence,quarantined,provenance_class,charge,revised_at,hex(tuple_hv) FROM belief_edges ORDER BY id";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            json r;
            r["id"] = sqlite3_column_int(stmt, 0);
            const char* cols[] = {"subject", "relation", "object", "source_type", "source_ref"};
            for (int i = 1; i <= 5; ++i) r[cols[i - 1]] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, i));
            r["confidence"] = sqlite3_column_double(stmt, 6);
            r["quarantined"] = sqlite3_column_int(stmt, 7) != 0;
            r["provenance_class"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 8));
            r["charge"] = sqlite3_column_double(stmt, 9);
            r["revised_at"] = sqlite3_column_double(stmt, 10);
            r["tuple_hv"] = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 11));
            d.belief_edges.push_back(r);
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
}

Dataset survey(const std::filesystem::path& source) {
    if (!std::filesystem::exists(source)) throw std::runtime_error("source directory does not exist: " + source.string());
    Dataset d;
    const std::set<std::string> suffixes{".json", ".db", ".sqlite", ".sqlite3", ".pkl", ".bin"};
    for (auto it = std::filesystem::recursive_directory_iterator(source); it != std::filesystem::recursive_directory_iterator(); ++it) {
        const auto p = it->path();
        if (path_contains_voice_root(p)) { it.disable_recursion_pending(); continue; }
        if (!it->is_regular_file()) continue;
        if (!suffixes.contains(p.extension().string())) continue;
        Artifact a{p, std::filesystem::relative(p, source).string(), sha256_file(p), it->file_size()};
        d.artifacts.push_back(a);
        if (p.extension() == ".db" || p.extension() == ".sqlite" || p.extension() == ".sqlite3") load_sqlite_beliefs(p, d);
    }

    auto as_array = [](json j) { return j.is_array() ? j : json::array({j}); };
    const auto load_named_array = [&](const std::vector<std::string>& names) {
        for (const auto& name : names) {
            const auto p = source / name;
            if (std::filesystem::exists(p)) return as_array(read_json_if_exists(p, json::array()));
        }
        return json::array();
    };
    auto merge = [](json& dst, const json& src) { for (const auto& row : src) dst.push_back(row); };
    merge(d.belief_edges, load_named_array({"belief_edges.json", "holograph/belief_edges.json", "beliefstore.json"}));
    merge(d.hmem_records, load_named_array({"hmem_records.json", "hmem/memories.json", "holograph/hmem_records.json"}));
    merge(d.sage_entities, load_named_array({"sage_entities.json", "sage/entities.json", "holograph/sage_entities.json"}));
    merge(d.sage_edges, load_named_array({"sage_edges.json", "sage/edges.json", "holograph/sage_edges.json"}));
    merge(d.sage_documents, load_named_array({"sage_documents.json", "sage/documents.json", "holograph/sage_documents.json"}));
    merge(d.pheromind_signals, load_named_array({"pheromind_state.json", "stigmergy_state.json", "swarm/pheromind_state.json"}));
    d.endocrine_state = read_json_if_exists(source / "endocrine_state.json", json::object());
    d.endocannabinoid_state = read_json_if_exists(source / "endocannabinoid_state.json", json::object());
    d.swarm_state = read_json_if_exists(source / "swarm_state.json", json::object());
    d.identity_entries = load_named_array({"identity_continuity.json", "identity/continuity_ledger.json", "continuity_ledger.json"});
    d.python_audit_head = last_json_hash_line(source / "audit.log");
    if (d.python_audit_head.empty()) d.python_audit_head = last_json_hash_line(source / "integrity/audit/audit.log");
    if (!d.identity_entries.empty()) {
        const auto& last = d.identity_entries.back();
        d.python_identity_head = last.value("certificate_hash", last.value("own_hash", last.value("hash", sha256_text(last.dump()))));
    }

    validate_fields(d.belief_edges, {"id","subject","relation","object","source_type","source_ref","confidence","quarantined","quarantine","provenance_class","charge","revised_at","tuple_hv"}, "BeliefStore");
    validate_fields(d.hmem_records, {"id","text","anchor","tier","salience","hv"}, "HMEM");
    validate_fields(d.sage_entities, {"id","canonical","type","layer","hv"}, "SAGE.entity");
    validate_fields(d.sage_edges, {"id","head_id","tail_id","relation","weight","source","quarantined"}, "SAGE.edge");
    validate_fields(d.sage_documents, {"anchor","text","id"}, "SAGE.document");
    validate_fields(d.pheromind_signals, {"kind","topic","strength","last_t","depositors","vec"}, "Pheromind");

    d.counts["source_artifacts"] = d.artifacts.size();
    d.counts["belief_edges"] = d.belief_edges.size();
    d.counts["hmem_records"] = d.hmem_records.size();
    d.counts["sage_entities"] = d.sage_entities.size();
    d.counts["sage_edges"] = d.sage_edges.size();
    d.counts["sage_documents"] = d.sage_documents.size();
    d.counts["pheromind_signals"] = d.pheromind_signals.size();
    d.counts["identity_continuity_entries"] = d.identity_entries.size();
    d.counts["endocrine_state"] = d.endocrine_state.empty() ? 0 : 1;
    d.counts["endocannabinoid_state"] = d.endocannabinoid_state.empty() ? 0 : 1;
    d.counts["swarm_state"] = d.swarm_state.empty() ? 0 : 1;
    return d;
}

std::filesystem::path backup_dest(const std::filesystem::path& dest) {
    const auto backup = dest.parent_path() / (dest.filename().string() + ".migration_backup_" + now_stamp());
    if (std::filesystem::exists(dest)) std::filesystem::copy(dest, backup, std::filesystem::copy_options::recursive | std::filesystem::copy_options::copy_symlinks);
    else std::filesystem::create_directories(backup);
    return backup;
}

void restore_backup(const std::filesystem::path& dest, const std::filesystem::path& backup) {
    std::error_code ec;
    std::filesystem::remove_all(dest, ec);
    if (std::filesystem::exists(backup)) std::filesystem::copy(backup, dest, std::filesystem::copy_options::recursive | std::filesystem::copy_options::copy_symlinks | std::filesystem::copy_options::overwrite_existing);
}

void write_db(const Options& o, const Dataset& d) {
    const auto db_path = o.destination_dir / "holograph" / "beliefstore" / "beliefstore_migrated.sqlcipher";
    Db db(db_path, o.sqlcipher_key_hex);
    exec(db.db, "BEGIN IMMEDIATE;");
    try {
        exec(db.db, "CREATE TABLE IF NOT EXISTS migration_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS source_artifacts(rel_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL, size INTEGER NOT NULL);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS belief_edges(id INTEGER PRIMARY KEY, subject TEXT, relation TEXT, object TEXT, source_type TEXT, source_ref TEXT, confidence REAL, quarantined INTEGER, provenance_class TEXT, charge REAL, revised_at REAL, tuple_hv_hex TEXT);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS hmem_records(id INTEGER PRIMARY KEY, text TEXT, anchor TEXT, tier TEXT, salience REAL, hv_hex TEXT);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS sage_entities(id INTEGER PRIMARY KEY, canonical TEXT, type TEXT, layer INTEGER, hv_hex TEXT);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS sage_edges(id INTEGER PRIMARY KEY, head_id INTEGER, tail_id INTEGER, relation TEXT, weight REAL, source TEXT, quarantined INTEGER);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS sage_documents(id INTEGER PRIMARY KEY AUTOINCREMENT, anchor TEXT, text TEXT);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS pheromind_signals(kind TEXT, topic TEXT, strength REAL, last_t REAL, depositors_json TEXT, vec_hex TEXT, PRIMARY KEY(kind, topic));");
        exec(db.db, "CREATE TABLE IF NOT EXISTS organ_state(organ TEXT PRIMARY KEY, json TEXT NOT NULL);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS identity_continuity(seq INTEGER PRIMARY KEY AUTOINCREMENT, entry_json TEXT NOT NULL, predecessor_hash TEXT, own_hash TEXT);");
        exec(db.db, "CREATE TABLE IF NOT EXISTS audit_bridge(id INTEGER PRIMARY KEY CHECK(id=1), python_audit_head TEXT, first_cpp_predecessor_hash TEXT, first_cpp_own_hash TEXT);");
        exec(db.db, "DELETE FROM source_artifacts; DELETE FROM belief_edges; DELETE FROM hmem_records; DELETE FROM sage_entities; DELETE FROM sage_edges; DELETE FROM sage_documents; DELETE FROM pheromind_signals; DELETE FROM organ_state; DELETE FROM identity_continuity; DELETE FROM audit_bridge;");
        for (const auto& a : d.artifacts) exec(db.db, "INSERT INTO source_artifacts VALUES(" + sql_quote(a.rel) + "," + sql_quote(a.sha256) + "," + std::to_string(a.size) + ");");
        for (const auto& r : d.belief_edges) exec(db.db, "INSERT INTO belief_edges VALUES(" + std::to_string(jint(r,"id")) + "," + sql_quote(jstr(r,"subject")) + "," + sql_quote(jstr(r,"relation")) + "," + sql_quote(jstr(r,"object")) + "," + sql_quote(jstr(r,"source_type","Inference")) + "," + sql_quote(jstr(r,"source_ref")) + "," + std::to_string(jdbl(r,"confidence")) + "," + std::to_string(jbool(r,"quarantined", jbool(r,"quarantine")) ? 1 : 0) + "," + sql_quote(jstr(r,"provenance_class","real")) + "," + std::to_string(jdbl(r,"charge")) + "," + std::to_string(jdbl(r,"revised_at")) + "," + sql_quote(blob_hex_from_json(r,"tuple_hv")) + ");");
        for (const auto& r : d.hmem_records) exec(db.db, "INSERT INTO hmem_records VALUES(" + std::to_string(jint(r,"id")) + "," + sql_quote(jstr(r,"text")) + "," + sql_quote(jstr(r,"anchor")) + "," + sql_quote(jstr(r,"tier","ShortTerm")) + "," + std::to_string(jdbl(r,"salience",0.5)) + "," + sql_quote(blob_hex_from_json(r,"hv")) + ");");
        for (const auto& r : d.sage_entities) exec(db.db, "INSERT INTO sage_entities VALUES(" + std::to_string(jint(r,"id")) + "," + sql_quote(jstr(r,"canonical")) + "," + sql_quote(jstr(r,"type","concept")) + "," + std::to_string(jint(r,"layer")) + "," + sql_quote(blob_hex_from_json(r,"hv")) + ");");
        for (const auto& r : d.sage_edges) exec(db.db, "INSERT INTO sage_edges VALUES(" + std::to_string(jint(r,"id")) + "," + std::to_string(jint(r,"head_id")) + "," + std::to_string(jint(r,"tail_id")) + "," + sql_quote(jstr(r,"relation")) + "," + std::to_string(jdbl(r,"weight",1.0)) + "," + sql_quote(jstr(r,"source")) + "," + std::to_string(jbool(r,"quarantined") ? 1 : 0) + ");");
        for (const auto& r : d.sage_documents) exec(db.db, "INSERT INTO sage_documents(anchor,text) VALUES(" + sql_quote(jstr(r,"anchor")) + "," + sql_quote(jstr(r,"text")) + ");");
        for (const auto& r : d.pheromind_signals) exec(db.db, "INSERT INTO pheromind_signals VALUES(" + sql_quote(jstr(r,"kind")) + "," + sql_quote(jstr(r,"topic")) + "," + std::to_string(jdbl(r,"strength")) + "," + std::to_string(jdbl(r,"last_t")) + "," + sql_quote(r.contains("depositors") ? r.at("depositors").dump() : "[]") + "," + sql_quote(blob_hex_from_json(r,"vec")) + ");");
        if (!d.endocrine_state.empty()) exec(db.db, "INSERT INTO organ_state VALUES('endocrine'," + sql_quote(d.endocrine_state.dump()) + ");");
        if (!d.endocannabinoid_state.empty()) exec(db.db, "INSERT INTO organ_state VALUES('endocannabinoid'," + sql_quote(d.endocannabinoid_state.dump()) + ");");
        if (!d.swarm_state.empty()) exec(db.db, "INSERT INTO organ_state VALUES('swarm'," + sql_quote(d.swarm_state.dump()) + ");");
        std::string pred = d.python_identity_head;
        for (const auto& r : d.identity_entries) {
            const auto own = r.value("certificate_hash", r.value("own_hash", r.value("hash", sha256_text(pred + r.dump()))));
            exec(db.db, "INSERT INTO identity_continuity(entry_json,predecessor_hash,own_hash) VALUES(" + sql_quote(r.dump()) + "," + sql_quote(pred) + "," + sql_quote(own) + ");");
            pred = own;
        }
        const std::string bridge_own = sha256_text(d.python_audit_head + "JARVIS_CPP_MIGRATION_BRIDGE");
        exec(db.db, "INSERT INTO audit_bridge VALUES(1," + sql_quote(d.python_audit_head) + "," + sql_quote(d.python_audit_head) + "," + sql_quote(bridge_own) + ");");
        exec(db.db, "INSERT OR REPLACE INTO migration_meta VALUES('schema_version','jarvis-migration-schema-1');");
        exec(db.db, "INSERT OR REPLACE INTO migration_meta VALUES('completed','true');");
        exec(db.db, "COMMIT;");
    } catch (...) {
        sqlite3_exec(db.db, "ROLLBACK;", nullptr, nullptr, nullptr);
        throw;
    }
}

json manifest_json(const Options& o, const Dataset& d, const std::filesystem::path& backup) {
    json sources = json::array();
    for (const auto& a : d.artifacts) sources.push_back({{"path", a.path.string()}, {"relative_path", a.rel}, {"sha256", a.sha256}, {"size", a.size}});
    json counts = json::object();
    for (const auto& [k,v] : d.counts) counts[k] = v;
    return json{{"version","jarvis-migration-manifest-1"},{"created_at",now_stamp()},{"source_dir",o.source_dir.string()},{"destination_dir",o.destination_dir.string()},{"backup_dir",backup.string()},{"destination_paths",json::array({(o.destination_dir / "holograph/beliefstore/beliefstore_migrated.sqlcipher").string(), (o.destination_dir / "integrity/audit/migration.audit.jsonl").string()})},{"source_paths",sources},{"row_counts",counts},{"schema_version_mapping",{{"python_prototype","surveyed-artifacts"},{"cpp_sqlcipher","jarvis-migration-schema-1"}}},{"audit_chain_hash_continuation",{{"last_python_audit_hash",d.python_audit_head},{"first_cpp_predecessor_hash",d.python_audit_head},{"bridge_hash",sha256_text(d.python_audit_head + "JARVIS_CPP_MIGRATION_BRIDGE")}}},{"identity_continuity",{{"last_python_identity_hash",d.python_identity_head},{"first_cpp_predecessor_hash",d.python_identity_head}}}};
}

bool verify_db_counts(const Options& o, const Dataset& d) {
    Db db(o.destination_dir / "holograph" / "beliefstore" / "beliefstore_migrated.sqlcipher", o.sqlcipher_key_hex);
    for (const auto& [table, expected] : std::map<std::string,std::uint64_t>{{"belief_edges",d.belief_edges.size()},{"hmem_records",d.hmem_records.size()},{"sage_entities",d.sage_entities.size()},{"sage_edges",d.sage_edges.size()},{"sage_documents",d.sage_documents.size()},{"pheromind_signals",d.pheromind_signals.size()},{"identity_continuity",d.identity_entries.size()}}) {
        sqlite3_stmt* stmt = nullptr;
        const auto sql = "SELECT COUNT(*) FROM " + table;
        if (sqlite3_prepare_v2(db.db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) return false;
        const int rc = sqlite3_step(stmt);
        const auto got = rc == SQLITE_ROW ? static_cast<std::uint64_t>(sqlite3_column_int64(stmt, 0)) : UINT64_MAX;
        sqlite3_finalize(stmt);
        if (got != expected) return false;
    }
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db.db, "SELECT first_cpp_predecessor_hash FROM audit_bridge WHERE id=1", -1, &stmt, nullptr) != SQLITE_OK) return false;
    const int rc = sqlite3_step(stmt);
    const std::string pred = rc == SQLITE_ROW && sqlite3_column_text(stmt,0) ? reinterpret_cast<const char*>(sqlite3_column_text(stmt,0)) : "";
    sqlite3_finalize(stmt);
    return pred == d.python_audit_head;
}

} // namespace

std::string sha256_text(const std::string& text) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(text.data(), static_cast<CC_LONG>(text.size()), digest);
    return hex(digest, sizeof(digest));
}

std::string sha256_file(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot hash " + path.string());
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    std::array<char, 16384> buf{};
    while (in) {
        in.read(buf.data(), static_cast<std::streamsize>(buf.size()));
        if (in.gcount() > 0) CC_SHA256_Update(&ctx, buf.data(), static_cast<CC_LONG>(in.gcount()));
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    return hex(digest, sizeof(digest));
}

bool path_contains_voice_root(const std::filesystem::path& path) {
    for (const auto& part : path) if (part == "_local_voice") return true;
    return false;
}

Result run(const Options& o) {
    try {
        ensure_voice_guard(o);
        require_attestation(o.attestation_token_path);
        const Dataset d = survey(o.source_dir);
        Result r{true, "OK", "JARVIS state mapping is complete and reversible", o.manifest_path, d.counts};
        if (o.mode == Mode::DryRun) return r;
        if (o.sqlcipher_key_hex.empty()) throw std::runtime_error("--sqlcipher-key-hex required for migrate/verify");
        if (o.mode == Mode::Verify) {
            r.ok = verify_db_counts(o, d);
            r.code = r.ok ? "VERIFY_OK" : "VERIFY_MISMATCH";
            r.message = r.ok ? "post-migration state matches surveyed Python source" : "post-migration state does not match surveyed Python source";
            return r;
        }
        std::filesystem::create_directories(o.destination_dir);
        if (std::filesystem::exists(o.destination_dir / ".jarvis_migration_complete")) {
            r.code = "ALREADY_MIGRATED";
            r.message = "migration already completed; idempotent no-op";
            return r;
        }
        const auto backup = backup_dest(o.destination_dir);
        if (o.inject_failure_after_backup_for_test) throw std::runtime_error("injected partial failure after backup");
        try {
            append_audit(o.destination_dir, "migration_started", d.python_audit_head, {{"source_dir", o.source_dir.string()}});
            write_db(o, d);
            append_audit(o.destination_dir, "migration_committed", "", {{"row_counts", d.counts}});
            auto mp = o.manifest_path.empty() ? (o.destination_dir / ("MIGRATION_" + now_stamp() + ".manifest")) : o.manifest_path;
            const auto mf = manifest_json(o, d, backup);
            write_text_atomic(mp, mf.dump(2));
            write_text_atomic(o.destination_dir / ".jarvis_migration_complete", mf.dump());
            r.manifest_path = mp;
            r.code = "MIGRATE_OK";
            r.message = "JARVIS state migrated atomically into SQLCipher persistence";
            return r;
        } catch (...) {
            restore_backup(o.destination_dir, backup);
            throw;
        }
    } catch (const std::exception& e) {
        return {false, "ERROR", e.what(), o.manifest_path, {}};
    }
}

Result rollback(const std::filesystem::path& manifest_path, const std::filesystem::path& attestation_token_path) {
    try {
        require_attestation(attestation_token_path);
        const auto mf = json::parse(read_text(manifest_path));
        const auto dest = std::filesystem::path(mf.at("destination_dir").get<std::string>());
        const auto backup = std::filesystem::path(mf.at("backup_dir").get<std::string>());
        if (path_contains_voice_root(dest) || path_contains_voice_root(backup)) throw std::runtime_error("CRITICAL_VOICE_INTEGRITY_VIOLATION: rollback path enters _local_voice");
        append_audit(dest, "rollback_started", "", {{"manifest", manifest_path.string()}});
        restore_backup(dest, backup);
        append_audit(dest, "rollback_completed", "", {{"manifest", manifest_path.string()}});
        return {true, "ROLLBACK_OK", "destination tree restored from migration backup", manifest_path, {}};
    } catch (const std::exception& e) {
        return {false, "ERROR", e.what(), manifest_path, {}};
    }
}

Options parse_args(int argc, char** argv, bool rollback_binary) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto need = [&](const char* name) -> std::string { if (i + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name); return argv[++i]; };
        if (a == "--dry-run") o.mode = Mode::DryRun;
        else if (a == "--migrate") o.mode = Mode::Migrate;
        else if (a == "--verify") o.mode = Mode::Verify;
        else if (a == "--source") o.source_dir = need("--source");
        else if (a == "--destination") o.destination_dir = need("--destination");
        else if (a == "--manifest") o.manifest_path = need("--manifest");
        else if (a == "--attestation-token") o.attestation_token_path = need("--attestation-token");
        else if (a == "--sqlcipher-key-hex") o.sqlcipher_key_hex = need("--sqlcipher-key-hex");
        else if (a == "--voice-baseline-hash") o.voice_baseline_hash = need("--voice-baseline-hash");
        else if (a == "--voice-current-hash") o.voice_current_hash = need("--voice-current-hash");
        else throw std::runtime_error("unknown argument: " + a);
    }
    if (rollback_binary) {
        if (o.manifest_path.empty()) throw std::runtime_error("rollback requires --manifest");
        return o;
    }
    if (o.source_dir.empty()) throw std::runtime_error("--source is required");
    if (o.destination_dir.empty()) throw std::runtime_error("--destination is required");
    return o;
}

} // namespace jarvis::migration
