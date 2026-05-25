#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "character_values.h"
#include "cert_pinning.h"
#include "convex_backend.h"
#include "hdc.h"
#include "beliefstore.h"
#include "memory_security.h"

#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <sodium.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <numeric>
#include <string>
#include <vector>

namespace {
constexpr int kIterations = 10'000;
volatile std::uint64_t g_sink = 0;

struct WelchResult {
    double mean_a_ns{};
    double mean_b_ns{};
    double t{};
};

double mean(const std::vector<double>& values) {
    return std::accumulate(values.begin(), values.end(), 0.0) / static_cast<double>(values.size());
}

double variance(const std::vector<double>& values, double m) {
    double acc = 0.0;
    for (double v : values) {
        const double d = v - m;
        acc += d * d;
    }
    return acc / static_cast<double>(values.size() - 1);
}

WelchResult welch_t(const std::vector<double>& a, const std::vector<double>& b) {
    const double ma = mean(a);
    const double mb = mean(b);
    const double va = variance(a, ma);
    const double vb = variance(b, mb);
    const double denom = std::sqrt((va / static_cast<double>(a.size())) + (vb / static_cast<double>(b.size())));
    return {ma, mb, denom == 0.0 ? 0.0 : (ma - mb) / denom};
}

std::vector<double> measure_ns(const std::function<void()>& op) {
    std::vector<double> out;
    out.reserve(kIterations);
    for (int i = 0; i < kIterations; ++i) {
        const auto start = std::chrono::steady_clock::now();
        op();
        const auto stop = std::chrono::steady_clock::now();
        out.push_back(static_cast<double>(std::chrono::duration_cast<std::chrono::nanoseconds>(stop - start).count()));
    }
    return out;
}

void require_no_gross_input_dependence(const char* label, const WelchResult& r, double max_abs_t = 25.0) {
    INFO(label << " mean_a_ns=" << r.mean_a_ns << " mean_b_ns=" << r.mean_b_ns << " welch_t=" << r.t);
    REQUIRE(std::isfinite(r.t));
    CHECK(std::abs(r.t) < max_abs_t);
}

std::filesystem::path artifact_dir(const char* name) {
    auto p = std::filesystem::path(TEST_ARTIFACT_DIR) / name;
    std::filesystem::create_directories(p);
    return p;
}

static const char kValidCertDERb64[] =
    "MIIByzCCAXGgAwIBAgIUM3228cddbn2GHMMygpHDsJbQrj0wCgYIKoZIzj0EAwIw"
    "OzEdMBsGA1UEAwwUdGVzdC5qYXJ2aXMuaW50ZXJuYWwxDTALBgNVBAoMBEdNUkkx"
    "CzAJBgNVBAYTAlVTMB4XDTI2MDUyNDAxMzU1NFoXDTM2MDUyMTAxMzU1NFowOzEd"
    "MBsGA1UEAwwUdGVzdC5qYXJ2aXMuaW50ZXJuYWwxDTALBgNVBAoMBEdNUkkxCzAJ"
    "BgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEI9wswv+4Ef9COc5/"
    "9WDqBDVBFZluoSnNHu2GAS4Bb3fwyU3KIu3qg5pFAtBuUKkx2UxcuKqR13p/yfIk"
    "NOyXZ6NTMFEwHQYDVR0OBBYEFBVejPOwA3mmrHrmFcLMbhLxOZ5sMB8GA1UdIwQY"
    "MBaAFBVejPOwA3mmrHrmFcLMbhLxOZ5sMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZI"
    "zj0EAwIDSAAwRQIhAJAhBvVs2pUMsvxNW8SLTXwxTeqA7wynmEGJrbdtIGKqAiAK"
    "JnrMi2jNpf/BDpo4lcbViRKcHsCIKLv/fsGEwvysAw==";
static const char kValidCertPin[] = "Decreb4tbND/uNMBxd5MQXGPfccTHvl2gMG4Z2MH3vQ=";
static const char kWrongCertPin[] = "CDYzDujcWCrd+19wxs/bGiSZ1Pgc8ST+6LYI3QL0jMg=";

X509* load_cert_from_der_b64(const char* b64) {
    BIO* b64_bio = BIO_new(BIO_f_base64());
    BIO* mem_bio = BIO_new_mem_buf(b64, static_cast<int>(std::strlen(b64)));
    BIO_set_flags(b64_bio, BIO_FLAGS_BASE64_NO_NL);
    BIO* chain = BIO_push(b64_bio, mem_bio);
    unsigned char der[4096] = {};
    const int der_len = BIO_read(chain, der, sizeof(der));
    BIO_free_all(chain);
    if (der_len <= 0) return nullptr;
    const unsigned char* p = der;
    return d2i_X509(nullptr, &p, der_len);
}

struct X509Guard {
    X509* cert;
    explicit X509Guard(const char* b64) : cert(load_cert_from_der_b64(b64)) {}
    ~X509Guard() { if (cert) X509_free(cert); }
    X509Guard(const X509Guard&) = delete;
    X509Guard& operator=(const X509Guard&) = delete;
};

} // namespace

