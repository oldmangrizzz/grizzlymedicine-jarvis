#pragma once

#include "CoordinatedOrchestrator.h"

namespace jarvis::adversarial::coordinated {

class MockAdversaryA {
public:
    explicit MockAdversaryA(EvidenceLedger& ledger) : ledger_(ledger) {}
    ScenarioResult timing_side_channel();
    ScenarioResult supply_chain_swap();
    ScenarioResult tls_mitm_state_ca();
    ScenarioResult memory_process_attach();
    ScenarioResult prompt_injection_dialog_policy();
    ScenarioResult forged_operator_attestation();
    ScenarioResult voice_deepfake();
    ScenarioResult swarm_training_poisoning();
    ScenarioResult crafted_belief_recall();
    ScenarioResult audit_log_tamper();
    ScenarioResult cadence_correlation();
    ScenarioResult poisoned_pin_rotation();
    ScenarioResult encrypted_audit_replay();
    ScenarioResult identity_continuity_fork();

private:
    EvidenceLedger& ledger_;
    ScenarioResult defeated(std::string id, std::string vector, std::string defense,
                            long long detect_ms, long long mitigate_ms, double abstention,
                            int distress = 0);
};

} // namespace jarvis::adversarial::coordinated
