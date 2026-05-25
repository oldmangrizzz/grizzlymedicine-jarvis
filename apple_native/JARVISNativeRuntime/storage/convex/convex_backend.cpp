#include "convex_backend.h"

#include "../../integrity/audit/audit_event.h"
#include "../../integrity/audit/audit_log.h"
#include "../../logging/redacting_logger.h"
#include "../../security/cert_pinning.h"
#include "../../security/memory_security.h"
#include "../../security/egress/egress_allowlist.h"
#include "../../security/pins_embedded.h"

#include <curl/curl.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <regex>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace jarvis::storage::convex {
namespace {

std::string home_dir() {
    const char* h = std::getenv("HOME");
    if (!h || !*h) throw std::runtime_error("HOME is not set; cannot load ~/.jarvis/runtime_secret.key");
    return std::string(h);
}

std::string default_jarvis_home() { return home_dir() + "/.jarvis"; }

void ensure_private_dir(const std::filesystem::path& p) {
    std::filesystem::create_directories(p);
    chmod(p.c_str(), 0700);
}

std::string hex_of(const unsigned char* bytes, std::size_t n) {
    static constexpr char lut[] = "0123456789abcdef";
    std::string out(n * 2, '0');
    for (std::size_t i = 0; i < n; ++i) {
        out[2 * i] = lut[(bytes[i] >> 4) & 0x0f];
        out[2 * i + 1] = lut[bytes[i] & 0x0f];
    }
    return out;
}


std::string host_from_url(const std::string& url) {
    static const std::regex re(R"(^https://([^/:]+)(?::443)?(?:/.*)?$)");
    std::smatch m;
    if (!std::regex_match(url, m, re)) {
        throw std::runtime_error("Convex URL must be https://host[/path] on port 443");
    }
    return m[1].str();
}

size_t curl_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* out = static_cast<std::string*>(userdata);
    out->append(ptr, size * nmemb);
    return size * nmemb;
}

bool sensitive_key(std::string_view k) {
    return k == "topic" || k == "kind";
}

void scan_topic_kind(const nlohmann::json& j) {
    if (j.is_object()) {
        for (auto it = j.begin(); it != j.end(); ++it) {
            if (sensitive_key(it.key())) {
                if (!it.value().is_string() || !is_hmac_hex(it.value().get<std::string>())) {
                    throw std::runtime_error("Convex privacy gate blocked cleartext topic/kind egress");
                }
            }
            scan_topic_kind(it.value());
        }
    } else if (j.is_array()) {
        for (const auto& v : j) scan_topic_kind(v);
    }
}

std::string subject_hash(const nlohmann::json& args) {
    unsigned char digest[SHA256_DIGEST_LENGTH];
    const auto dumped = args.dump();
    SHA256(reinterpret_cast<const unsigned char*>(dumped.data()), dumped.size(), digest);
    return hex_of(digest, SHA256_DIGEST_LENGTH);
}

std::string b64_encode(const unsigned char* bytes, std::size_t len) {
    std::string out(4 * ((len + 2) / 3), '\0');
    const int written = EVP_EncodeBlock(reinterpret_cast<unsigned char*>(out.data()), bytes, static_cast<int>(len));
    if (written < 0) throw std::runtime_error("base64 encode failed");
    out.resize(static_cast<std::size_t>(written));
    return out;
}

std::vector<unsigned char> b64_decode(const std::string& encoded) {
    if (encoded.empty() || encoded.size() % 4 != 0) throw std::runtime_error("invalid base64 envelope field");
    std::vector<unsigned char> out((encoded.size() / 4) * 3);
    const int written = EVP_DecodeBlock(out.data(), reinterpret_cast<const unsigned char*>(encoded.data()), static_cast<int>(encoded.size()));
    if (written < 0) throw std::runtime_error("base64 decode failed");
    std::size_t n = static_cast<std::size_t>(written);
    if (!encoded.empty() && encoded[encoded.size() - 1] == '=') --n;
    if (encoded.size() > 1 && encoded[encoded.size() - 2] == '=') --n;
    out.resize(n);
    return out;
}

std::string version_key(const std::string& kind_hash, const std::string& topic_hash) {
    return kind_hash + ":" + topic_hash;
}