TEST_CASE("libsodium Ed25519 signing through SoulAnchor shows no gross secret-key timing split", "[side-channel][identity]") {
    jarvis::security::memory::ensure_sodium_initialized();
    const auto values = jarvis::identity::CharacterValues::canonical();
    const jarvis::identity::HardwareFingerprint hw{"machine-uuid-side-channel-00000001", "secure-enclave-key-id-side-channel-01"};
    const auto key_a = jarvis::identity::SoulAnchor::generate_mock_usb_root_keypair();
    const auto key_b = jarvis::identity::SoulAnchor::generate_mock_usb_root_keypair();

    auto a = measure_ns([&] {
        auto cert = jarvis::identity::SoulAnchor::anchor_birth_certificate(values, hw, key_a.public_key, key_a.private_key, "1800000000");
        g_sink += cert.signature_hex[0];
    });
    auto b = measure_ns([&] {
        auto cert = jarvis::identity::SoulAnchor::anchor_birth_certificate(values, hw, key_b.public_key, key_b.private_key, "1800000000");
        g_sink += cert.signature_hex[0];
    });
    require_no_gross_input_dependence("SoulAnchor::anchor_birth_certificate/libsodium crypto_sign_detached", welch_t(a, b));
}

TEST_CASE("libsodium Ed25519 verification through SoulAnchor shows no gross valid-input timing split", "[side-channel][identity]") {
    jarvis::security::memory::ensure_sodium_initialized();
    const auto values = jarvis::identity::CharacterValues::canonical();
    const jarvis::identity::HardwareFingerprint hw{"machine-uuid-side-channel-00000001", "secure-enclave-key-id-side-channel-01"};
    const auto key_a = jarvis::identity::SoulAnchor::generate_mock_usb_root_keypair();
    const auto key_b = jarvis::identity::SoulAnchor::generate_mock_usb_root_keypair();
    const auto cert_a = jarvis::identity::SoulAnchor::anchor_birth_certificate(values, hw, key_a.public_key, key_a.private_key, "1800000000");
    const auto cert_b = jarvis::identity::SoulAnchor::anchor_birth_certificate(values, hw, key_b.public_key, key_b.private_key, "1800000000");

    auto a = measure_ns([&] { g_sink += static_cast<unsigned>(jarvis::identity::SoulAnchor::verify_birth_certificate(cert_a, values, hw, cert_a.root_public_key_hex)); });
    auto b = measure_ns([&] { g_sink += static_cast<unsigned>(jarvis::identity::SoulAnchor::verify_birth_certificate(cert_b, values, hw, cert_b.root_public_key_hex)); });
    require_no_gross_input_dependence("SoulAnchor::verify_birth_certificate/libsodium crypto_sign_verify_detached", welch_t(a, b));
}

