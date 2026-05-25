#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "beliefstore.h"
#include "beliefstore_persistence.h"

#include <sodium.h>

#include <filesystem>
#include <functional>
#include <memory>
#include <fstream>
#include <nlohmann/json.hpp>
#include <string>
#include <utility>
#include <vector>

using json = nlohmann::json;
using jarvis::BeliefStore;
using jarvis::BeliefStorePersistenceConfig;

namespace {
std::vector<json> load_belief_records() {
    std::filesystem::path path = std::filesystem::path(BELIEFSTORE_ORACLE_DIR) / "api_traces.jsonl";
    std::ifstream in(path);
    REQUIRE(in.good());
    std::vector<json> records;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto rec = json::parse(line);
        const std::string fn = rec.value("function", "");
        const std::string section = rec.value("section", "");
        if (section == "beliefs" || fn == "BeliefStore.consolidate__sleep_boundary") records.push_back(std::move(rec));
    }
    return records;
}

void require_optional_string(const std::optional<std::string>& got, const json& expected) {
    if (expected.is_null()) {
        REQUIRE_FALSE(got.has_value());
    } else {
        REQUIRE(got.has_value());
        REQUIRE(*got == expected.get<std::string>());
    }
}

jarvis::security::memory::LockedBytes locked_key(std::string label) {
    jarvis::security::memory::ensure_sodium_initialized();
    jarvis::security::memory::LockedBytes key(32);
    crypto_generichash(key.data(), key.size(),
                       reinterpret_cast<const unsigned char*>(label.data()), label.size(),
                       nullptr, 0);
    return key;
}

BeliefStorePersistenceConfig encrypted_config(const std::filesystem::path& db, std::string label) {
    std::filesystem::remove(db);
    std::filesystem::remove(db.string() + ".audit");
    std::filesystem::remove(db.string() + ".audit.key");
    BeliefStorePersistenceConfig cfg;
    cfg.database_path = db;
    cfg.audit_log_path = db.string() + ".audit";
    cfg.audit_key_path = db.string() + ".audit.key";
    cfg.key_provider = [label = std::move(label)] { return locked_key(label); };
    return cfg;
}

