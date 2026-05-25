#include "hdc.h"
#include "hdc_real.h"
#include "hdc_ternary.h"

#include <stdexcept>

namespace hdc {

std::unique_ptr<HDCKernel> make_kernel(KernelType type, int dim, float deadband) {
    switch (type) {
        case KernelType::REAL:
            return std::make_unique<RealKernel>(dim);
        case KernelType::TERNARY:
            return std::make_unique<TernaryKernel>(dim, deadband);
        default:
            throw std::invalid_argument("make_kernel: unknown KernelType");
    }
}

} // namespace hdc