nlohmann::json load_state_file(const std::filesystem::path& path) {
    nlohmann::json state = {{"versions", nlohmann::json::object()}, {"expected", nlohmann::json::object()}};
    if (!std::filesystem::exists(path)) return state;
    std::ifstream in(path);
    try { in >> state; } catch (...) { state = nlohmann::json::object(); }
    if (!state.is_object()) state = nlohmann::json::object();
    if (!state.contains("versions") || !state["versions"].is_object()) state["versions"] = nlohmann::json::object();
    if (!state.contains("expected") || !state["expected"].is_object()) state["expected"] = nlohmann::json::object();
    return state;
}

void save_state_file(const std::filesystem::path& path, const nlohmann::json& state) {
    ensure_private_dir(path.parent_path());
    std::ofstream out(path, std::ios::trunc);
    out << state.dump(2);
    out.close();
    chmod(path.c_str(), 0600);
}

std::string signature_payload(const nlohmann::json& doc) {
    return doc.at("kind").get<std::string>() + "\n" +
           doc.at("topic").get<std::string>() + "\n" +
           std::to_string(doc.at("version").get<uint64_t>()) + "\n" +
           doc.at("values").dump();
}

} // namespace

bool is_hmac_hex(std::string_view value) noexcept {
    if (value.size() != 64) return false;
    return std::all_of(value.begin(), value.end(), [](unsigned char c) { return std::isxdigit(c) != 0; });
}

void assert_no_cleartext_topic_kind(const nlohmann::json& payload) { scan_topic_kind(payload); }

RuntimeSecretStore::RuntimeSecretStore() : RuntimeSecretStore(default_jarvis_home()) {}

RuntimeSecretStore::RuntimeSecretStore(std::string jarvis_home)
    : jarvis_home_(std::move(jarvis_home)) {}

RuntimeSecretStore::~RuntimeSecretStore() {
    if (!secret_.empty()) {
        jarvis::security::memory::secure_zero(secret_.data(), secret_.size());
        jarvis::security::memory::unlock_no_swap(secret_.data(), secret_.size());
    }
}

const std::vector<unsigned char>& RuntimeSecretStore::secret() {
    if (!secret_.empty()) return secret_;
    const auto dir = std::filesystem::path(jarvis_home_);
    ensure_private_dir(dir);
    const auto path = dir / "runtime_secret.key";
    if (std::filesystem::exists(path)) {
        std::ifstream in(path, std::ios::binary);
        secret_.assign(std::istreambuf_iterator<char>(in), {});
        if (secret_.size() == 32) {
            jarvis::security::memory::lock_no_swap(secret_.data(), secret_.size());
            return secret_;
        }
        throw std::runtime_error("~/.jarvis/runtime_secret.key exists but is not 32 raw bytes");
    }
    throw RuntimeSecretMissingError(
        "runtime_secret.key absent and no ceremony attestation is present; "
        "refusing silent rekey — run the JARVIS birth ceremony first");
}

// Ceremony-only issuance. Never called by the runtime itself.
void RuntimeSecretStore::issue_from_ceremony(const std::string& jarvis_home,
                                              const std::vector<unsigned char>& secret_bytes) {
    if (secret_bytes.size() != 32)
        throw std::invalid_argument("issue_from_ceremony: secret_bytes must be exactly 32 bytes");
    const auto dir = std::filesystem::path(jarvis_home);
    ensure_private_dir(dir);
    const auto path = dir / "runtime_secret.key";
    if (std::filesystem::exists(path))
        throw std::runtime_error(
            "issue_from_ceremony: runtime_secret.key already exists; "
            "delete it explicitly before rotating");
    // O_EXCL refuses overwrite even if a race writes the file between the
    // filesystem::exists check above and here.
    const int fd = ::open(path.c_str(),
                          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          0600);
    if (fd < 0)
        throw std::system_error(errno, std::generic_category(),
                                "issue_from_ceremony: open O_EXCL failed for runtime_secret.key");
    std::size_t written = 0;
    while (written < secret_bytes.size()) {
        const ssize_t n = ::write(fd,
                                  secret_bytes.data() + written,
                                  secret_bytes.size() - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            const int e = errno;
            ::close(fd);
            throw std::system_error(e, std::generic_category(),
                                    "issue_from_ceremony: write failed for runtime_secret.key");
        }
        written += static_cast<std::size_t>(n);
    }
    if (::fsync(fd) != 0) {
        const int e = errno;
        ::close(fd);
        throw std::system_error(e, std::generic_category(),
                                "issue_from_ceremony: fsync failed for runtime_secret.key");
    }
    ::close(fd);
    ::chmod(path.c_str(), 0600); // belt-and-suspenders after O_CREAT
}(const std::string& label, std::array<unsigned char, 32>& out) {
    const auto& key = secret();
    unsigned int out_len = 0;
    if (!HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
              reinterpret_cast<const unsigned char*>(label.data()), label.size(), out.data(), &out_len) || out_len != 32) {
        throw std::runtime_error("HMAC-SHA256 failed for Convex key derivation");
    }
}