int replay_oracle(BeliefStore& store, const std::vector<json>& records,
                  const std::function<std::unique_ptr<BeliefStore>()>& sleep_factory) {
    int matched = 0;
    for (const auto& rec : records) {
        const std::string fn = rec.at("function").get<std::string>();
        const auto& args = rec.at("args");
        const auto& retval = rec.at("retval");

        if (fn == "BeliefStore.assert_belief") {
            int eid = store.assert_belief(args.at("subject").get<std::string>(),
                                          args.at("relation").get<std::string>(),
                                          args.at("object").get<std::string>(),
                                          args.at("source_type").get<std::string>(),
                                          "", std::nullopt, std::nullopt,
                                          args.at("provenance_class").get<std::string>(),
                                          args.at("charge").get<double>());
            REQUIRE(eid == retval.at("edge_id").get<int>());
            ++matched;
        } else if (fn == "BeliefStore.recall" || fn.rfind("BeliefStore.recall__abstain", 0) == 0 || fn == "BeliefStore.recall__after_corroboration") {
            if (fn == "BeliefStore.recall__abstain_low_confidence") {
                store.assert_belief("lowconf", "prop", "val", "inference", "", 0.15);
            }
            auto got = store.recall(args.at("subject").get<std::string>(), args.at("relation").get<std::string>());
            require_optional_string(got, retval.at("result"));
            ++matched;
        } else if (fn == "BeliefStore.recall_origin") {
            REQUIRE(store.recall_origin(args.at("subject").get<std::string>(), args.at("relation").get<std::string>()) == retval.at("results").get<std::vector<std::string>>());
            ++matched;
        } else if (fn == "BeliefStore.recall_detail") {
            auto detail = store.recall_detail(args.at("subject").get<std::string>(), args.at("relation").get<std::string>());
            REQUIRE(detail.has_value());
            REQUIRE(detail->id == retval.at("edge_id").get<int>());
            REQUIRE(detail->confidence == Catch::Approx(retval.at("confidence").get<double>()));
            REQUIRE(to_string(detail->source_type) == retval.at("source_type").get<std::string>());
            REQUIRE(detail->quarantined == retval.at("quarantined").get<bool>());
            ++matched;
        } else if (fn == "BeliefStore.set_charge") {
            REQUIRE(store.set_charge(args.at("edge_id").get<int>(), args.at("charge").get<double>()));
            ++matched;
        } else if (fn == "BeliefStore.revise__stronger_source") {
            auto rr = store.revise(args.at("subject").get<std::string>(), args.at("relation").get<std::string>(),
                                   args.at("new_obj").get<std::string>(), args.at("source_type").get<std::string>());
            REQUIRE(rr.flipped == retval.at("flipped").get<bool>());
            REQUIRE(rr.reason == retval.at("reason").get<std::string>());
            REQUIRE(rr.demoted_edge_ids == retval.at("demoted").get<std::vector<int>>());
            ++matched;
        } else if (fn == "BeliefStore.revise__weaker_source") {
            auto rr = store.revise(args.at("subject").get<std::string>(), args.at("relation").get<std::string>(),
                                   args.at("new_obj").get<std::string>(), args.at("source_type").get<std::string>());
            REQUIRE(rr.flipped == retval.at("flipped").get<bool>());
            REQUIRE(rr.reason == retval.at("reason").get<std::string>());
            ++matched;
        } else if (fn == "BeliefStore.revise__below_hysteresis") {
            store.assert_belief("planet", "mass", "5.97e24", "document", "", 0.80);
            auto rr = store.revise("planet", "mass", "5.90e24", "document", "", 0.70);
            REQUIRE(rr.flipped == retval.at("flipped").get<bool>());
            REQUIRE(rr.reason == retval.at("reason").get<std::string>());
            ++matched;
        } else if (fn == "BeliefStore.corroborate") {
            bool changed = store.corroborate(args.at("subject").get<std::string>(), args.at("relation").get<std::string>(),
                                             args.at("obj").get<std::string>(), args.at("source_type").get<std::string>());
            REQUIRE(changed == retval.at("changed").get<bool>());
            ++matched;
        } else if (fn == "BeliefStore.consolidate") {
            auto summary = store.consolidate();
            REQUIRE(summary.contradictions_resolved == retval.at("contradictions_resolved").get<int>());
            REQUIRE(summary.quarantined_aged == retval.at("quarantined_aged").get<int>());
            ++matched;
        } else if (fn == "BeliefStore.consolidate__sleep_boundary") {
            auto sleep = sleep_factory();
            sleep->assert_belief("sector", "threat", "low", "document", "", 0.55, false);
            sleep->assert_belief("sector", "threat", "medium", "document", "", 0.60, false);
            sleep->assert_belief("sector", "threat", "high", "document", "", 0.80, false);
            REQUIRE(sleep->recall("sector", "threat") == retval.at("pre_recall").get<std::string>());
            auto summary = sleep->consolidate();
            REQUIRE(sleep->recall("sector", "threat") == retval.at("post_recall").get<std::string>());
            REQUIRE(summary.contradictions_resolved == retval.at("result").at("contradictions_resolved").get<int>());
            REQUIRE(summary.quarantined_aged == retval.at("result").at("quarantined_aged").get<int>());
            ++matched;
        }
    }
    return matched;
}
}

TEST_CASE("BeliefStore matches Python oracle BeliefStore-relevant traces", "[beliefstore][oracle]") {
    auto records = load_belief_records();
    REQUIRE(records.size() == 27);
    BeliefStore store;
    REQUIRE(replay_oracle(store, records, [] { return std::make_unique<BeliefStore>(); }) == 27);
}

TEST_CASE("BeliefStore matches all 27 oracle traces with SQLCipher enabled", "[beliefstore][oracle][sqlcipher]") {
    auto records = load_belief_records();
    REQUIRE(records.size() == 27);
    const auto base = std::filesystem::path(TEST_ARTIFACT_DIR);
    BeliefStore store(encrypted_config(base / "beliefstore_oracle_encrypted.db", "oracle-main"));
    auto sleep_factory = [base] {
        return std::make_unique<BeliefStore>(encrypted_config(base / "beliefstore_oracle_sleep_encrypted.db", "oracle-sleep"));
    };
    REQUIRE(replay_oracle(store, records, sleep_factory) == 27);
}
