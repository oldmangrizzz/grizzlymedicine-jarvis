#pragma once
#include "hdc.h"
#include <shared_mutex>
#include <vector>

namespace hdc {

// ---------------------------------------------------------------------------
// TernaryKernel — trits {-1, 0, +1}, 2-bits-per-trit packing, Hamming sim.
//
// Packing (matches Python exactly):
//   trit  0  →  0b00  (code 0)
//   trit +1  →  0b01  (code 1)
//   trit -1  →  0b10  (code 2)
//   0b11 (code 3) is reserved; decoded as 0.
//   4 trits per byte, LSB first: byte = code0 | (code1<<2) | (code2<<4) | (code3<<6)
//
// Similarity:
//   active  = { i : a[i]≠0 AND b[i]≠0 }
//   matches = { i ∈ active : a[i]=b[i] }
//   mismatches = active \ matches
//   sim = (|matches| − |mismatches|) / max(|active|, 1)
//
// Bundle deadband:
//   threshold = 0.5 * sqrt(n),  applied as float64 exactly as Python.
//   result[i] = +1 if acc[i] > threshold
//             = -1 if acc[i] < -threshold
//             =  0 otherwise
// ---------------------------------------------------------------------------
class TernaryKernel final : public HDCKernel {
public:
    explicit TernaryKernel(int dim, float deadband = 0.0f);
    ~TernaryKernel() override = default;

    int        dim()       const noexcept override { return dim_; }
    KernelType type()      const noexcept override { return KernelType::TERNARY; }
    std::string name()     const override          { return "ternary"; }
    /// ceil(dim / 4) bytes.
    size_t     blob_size() const noexcept override { return packed_bytes_; }

    std::vector<float>   random_basis(int n_rows, uint64_t seed) const override;
    std::vector<uint8_t> zeros()       const override;

    std::vector<uint8_t> bind(
        std::span<const uint8_t> a,
        std::span<const uint8_t> b)    const override;

    std::vector<uint8_t> bundle(
        const std::vector<std::vector<uint8_t>>& hvs) const override;

    std::vector<uint8_t> permute_roll(
        std::span<const uint8_t> hv,
        int shift)                     const override;

    double similarity(
        std::span<const uint8_t> a,
        std::span<const uint8_t> b)    const override;

    std::vector<uint8_t> pack_floats(std::span<const float>   hv)   const override;
    std::vector<uint8_t> pack_trits (std::span<const int8_t>  hv)   const override;
    std::vector<float>   unpack_floats(std::span<const uint8_t> blob) const override;
    std::vector<int8_t>  unpack_trits (std::span<const uint8_t> blob) const override;
    std::vector<uint8_t> quantize(std::span<const float> real_hv)    const override;

private:
    int    dim_;
    float  deadband_;
    size_t packed_bytes_;  // ceil(dim_ / 4)

    // Pre-allocated bundle accumulator (int32, dim_ elements).
    mutable std::vector<int32_t> ws_;
    mutable std::shared_mutex    ws_mu_;

    // Internal helpers
    std::vector<int8_t> sign_dead(const float* x, int n, double threshold) const;
};

} // namespace hdc