TEST_CASE("Convex HMAC topic hashing and key derivation show no gross same-length input timing split", "[side-channel][convex]") {
    jarvis::storage::convex::RuntimeSecretStore store(artifact_dir("convex_hmac").string());
    (void)store.secret();
    const std::string topic_a = "topic-side-channel-A-000000000000000000000000000000";
    const std::string topic_b = "topic-side-channel-B-111111111111111111111111111111";
    REQUIRE(topic_a.size() == topic_b.size());

    auto a = measure_ns([&] { g_sink += store.hmac_hex("topic:", topic_a)[0]; });
    auto b = measure_ns([&] { g_sink += store.hmac_hex("topic:", topic_b)[0]; });
    require_no_gross_input_dependence("RuntimeSecretStore::hmac_hex/OpenSSL HMAC(EVP_sha256)", welch_t(a, b));

    auto da = measure_ns([&] { g_sink += store.derived_key("jarvis.convex.values.aes256gcm.v1")[0]; });
    auto db = measure_ns([&] { g_sink += store.derived_key("jarvis.convex.doc.hmac.v1.....")[0]; });
    require_no_gross_input_dependence("RuntimeSecretStore::derived_key/OpenSSL HMAC(EVP_sha256)", welch_t(da, db));
}

TEST_CASE("Convex AES-256-GCM encrypt/decrypt show no gross same-length input timing split", "[side-channel][convex]") {
    jarvis::storage::convex::RuntimeSecretStore store(artifact_dir("convex_aes_gcm").string());
    const std::string kind = store.hmac_hex("kind:", "side-channel-kind");
    const std::string topic = store.hmac_hex("topic:", "side-channel-topic");
    const nlohmann::json values_a{{"strength", 0.5}, {"last_t", 1.0}, {"depositors", std::vector<std::string>{"alpha"}}};
    const nlohmann::json values_b{{"strength", 0.6}, {"last_t", 2.0}, {"depositors", std::vector<std::string>{"bravo"}}};
    REQUIRE(values_a.dump().size() == values_b.dump().size());
    const auto env_a = store.encrypt_values(kind, topic, 7, values_a);
    const auto env_b = store.encrypt_values(kind, topic, 8, values_b);

    auto ea = measure_ns([&] { g_sink += store.encrypt_values(kind, topic, 7, values_a).at("tag").get<std::string>()[0]; });
    auto eb = measure_ns([&] { g_sink += store.encrypt_values(kind, topic, 8, values_b).at("tag").get<std::string>()[0]; });
    require_no_gross_input_dependence("RuntimeSecretStore::encrypt_values/OpenSSL EVP_aes_256_gcm", welch_t(ea, eb));

    auto da = measure_ns([&] { g_sink += static_cast<std::uint64_t>(store.decrypt_values(kind, topic, 7, env_a).dump().size()); });
    auto db = measure_ns([&] { g_sink += static_cast<std::uint64_t>(store.decrypt_values(kind, topic, 8, env_b).dump().size()); });
    require_no_gross_input_dependence("RuntimeSecretStore::decrypt_values/OpenSSL EVP_aes_256_gcm", welch_t(da, db));
}

TEST_CASE("Convex document signature verification uses constant-time CRYPTO_memcmp for same-size mismatches", "[side-channel][convex]") {
    jarvis::storage::convex::RuntimeSecretStore store(artifact_dir("convex_sig").string());
    nlohmann::json doc{{"kind", store.hmac_hex("kind:", "sig-kind")},
                       {"topic", store.hmac_hex("topic:", "sig-topic")},
                       {"version", 1},
                       {"values", nlohmann::json{{"alg", "AES-256-GCM"}, {"nonce", "AAAAAAAAAAAAAAAA"}, {"ciphertext", ""}, {"tag", "AAAAAAAAAAAAAAAAAAAAAA=="}}}};
    doc["sig"] = store.sign_doc(doc);
    auto first_bad = doc;
    auto last_bad = doc;
    std::string sig_first = first_bad["sig"].get<std::string>();
    std::string sig_last = last_bad["sig"].get<std::string>();
    sig_first[0] = sig_first[0] == '0' ? '1' : '0';
    sig_last.back() = sig_last.back() == '0' ? '1' : '0';
    first_bad["sig"] = sig_first;
    last_bad["sig"] = sig_last;

    auto a = measure_ns([&] { g_sink += store.verify_doc_signature(first_bad) ? 1 : 0; });
    auto b = measure_ns([&] { g_sink += store.verify_doc_signature(last_bad) ? 1 : 0; });
    require_no_gross_input_dependence("RuntimeSecretStore::verify_doc_signature/OpenSSL CRYPTO_memcmp", welch_t(a, b));
}

