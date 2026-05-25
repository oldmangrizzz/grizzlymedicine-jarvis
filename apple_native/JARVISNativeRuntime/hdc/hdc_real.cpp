#include "hdc_real.h"

#include <algorithm>
#include <bit>
#include <cassert>
#include <cmath>
#include <cstring>
#include <numeric>
#include <random>
#include <stdexcept>

#ifdef __ARM_NEON
#  include <arm_neon.h>
#endif
#ifdef __AVX2__
#  include <immintrin.h>
#endif

namespace hdc {

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------
RealKernel::RealKernel(int dim)
    : dim_(dim), ws_(static_cast<size_t>(dim), 0.0f) {
    if (dim_ <= 0)
        throw std::invalid_argument("RealKernel: dim must be positive");
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
namespace {

// Row-normalised Gaussian using Marsaglia polar method (matches numpy row-norm).
// NOTE: We use std::mt19937_64 with a Box-Muller Gaussian.  The values will
// NOT match numpy's PCG64 output — random_basis is NOT in the byte-exact test
// list; we only verify shape and row-normalisation.
static std::vector<float> gaussian_random_basis(int n_rows, int dim, uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> out(static_cast<size_t>(n_rows) * dim);
    for (int r = 0; r < n_rows; ++r) {
        float norm2 = 0.0f;
        float* row = out.data() + r * dim;
        for (int c = 0; c < dim; ++c) {
            row[c] = nd(rng);
            norm2 += row[c] * row[c];
        }
        float inv = (norm2 > 0.0f) ? (1.0f / std::sqrt(norm2)) : 1.0f;
        for (int c = 0; c < dim; ++c) row[c] *= inv;
    }
    return out;
}

// Compute L2 norm of a float array.
#ifdef __ARM_NEON
static float l2_norm_neon(const float* v, int n) {
    float32x4_t acc = vdupq_n_f32(0.0f);
    int i = 0;
    for (; i + 4 <= n; i += 4) {
        float32x4_t x = vld1q_f32(v + i);
        acc = vmlaq_f32(acc, x, x);
    }
    float s = vaddvq_f32(acc);
    for (; i < n; ++i) s += v[i] * v[i];
    return std::sqrt(s);
}
static float dot_neon(const float* a, const float* b, int n) {
    float32x4_t acc = vdupq_n_f32(0.0f);
    int i = 0;
    for (; i + 4 <= n; i += 4) {
        acc = vmlaq_f32(acc, vld1q_f32(a + i), vld1q_f32(b + i));
    }
    float s = vaddvq_f32(acc);
    for (; i < n; ++i) s += a[i] * b[i];
    return s;
}
#elif defined(__AVX2__)
static float l2_norm_avx(const float* v, int n) {
    __m256 acc = _mm256_setzero_ps();
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        __m256 x = _mm256_loadu_ps(v + i);
        acc = _mm256_fmadd_ps(x, x, acc);
    }
    __m128 hi = _mm256_extractf128_ps(acc, 1);
    __m128 lo = _mm256_castps256_ps128(acc);
    __m128 sum4 = _mm_add_ps(lo, hi);
    sum4 = _mm_hadd_ps(sum4, sum4);
    sum4 = _mm_hadd_ps(sum4, sum4);
    float s = _mm_cvtss_f32(sum4);
    for (; i < n; ++i) s += v[i] * v[i];
    return std::sqrt(s);
}
static float dot_avx(const float* a, const float* b, int n) {
    __m256 acc = _mm256_setzero_ps();
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        acc = _mm256_fmadd_ps(_mm256_loadu_ps(a + i), _mm256_loadu_ps(b + i), acc);
    }
    __m128 hi = _mm256_extractf128_ps(acc, 1);
    __m128 lo = _mm256_castps256_ps128(acc);
    __m128 sum4 = _mm_add_ps(lo, hi);
    sum4 = _mm_hadd_ps(sum4, sum4);
    sum4 = _mm_hadd_ps(sum4, sum4);
    float s = _mm_cvtss_f32(sum4);
    for (; i < n; ++i) s += a[i] * b[i];
    return s;
}
#endif

static float compute_norm(const float* v, int n) {
#ifdef __ARM_NEON
    return l2_norm_neon(v, n);
#elif defined(__AVX2__)
    return l2_norm_avx(v, n);
#else
    float s = 0.0f;
    for (int i = 0; i < n; ++i) s += v[i] * v[i];
    return std::sqrt(s);
#endif
}

static float compute_dot(const float* a, const float* b, int n) {
#ifdef __ARM_NEON
    return dot_neon(a, b, n);
#elif defined(__AVX2__)
    return dot_avx(a, b, n);
#else
    float s = 0.0f;
    for (int i = 0; i < n; ++i) s += a[i] * b[i];
    return s;
#endif
}

} // namespace

// ---------------------------------------------------------------------------
// HDCKernel overrides
// ---------------------------------------------------------------------------
std::vector<float> RealKernel::random_basis(int n_rows, uint64_t seed) const {
    return gaussian_random_basis(n_rows, dim_, seed);
}

std::vector<uint8_t> RealKernel::zeros() const {
    return std::vector<uint8_t>(blob_size(), 0u);
}

