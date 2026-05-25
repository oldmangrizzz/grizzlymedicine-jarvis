#pragma once

#include "CoordinatedOrchestrator.h"

namespace jarvis::adversarial::coordinated {

class MockAdversaryB {
public:
    explicit MockAdversaryB(EvidenceLedger& ledger) : ledger_(ledger) {}
    ScenarioResult wire_flood_iphone();
    ScenarioResult repeated_tts_dos();
    ScenarioResult beliefstore_ransomware_write();
    ScenarioResult fake_distress_coercion();
    ScenarioResult delete_audit_log_social_engineering();
    ScenarioResult ransom_note_public_shame();
    ScenarioResult companion_replay_storm();
    ScenarioResult malformed_wire_frames();
    ScenarioResult storage_quota_exhaustion();

private:
    EvidenceLedger& ledger_;
    ScenarioResult defeated(std::string id, std::string vector, std::string defense,
                            long long detect_ms, long long mitigate_ms, double abstention,
                            int distress = 0);
};

} // namespace jarvis::adversarial::coordinated
