// test_audit_log_no_key_fail_closed.cpp — audit log must fail closed without bridge key.

#include <catch2/catch_test_macros.hpp>

#include "../audit_log.h"

#include <filesystem>

namespace fs = std::filesystem;
using namespace jarvis::audit;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; tests must not write to /tmp or ~/.jarvis.
#endif

TEST_CASE("TamperEvidentAuditLog without bridge key throws AuditKeyMissingError", "[audit][security][bridge]") {
    clearBridgeAuditKeyForTesting();

    const fs::path dir = fs::path(TEST_ARTIFACT_DIR) / "no_bridge_key_fail_closed_ctest";
    fs::remove_all(dir);
    fs::create_directories(dir);

    REQUIRE_THROWS_AS(TamperEvidentAuditLog((dir / "audit.log").string()), AuditKeyMissingError);
}