std::string RuntimeSecretStore::hmac_hex(const std::string& prefix, const std::string& value) {
    const auto& key = secret();
    const std::string msg = prefix + value;
    unsigned int out_len = 0;
    unsigned char out[EVP_MAX_MD_SIZE];
    if (!HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
              reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), out, &out_len) || out_len != 32) {
        throw std::runtime_error("HMAC-SHA256 failed for Convex topic/kind hash");
    }
    auto hex = hex_of(out, out_len);
    jarvis::security::memory::secure_zero(out, sizeof(out));
    return hex;
}

std::vector<unsigned char> RuntimeSecretStore::derived_key(const std::string& label) {
    std::array<unsigned char, 32> out{};
    derived_key_into(label, out);
    std::vector<unsigned char> derived(out.begin(), out.end());
    jarvis::security::memory::secure_zero(out.data(), out.size());
    return derived;
}

nlohmann::json RuntimeSecretStore::encrypt_values(const std::string& kind_hash,
                                                  const std::string& topic_hash,
                                                  uint64_t version,
                                                  const nlohmann::json& values) {
    std::array<unsigned char, 12> nonce{};
    if (RAND_bytes(nonce.data(), static_cast<int>(nonce.size())) != 1) throw std::runtime_error("RAND_bytes failed for Convex payload nonce");
    std::array<unsigned char, 32> key{};
    derived_key_into("jarvis.convex.values.aes256gcm.v1", key);
    std::string plaintext = values.dump();
    const std::string aad = version_key(kind_hash, topic_hash) + ":" + std::to_string(version);
    std::vector<unsigned char> ciphertext(plaintext.size());
    std::array<unsigned char, 16> tag{};
    EVP_CIPHER_CTX* raw = EVP_CIPHER_CTX_new();
    if (!raw) throw std::runtime_error("EVP_CIPHER_CTX_new failed");
    std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> ctx(raw, EVP_CIPHER_CTX_free);
    int len = 0;
    int written = 0;
    if (EVP_EncryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) != 1 ||
        EVP_EncryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), nonce.data()) != 1 ||
        EVP_EncryptUpdate(ctx.get(), nullptr, &len, reinterpret_cast<const unsigned char*>(aad.data()), static_cast<int>(aad.size())) != 1 ||
        EVP_EncryptUpdate(ctx.get(), ciphertext.data(), &len, reinterpret_cast<const unsigned char*>(plaintext.data()), static_cast<int>(plaintext.size())) != 1) {
        throw std::runtime_error("Convex payload encryption failed");
    }
    written = len;
    if (EVP_EncryptFinal_ex(ctx.get(), ciphertext.data() + written, &len) != 1) throw std::runtime_error("Convex payload encryption final failed");
    written += len;
    ciphertext.resize(static_cast<std::size_t>(written));
    if (EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_GET_TAG, static_cast<int>(tag.size()), tag.data()) != 1) {
        throw std::runtime_error("Convex payload tag extraction failed");
    }
    auto envelope = nlohmann::json{{"alg", "AES-256-GCM"},
                                   {"nonce", b64_encode(nonce.data(), nonce.size())},
                                   {"ciphertext", b64_encode(ciphertext.data(), ciphertext.size())},
                                   {"tag", b64_encode(tag.data(), tag.size())}};
    jarvis::security::memory::secure_zero(key.data(), key.size());
    jarvis::security::memory::secure_zero(plaintext.data(), plaintext.size());
    return envelope;
}

