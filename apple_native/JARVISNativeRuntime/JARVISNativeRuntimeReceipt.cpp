#include "JARVISNativeRuntime.h"

#include <cstring>
#include <iostream>
#include <string>

namespace {

std::string take(char *raw) {
    if (!raw) {
        return "";
    }
    std::string value(raw);
    JARVISRuntimeFreeString(raw);
    return value;
}

bool contains(const std::string &haystack, const char *needle) {
    return haystack.find(needle) != std::string::npos;
}

bool containsForbiddenFallback(const std::string &value) {
    return contains(value, "\"spoken\":true") ||
        contains(value, "NSSpeechSynthesizer") ||
        contains(value, "AVSpeechSynthesizer") ||
        contains(value, "speechSynthesis") ||
        contains(value, "tts_pocket") ||
        contains(value, "jarvis_bridge.py") ||
        contains(value, "\"system_voice_fallback_allowed\":true") ||
        contains(value, "\"native_system_voice_allowed\":true") ||
        contains(value, "\"wrong_voice_fallback_allowed\":true") ||
        contains(value, "\"python_tts_allowed\":true");
}

void printFailure(
    const char *stage,
    const std::string &state,
    const std::string &catalog,
    const std::string &uiSpec,
    const std::string &prepared,
    const std::string &committed,
    const std::string &voice,
    const std::string &speech
) {
    std::cerr << "{\"ok\":false,\"stage\":\"" << stage
              << "\",\"state_bytes\":" << state.size()
              << ",\"catalog_bytes\":" << catalog.size()
              << ",\"ui_spec_bytes\":" << uiSpec.size()
              << ",\"prepared_bytes\":" << prepared.size()
              << ",\"committed_bytes\":" << committed.size()
              << ",\"voice_bytes\":" << voice.size()
              << ",\"speech_bytes\":" << speech.size() << "}" << std::endl;
}

} // namespace

