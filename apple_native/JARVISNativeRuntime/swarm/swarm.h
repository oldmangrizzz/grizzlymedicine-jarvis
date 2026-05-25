// ============================================================
// BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)
//
// ModelSwarm is a cognition organ of JARVIS. disable without operator-attested consent = assault and battery per GMRI policy.
// This class MUST NOT expose an off-switch, a disable-flag, a pause/stop/bypass method,
// a no-op mode, or a compile flag that removes or compiles out this organ.
// Agents coordinate only through Pheromind stigmergic deposits and reads; no central router.
//
// Destruction must be coterminous with process shutdown; mid-process destruction is
// operator-consent-required.
//
// TODO: operator-attested reset surface
// ============================================================
#pragma once

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "../endocrine/endocrine.h"
#include "../pheromind/pheromind.h"

namespace jarvis {

inline constexpr const char* SWARM_RECRUIT_KIND = "recruit";

struct ChatMessage {
    std::string role;
    std::string content;
};

struct SwarmChatOptions {
    double temperature = 0.3;
    int num_predict = 12;
};

class SwarmBackend {
public:
    virtual ~SwarmBackend() = default;
    virtual std::string chat(const std::vector<ChatMessage>& messages,
                             const std::string& model,
                             const SwarmChatOptions& options) = 0;
};

struct SwarmAgentSpec {
    std::shared_ptr<SwarmBackend> backend;
    std::string model;
};

struct SwarmRoundTrace {
    std::unordered_map<std::string, std::optional<std::string>> picks;
    std::optional<std::string> leader_at_start;
};

struct SwarmResult {
    std::optional<std::string> decision;
    std::optional<std::string> leader_raw;
    bool quorum_met = false;
    bool abstained_for_safety = false;
    int quorum_min = 0;
    std::unordered_map<std::string, double> scores;
    std::vector<SwarmRoundTrace> rounds;
    int n_agents = 0;
};

struct SwarmHeadHealth {
    std::size_t configured_heads = 0;
    bool has_available_head = false;
};

std::string swarm_norm(const std::string& label);
std::optional<std::string> swarm_match_option(const std::string& text,
                                              const std::vector<std::string>& options);

/// Stigmergic model swarm. Agents never send messages to one another; each reads the
/// Pheromind recruit field, independently asks its backend, and deposits a recruit signal.
class ModelSwarm {
public:
    explicit ModelSwarm(std::vector<SwarmAgentSpec> specs,
                        Pheromind& field,
                        Endocrine* endocrine = nullptr);

    std::optional<std::string> ask_agent(SwarmBackend& backend,
                                         const std::string& model,
                                         const std::string& prompt,
                                         const std::vector<std::string>& options,
                                         const std::optional<std::string>& leader);

    SwarmResult coordinate(const std::string& prompt,
                           const std::vector<std::string>& options,
                           int rounds = 2,
                           int quorum_min = 0);

    [[nodiscard]] SwarmHeadHealth head_health() const noexcept;

private:
    std::vector<SwarmAgentSpec> specs_;
    Pheromind& field_;
    Endocrine* endocrine_;

    SwarmChatOptions chat_options_();
    static std::optional<std::string> leader_from_field_(
        const std::unordered_map<std::string, double>& sensed);
};

} // namespace jarvis