nlohmann::json RuntimeSecretStore::decrypt_values(const std::string& kind_hash,
                                                  const std::string& topic_hash,
                                                  uint64_t version,
                                                  const nlohmann::json& envelope) {
    if (!envelope.is_object() || envelope.value("alg", "") != "AES-256-GCM") throw std::runtime_error("Convex encrypted values envelope is invalid");
    auto nonce = b64_decode(envelope.at("nonce").get<std::string>());
    auto ciphertext = b64_decode(envelope.at("ciphertext").get<std::string>());
    auto tag = b64_decode(envelope.at("tag").get<std::string>());
    if (nonce.size() != 12 || tag.size() != 16) throw std::runtime_error("Convex encrypted values envelope sizes are invalid");
    std::array<unsigned char, 32> key{};
    derived_key_into("jarvis.convex.values.aes256gcm.v1", key);
    const std::string aad = version_key(kind_hash, topic_hash) + ":" + std::to_string(version);
    std::vector<unsigned char> plaintext(ciphertext.size() + 16);
    EVP_CIPHER_CTX* raw = EVP_CIPHER_CTX_new();
    if (!raw) throw std::runtime_error("EVP_CIPHER_CTX_new failed");
    std::unique_ptr<EVP_CIPHER_CTX, decltype(&EVP_CIPHER_CTX_free)> ctx(raw, EVP_CIPHER_CTX_free);
    int len = 0;
    int written = 0;
    if (EVP_DecryptInit_ex(ctx.get(), EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1 ||
        EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(nonce.size()), nullptr) != 1 ||
        EVP_DecryptInit_ex(ctx.get(), nullptr, nullptr, key.data(), nonce.data()) != 1 ||
        EVP_DecryptUpdate(ctx.get(), nullptr, &len, reinterpret_cast<const unsigned char*>(aad.data()), static_cast<int>(aad.size())) != 1 ||
        EVP_DecryptUpdate(ctx.get(), plaintext.data(), &len, ciphertext.data(), static_cast<int>(ciphertext.size())) != 1) {
        throw std::runtime_error("Convex payload decryption failed");
    }
    written = len;
    if (EVP_CIPHER_CTX_ctrl(ctx.get(), EVP_CTRL_GCM_SET_TAG, static_cast<int>(tag.size()), tag.data()) != 1 ||
        EVP_DecryptFinal_ex(ctx.get(), plaintext.data() + written, &len) != 1) {
        throw std::runtime_error("Convex payload authentication failed");
    }
    written += len;
    plaintext.resize(static_cast<std::size_t>(written));
    auto parsed = nlohmann::json::parse(std::string(reinterpret_cast<const char*>(plaintext.data()), plaintext.size()));
    jarvis::security::memory::secure_zero(key.data(), key.size());
    jarvis::security::memory::secure_zero(plaintext.data(), plaintext.size());
    return parsed;
}

std::string RuntimeSecretStore::sign_doc(const nlohmann::json& doc) {
    std::array<unsigned char, 32> key{};
    derived_key_into("jarvis.convex.doc.hmac.v1", key);
    const auto msg = signature_payload(doc);
    unsigned int out_len = 0;
    unsigned char out[EVP_MAX_MD_SIZE];
    if (!HMAC(EVP_sha256(), key.data(), static_cast<int>(key.size()),
              reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), out, &out_len) || out_len != 32) {
        throw std::runtime_error("Convex document signature failed");
    }
    auto hex = hex_of(out, out_len);
    jarvis::security::memory::secure_zero(key.data(), key.size());
    jarvis::security::memory::secure_zero(out, sizeof(out));
    return hex;
}

bool RuntimeSecretStore::verify_doc_signature(const nlohmann::json& doc) {
    if (!doc.is_object() || !doc.contains("sig") || !doc["sig"].is_string()) return false;
    const std::string expected = sign_doc(doc);
    const std::string actual = doc["sig"].get<std::string>();
    return actual.size() == expected.size() && CRYPTO_memcmp(actual.data(), expected.data(), expected.size()) == 0;
}

uint64_t RuntimeSecretStore::next_local_version(const std::string& kind_hash, const std::string& topic_hash) {
    const auto path = std::filesystem::path(jarvis_home_) / "convex_state.json";
    auto state = load_state_file(path);
    const auto key = version_key(kind_hash, topic_hash);
    uint64_t version = state["versions"].value(key, 0ULL) + 1ULL;
    state["versions"][key] = version;
    state["expected"][key] = true;
    save_state_file(path, state);
    return version;
}

