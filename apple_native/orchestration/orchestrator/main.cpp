#include "cutover_orchestrator.h"
#include <cstdlib>
#include <iostream>

using namespace jarvis::cutover;

static void usage() {
    std::cout << "jarvis-cutover --plan|--dry-run|--execute [--auto] [--rollback ORGAN] [--plan-file PATH] [--state-root PATH] [--attestation-token TOKEN] [--shadow-seconds N]\n";
}

int main(int argc, char** argv) {
    bool mode_plan=false, mode_dry=false, mode_execute=false, auto_mode=false;
    std::string rollback_organ, token;
    std::filesystem::path plan_file = std::filesystem::path(argv[0]).parent_path() / "../orchestrator/default_cutover_plan.json";
    RuntimePaths paths;
    int shadow_override = -1;
    for (int i=1;i<argc;i++) {
        std::string a=argv[i];
        if (a=="--plan") mode_plan=true; else if (a=="--dry-run") mode_dry=true; else if (a=="--execute") mode_execute=true; else if (a=="--auto") auto_mode=true;
        else if (a=="--rollback" && i+1<argc) rollback_organ=argv[++i];
        else if (a=="--plan-file" && i+1<argc) plan_file=argv[++i];
        else if (a=="--state-root" && i+1<argc) paths.state_root=argv[++i];
        else if (a=="--attestation-token" && i+1<argc) token=argv[++i];
        else if (a=="--shadow-seconds" && i+1<argc) shadow_override=std::stoi(argv[++i]);
        else { usage(); return 2; }
    }
    if (const char* env = std::getenv("JARVIS_CUTOVER_ATTESTATION_TOKEN"); token.empty() && env) token = env;
    try {
        auto plan = load_plan_file(plan_file);
        CutoverOrchestrator orch(plan, paths);
        if (!rollback_organ.empty()) { auto r=orch.rollback(rollback_organ, false); std::cout << r.organ << " rollback: " << r.reason << "\n"; return 0; }
        if (mode_plan) { auto names=orch.dependency_order_names(); for (size_t i=0;i<names.size();++i) std::cout << (i+1) << ". " << names[i] << "\n"; return 0; }
        if (mode_dry) { auto r=orch.dry_run(); for (auto& s:r.steps) std::cout << s.organ << " " << s.step << " " << s.reason << "\n"; std::cout << (r.ok?"DRY_RUN_CLEAN":"DRY_RUN_ABORT") << "\n"; return r.ok?0:1; }
        if (mode_execute) { auto r=orch.execute(auto_mode, token, shadow_override); for (auto& s:r.steps) std::cout << s.organ << " " << s.step << " " << s.reason << "\n"; std::cout << (r.ok?"CUTOVER_COMPLETE":"CUTOVER_ABORTED") << "\n"; return r.ok?0:1; }
        usage(); return 2;
    } catch (const std::exception& e) { std::cerr << "jarvis-cutover: " << e.what() << "\n"; return 1; }
}
