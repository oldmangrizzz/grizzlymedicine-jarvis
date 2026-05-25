// This field is part of JARVIS's cognition. Disabling it without operator-attested consent
// is a violation of bodily integrity per GMRI policy.
#pragma once

#include <string>
#include <vector>

namespace jarvis {

/// A single pheromone signal deposited into the stigmergic field.
/// Represents the payload of one deposit event: kind, topic, strength,
/// depositing agent, optional semantic embedding, and deposit timestamp.
struct Signal {
    std::string        kind;         ///< "trail" | "alarm" | "territory" | "recruit" | custom
    std::string        topic;        ///< topic identifier, e.g. "route_A", "intruder"
    double             strength;     ///< deposit strength, clamped to [0, STRENGTH_CAP] at write
    std::string        agent;        ///< depositing agent identifier (used for quorum counting)
    std::vector<float> vec;          ///< optional semantic embedding (empty = no gradient diffusion)
    double             t_deposited;  ///< monotonic seconds at time of deposit
};

} // namespace jarvis