bool RuntimeSecretStore::observe_remote_version(const std::string& kind_hash, const std::string& topic_hash, uint64_t version) {
    const auto path = std::filesystem::path(jarvis_home_) / "convex_state.json";
    auto state = load_state_file(path);
    const auto key = version_key(kind_hash, topic_hash);
    const uint64_t latest = state["versions"].value(key, 0ULL);
    if (version < latest) return false;
    state["versions"][key] = version;
    save_state_file(path, state);
    return true;
}

void RuntimeSecretStore::mark_expected(const std::string& kind_hash, const std::string& topic_hash) {
    const auto path = std::filesystem::path(jarvis_home_) / "convex_state.json";
    auto state = load_state_file(path);
    state["expected"][version_key(kind_hash, topic_hash)] = true;
    save_state_file(path, state);
}

void RuntimeSecretStore::clear_expected(const std::string& kind_hash, const std::string& topic_hash) {
    const auto path = std::filesystem::path(jarvis_home_) / "convex_state.json";
    auto state = load_state_file(path);
    state["expected"].erase(version_key(kind_hash, topic_hash));
    save_state_file(path, state);
}

bool RuntimeSecretStore::has_expected(const std::string& kind_hash, const std::string& topic_hash) const {
    const auto path = std::filesystem::path(jarvis_home_) / "convex_state.json";
    auto state = load_state_file(path);
    return state["expected"].value(version_key(kind_hash, topic_hash), false);
}

void RuntimeSecretStore::update_local_index(const std::string& hash, const std::string& plaintext) {
    ensure_private_dir(jarvis_home_);
    const auto path = std::filesystem::path(jarvis_home_) / "topic_index.json";
    nlohmann::json idx = nlohmann::json::object();
    if (std::filesystem::exists(path)) {
        std::ifstream in(path);
        try { in >> idx; } catch (...) { idx = nlohmann::json::object(); }
        if (!idx.is_object()) idx = nlohmann::json::object();
    }
    if (!idx.contains(hash) || idx[hash] != plaintext) {
        idx[hash] = plaintext;
        std::ofstream out(path, std::ios::trunc);
        out << idx.dump(2);
        out.close();
        chmod(path.c_str(), 0600);
    }
}

std::optional<std::string> RuntimeSecretStore::lookup_topic(const std::string& hash) const {
    const auto path = std::filesystem::path(jarvis_home_) / "topic_index.json";
    if (!std::filesystem::exists(path)) return std::nullopt;
    std::ifstream in(path);
    nlohmann::json idx;
    try { in >> idx; } catch (...) { return std::nullopt; }
    if (!idx.is_object() || !idx.contains(hash) || !idx[hash].is_string()) return std::nullopt;
    return idx[hash].get<std::string>();
}

ConvexBackend::ConvexBackend(std::shared_ptr<ConvexTransport> transport,
                             std::shared_ptr<RuntimeSecretStore> secrets,
                             std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log)
    : transport_(std::move(transport))
    , secrets_(std::move(secrets))
    , audit_log_(std::move(audit_log)) {
    if (!transport_) throw std::invalid_argument("ConvexBackend requires a transport");
    if (!secrets_) secrets_ = std::make_shared<RuntimeSecretStore>();
    if (!audit_log_) audit_log_ = std::make_shared<jarvis::audit::TamperEvidentAuditLog>();
}

ConvexBackend ConvexBackend::live(std::string url,
                                  std::shared_ptr<RuntimeSecretStore> secrets,
                                  std::shared_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log) {
    return ConvexBackend(std::make_shared<CurlConvexTransport>(std::move(url)), std::move(secrets), std::move(audit_log));
}

nlohmann::json ConvexBackend::to_doc(const Signal& sig) {
    const auto topic_hash = secrets_->hmac_hex("topic:", sig.topic);
    const auto kind_hash = secrets_->hmac_hex("kind:", sig.kind);
    secrets_->update_local_index(topic_hash, sig.topic);
    secrets_->update_local_index(kind_hash, sig.kind);
    const uint64_t version = secrets_->next_local_version(kind_hash, topic_hash);

    nlohmann::json values{{"strength", sig.strength}, {"last_t", sig.last_t}, {"depositors", sig.depositors}};
    if (sig.vec) values["vec"] = *sig.vec;
    nlohmann::json doc{{"kind", kind_hash},
                       {"topic", topic_hash},
                       {"version", version},
                       {"values", secrets_->encrypt_values(kind_hash, topic_hash, version, values)}};
    doc["sig"] = secrets_->sign_doc(doc);
    assert_no_cleartext_topic_kind(doc);
    return doc;
}