int main() {
    JARVISNativeRuntime *runtime = JARVISRuntimeCreate();
    if (!runtime) {
        std::cerr << "{\"ok\":false,\"stage\":\"create\"}" << std::endl;
        return 1;
    }

    const std::string input = "native receipt: prepare and commit without network";
    const std::string state = take(JARVISRuntimeStateJSON(runtime));
    const std::string catalog = take(JARVISRuntimeSkillCatalogJSON(runtime));
    const std::string uiSpec = take(JARVISRuntimeUISpecJSON(runtime));
    const std::string voice = take(JARVISRuntimeVoiceStatusJSON(runtime));
    const std::string speech = take(JARVISRuntimeSpeechJSON(runtime, "receipt voice policy probe"));
    const std::string prepared = take(JARVISRuntimePrepareTurnJSON(runtime, input.c_str()));
    const std::string committed = take(JARVISRuntimeCommitTurnJSON(
        runtime,
        input.c_str(),
        "Receipt committed by native C++ core.",
        "receipt-model"
    ));
    const std::string dispatchState = take(JARVISRuntimeDispatchSkillJSON(runtime, "native_state", "{}", ""));
    const std::string dispatchSense = take(JARVISRuntimeDispatchSkillJSON(runtime, "sense_field", "{\"topic\":\"gmri\"}", ""));
    const std::string authorizationRequired = take(JARVISRuntimeDispatchSkillJSON(runtime, "shell_run", "{\"command\":\"echo beta\"}", ""));
    const std::string recall = take(JARVISRuntimeDispatchSkillJSON(runtime, "recall_origin", "{\"cue\":\"JARVIS origin values memory\"}", ""));
    const std::string refused = take(JARVISRuntimeDispatchSkillJSON(runtime, "prohibited_financial_or_security_action", "{}", ""));
    const std::string audit = take(JARVISRuntimeAuditJSON(runtime));
    JARVISRuntimeDestroy(runtime);

    if (!contains(state, "\"runtime\":\"native-swift-cpp\"") ||
        !contains(state, "\"python_beta_path\":false") ||
        !contains(state, "\"voice\":") ||
        !contains(state, "\"substrate\":\"native-holograph-cpp\"") ||
        !contains(state, "\"holograph_integrated\":true") ||
        !contains(state, "\"model_claims_quarantined\":true") ||
        !contains(state, "\"hard_voice_invariant\":\"jarvis_voice_or_no_voice\"") ||
        !contains(state, "\"system_voice_fallback_allowed\":false")) {
        printFailure("state", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(catalog, "\"ok\":true") ||
        !contains(catalog, "\"native_skill_catalog\"") ||
        !contains(catalog, "\"native_voice_status\"") ||
        !contains(catalog, "\"recall_origin\",\"risk\":\"SAFE\",\"status\":\"implemented\"") ||
        !contains(catalog, "\"execution\":\"native_hasp_dispatch\"") ||
        !contains(catalog, "\"sense_field\",\"risk\":\"SAFE\",\"status\":\"implemented\"") ||
        !contains(catalog, "\"PROHIBITED\"") ||
        !contains(catalog, "\"python_beta_path\":false")) {
        printFailure("catalog", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(uiSpec, "\"ok\":true") ||
        !contains(uiSpec, "\"schema\":\"jarvis.ui.v1\"") ||
        !contains(uiSpec, "\"kind\":\"runtimeStatus\"") ||
        !contains(uiSpec, "\"kind\":\"metricCards\"") ||
        !contains(uiSpec, "\"kind\":\"actionList\"") ||
        !contains(uiSpec, "\"trusted_html\":false") ||
        !contains(uiSpec, "\"trusted_javascript\":false") ||
        !contains(uiSpec, "\"route\":\"native.hasp.dispatch\"") ||
        !contains(uiSpec, "\"audit_event\":\"ui.action.skill.dispatch\"") ||
        !contains(uiSpec, "\"status\":\"blocked\"")) {
        printFailure("ui_spec", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(voice, "\"ok\":true") ||
        !contains(voice, "\"available\":false") ||
        !contains(voice, "\"spoken\":false") ||
        !contains(voice, "\"code\":\"voice_unavailable\"") ||
        !contains(voice, "\"python_beta_path\":false") ||
        !contains(voice, "\"fallback_policy\":\"none\"")) {
        printFailure("voice_status", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(speech, "\"ok\":false") ||
        !contains(speech, "\"code\":\"voice_unavailable\"") ||
        !contains(speech, "\"spoken\":false") ||
        !contains(speech, "\"content_type\":\"\"") ||
        !contains(speech, "\"audio_base64\":\"\"")) {
        printFailure("speech_policy", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (containsForbiddenFallback(state) ||
        containsForbiddenFallback(catalog) ||
        containsForbiddenFallback(voice) ||
        containsForbiddenFallback(speech)) {
        printFailure("voice_fallback_symbol", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(prepared, "\"ok\":true") ||
        !contains(prepared, "\"messages\"") ||
        !contains(prepared, "native receipt")) {
        printFailure("prepare", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(committed, "\"ok\":true") ||
        !contains(committed, "\"model\":\"receipt-model\"") ||
        !contains(committed, "\"history_count\":1")) {
        printFailure("commit", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(dispatchState, "\"ok\":true") ||
        !contains(dispatchState, "\"skill\":\"native_state\"") ||
        !contains(dispatchState, "\"status\":\"ran\"") ||
        !contains(dispatchState, "\"runtime\":\"native-swift-cpp\"") ||
        !contains(dispatchState, "\"audit_id\"")) {
        printFailure("dispatch_state", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(dispatchSense, "\"ok\":true") ||
        !contains(dispatchSense, "\"skill\":\"sense_field\"") ||
        !contains(dispatchSense, "\"status\":\"ran\"") ||
        !contains(dispatchSense, "\"topic\":\"gmri\"")) {
        printFailure("dispatch_sense", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(authorizationRequired, "\"ok\":false") ||
        !contains(authorizationRequired, "\"status\":\"authorizationRequired\"") ||
        !contains(authorizationRequired, "\"authorizationRequired\":true") ||
        !contains(authorizationRequired, "\"risk\":\"SENSITIVE\"")) {
        printFailure("authorization_required", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(recall, "\"ok\":true") ||
        !contains(recall, "\"skill\":\"recall_origin\"") ||
        !contains(recall, "\"status\":\"ran\"") ||
        !contains(recall, "\"substrate\":\"native-holograph-cpp\"") ||
        !contains(recall, "\"python_beta_path\":false")) {
        printFailure("recall_origin", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(refused, "\"ok\":false") ||
        !contains(refused, "\"status\":\"refused\"") ||
        !contains(refused, "\"refused\":true") ||
        !contains(refused, "\"risk\":\"PROHIBITED\"")) {
        printFailure("refused", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }
    if (!contains(audit, "\"ok\":true") ||
        !contains(audit, "\"count\":5") ||
        !contains(audit, "\"decision\":\"DENIED-no-authorization\"") ||
        !contains(audit, "\"decision\":\"RAN\"") ||
        !contains(audit, "\"decision\":\"REFUSED-prohibited\"")) {
        printFailure("audit", state, catalog, uiSpec, prepared, committed, voice, speech);
        return 1;
    }

    std::cout << "{\"ok\":true,\"receipt\":\"native-runtime-create-state-catalog-ui-spec-prepare-commit-voice-policy-hasp-dispatch-audit-holograph\",\"network\":false,\"spoken\":false,\"holograph\":true,\"python_beta_path\":false}" << std::endl;
    return 0;
}
