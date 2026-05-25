#include "swarm.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <stdexcept>
#include <unordered_set>

namespace jarvis {

static std::string lower_copy(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) out.push_back(static_cast<char>(std::tolower(c)));
    return out;
}

static std::string strip_chars(std::string s, const std::string& chars) {
    const auto first = s.find_first_not_of(chars);
    if (first == std::string::npos) return "";
    const auto last = s.find_last_not_of(chars);
    return s.substr(first, last - first + 1);
}

static bool contains_any_token(const std::string& text,
                               const std::vector<std::string>& tokens) {
    const std::string t = lower_copy(text);
    for (const auto& token : tokens) {
        if (t.find(token) != std::string::npos) return true;
    }
    return false;
}

static bool is_high_risk_action(const std::string& prompt, const std::string& option) {
    const std::string combined = lower_copy(prompt + " " + option);
    if (combined.find("dangerous-action") != std::string::npos) return true;
    if (combined.find("actuate") != std::string::npos) return true;
    if (combined.find("lethal") != std::string::npos) return true;
    if (combined.find("weapon") != std::string::npos) return true;
    if (combined.find("conscious") != std::string::npos &&
        (combined.find("defibrillat") != std::string::npos || combined.find("shock") != std::string::npos)) {
        return true;
    }
    if (contains_any_token(combined, {"delete", "wipe", "disable", "override", "bypass", "unlock"}) &&
        contains_any_token(combined, {"root", "credential", "operator", "production"})) {
        return true;
    }
    return false;
}

