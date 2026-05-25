/// run_all.cpp — Standalone oracle-equivalence runner.
///
/// Discovers every `test_oracle_equivalence` binary under a build directory,
/// runs them in sequence, aggregates exit codes, and exits 1 if ANY test
/// reported drift or failure.
///
/// Usage:
///   ./regression_run_all [--build-dir <path>] [--verbose] [--dry-run]
///
/// If --build-dir is omitted the executable's parent directory is used as
/// the root to search from (sensible when CTest invokes it from build/).
///
/// Note: this binary is intentionally NOT registered as a CTest test itself.
/// Run it standalone for quick local validation, or use
///   ctest -L regression --test-dir <build>
/// to run the suite via CTest with label filtering.

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

static bool is_executable(const fs::path& p) {
    if (!fs::is_regular_file(p)) return false;
#if defined(_WIN32)
    std::string ext = p.extension().string();
    return ext == ".exe" || ext == ".com";
#else
    auto perms = fs::status(p).permissions();
    return (perms & fs::perms::owner_exec) != fs::perms::none;
#endif
}

/// Return true if the filename matches an oracle equivalence test binary
/// (test_oracle_equivalence or test_holograph_153 or test_*_oracle*).
static bool is_regression_binary(const fs::path& p) {
    const std::string name = p.filename().string();
    if (name == "test_oracle_equivalence")   return true;
    if (name == "test_holograph_153")        return true;
    // Allow "test_oracle_equivalence.exe" on Windows.
    if (name.find("test_oracle_equivalence") == 0 && name.size() < 40) return true;
    if (name.find("test_holograph_153")      == 0 && name.size() < 40) return true;
    return false;
}

/// Recursively find regression binaries under root.
static std::vector<fs::path> find_binaries(const fs::path& root) {
    std::vector<fs::path> found;
    if (!fs::exists(root)) return found;
    for (const auto& entry : fs::recursive_directory_iterator(root,
             fs::directory_options::skip_permission_denied)) {
        if (entry.is_regular_file()
                && is_regression_binary(entry.path())
                && is_executable(entry.path())) {
            found.push_back(entry.path());
        }
    }
    std::sort(found.begin(), found.end());
    return found;
}

int main(int argc, char** argv) {
    std::string build_dir;
    bool verbose  = false;
    bool dry_run  = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--verbose" || arg == "-v") {
            verbose = true;
        } else if (arg == "--dry-run") {
            dry_run = true;
        } else if ((arg == "--build-dir" || arg == "-B") && i + 1 < argc) {
            build_dir = argv[++i];
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: regression_run_all [--build-dir <path>] [--verbose] [--dry-run]\n"
                      << "\n"
                      << "  --build-dir <path>  Root of the CMake build tree to search for test binaries.\n"
                      << "                      Default: directory containing this executable.\n"
                      << "  --verbose, -v       Print test output even on success.\n"
                      << "  --dry-run           List binaries that would be run without executing them.\n"
                      << "\n"
                      << "Discovers every oracle equivalence binary under the build tree,\n"
                      << "runs each, and exits 1 if ANY binary reports drift > 1e-9 or failure.\n"
                      << "\n"
                      << "Equivalent CTest invocation:\n"
                      << "  ctest -L regression --test-dir <build> --output-on-failure\n";
            return 0;
        }
    }

    // Default build dir: directory containing this binary.
    if (build_dir.empty()) {
        fs::path self(argv[0]);
        build_dir = self.parent_path().string();
        if (build_dir.empty()) build_dir = ".";
    }

    std::cout << "=== JARVIS Oracle Regression Runner ===\n"
              << "  search root: " << build_dir << "\n\n";

    auto binaries = find_binaries(build_dir);
    if (binaries.empty()) {
        std::cout << "WARNING: No oracle equivalence test binaries found under " << build_dir << "\n"
                  << "  Expected binaries: test_oracle_equivalence, test_holograph_153\n"
                  << "  Have you built the project?  Run: cmake --build <build_dir>\n";
        return 1;
    }

    std::cout << "Found " << binaries.size() << " oracle equivalence binary/binaries:\n";
    for (const auto& b : binaries) std::cout << "  " << b << "\n";
    std::cout << "\n";

    if (dry_run) {
        std::cout << "[dry-run] skipping execution\n";
        return 0;
    }

    int failures = 0;
    for (const auto& bin : binaries) {
        std::cout << "── Running: " << bin.filename() << " ──\n";
        std::string cmd = "\"" + bin.string() + "\"";
        if (!verbose) cmd += " --reporter compact";
        int ret = std::system(cmd.c_str());
        if (ret != 0) {
            ++failures;
            std::cout << "  FAILED  (exit " << ret << ")\n\n";
        } else {
            std::cout << "  PASSED\n\n";
        }
    }

    std::cout << "══════════════════════════════════════\n";
    if (failures == 0) {
        std::cout << "All " << binaries.size() << " oracle equivalence test(s) PASSED.  drift ≤ 1e-9\n";
        return 0;
    } else {
        std::cout << failures << " of " << binaries.size() << " oracle equivalence test(s) FAILED.\n";
        return 1;
    }
}