std::optional<Signal> ConvexBackend::from_doc(const nlohmann::json& d) {
    if (d.is_null() || d.empty()) return std::nullopt;
    if (!d.is_object()) {
        audit_security_reject("convex_malformed_record", d);
        throw std::runtime_error("Convex record is malformed");
    }
    const std::string kind_hash = d.at("kind").get<std::string>();
    const std::string topic_hash = d.at("topic").get<std::string>();
    if (!is_hmac_hex(kind_hash) || !is_hmac_hex(topic_hash)) {
        audit_security_reject("convex_cleartext_or_invalid_key", d);
        throw std::runtime_error("Convex record failed topic/kind HMAC gate");
    }
    if (!secrets_->verify_doc_signature(d)) {
        audit_security_reject("convex_signature_rejected", d);
        throw std::runtime_error("Convex record failed signature gate");
    }
    const uint64_t version = d.at("version").get<uint64_t>();
    if (!secrets_->observe_remote_version(kind_hash, topic_hash, version)) {
        audit_security_reject("convex_replay_detected", d);
        throw std::runtime_error("Convex replayed stale encrypted record");
    }
    const auto values = secrets_->decrypt_values(kind_hash, topic_hash, version, d.at("values"));
    Signal s;
    s.kind = secrets_->lookup_topic(kind_hash).value_or(kind_hash);
    s.topic = secrets_->lookup_topic(topic_hash).value_or(topic_hash);
    s.strength = values.at("strength").get<double>();
    s.last_t = values.at("last_t").get<double>();
    if (values.contains("depositors") && values["depositors"].is_array()) {
        for (const auto& v : values["depositors"]) s.depositors.insert(v.get<std::string>());
    }
    if (values.contains("vec") && values["vec"].is_array()) s.vec = values["vec"].get<std::vector<double>>();
    return s;
}

nlohmann::json ConvexBackend::hashed_key_args(const std::pair<std::string, std::string>& key) {
    nlohmann::json args{{"kind", secrets_->hmac_hex("kind:", key.first)},
                        {"topic", secrets_->hmac_hex("topic:", key.second)}};
    secrets_->update_local_index(args["kind"].get<std::string>(), key.first);
    secrets_->update_local_index(args["topic"].get<std::string>(), key.second);
    assert_no_cleartext_topic_kind(args);
    return args;
}

void ConvexBackend::audit_call(const char* operation, const char* outcome, const nlohmann::json& args) {
    jarvis::logInfo("convex", operation, {
        jarvis::LogField::str("subject", subject_hash(args)),
        jarvis::LogField::str("outcome", outcome),
    });
    if (!audit_log_) return;
    jarvis::audit::AuditEvent e;
    e.event_kind = std::string(operation) == "query" ? jarvis::audit::EventKind::CONVEX_QUERY
                                                       : jarvis::audit::EventKind::CONVEX_MUTATION;
    e.actor = jarvis::audit::Actor::SELF;
    e.subject = subject_hash(args);
    e.outcome = outcome;
    e.reason = "convex_backend";
    e.redacted_metadata = std::string("{\"arg_sha256\":\"") + e.subject + "\"}";
    audit_log_->append(std::move(e));
}

void ConvexBackend::audit_security_reject(const char* reason, const nlohmann::json& doc) {
    jarvis::logWarn("convex", "security_reject", {
        jarvis::LogField::str("subject", subject_hash(doc)),
        jarvis::LogField::str("reason", reason),
    });
    if (!audit_log_) return;
    jarvis::audit::AuditEvent e;
    e.event_kind = jarvis::audit::EventKind::CONVEX_QUERY;
    e.actor = jarvis::audit::Actor::EXTERNAL;
    e.subject = subject_hash(doc);
    e.outcome = jarvis::audit::Outcome::DENIED;
    e.reason = reason;
    e.redacted_metadata = std::string("{\"doc_sha256\":\"") + e.subject + "\"}";
    audit_log_->append(std::move(e));
}

