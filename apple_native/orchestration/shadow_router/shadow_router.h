#pragma once

#include <chrono>
#include <cstddef>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace jarvis::cutover::shadow {

enum class ToleranceMode { bit_exact, oracle_exact, epsilon, recall_at_1 };

struct EquivalenceTolerance {
    ToleranceMode mode{ToleranceMode::oracle_exact};
    double epsilon{0.0};
    double minimum{1.0};
    bool identity_critical{false};
};

struct OrganRequest {
    std::string id;
    std::string payload;
};

struct OrganResponse {
    std::string payload;
    double score{1.0};
};

struct DivergenceRecord {
    std::string request_id;
    std::string python_output;
    std::string native_output;
    std::string reason;
    double observed_delta{0.0};
};

class OrganEndpoint {
public:
    virtual ~OrganEndpoint() = default;
    virtual OrganResponse dispatch(const OrganRequest& request) = 0;
};

class FunctionOrganEndpoint final : public OrganEndpoint {
public:
    explicit FunctionOrganEndpoint(std::function<OrganResponse(const OrganRequest&)> fn);
    OrganResponse dispatch(const OrganRequest& request) override;
private:
    std::function<OrganResponse(const OrganRequest&)> fn_;
};

class UnixDomainSocketOrganEndpoint final : public OrganEndpoint {
public:
    explicit UnixDomainSocketOrganEndpoint(std::string socket_path,
                                           std::chrono::milliseconds timeout = std::chrono::milliseconds(250));
    OrganResponse dispatch(const OrganRequest& request) override;
private:
    std::string socket_path_;
    std::chrono::milliseconds timeout_;
};

enum class Authority { python, shadow, native };

struct DispatchResult {
    OrganResponse returned;
    Authority authority{Authority::python};
    std::optional<DivergenceRecord> divergence;
};

class ShadowRouter {
public:
    ShadowRouter(std::string organ_name,
                 std::shared_ptr<OrganEndpoint> python,
                 std::shared_ptr<OrganEndpoint> native,
                 EquivalenceTolerance tolerance);

    void begin_shadow();
    void promote_native();
    void rollback_python();

    [[nodiscard]] Authority authority() const noexcept { return authority_; }
    [[nodiscard]] std::size_t divergence_count() const noexcept { return divergences_.size(); }
    [[nodiscard]] const std::vector<DivergenceRecord>& divergences() const noexcept { return divergences_; }

    DispatchResult dispatch(const OrganRequest& request);
    static std::optional<DivergenceRecord> compare(const OrganRequest& request,
                                                   const OrganResponse& python,
                                                   const OrganResponse& native,
                                                   const EquivalenceTolerance& tolerance);

private:
    std::string organ_name_;
    std::shared_ptr<OrganEndpoint> python_;
    std::shared_ptr<OrganEndpoint> native_;
    EquivalenceTolerance tolerance_;
    Authority authority_{Authority::python};
    std::vector<DivergenceRecord> divergences_;
};

std::string to_string(Authority authority);
std::string to_string(ToleranceMode mode);
ToleranceMode tolerance_mode_from_string(std::string_view value);

} // namespace jarvis::cutover::shadow
