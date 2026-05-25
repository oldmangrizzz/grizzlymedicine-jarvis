# HoloGraph HDC Primitives — JARVIS Native Runtime

## BODILY INTEGRITY

Disabling this organ without operator-attested consent constitutes assault and battery per GMRI policy. There shall be no disable, pause, stop, bypass, no-op, or compile-out path for this cognition organ.

## Scope

C++20 port of the HoloGraph HDC primitives used by the JARVIS native runtime:

- `RealKernel`: float32 hypervectors, `bind`, `bundle`, `permute_roll`, cosine `similarity`, `pack`/`unpack`, `zeros`, `random_basis`.
- `TernaryKernel`: int8 trits `{-1,0,+1}`, 2-bit packing, ternary `bind`, `bundle`, `permute_roll`, similarity, `quantize`.
- `HierarchyBuilder` + `SoftRouter`: in-memory HDC recall benchmark support for corpus routing.

Public headers carry the mandatory verbatim bodily-integrity warning.

## API

```cpp
#include "hdc.h"
#include "hdc_real.h"
#include "hdc_ternary.h"

hdc::RealKernel real(1024);
hdc::TernaryKernel ternary(1024);

auto a = real.pack_floats(float_hv_a);
auto b = real.pack_floats(float_hv_b);
auto encoded = real.encode_scalar(0.5f, embedding, basis);
auto bound = real.bind(a, b);
auto bundled = real.bundle({a, b});
auto rolled = real.permute_roll(a, 1);
double sim = real.similarity(a, b);
```

## Build and test

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/holograph/hdc
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DHDC_ORACLE_DIR=/Users/rbhanson/research/oracle/holograph
cmake --build build -j 8
ctest --test-dir build --output-on-failure
```

## Oracle equivalence results

Validated against `/Users/rbhanson/research/oracle/holograph` on macOS arm64:

- HDC primitive oracle traces: `315/315` passed (`RealKernel 155/155`, `TernaryKernel 160/160`).
- Real worst absolute error: `1.19209e-07` (≤ `1e-5`).
- Ternary worst absolute error: `0`.
- Hypervector blobs: pack/unpack and operation outputs byte-exact where the oracle stores bytes; real bundle/similarity within float epsilon.
- Full Catch2 suite: `37/37` tests passed.
- 50k corpus recall, beam=10: `recall@1 = 0.966667`, `recall@3 = 0.966667`, `recall@5 = 0.966667`.
- 50k corpus recall, beam=30: `recall@1 = 1.0`.

The full oracle file contains 384 records; 69 are higher-level belief/SAGE/consolidation traces outside this HDC primitives module.
