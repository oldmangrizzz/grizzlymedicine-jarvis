#include "migration.h"
#include <iostream>

int main(int argc, char** argv) {
    try {
        auto options = jarvis::migration::parse_args(argc, argv);
        auto result = jarvis::migration::run(options);
        std::cout << (result.ok ? "JARVIS migration runner completed: " : "JARVIS migration runner refused: ")
                  << result.code << " — " << result.message << "\n";
        if (!result.manifest_path.empty()) std::cout << "manifest=" << result.manifest_path << "\n";
        for (const auto& [table, count] : result.row_counts) std::cout << table << "=" << count << "\n";
        return result.ok ? 0 : 1;
    } catch (const std::exception& e) {
        std::cerr << "JARVIS migration runner failed: " << e.what() << "\n";
        return 2;
    }
}
