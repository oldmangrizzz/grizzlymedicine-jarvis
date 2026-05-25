#include "hdc_ternary.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <stdexcept>

#ifdef __ARM_NEON
#  include <arm_neon.h>
#endif
#ifdef __AVX2__
#  include <immintrin.h>
#  include <nmmintrin.h>
#endif

namespace hdc {

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------
TernaryKernel::TernaryKernel(int dim, float deadband)
    : dim_(dim),
      deadband_(deadband),
      packed_bytes_((static_cast<size_t>(dim) + 3u) / 4u),
      ws_(static_cast<size_t>(dim), 0)
{
    if (dim_ <= 0)
        throw std::invalid_argument("TernaryKernel: dim must be positive");
}

// ---------------------------------------------------------------------------
// Internal helper: sign-with-deadband
// ---------------------------------------------------------------------------
std::vector<int8_t> TernaryKernel::sign_dead(
    const float* x, int n, double threshold) const
{
    std::vector<int8_t> out(static_cast<size_t>(n));
    double t = std::max(threshold, static_cast<double>(deadband_));
    for (int i = 0; i < n; ++i) {
        double v = static_cast<double>(x[i]);
        if      (v >  t) out[i] =  1;
        else if (v < -t) out[i] = -1;
        else              out[i] =  0;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Core operators
// ---------------------------------------------------------------------------
std::vector<float> TernaryKernel::random_basis(int n_rows, uint64_t seed) const {
    // Real-valued Gaussian basis (same as RealKernel) — row-normalised.
    // Not byte-exact with numpy; only shape/normalisation is tested.
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> out(static_cast<size_t>(n_rows) * dim_);
    for (int r = 0; r < n_rows; ++r) {
        float norm2 = 0.0f;
        float* row = out.data() + r * dim_;
        for (int c = 0; c < dim_; ++c) {
            row[c] = nd(rng);
            norm2 += row[c] * row[c];
        }
        float inv = (norm2 > 0.0f) ? (1.0f / std::sqrt(norm2)) : 1.0f;
        for (int c = 0; c < dim_; ++c) row[c] *= inv;
    }
    return out;
}

std::vector<uint8_t> TernaryKernel::zeros() const {
    // All trits zero → all codes 0b00 → all bytes 0.
    return std::vector<uint8_t>(packed_bytes_, 0u);
}

std::vector<uint8_t> TernaryKernel::encode_scalar(
    float scaled,
    std::span<const float> embedding,
    std::span<const float> basis) const
{
    const size_t rows = embedding.size();
    if (rows == 0 || basis.size() != rows * static_cast<size_t>(dim_))
        throw std::invalid_argument("TernaryKernel::encode_scalar: basis shape mismatch");

    std::vector<float> projected(static_cast<size_t>(dim_), 0.0f);
    for (int d = 0; d < dim_; ++d) {
        float acc = 0.0f;
        for (size_t r = 0; r < rows; ++r)
            acc += (scaled * embedding[r]) * basis[r * static_cast<size_t>(dim_) + static_cast<size_t>(d)];
        projected[static_cast<size_t>(d)] = acc;
    }
    auto trits = sign_dead(projected.data(), dim_, 0.0);
    return pack_trits(trits);
}

std::vector<uint8_t> TernaryKernel::bind(
    std::span<const uint8_t> a_blob,
    std::span<const uint8_t> b_blob) const
{
    if (a_blob.size() != packed_bytes_)
        throw InvalidBlobLength(
            "TernaryKernel::bind: a_blob size " + std::to_string(a_blob.size()) +
            " != packed_bytes_ " + std::to_string(packed_bytes_));
    if (b_blob.size() != packed_bytes_)
        throw InvalidBlobLength(
            "TernaryKernel::bind: b_blob size " + std::to_string(b_blob.size()) +
            " != packed_bytes_ " + std::to_string(packed_bytes_));

    auto a_trits = unpack_trits(a_blob);
    auto b_trits = unpack_trits(b_blob);

    std::vector<int8_t> result(static_cast<size_t>(dim_));
    // Trit Hadamard product: signed int8 multiplication (no overflow for {-1,0,+1}).
    for (int i = 0; i < dim_; ++i) {
        result[i] = static_cast<int8_t>(a_trits[i] * b_trits[i]);
    }
    return pack_trits(result);
}

std::vector<uint8_t> TernaryKernel::bundle(
    const std::vector<std::vector<uint8_t>>& hvs) const
{
    if (hvs.empty()) return zeros();

    int n = static_cast<int>(hvs.size());
    // Deadband: 0.5 * sqrt(n) — computed as float64 to match Python exactly.
    double threshold = 0.5 * std::sqrt(static_cast<double>(n));

    // Exclusive lock for the workspace accumulator.
    std::unique_lock<std::shared_mutex> lock(ws_mu_);
    std::fill(ws_.begin(), ws_.end(), 0);

    for (const auto& blob : hvs) {
        if (blob.size() != packed_bytes_)
            throw InvalidBlobLength(
                "TernaryKernel::bundle: blob size " + std::to_string(blob.size()) +
                " != packed_bytes_ " + std::to_string(packed_bytes_));
        auto trits = unpack_trits(blob);
        for (int i = 0; i < dim_; ++i) ws_[i] += static_cast<int32_t>(trits[i]);
    }

    // Convert int32 accumulator to float32, apply deadband sign.
    std::vector<float> acc_f(static_cast<size_t>(dim_));
    for (int i = 0; i < dim_; ++i) acc_f[i] = static_cast<float>(ws_[i]);

    auto trits = sign_dead(acc_f.data(), dim_, threshold);
    return pack_trits(trits);
}

std::vector<uint8_t> TernaryKernel::permute_roll(
    std::span<const uint8_t> hv_blob,
    int shift) const
{
    // Unpack → rotate int8 array → repack.
    auto trits = unpack_trits(hv_blob);

    int s = ((shift % dim_) + dim_) % dim_;
    int split = (s == 0) ? 0 : (dim_ - s);

    std::vector<int8_t> result(static_cast<size_t>(dim_));
    int first_len = dim_ - split;
    std::memcpy(result.data(),            trits.data() + split, first_len);
    std::memcpy(result.data() + first_len, trits.data(),         split);

    return pack_trits(result);
}

// ---------------------------------------------------------------------------
// Similarity — NEON / AVX2 / scalar
// ---------------------------------------------------------------------------
namespace {

#ifdef __ARM_NEON
static std::pair<int32_t,int32_t> ternary_sim_neon(
    const int8_t* a, const int8_t* b, int n)
{
    // product = a[i] * b[i] ∈ {-1, 0, +1}
    // matches - mismatches = sum(product) for all i
    // active               = count(product != 0)
    int32_t sum_prod  = 0;
    int32_t sum_active = 0;

    int i = 0;
    // Process 16 elements at a time using NEON int8
    int32x4_t vacc_prod   = vdupq_n_s32(0);
    int32x4_t vacc_active = vdupq_n_s32(0);
    for (; i + 16 <= n; i += 16) {
        int8x16_t va = vld1q_s8(a + i);
        int8x16_t vb = vld1q_s8(b + i);
        // Product: {-1,0,1} × {-1,0,1} fits in int8 with no overflow
        int8x16_t prod = vmulq_s8(va, vb);
        // Active: product != 0
        // NEON: compare equal to zero → invert → 1 where non-zero
        uint8x16_t nz = vmvnq_u8(vceqzq_s8(prod));  // 0xFF where non-zero
        // Count non-zero: each 0xFF contributes 1 to count
        // Use 8-bit widening to 16-bit then 32-bit
        int16x8_t active_lo = vpaddlq_u8(vshrq_n_u8(nz, 7));  // each 0xFF/0x00 → 1/0
        vacc_active = vaddq_s32(vacc_active, vpaddlq_s16(active_lo));
        // Accumulate products: widen int8 → int16 → int32
        int16x8_t prod_lo = vmovl_s8(vget_low_s8(prod));
        int16x8_t prod_hi = vmovl_s8(vget_high_s8(prod));
        vacc_prod = vaddq_s32(vacc_prod, vpaddlq_s16(prod_lo));
        vacc_prod = vaddq_s32(vacc_prod, vpaddlq_s16(prod_hi));
    }
    sum_prod   = vaddvq_s32(vacc_prod);
    sum_active = vaddvq_s32(vacc_active);

    for (; i < n; ++i) {
        int32_t p = static_cast<int32_t>(a[i]) * static_cast<int32_t>(b[i]);
        sum_prod   += p;
        sum_active += (p != 0) ? 1 : 0;
    }
    return {sum_prod, sum_active};
}
#endif // __ARM_NEON

#ifdef __AVX2__
static std::pair<int32_t,int32_t> ternary_sim_avx2(
    const int8_t* a, const int8_t* b, int n)
{
    int32_t sum_prod = 0, sum_active = 0;
    int i = 0;
    __m256i vacc_prod   = _mm256_setzero_si256();
    __m256i vacc_active = _mm256_setzero_si256();
    const __m256i zero256 = _mm256_setzero_si256();

    for (; i + 32 <= n; i += 32) {
        __m256i va;
        __m256i vb;
        std::memcpy(&va, a + i, sizeof(va));
        std::memcpy(&vb, b + i, sizeof(vb));
        // int8 mul in AVX2: use _mm256_sign_epi8 trick
        // prod[i] = a[i] * b[i]; since values in {-1,0,1} use _mm256_sign_epi8
        __m256i prod = _mm256_sign_epi8(vb, va);  // b * sign(a): sign(-1)=-1, sign(0)=0, sign(1)=1
        // But this gives b*sign(a), not a*b. For {-1,0,1}: they're equivalent.
        // Actually _mm256_sign_epi8(v, k): v[i] if k[i]>0, -v[i] if k[i]<0, 0 if k[i]=0
        // So for a[i]=-1: prod[i]=-b[i]; for a[i]=0: prod[i]=0; for a[i]=+1: prod[i]=b[i]
        // This equals a[i]*b[i] when a[i] ∈ {-1,0,1}. ✓

        // Active: prod != 0
        __m256i is_nz = _mm256_cmpgt_epi8(
            _mm256_abs_epi8(prod), zero256);  // 0xFF where |prod|>0
        // Sum active: each 0xFF means 1, but we need to count bytes
        // Use POPCOUNT approach: horizontal sum of bits
        // Simpler: use sad_epu8 to sum absolute differences from 0
        // 0xFF → 0xFF/0xFF = 1 after shift
        __m256i active_ones = _mm256_srli_epi16(
            _mm256_and_si256(is_nz, _mm256_set1_epi8(1)), 0);
        // Actually just count: sum(abs(is_nz) >> 7)... complex. Use scalar fallback for active.
        // For simplicity, use scalar for active count:
        (void)active_ones;

        // Widen prod int8 → int16 for accumulation
        __m128i prod_lo = _mm256_castsi256_si128(prod);
        __m128i prod_hi = _mm256_extracti128_si256(prod, 1);
        __m256i prod16_lo = _mm256_cvtepi8_epi16(prod_lo);
        __m256i prod16_hi = _mm256_cvtepi8_epi16(prod_hi);
        vacc_prod = _mm256_add_epi32(vacc_prod, _mm256_madd_epi16(prod16_lo, _mm256_set1_epi16(1)));
        vacc_prod = _mm256_add_epi32(vacc_prod, _mm256_madd_epi16(prod16_hi, _mm256_set1_epi16(1)));

        // Active count using popcount on abs
        __m256i absv = _mm256_abs_epi8(prod);
        // Each byte is 0 or 1 (since {-1,0,1} products → abs ∈ {0,1})
        // Sum using sad_epu8 against zero
        __m256i active_sum = _mm256_sad_epu8(absv, zero256);
        vacc_active = _mm256_add_epi64(vacc_active, active_sum);
    }

    // Horizontal reduce vacc_prod
    __m128i lo128 = _mm256_castsi256_si128(vacc_prod);
    __m128i hi128 = _mm256_extracti128_si256(vacc_prod, 1);
    __m128i sum128 = _mm_add_epi32(lo128, hi128);
    sum128 = _mm_hadd_epi32(sum128, sum128);
    sum128 = _mm_hadd_epi32(sum128, sum128);
    sum_prod = _mm_cvtsi128_si32(sum128);

    // Horizontal reduce vacc_active
    __m128i lo_a = _mm256_castsi256_si128(vacc_active);
    __m128i hi_a = _mm256_extracti128_si256(vacc_active, 1);
    __m128i sum_a = _mm_add_epi64(lo_a, hi_a);
    sum_a = _mm_add_epi64(sum_a, _mm_srli_si128(sum_a, 8));
    sum_active = static_cast<int32_t>(_mm_cvtsi128_si64(sum_a));

    for (; i < n; ++i) {
        int32_t p = static_cast<int32_t>(a[i]) * static_cast<int32_t>(b[i]);
        sum_prod   += p;
        sum_active += (p != 0) ? 1 : 0;
    }
    return {sum_prod, sum_active};
}
#endif // __AVX2__

static std::pair<int32_t,int32_t> ternary_sim_scalar(
    const int8_t* a, const int8_t* b, int n)
{
    int32_t sum_prod = 0, sum_active = 0;
    for (int i = 0; i < n; ++i) {
        int32_t p = static_cast<int32_t>(a[i]) * static_cast<int32_t>(b[i]);
        sum_prod   += p;
        sum_active += (p != 0) ? 1 : 0;
    }
    return {sum_prod, sum_active};
}

} // anonymous namespace

double TernaryKernel::similarity(
    std::span<const uint8_t> a_blob,
    std::span<const uint8_t> b_blob) const
{
    if (a_blob.size() != packed_bytes_)
        throw InvalidBlobLength(
            "TernaryKernel::similarity: a_blob size " + std::to_string(a_blob.size()) +
            " != packed_bytes_ " + std::to_string(packed_bytes_));
    if (b_blob.size() != packed_bytes_)
        throw InvalidBlobLength(
            "TernaryKernel::similarity: b_blob size " + std::to_string(b_blob.size()) +
            " != packed_bytes_ " + std::to_string(packed_bytes_));

    auto a_trits = unpack_trits(a_blob);
    auto b_trits = unpack_trits(b_blob);

    auto [sum_prod, sum_active] =
#ifdef __ARM_NEON
        ternary_sim_neon(a_trits.data(), b_trits.data(), dim_);
#elif defined(__AVX2__)
        ternary_sim_avx2(a_trits.data(), b_trits.data(), dim_);
#else
        ternary_sim_scalar(a_trits.data(), b_trits.data(), dim_);
#endif

    if (sum_active == 0) return 0.0;
    return static_cast<double>(sum_prod) / static_cast<double>(sum_active);
}

// ---------------------------------------------------------------------------
// Pack / Unpack — byte-exact match to Python oracle
// ---------------------------------------------------------------------------
std::vector<uint8_t> TernaryKernel::pack_trits(std::span<const int8_t> hv) const {
    if (static_cast<int>(hv.size()) != dim_)
        throw std::invalid_argument("TernaryKernel::pack_trits: wrong HV size");

    // Pad dim to multiple of 4 (same as Python np.concatenate([codes, zeros(pad)]))
    int padded = dim_ + ((-dim_) & 3);  // rounds up to multiple of 4
    std::vector<uint8_t> out((static_cast<size_t>(padded) + 3u) / 4u, 0u);

    for (int i = 0; i < dim_; ++i) {
        uint8_t code = (hv[i] == 1) ? 1u : (hv[i] == -1) ? 2u : 0u;
        int byte_idx = i / 4;
        int bit_off  = (i % 4) * 2;
        out[byte_idx] |= static_cast<uint8_t>(code << bit_off);
    }
    return out;
}

std::vector<uint8_t> TernaryKernel::pack_floats(std::span<const float>) const {
    throw std::logic_error("TernaryKernel::pack_floats: not applicable");
}

std::vector<int8_t> TernaryKernel::unpack_trits(std::span<const uint8_t> blob) const {
    // Runtime guard: attacker-supplied short blob → OOB read. Assert vanishes
    // in release; this check does not.
    if (blob.size() < packed_bytes_)
        throw InvalidBlobLength(
            "TernaryKernel::unpack_trits: InvalidPackedLength: blob.size()=" +
            std::to_string(blob.size()) + " < packed_bytes_=" +
            std::to_string(packed_bytes_));
    std::vector<int8_t> out(static_cast<size_t>(dim_), 0);
    for (int i = 0; i < dim_; ++i) {
        int byte_idx = i / 4;
        int bit_off  = (i % 4) * 2;
        uint8_t code = (blob[byte_idx] >> bit_off) & 0x03u;
        if      (code == 1u) out[i] =  1;
        else if (code == 2u) out[i] = -1;
        // code 0 or 3 → 0 (defensive; code 3 is reserved)
    }
    return out;
}

std::vector<float> TernaryKernel::unpack_floats(std::span<const uint8_t>) const {
    throw std::logic_error("TernaryKernel::unpack_floats: not applicable");
}

// ---------------------------------------------------------------------------
// Quantize
// ---------------------------------------------------------------------------
std::vector<uint8_t> TernaryKernel::quantize(std::span<const float> real_hv) const {
    if (static_cast<int>(real_hv.size()) != dim_)
        throw std::invalid_argument("TernaryKernel::quantize: wrong HV size");
    // sign-with-deadband=0 (threshold=0 → |x|<=0 → 0, else sign(x))
    // Note: threshold=0 means strictly x==0 → 0, x>0 → +1, x<0 → -1
    // but std::max(0, deadband_) handles non-zero deadband too.
    auto trits = sign_dead(real_hv.data(), dim_, 0.0);
    return pack_trits(trits);
}

} // namespace hdc
