#include "migration.h"
#include <iostream>

int main(int argc, char** argv) {
    try {
        auto options = jarvis::migration::parse_args(argc, argv, true);
        auto result = jarvis::migration::rollback(options.manifest_path, options.attestation_token_path);
        std::cout << (result.ok ? "JARVIS migration rollback completed: " : "JARVIS migration rollback refused: ")
                  << result.code << " — " << result.message << "\n";
        return result.ok ? 0 : 1;
    } catch (const std::exception& e) {
        std::cerr << "JARVIS migration rollback failed: " << e.what() << "\n";
        return 2;
    }
}