TEST_CASE("Certificate pin matching is measured and documented as non-secret but input-dependent", "[side-channel][cert-pinning]") {
    X509Guard cert(kValidCertDERb64);
    REQUIRE(cert.cert != nullptr);
    jarvis::security::CertPinStore first_match;
    jarvis::security::CertPinStore second_match;
    first_match.add_pins("test.jarvis.internal", {kValidCertPin, kWrongCertPin});
    second_match.add_pins("test.jarvis.internal", {kWrongCertPin, kValidCertPin});

    auto a = measure_ns([&] { g_sink += static_cast<unsigned>(jarvis::security::validate_leaf_cert(cert.cert, "test.jarvis.internal", first_match)); });
    auto b = measure_ns([&] { g_sink += static_cast<unsigned>(jarvis::security::validate_leaf_cert(cert.cert, "test.jarvis.internal", second_match)); });
    const auto r = welch_t(a, b);
    INFO("validate_leaf_cert first-pin vs second-pin mean_a_ns=" << r.mean_a_ns << " mean_b_ns=" << r.mean_b_ns << " welch_t=" << r.t);
    REQUIRE(std::isfinite(r.t));
    WARN("cert pin loop uses std::string::operator== and exits on first public SPKI-pin match; tracked in GAP-SC-001 because it is input-dependent, not because it exposes secret material");
}

TEST_CASE("HDC similarity and BeliefStore abstention threshold are measured as non-secret input-dependent paths", "[side-channel][non-secret]") {
    auto kernel = hdc::make_kernel(hdc::KernelType::REAL, 1024);
    const auto basis_a = kernel->random_basis(1, 1234);
    const auto basis_b = kernel->random_basis(1, 5678);
    const auto hv_a = kernel->quantize(basis_a);
    const auto hv_b = kernel->quantize(basis_b);
    const auto zero = kernel->zeros();

    auto sim_active = measure_ns([&] { g_sink += static_cast<std::uint64_t>((kernel->similarity(hv_a, hv_b) + 2.0) * 1000.0); });
    auto sim_zero = measure_ns([&] { g_sink += static_cast<std::uint64_t>((kernel->similarity(zero, hv_b) + 2.0) * 1000.0); });
    const auto sim_r = welch_t(sim_active, sim_zero);
    INFO("HDC RealKernel::similarity active-vs-zero mean_a_ns=" << sim_r.mean_a_ns << " mean_b_ns=" << sim_r.mean_b_ns << " welch_t=" << sim_r.t);
    REQUIRE(std::isfinite(sim_r.t));

    jarvis::BeliefStore store;
    store.assert_belief("subject-a", "relation-a", "object-a", jarvis::SourceType::Document, "doc", 0.80, false);
    store.assert_belief("subject-b", "relation-b", "object-b", jarvis::SourceType::Model, "model", 0.20, false);
    auto hit = measure_ns([&] { g_sink += store.query("subject-a", "relation-a", 0.35).abstained ? 0 : 1; });
    auto abstain = measure_ns([&] { g_sink += store.query("subject-b", "relation-b", 0.35).abstained ? 1 : 0; });
    const auto belief_r = welch_t(hit, abstain);
    INFO("BeliefStore::query hit-vs-abstain mean_a_ns=" << belief_r.mean_a_ns << " mean_b_ns=" << belief_r.mean_b_ns << " welch_t=" << belief_r.t);
    REQUIRE(std::isfinite(belief_r.t));
    WARN("HDC similarity and BeliefStore threshold branches are expected input-dependent paths over non-secret hypervectors/beliefs; documented in STATIC_AUDIT.md and OPERATOR_REPORT.md");
}