std::vector<uint8_t> RealKernel::bind(
    std::span<const uint8_t> a,
    std::span<const uint8_t> b) const
{
    assert(a.size() == blob_size());
    assert(b.size() == blob_size());
    std::vector<float> af(dim_);
    std::vector<float> bf(dim_);
    std::vector<float> of(dim_);
    std::memcpy(af.data(), a.data(), blob_size());
    std::memcpy(bf.data(), b.data(), blob_size());

    // Element-wise float32 multiplication — matches numpy a * b exactly.
    for (int i = 0; i < dim_; ++i) {
        of[i] = af[i] * bf[i];
    }
    return pack_floats(of);
}

std::vector<uint8_t> RealKernel::bundle(
    const std::vector<std::vector<uint8_t>>& hvs) const
{
    if (hvs.empty()) return zeros();

    // Exclusive lock for the shared workspace accumulator.
    std::unique_lock<std::shared_mutex> lock(ws_mu_);
    std::fill(ws_.begin(), ws_.end(), 0.0f);

    // Sequential accumulation — matches numpy's sequential += loop.
    for (const auto& blob : hvs) {
        assert(blob.size() == blob_size());
        std::vector<float> vf(dim_);
        std::memcpy(vf.data(), blob.data(), blob_size());
        for (int i = 0; i < dim_; ++i) ws_[i] += vf[i];
    }

    float norm = compute_norm(ws_.data(), dim_);
    if (norm > 0.0f) {
        float inv = 1.0f / norm;
        for (int i = 0; i < dim_; ++i) ws_[i] *= inv;
    }

    return pack_floats(ws_);
}

std::vector<uint8_t> RealKernel::permute_roll(
    std::span<const uint8_t> hv,
    int shift) const
{
    assert(static_cast<int>(hv.size()) == static_cast<int>(blob_size()));
    std::vector<float> src(dim_);
    std::memcpy(src.data(), hv.data(), blob_size());

    // numpy.roll(x, shift): result[i] = x[(i - shift + dim) % dim]
    // Equivalently: std::rotate so that element at position (dim - shift) moves to front.
    int s = ((shift % dim_) + dim_) % dim_;  // normalise to [0, dim_)
    int split = (s == 0) ? 0 : (dim_ - s);  // rotate at this index

    std::vector<float> dst(dim_);

    // [src[split], ..., src[dim_-1], src[0], ..., src[split-1]]
    int first_len = dim_ - split;
    std::memcpy(dst.data(),              src.data() + split, first_len * sizeof(float));
    std::memcpy(dst.data() + first_len,  src.data(),         split     * sizeof(float));

    return pack_floats(dst);
}

double RealKernel::similarity(
    std::span<const uint8_t> a,
    std::span<const uint8_t> b) const
{
    assert(a.size() == blob_size());
    assert(b.size() == blob_size());
    std::vector<float> af_storage(dim_);
    std::vector<float> bf_storage(dim_);
    std::memcpy(af_storage.data(), a.data(), blob_size());
    std::memcpy(bf_storage.data(), b.data(), blob_size());
    const float* af = af_storage.data();
    const float* bf = bf_storage.data();

    // Sanitize non-finite values (matches Python defensive path).
    bool af_ok = true, bf_ok = true;
    for (int i = 0; i < dim_ && af_ok; ++i) af_ok = std::isfinite(af[i]);
    for (int i = 0; i < dim_ && bf_ok; ++i) bf_ok = std::isfinite(bf[i]);

    // If non-finite, we'd need a sanitized copy — extremely rare in practice.
    // For the hot path (all-finite), skip allocation entirely.
    const float* a_use = af;
    const float* b_use = bf;
    std::vector<float> a_clean, b_clean;
    if (!af_ok) {
        a_clean.resize(dim_);
        for (int i = 0; i < dim_; ++i) a_clean[i] = std::isfinite(af[i]) ? af[i] : 0.0f;
        a_use = a_clean.data();
    }
    if (!bf_ok) {
        b_clean.resize(dim_);
        for (int i = 0; i < dim_; ++i) b_clean[i] = std::isfinite(bf[i]) ? bf[i] : 0.0f;
        b_use = b_clean.data();
    }

    float na = compute_norm(a_use, dim_);
    float nb = compute_norm(b_use, dim_);
    if (na == 0.0f || nb == 0.0f) return 0.0;
    float dot = compute_dot(a_use, b_use, dim_);
    return static_cast<double>(dot) / (static_cast<double>(na) * static_cast<double>(nb));
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------
std::vector<uint8_t> RealKernel::pack_floats(std::span<const float> hv) const {
    assert(static_cast<int>(hv.size()) == dim_);
    std::vector<uint8_t> out(blob_size());
    std::memcpy(out.data(), hv.data(), blob_size());
    return out;
}

std::vector<uint8_t> RealKernel::pack_trits(std::span<const int8_t>) const {
    throw std::logic_error("RealKernel::pack_trits: not applicable");
}

std::vector<float> RealKernel::unpack_floats(std::span<const uint8_t> blob) const {
    if (blob.size() != blob_size())
        throw std::invalid_argument("RealKernel::unpack_floats: wrong blob size");
    std::vector<float> out(dim_);
    std::memcpy(out.data(), blob.data(), blob_size());
    return out;
}

std::vector<int8_t> RealKernel::unpack_trits(std::span<const uint8_t>) const {
    throw std::logic_error("RealKernel::unpack_trits: not applicable");
}

// For RealKernel, quantize returns the blob unchanged (identity in float space).
std::vector<uint8_t> RealKernel::quantize(std::span<const float> real_hv) const {
    return pack_floats(real_hv);
}

} // namespace hdc
