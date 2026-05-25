#include "JARVISCharacterValuesBridge.h"
#include "character_values.h"
#include "audit_log.h"
#include "audit_event.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>

namespace {
char *dup_string(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

std::string escape_json(const std::string &s) {
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
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}
}

void jarvis_cv_free(char *ptr) { std::free(ptr); }

bool jarvis_cv_canonical_json(char **json_out, char **error_out) {
    if (json_out) *json_out = nullptr;
    if (error_out) *error_out = nullptr;
    try {
        const auto values = jarvis::identity::CharacterValues::canonical();
        const auto &hv = values.values_hypervector();
        std::string json = "{";
        json += "\"boot_identity\":\"" + escape_json(values.boot_identity()) + "\",";
        json += "\"values_hash\":\"" + escape_json(values.values_hash()) + "\",";
        json += "\"origin_hash\":\"" + escape_json(values.origin_hash()) + "\",";
        json += "\"identity_hash\":\"" + escape_json(values.identity_hash()) + "\",";
        json += "\"hv_anchor\":\"" + escape_json(hv.sha256_hex) + "\",";
        json += "\"hv_kernel\":\"" + escape_json(hv.kernel_name) + "\",";
        json += "\"hv_dimension\":" + std::to_string(hv.dimension);
        json += "}";
        if (json_out) *json_out = dup_string(json);
        return json_out && *json_out;
    } catch (const std::exception &e) {
        if (error_out) *error_out = dup_string(e.what());
        return false;
    } catch (...) {
        if (error_out) *error_out = dup_string("unknown CharacterValues failure");
        return false;
    }
}


bool jarvis_cv_install_audit_bridge_key(const unsigned char *key, unsigned long key_len, char **error_out) {
    if (error_out) *error_out = nullptr;
    try {
        jarvis::audit::installBridgeAuditKey(key, static_cast<size_t>(key_len));
        return true;
    } catch (const std::exception &e) {
        if (error_out) *error_out = dup_string(e.what());
        return false;
    } catch (...) {
        if (error_out) *error_out = dup_string("unknown audit bridge key install failure");
        return false;
    }
}

bool jarvis_cv_audit_append(const char *log_path, const unsigned char *key, unsigned long key_len, const char *step, const char *outcome, const char *metadata_json, char **error_out) {
    if (error_out) *error_out = nullptr;
    try {
        jarvis::audit::installBridgeAuditKey(key, static_cast<size_t>(key_len));
        jarvis::audit::TamperEvidentAuditLog log(log_path ? log_path : "~/.jarvis/audit/soul_anchor_ceremony.log");
        jarvis::audit::AuditEvent event;
        event.event_kind = jarvis::audit::EventKind::AUTHORITY_GATE;
        event.actor = jarvis::audit::Actor::OPERATOR;
        event.subject = "JARVIS_SOUL_ANCHOR_CEREMONY";
        const std::string outcome_value = outcome ? outcome : "";
        event.outcome = (outcome_value == "pass") ? jarvis::audit::Outcome::PASS :
                        (outcome_value == "fail") ? jarvis::audit::Outcome::FAIL :
                        jarvis::audit::Outcome::DEFERRED;
        event.reason = step ? step : "ceremony_step";
        event.redacted_metadata = metadata_json ? metadata_json : "{}";
        log.append(event);
        return true;
    } catch (const std::exception &e) {
        if (error_out) *error_out = dup_string(e.what());
        return false;
    } catch (...) {
        if (error_out) *error_out = dup_string("unknown audit append failure");
        return false;
    }
}