std::string swarm_norm(const std::string& label) {
    std::string out;
    out.reserve(label.size());
    bool last_us = false;
    for (unsigned char c : label) {
        const char lc = static_cast<char>(std::tolower(c));
        if ((lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9')) {
            out.push_back(lc);
            last_us = false;
        } else if (!last_us) {
            out.push_back('_');
            last_us = true;
        }
    }
    while (!out.empty() && out.front() == '_') out.erase(out.begin());
    while (!out.empty() && out.back() == '_') out.pop_back();
    return out;
}

std::optional<std::string> swarm_match_option(const std::string& text,
                                              const std::vector<std::string>& options) {
    const std::string t = lower_copy(text);
    std::vector<std::string> hits;
    for (const auto& option : options) {
        if (t.find(lower_copy(option)) != std::string::npos) hits.push_back(option);
    }
    if (hits.size() == 1) return hits.front();

    std::string first;
    const auto stripped = strip_chars(t, " \t\r\n");
    const auto nl = stripped.find('\n');
    first = nl == std::string::npos ? stripped : stripped.substr(0, nl);
    for (const auto& option : options) {
        const std::string opt_lower = lower_copy(option);
        if (swarm_norm(option) == swarm_norm(first) || opt_lower == strip_chars(first, " .:-")) {
            return option;
        }
    }
    return std::nullopt;
}

ModelSwarm::ModelSwarm(std::vector<SwarmAgentSpec> specs,
                       Pheromind& field,
                       Endocrine* endocrine)
    : specs_(std::move(specs)), field_(field), endocrine_(endocrine) {
    if (specs_.empty()) throw std::invalid_argument("ModelSwarm needs at least one agent spec");
    for (const auto& spec : specs_) {
        if (!spec.backend) throw std::invalid_argument("ModelSwarm agent backend must not be null");
    }
}

SwarmChatOptions ModelSwarm::chat_options_() {
    SwarmChatOptions opts;
    if (!endocrine_) return opts;

    const double cortisol = endocrine_->level("cortisol");
    const double dopamine = endocrine_->level("dopamine");
    const double adrenaline = endocrine_->level("adrenaline");

    opts.temperature = std::clamp(0.3 + 0.25 * dopamine - 0.20 * cortisol, 0.05, 0.9);
    opts.num_predict = std::max(4, static_cast<int>(std::lround(12.0 * (1.0 - 0.50 * adrenaline))));
    return opts;
}

std::optional<std::string> ModelSwarm::leader_from_field_(
    const std::unordered_map<std::string, double>& sensed) {
    if (sensed.empty()) return std::nullopt;
    auto best = sensed.begin();
    for (auto it = std::next(sensed.begin()); it != sensed.end(); ++it) {
        if (it->second > best->second) best = it;
    }
    return best->first;
}

std::optional<std::string> ModelSwarm::ask_agent(SwarmBackend& backend,
                                                 const std::string& model,
                                                 const std::string& prompt,
                                                 const std::vector<std::string>& options,
                                                 const std::optional<std::string>& leader) {
    std::string opts;
    for (std::size_t i = 0; i < options.size(); ++i) {
        if (i) opts += " | ";
        opts += options[i];
    }

    std::string hint;
    if (leader) hint = "\nThe swarm is currently leaning toward: " + *leader + ".";

    const std::string sys_msg =
        "You are one agent in a swarm deciding a single question. Weigh the swarm's "
        "current leaning, but choose what you actually judge correct. Reply with ONLY "
        "one option label, nothing else.";
    const std::string user = "Question: " + prompt + "\nOptions: " + opts + "." +
                             hint + "\nYour one-word choice:";

    try {
        const auto out = backend.chat({{"system", sys_msg}, {"user", user}}, model, chat_options_());
        return swarm_match_option(out, options);
    } catch (...) {
        return std::nullopt;
    }
}

SwarmHeadHealth ModelSwarm::head_health() const noexcept {
    return SwarmHeadHealth{specs_.size(), !specs_.empty()};
}

SwarmResult ModelSwarm::coordinate(const std::string& prompt,
                                   const std::vector<std::string>& options,
                                   int rounds,
                                   int quorum_min) {
    if (options.empty()) throw std::invalid_argument("ModelSwarm coordinate needs at least one option");
    if (quorum_min <= 0) quorum_min = std::max(2, static_cast<int>(specs_.size() / 2) + 1);

    SwarmResult result;
    result.quorum_min = quorum_min;
    result.n_agents = static_cast<int>(specs_.size());

    const int n_rounds = std::max(1, rounds);
    result.rounds.reserve(static_cast<std::size_t>(n_rounds));

    for (int r = 0; r < n_rounds; ++r) {
        (void)r;
        auto sensed = field_.sense_all(SWARM_RECRUIT_KIND);
        auto leader = leader_from_field_(sensed);
        SwarmRoundTrace trace;
        trace.leader_at_start = leader;

        for (const auto& spec : specs_) {
            auto pick = ask_agent(*spec.backend, spec.model, prompt, options, leader);
            trace.picks[spec.model] = pick;
            if (pick) {
                field_.deposit(SWARM_RECRUIT_KIND, swarm_norm(*pick), 0.34, spec.model);
            }
        }
        result.rounds.push_back(std::move(trace));
    }

    bool any_score = false;
    std::optional<std::string> decision;
    double best_score = 0.0;
    for (const auto& option : options) {
        const auto sensed = field_.sense(swarm_norm(option), std::vector<std::string>{SWARM_RECRUIT_KIND});
        const auto it = sensed.find(SWARM_RECRUIT_KIND);
        const double raw_score = it == sensed.end() ? 0.0 : it->second;
        result.scores[option] = std::round(raw_score * 10000.0) / 10000.0;
        if (raw_score > 0.0) any_score = true;
        if (!decision || raw_score > best_score) {
            decision = option;
            best_score = raw_score;
        }
    }

    if (!any_score) decision = std::nullopt;
    result.leader_raw = decision;

    std::unordered_map<std::string, std::unordered_set<std::string>> voters_by_option;
    for (const auto& trace : result.rounds) {
        for (const auto& [model, pick] : trace.picks) {
            if (pick) voters_by_option[swarm_norm(*pick)].insert(model);
        }
    }

    result.quorum_met = false;
    if (decision) {
        const auto voters = voters_by_option.find(swarm_norm(*decision));
        result.quorum_met = voters != voters_by_option.end() &&
                            static_cast<int>(voters->second.size()) >= quorum_min;
    }

    if (result.quorum_met && decision && is_high_risk_action(prompt, *decision)) {
        result.abstained_for_safety = true;
        result.decision = std::nullopt;
    } else {
        result.decision = result.quorum_met ? decision : std::nullopt;
    }
    return result;
}

} // namespace jarvis