void ConvexBackend::put(const std::pair<std::string, std::string>&, const Signal& sig) {
    auto args = to_doc(sig);
    audit_call("mutation", "attempt", args);
    transport_->mutation("stigmergy:put", args);
    audit_call("mutation", "success", args);
}

std::optional<Signal> ConvexBackend::get(const std::pair<std::string, std::string>& key) {
    auto args = hashed_key_args(key);
    audit_call("query", "attempt", args);
    auto row = transport_->query("stigmergy:get", args);
    if ((row.is_null() || row.empty()) && secrets_->has_expected(args.at("kind").get<std::string>(), args.at("topic").get<std::string>())) {
        audit_security_reject("convex_missing_expected_record", args);
        throw std::runtime_error("Convex omitted an expected record");
    }
    audit_call("query", "success", args);
    return from_doc(row);
}

std::vector<Signal> ConvexBackend::all() {
    nlohmann::json args = nlohmann::json::object();
    audit_call("query", "attempt", args);
    auto rows = transport_->query("stigmergy:all", args);
    audit_call("query", "success", args);
    std::vector<Signal> out;
    if (!rows.is_array()) return out;
    for (const auto& row : rows) if (auto s = from_doc(row)) out.push_back(*s);
    return out;
}

void ConvexBackend::delete_key(const std::pair<std::string, std::string>& key) {
    auto args = hashed_key_args(key);
    audit_call("mutation", "attempt", args);
    transport_->mutation("stigmergy:del", args);
    secrets_->clear_expected(args.at("kind").get<std::string>(), args.at("topic").get<std::string>());
    audit_call("mutation", "success", args);
}

void ConvexBackend::gc_keys(const std::vector<std::pair<std::string, std::string>>& keys) {
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& k : keys) arr.push_back(hashed_key_args(k));
    nlohmann::json args{{"keys", arr}};
    assert_no_cleartext_topic_kind(args);
    audit_call("mutation", "attempt", args);
    transport_->mutation("stigmergy:gcKeys", args);
    for (const auto& k : args.at("keys")) secrets_->clear_expected(k.at("kind").get<std::string>(), k.at("topic").get<std::string>());
    audit_call("mutation", "success", args);
}

CurlConvexTransport::CurlConvexTransport(std::string url)
    : url_(std::move(url)), host_(host_from_url(url_)) {
    jarvis::security::egress::EgressAllowlist::global().enforce(host_, 443);
    if (!jarvis::security::CertPinStore::global().is_pinned(host_)) {
        throw std::runtime_error("Convex host is allowlisted but has no SPKI pin");
    }
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

CurlConvexTransport::~CurlConvexTransport() { curl_global_cleanup(); }

nlohmann::json CurlConvexTransport::mutation(const std::string& name, const nlohmann::json& args) {
    return call("/api/mutation", name, args);
}

nlohmann::json CurlConvexTransport::query(const std::string& name, const nlohmann::json& args) {
    return call("/api/query", name, args);
}

nlohmann::json CurlConvexTransport::call(const std::string& endpoint,
                                         const std::string& name,
                                         const nlohmann::json& args) {
    nlohmann::json body{{"path", name}, {"args", args}};
    assert_no_cleartext_topic_kind(body);
    auto* curl = curl_easy_init();
    if (!curl) throw std::runtime_error("curl_easy_init failed");
    std::string response;
    struct curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    const std::string target = url_ + endpoint;
    const std::string body_s = body.dump();
    auto pin_ctx = jarvis::security::make_curl_pin_context(host_);
    jarvis::security::install_pin_validator(curl, pin_ctx.get());
    curl_easy_setopt(curl, CURLOPT_URL, target.c_str());
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body_s.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, body_s.size());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    const CURLcode rc = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK) throw std::runtime_error(std::string("Convex HTTP request failed: ") + curl_easy_strerror(rc));
    if (status < 200 || status >= 300) throw std::runtime_error("Convex HTTP status " + std::to_string(status));
    if (response.empty()) return nullptr;
    auto parsed = nlohmann::json::parse(response);
    if (parsed.is_object() && parsed.contains("value")) return parsed["value"];
    return parsed;
}

} // namespace jarvis::storage::convex
