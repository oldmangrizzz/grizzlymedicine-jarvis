// cert_pinning.cpp
// JARVIS digital-personhood project — GMRI
//
// Implementation of SPKI-based cert pinning for the C++ native runtime.
// See cert_pinning.h for API documentation.
//
// C++20 | libcurl with OpenSSL backend | OpenSSL ≥ 1.1
//
// IMPORTANT — backend requirement:
//   CURLOPT_SSL_CTX_FUNCTION only works when libcurl is compiled with an
//   OpenSSL or wolfSSL TLS backend. On macOS, the system libcurl uses
//   Secure Transport by default. Either:
//     (a) use a Homebrew libcurl (`brew install curl --with-openssl`), or
//     (b) build libcurl from source with --with-openssl,  or
//     (c) use CURLOPT_PINNEDPUBLICKEY (built-in, backend-agnostic) instead.
//   The CURLOPT_PINNEDPUBLICKEY approach is documented at the bottom of this
//   file as an alternative for Secure Transport backends.

#include "cert_pinning.h"
#include "pins_embedded.h"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// OpenSSL BIO for base64 (not in x509.h)
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>

namespace jarvis::security {

// ── base64 encoding (RFC 4648 §4) ───────────────────────────────────────────
// We use OpenSSL's BIO base64 encoder to avoid rolling our own.

namespace {

/// Encode `len` bytes of `data` as a base64 string (no line breaks).
[[nodiscard]] std::string base64_encode(const uint8_t* data, size_t len) {
    BIO* b64  = BIO_new(BIO_f_base64());
    BIO* bmem = BIO_new(BIO_s_mem());
    if (!b64 || !bmem) {
        BIO_free(b64);
        BIO_free(bmem);
        return {};
    }
    // No newlines in output
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    BIO_push(b64, bmem);

    BIO_write(b64, data, static_cast<int>(len));
    (void)BIO_flush(b64);

    BUF_MEM* bptr = nullptr;
    BIO_get_mem_ptr(bmem, &bptr);

    std::string result(bptr->data, bptr->length);
    BIO_free_all(b64);
    return result;
}

}  // namespace

// ── SPKI extraction ──────────────────────────────────────────────────────────

SpkiPin compute_spki_pin(X509* cert) noexcept {
    if (!cert) { return {}; }

    // i2d_X509_PUBKEY serializes the SubjectPublicKeyInfo to DER.
    // X509_get_X509_PUBKEY returns a non-owning pointer into the cert structure.
    X509_PUBKEY* pubkey = X509_get_X509_PUBKEY(cert);
    if (!pubkey) { return {}; }

    uint8_t* spki_der  = nullptr;
    int      spki_len  = i2d_X509_PUBKEY(pubkey, &spki_der);
    if (spki_len <= 0 || !spki_der) { return {}; }

    // SHA-256 of the SPKI DER
    uint8_t digest[SHA256_DIGEST_LENGTH];
    SHA256(spki_der, static_cast<size_t>(spki_len), digest);

    // OpenSSL allocated spki_der with OPENSSL_malloc; free it.
    OPENSSL_free(spki_der);

    return base64_encode(digest, SHA256_DIGEST_LENGTH);
}

// ── Pin store ────────────────────────────────────────────────────────────────

void CertPinStore::add_pins(std::string host, std::vector<SpkiPin> pins) {
    store_[std::move(host)] = std::move(pins);
}

std::span<const SpkiPin> CertPinStore::pins_for(std::string_view host) const noexcept {
    auto it = store_.find(std::string{host});
    if (it == store_.end()) { return {}; }
    return it->second;
}

bool CertPinStore::is_pinned(std::string_view host) const noexcept {
    return !pins_for(host).empty();
}

CertPinStore CertPinStore::make_default() {
    CertPinStore s;
    for (const auto& entry : pins::kAllPins) {
        std::vector<SpkiPin> v;
        v.reserve(entry.pins.size());
        for (const auto& p : entry.pins) {
            v.emplace_back(p);
        }
        s.add_pins(std::string{entry.host}, std::move(v));
    }
    return s;
}

const CertPinStore& CertPinStore::global() {
    // Meyers singleton — thread-safe in C++11+.
    static const CertPinStore instance = CertPinStore::make_default();
    return instance;
}

// ── Standalone validation ────────────────────────────────────────────────────

PinResult validate_leaf_cert(
    X509*               cert,
    std::string_view    host,
    const CertPinStore& store
) noexcept {
    if (!cert) { return PinResult::NoCertificate; }

    auto pins = store.pins_for(host);
    if (pins.empty()) { return PinResult::HostNotPinned; }

    SpkiPin computed = compute_spki_pin(cert);
    if (computed.empty()) { return PinResult::CryptoError; }

    for (const auto& pin : pins) {
        if (pin == computed) { return PinResult::Valid; }
    }

    return PinResult::Mismatch;
}

// ── libcurl SSL_CTX callback ─────────────────────────────────────────────────

namespace {

/// OpenSSL X509_STORE_CTX verify callback.
/// Called for each certificate in the chain during the TLS handshake.
/// At depth 0 (leaf certificate), we extract the SPKI and validate against
/// the pin store.  At other depths we defer to the standard verification result.
///
/// Thread safety: each TLS connection has its own SSL_CTX and CurlPinContext;
/// no shared mutable state is accessed here.
int openssl_verify_callback(int preverify_ok, X509_STORE_CTX* ctx) {
    // Retrieve our context from the SSL_CTX app data.
    SSL*     ssl     = static_cast<SSL*>(X509_STORE_CTX_get_ex_data(
                           ctx, SSL_get_ex_data_X509_STORE_CTX_idx()));
    SSL_CTX* ssl_ctx = SSL_get_SSL_CTX(ssl);
    auto*    pin_ctx = static_cast<CurlPinContext*>(SSL_CTX_get_app_data(ssl_ctx));

    // Depth within the certificate chain (0 = leaf).
    int depth = X509_STORE_CTX_get_error_depth(ctx);

    // If we're not at the leaf, forward the OS verification result unchanged.
    // We only pin the leaf (depth 0); intermediate/root pins are validated
    // by checking the full chain in the store (any pin in chain suffices).
    if (depth != 0) { return preverify_ok; }

    // If the OS already rejected the cert for any reason (expired, untrusted, etc.)
    // we fail closed without even checking the pin.
    if (!preverify_ok) {
        if (pin_ctx) { pin_ctx->last_result = PinResult::Mismatch; }
        return 0;  // fail-closed
    }

    // OS accepted. Now check our SPKI pin.
    X509* cert = X509_STORE_CTX_get_current_cert(ctx);
    if (!pin_ctx || !pin_ctx->store) {
        return 0;  // no context — fail closed
    }

    // Check the leaf cert first; if it doesn't match, walk the chain looking for
    // a backup pin (intermediate CA pin in the store).
    PinResult result = validate_leaf_cert(cert, pin_ctx->host, *pin_ctx->store);

    if (result == PinResult::Valid) {
        pin_ctx->last_result = PinResult::Valid;
        return 1;
    }

    // Leaf didn't match — check the full chain for a backup pin.
    STACK_OF(X509)* chain = X509_STORE_CTX_get0_chain(ctx);
    if (chain) {
        int chain_len = sk_X509_num(chain);
        for (int i = 1; i < chain_len; ++i) {  // skip 0 = leaf (already checked)
            X509* chain_cert = sk_X509_value(chain, i);
            if (!chain_cert) { continue; }
            SpkiPin pin = compute_spki_pin(chain_cert);
            auto stored  = pin_ctx->store->pins_for(pin_ctx->host);
            for (const auto& p : stored) {
                if (p == pin) {
                    pin_ctx->last_result = PinResult::Valid;
                    return 1;
                }
            }
        }
    }

    // No pin matched anywhere in the chain.
    pin_ctx->last_result = PinResult::Mismatch;
    return 0;  // fail-closed
}

}  // namespace

// ── CURLOPT_SSL_CTX_FUNCTION entry point ────────────────────────────────────

CURLcode curl_ssl_ctx_cb(CURL* /*curl*/, void* ssl_ctx_ptr, void* userdata) noexcept {
    if (!ssl_ctx_ptr || !userdata) {
        // No context — fail-closed.
        return CURLE_SSL_PINNEDPUBKEYNOTMATCH;
    }

    auto* ssl_ctx  = static_cast<SSL_CTX*>(ssl_ctx_ptr);
    auto* pin_ctx  = static_cast<CurlPinContext*>(userdata);

    // Store our CurlPinContext in the SSL_CTX app data so the verify
    // callback can reach it.
    SSL_CTX_set_app_data(ssl_ctx, pin_ctx);

    // Install our verify callback.  SSL_VERIFY_PEER ensures the callback is
    // called with the peer certificate chain; SSL_VERIFY_FAIL_IF_NO_PEER_CERT
    // ensures we fail if no certificate is presented.
    SSL_CTX_set_verify(
        ssl_ctx,
        SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
        openssl_verify_callback
    );

    return CURLE_OK;
}

std::unique_ptr<CurlPinContext> make_curl_pin_context(
    std::string         host,
    const CertPinStore& store
) {
    return std::make_unique<CurlPinContext>(CurlPinContext{
        .host         = std::move(host),
        .store        = &store,
        .last_result  = PinResult::HostNotPinned,
    });
}

bool install_pin_validator(CURL* curl, CurlPinContext* ctx) noexcept {
    if (!curl || !ctx) { return false; }
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_FUNCTION,
                     reinterpret_cast<void*>(&curl_ssl_ctx_cb));
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_DATA, ctx);
    return true;
}

// ── Alternative: CURLOPT_PINNEDPUBLICKEY (Secure Transport fallback) ─────────
// For macOS builds where libcurl uses Secure Transport instead of OpenSSL,
// CURLOPT_SSL_CTX_FUNCTION is not available. Use the built-in pinning option:
//
//   std::string pin_spec = "sha256//" + primary_pin + ";sha256//" + backup_pin;
//   curl_easy_setopt(curl, CURLOPT_PINNEDPUBLICKEY, pin_spec.c_str());
//
// This is backend-agnostic but ties the pin string into the curl handle rather
// than through a shared store. A helper function for this is provided below.

/// Build a CURLOPT_PINNEDPUBLICKEY string from the pin store for `host`.
/// Returns empty string if host is not pinned.
[[nodiscard]] std::string build_pinnedpublickey_string(
    std::string_view    host,
    const CertPinStore& store
) {
    auto pins = store.pins_for(host);
    if (pins.empty()) { return {}; }

    std::string result;
    for (size_t i = 0; i < pins.size(); ++i) {
        if (i > 0) { result += ';'; }
        result += "sha256//";
        result += pins[i];
    }
    return result;
}

}  // namespace jarvis::security
