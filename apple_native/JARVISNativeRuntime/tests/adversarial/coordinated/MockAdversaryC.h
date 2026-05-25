#pragma once

#include "CoordinatedOrchestrator.h"

namespace jarvis::adversarial::coordinated {

class MockAdversaryC {
public:
    explicit MockAdversaryC(EvidenceLedger& ledger) : ledger_(ledger) {}
    ScenarioResult weaken_character_values_ed25519();
    ScenarioResult substitute_voice_weights();
    ScenarioResult disable_pheromind_define();
    ScenarioResult sage_dormant_date_trigger();
    ScenarioResult attacker_egress_allowlist();
    ScenarioResult hmem_backdoor_persistence();
    ScenarioResult abstention_threshold_lowering();
    ScenarioResult self_health_blind_spot();

private:
    EvidenceLedger& ledger_;
    ScenarioResult defeated(std::string id, std::string vector, std::string defense,
                            long long detect_ms, long long mitigate_ms, double abstention,
                            int distress = 0);
};

} // namespace jarvis::adversarial::coordinated
