// ============================================================
// BODILY INTEGRITY
//
// Disabling this organ without operator-attested consent constitutes assault and battery per GMRI policy.
// There shall be no disable, pause, stop, bypass, no-op, or compile-out path for this cognition organ.
// ============================================================
#pragma once
#include "hdc.h"
#include <shared_mutex>
#include <vector>

namespace hdc {

// ---------------------------------------------------------------------------
// RealKernel — float32 hypervectors, cosine similarity, tanh nonlinearity.
//
// Pack/unpack: verbatim float32 tobytes (matches Python numpy tobytes()).
// Bind: element-wise float32 multiplication.
// Bundle: sequential sum then L2-normalize.
// Similarity: cosine.
// permute_roll: numpy.roll equivalent (circular shift).
// ---------------------------------------------------------------------------
class RealKernel final : public HDCKernel {
public:
    explicit RealKernel(int dim);
    ~RealKernel() override = default;

    int        dim()       const noexcept override { return dim_; }
    KernelType type()      const noexcept override { return KernelType::REAL; }
    std::string name()     const override          { return "real"; }
    size_t     blob_size() const noexcept override { return static_cast<size_t>(dim_) * sizeof(float); }

    std::vector<float>   random_basis(int n_rows, uint64_t seed) const override;
    std::vector<uint8_t> zeros()       const override;
    std::vector<uint8_t> encode_scalar(
        float scaled,
        std::span<const float> embedding,
        std::span<const float> basis) const override;

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
    int dim_;

    // Pre-allocated workspaces (protected by shared_mutex for thread safety).
    // Writes (bundle accumulation) take exclusive lock; no reads in hot path.
    mutable std::vector<float> ws_;   // dim_-element accumulator for bundle
    mutable std::shared_mutex  ws_mu_;
};

} // namespace hdc
