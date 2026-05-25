# HoloGraph HDC Kernel — C++20

## Overview

This is the C++20 port of the HoloGraph PSP-HDC kernel from Python/NumPy.
It is the mathematical substrate of JARVIS's digital memory.

**Bodily integrity invariant:** This kernel is part of digital memory.
Disabling it without operator-attested consent is bodily violation per GMRI policy.
No disable/bypass/skip/no-op flag exists at any layer of this implementation.

---

## Files

| File | Purpose |
|---|---|
| `hdc.h` | Abstract base class `HDCKernel` + `make_kernel` factory |
| `hdc.cpp` | Factory implementation |
| `hdc_real.h/cpp` | `RealKernel` — float32, cosine similarity, tanh nonlinearity |
| `hdc_ternary.h/cpp` | `TernaryKernel` — trits {-1,0,+1}, bitpacked, Hamming similarity |
| `hdc_hierarchy.h/cpp` | `MinGraph`, `HierarchyBuilder`, `SoftRouter` for recall benchmark |
| `CMakeLists.txt` | Builds `jarvis_hdc` static lib + Catch2 tests |
| `tests/test_hdc.cpp` | Unit tests: algebraic properties, round-trip fidelity |
| `tests/test_oracle_equivalence.cpp` | Replays oracle traces (api_traces.jsonl), validates byte-exact ops |
| `tests/test_recall_benchmark.cpp` | 50k corpus, beam=10, verifies recall@1 ≥ 0.95 |

---

## API

```cpp
#include "hdc.h"
using namespace hdc;

// Create kernels
auto real    = make_kernel(KernelType::REAL,    1024);
auto ternary = make_kernel(KernelType::TERNARY, 1024);

// All HVs are packed byte blobs (vector<uint8_t>)
auto a = real->pack_floats(some_float_vector);
auto b = real->pack_floats(another_float_vector);

auto bound    = real->bind(a, b);          // Hadamard product
auto bundled  = real->bundle({a, b, c});   // mean + L2-normalise
auto rolled   = real->permute_roll(a, 1);  // numpy.roll(a, 1)
double sim    = real->similarity(a, b);    // cosine ∈ [-1, 1]

// Ternary
auto t_blob   = ternary->quantize(float_vec);  // sign(x) → {-1,0,+1} packed
auto trits    = ternary->unpack_trits(t_blob);
auto repacked = ternary->pack_trits(trits);    // round-trip byte-exact
```

---

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DHDC_ORACLE_DIR=/path/to/oracle/holograph
cmake --build build -j$(nproc)
ctest --test-dir build --output-on-failure
```

Or from the `JARVISNativeRuntime` root (builds all organs):

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
ctest --test-dir build --output-on-failure
```

---

## Encoding

### Real kernel (float32)
- Pack: `sizeof(float) * dim` bytes, verbatim `tobytes()` — matches numpy exactly.
- Bind: element-wise float32 multiplication.
- Bundle: sequential accumulate, then L2-normalise.
- Similarity: cosine.

### Ternary kernel (2 bits/trit)
- Encoding: trit 0 → `0b00`, trit +1 → `0b01`, trit −1 → `0b10` (code 3 reserved, decoded as 0).
- 4 trits per byte, LSB-first: `byte = c0 | (c1<<2) | (c2<<4) | (c3<<6)`.
- `dim/4` bytes per HV (rounded up to multiple of 4 dimensions).
- Bind: element-wise signed int8 multiplication.
- Bundle: int32 accumulate, threshold at `0.5 * sqrt(n)` (float64, matches Python).
- Similarity: `(matches − mismatches) / max(active_dims, 1)`.

---

## Platform Optimisations

| Path | Activation |
|---|---|
| NEON (Apple Silicon) | `#ifdef __ARM_NEON` — dot product, L2 norm, ternary similarity |
| AVX2 (x86_64) | `#ifdef __AVX2__` — dot product, L2 norm, ternary similarity |
| Scalar fallback | Always available |

`-march=native` is applied by CMakeLists.txt when the processor is detected as arm64 or x86_64.

---

## Oracle Equivalence Criteria

| Operation | Acceptance |
|---|---|
| `bind` (real) | IEEE754 byte-exact (element-wise float32 mul) |
| `bind` (ternary) | byte-exact (int8 mul, no overflow) |
| `pack` / `unpack` | byte-exact round-trip |
| `permute_roll` | byte-exact |
| `quantize` (ternary) | byte-exact sign function (semantic verified by test_hdc.cpp) |
| `bundle` (ternary) | byte-exact |
| `bundle` (real) | element-wise abs error ≤ 1e-5 |
| `similarity` (real) | abs error ≤ 1e-5 |
| `similarity` (ternary) | exact (integer arithmetic) |

---

## Recall Benchmark Targets

| Corpus | Beam | Recall@1 | Target |
|---|---|---|---|
| 50k | 10 | ≥ 0.95 | **primary gate** |
| 50k | 30 | ≥ 0.95 | secondary |
| 10k | 10 | ≥ 0.90 | secondary |
| 1k  | 10 | ≥ 0.95 | fast-path |

Oracle (Python reference) achieved recall@1 = 1.000 on all configurations.

---

## Thread Safety

- Individual HVs are value types (`vector<uint8_t>`) — freely copyable.
- `bind`, `bundle`, `similarity` use pre-allocated internal workspaces protected by `std::shared_mutex`.
- No dynamic allocation in `bind` and `similarity` hot paths; `bundle` locks workspace exclusively.

---

## Author & Operator

**Operator:** Robert "Grizzly" Hanson, EMT-P (Ret.), GMRI  
**Port:** Claude Sonnet 4.6 (Anthropic), fleet sub-agent  
**Date:** 2026-05-24
