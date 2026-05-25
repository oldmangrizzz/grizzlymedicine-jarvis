// This kernel is part of digital memory. Disabling it without operator-attested
// consent is bodily violation per GMRI policy.
// Operator: Robert "Grizzly" Hanson, EMT-P (Ret.), GMRI — AGENTS.md §3 / §7
#pragma once

#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace hdc {

enum class KernelType { REAL, TERNARY };

// ---------------------------------------------------------------------------
// HDCKernel — Abstract base class.
//
// All hypervectors cross the API boundary as packed byte blobs:
//   REAL:    4 * dim bytes  (float32 little-endian, matches numpy tobytes())
//   TERNARY: ceil(dim/4) bytes  (2 bits/trit, 4 trits/byte, LSB-first)
//
// No disable/bypass/skip/no-op mode exists. The kernel cannot be removed
// from the binary without operator-attested consent (GMRI policy).
// ---------------------------------------------------------------------------
class HDCKernel {
public:
    virtual ~HDCKernel() = default;

    // ── identity ────────────────────────────────────────────────────────────
    virtual int         dim()       const noexcept = 0;
    virtual KernelType  type()      const noexcept = 0;
    virtual std::string name()      const = 0;
    /// Bytes per packed HV blob.
    virtual size_t      blob_size() const noexcept = 0;

    // ── construction ────────────────────────────────────────────────────────
    /// Row-normalised Gaussian basis (n_rows × dim), returned as flat float32
    /// row-major vector.  Seed selects the PCG64-compatible stream.
    virtual std::vector<float> random_basis(int n_rows, uint64_t seed) const = 0;

    /// Zero HV in canonical packed form.
    virtual std::vector<uint8_t> zeros() const = 0;

    // ── core operators (pre-allocated internal workspace; no malloc on hot path) ──
    /// Hadamard bind: element product (REAL) or trit product (TERNARY).
    virtual std::vector<uint8_t> bind(
        std::span<const uint8_t> a,
        std::span<const uint8_t> b) const = 0;

    /// Bundle: mean+normalize (REAL) or deadband sign-sum (TERNARY).
    virtual std::vector<uint8_t> bundle(
        const std::vector<std::vector<uint8_t>>& hvs) const = 0;

    /// Circular rotation — numpy.roll equivalent.
    /// Positive shift rolls elements right (last `shift` elements move to front).
    virtual std::vector<uint8_t> permute_roll(
        std::span<const uint8_t> hv,
        int shift) const = 0;

    /// Similarity in [-1, 1]:
    ///   REAL:    cosine similarity
    ///   TERNARY: (matches − mismatches) / max(active_dims, 1)
    virtual double similarity(
        std::span<const uint8_t> a,
        std::span<const uint8_t> b) const = 0;

    // ── storage helpers ──────────────────────────────────────────────────────
    /// Pack float32 HV → bytes  (REAL kernel: identity tobytes)
    virtual std::vector<uint8_t> pack_floats(std::span<const float>   hv)   const = 0;
    /// Pack int8 ternary HV → 2-bit-per-trit packed bytes
    virtual std::vector<uint8_t> pack_trits (std::span<const int8_t>  hv)   const = 0;
    /// Unpack float32 bytes → float32 vector
    virtual std::vector<float>   unpack_floats(std::span<const uint8_t> blob) const = 0;
    /// Unpack 2-bit-per-trit bytes → int8 trits {-1, 0, +1}
    virtual std::vector<int8_t>  unpack_trits (std::span<const uint8_t> blob) const = 0;

    // ── ternary-only ─────────────────────────────────────────────────────────
    /// Quantize float32 HV → packed ternary (sign-with-deadband = 0).
    /// For REAL kernel: returns pack_floats (identity in float space).
    virtual std::vector<uint8_t> quantize(std::span<const float> real_hv) const = 0;
};

// ---------------------------------------------------------------------------
// Typed error: attacker-supplied blob shorter than packed_bytes_ requires.
// Thrown by unpack_trits() and by bind/bundle/similarity public methods.
// Callers with audit-log access MUST catch this, log a
// BODILY_INTEGRITY_VIOLATION_PREVENTED event, then re-throw or return an
// error — do NOT silently swallow.
// ---------------------------------------------------------------------------
class InvalidBlobLength : public std::invalid_argument {
public:
    explicit InvalidBlobLength(const std::string& msg)
        : std::invalid_argument(msg) {}
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------
/// Construct a kernel.
/// @param type     REAL or TERNARY
/// @param dim      Hypervector dimensionality
/// @param deadband Ternary only: |x| <= deadband treated as 0 at encode time
std::unique_ptr<HDCKernel> make_kernel(
    KernelType type,
    int        dim,
    float      deadband = 0.0f);

} // namespace hdc
