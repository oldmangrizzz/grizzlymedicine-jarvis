/// equivalence_assertions.h — assert_close family for oracle regression tests.
///
/// All functions use Catch2 macros (INFO, REQUIRE, FAIL) and must be called
/// inside a Catch2 TEST_CASE or SECTION.
///
/// Tolerances:
///   abs mode:  |expected - actual| ≤ tol
///   rel mode:  |expected - actual| / max(|expected|, 1e-30) ≤ tol
///
/// Per-row diagnostics: every failure prints the row index, column name,
/// expected, actual, and computed error so a drift hunt is productive.
#pragma once

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include <cmath>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace jarvis::oracle {

enum class TolMode { ABS, REL };

/// Check a single scalar comparison; emit per-row diagnostics on failure.
inline void assert_close(double expected, double actual, double tol,
                         TolMode mode,
                         const std::string& context) {
    double err;
    if (mode == TolMode::ABS) {
        err = std::abs(expected - actual);
    } else {
        double denom = std::max(std::abs(expected), 1e-30);
        err = std::abs(expected - actual) / denom;
    }
    if (err > tol) {
        std::ostringstream msg;
        msg << context
            << "  expected=" << expected
            << "  actual="   << actual
            << "  err=" << err
            << "  tol=" << tol
            << "  mode=" << (mode == TolMode::ABS ? "abs" : "rel");
        FAIL(msg.str());
    }
}

/// Shorthand absolute tolerance check.
inline void assert_close_abs(double expected, double actual, double tol,
                              const std::string& context = "") {
    assert_close(expected, actual, tol, TolMode::ABS, context);
}

/// Shorthand relative tolerance check.
inline void assert_close_rel(double expected, double actual, double tol,
                              const std::string& context = "") {
    assert_close(expected, actual, tol, TolMode::REL, context);
}

/// Check every element of two float32 vectors at absolute tolerance.
inline void assert_vectors_close(const std::vector<float>& expected,
                                 const std::vector<float>& actual,
                                 float tol,
                                 const std::string& context = "") {
    if (expected.size() != actual.size()) {
        FAIL(context + " size mismatch: expected=" + std::to_string(expected.size())
             + " actual=" + std::to_string(actual.size()));
    }
    for (size_t i = 0; i < expected.size(); ++i) {
        float err = std::abs(expected[i] - actual[i]);
        if (err > tol) {
            std::ostringstream msg;
            msg << context << " [" << i << "]"
                << "  expected=" << expected[i]
                << "  actual="   << actual[i]
                << "  err=" << err
                << "  tol=" << tol;
            FAIL(msg.str());
        }
    }
}

/// Replay a sequence of (expected, actual) pairs from oracle CSV rows,
/// asserting absolute tolerance on every row.  Prints row index on failure.
template<typename GetExpected, typename GetActual>
void replay_csv_column(const std::vector<struct CsvRow>& rows,
                        GetExpected&& get_exp,
                        GetActual&&   get_act,
                        double tol,
                        const std::string& col_name) {
    for (size_t i = 0; i < rows.size(); ++i) {
        double exp_val = get_exp(rows[i]);
        double act_val = get_act(rows[i]);
        if (std::isnan(exp_val)) continue; // oracle did not record this row
        std::ostringstream ctx;
        ctx << "row " << i << " col=" << col_name
            << " t=" << rows[i].get("t");
        assert_close_abs(exp_val, act_val, tol, ctx.str());
    }
}

/// Assert an exact boolean equality with context.
inline void assert_bool_exact(bool expected, bool actual,
                               const std::string& context = "") {
    if (expected != actual) {
        FAIL(context + "  expected=" + (expected ? "true" : "false")
             + "  actual=" + (actual ? "true" : "false"));
    }
}

/// Assert that a float32 vector is all-finite (no NaN/Inf).
inline void assert_all_finite(const std::vector<float>& v,
                               const std::string& context = "") {
    for (size_t i = 0; i < v.size(); ++i) {
        if (!std::isfinite(v[i])) {
            FAIL(context + " [" + std::to_string(i) + "] = "
                 + std::to_string(v[i]) + " (not finite)");
        }
    }
}

/// Assert that a float32 vector norm is within [lo, hi].
inline void assert_norm_in_range(const std::vector<float>& v,
                                  float lo, float hi,
                                  const std::string& context = "") {
    float sq = 0.f;
    for (float x : v) sq += x * x;
    float norm = std::sqrt(sq);
    if (norm < lo || norm > hi) {
        FAIL(context + "  norm=" + std::to_string(norm)
             + "  expected_range=[" + std::to_string(lo) + "," + std::to_string(hi) + "]");
    }
}

} // namespace jarvis::oracle
