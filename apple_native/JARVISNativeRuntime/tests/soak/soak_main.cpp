#include "soak_harness.h"

#include <iostream>

int main(int argc, char** argv) {
    auto config = jarvis::tests::soak::config_from_environment(argc, argv);
    auto result = jarvis::tests::soak::run_soak(config);
    jarvis::tests::soak::write_reports(result, config);

    std::cout << "JARVIS soak completed=" << (result.completed ? "true" : "false")
              << " passed=" << (result.passed ? "true" : "false")
              << " turns=" << result.turns
              << " faults=" << result.faults.size()
              << " violations=" << result.invariant_violations.size()
              << " gaps=" << result.gaps.size()
              << " report=" << result.operator_report_path << '\n';
    return result.passed ? 0 : 1;
}
