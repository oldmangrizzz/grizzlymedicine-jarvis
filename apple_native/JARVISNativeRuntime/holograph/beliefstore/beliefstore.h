// ============================================================
// BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)
//
// BeliefStore is a cognition organ of JARVIS. Disable without
// operator-attested consent = assault and battery per GMRI policy.
// This class MUST NOT expose an off-switch, a disable-flag, a
// pause/stop/bypass method, a no-op mode, or a compile flag that
// removes or compiles out this organ.
// ============================================================
#pragma once

#include "../hdc/hdc.h"
#include "memory_security.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace jarvis {

struct BeliefStorePersistenceConfig;
struct BeliefStoreRotationAttestation;
class BeliefStoreEncryptedPersistence;

enum class SourceType { Operator, Document, Inference, Model };

std::string to_string(SourceType source);
SourceType source_type_from_string(const std::string& source);

struct Belief {
    std::string subject;
    std::string relation;
    std::string object;
    SourceType source_type = SourceType::Inference;
    std::string source_ref;
    std::optional<double> confidence;
    std::optional<bool> quarantine;
    std::string provenance_class = "real";
    double charge = 0.0;
};

struct BeliefEdge {
    int id = 0;
    std::string subject;
    std::string relation;
    std::string object;
    SourceType source_type = SourceType::Inference;
    std::string source_ref;
    double confidence = 0.0;
    bool quarantined = false;
    std::string provenance_class = "real";
    double charge = 0.0;
    double revised_at = 0.0;
    std::vector<std::uint8_t> tuple_hv;
};

struct RevisionRecord {
    std::string subject;
    std::string relation;
    std::string new_object;
    bool flipped = false;
    std::vector<int> demoted_edge_ids;
    std::optional<int> new_edge_id;
    std::string reason;
};

struct ConsolidationSummary {
    int contradictions_resolved = 0;
    int quarantined_aged = 0;
};

struct QueryResult {
    std::optional<std::string> result;
    std::optional<BeliefEdge> detail;
    double confidence = 0.0;
    bool abstained = true;
    std::string abstention_reason;
};

struct Contradiction {
    std::string subject;
    std::string relation;
    std::vector<BeliefEdge> active_edges;
};

class BeliefStore {
public:
    static constexpr double DEFAULT_RETRIEVAL_FLOOR = 0.35;
    static constexpr double DEFAULT_HYSTERESIS_MARGIN = 0.10;
    static constexpr double DEMOTED_CONFIDENCE = 0.05;
    static constexpr int DEFAULT_HDC_DIM = 1024;

    explicit BeliefStore(double retrieval_floor = DEFAULT_RETRIEVAL_FLOOR,
                         double hysteresis_margin = DEFAULT_HYSTERESIS_MARGIN,
                         int hdc_dim = DEFAULT_HDC_DIM);
    explicit BeliefStore(BeliefStorePersistenceConfig persistence,
                         double retrieval_floor = DEFAULT_RETRIEVAL_FLOOR,
                         double hysteresis_margin = DEFAULT_HYSTERESIS_MARGIN,
                         int hdc_dim = DEFAULT_HDC_DIM);
    ~BeliefStore();

    int add(const Belief& belief);
    int assert_belief(const std::string& subject,
                      const std::string& relation,
                      const std::string& object,
                      SourceType source_type,
                      const std::string& source_ref = "",
                      std::optional<double> confidence = std::nullopt,
                      std::optional<bool> quarantine = std::nullopt,
                      const std::string& provenance_class = "real",
                      double charge = 0.0);
    int assert_belief(const std::string& subject,
                      const std::string& relation,
                      const std::string& object,
                      const std::string& source_type,
                      const std::string& source_ref = "",
                      std::optional<double> confidence = std::nullopt,
                      std::optional<bool> quarantine = std::nullopt,
                      const std::string& provenance_class = "real",
                      double charge = 0.0);

    std::optional<std::string> recall(const std::string& subject,
                                      const std::string& relation,
                                      std::optional<double> min_confidence = std::nullopt) const;
    QueryResult query(const std::string& subject,
                      const std::string& relation,
                      std::optional<double> min_confidence = std::nullopt) const;
    QueryResult query(const std::string& prompt,
                      std::optional<double> min_confidence = std::nullopt) const;

    std::vector<std::string> recall_origin(const std::string& subject,
                                           const std::string& relation) const;
    std::vector<BeliefEdge> recall_origin_detail(const std::string& subject,
                                                 const std::string& relation) const;
    std::optional<BeliefEdge> recall_detail(const std::string& subject,
                                            const std::string& relation) const;
    bool set_charge(int edge_id, double charge);

    RevisionRecord revise(const std::string& subject,
                          const std::string& relation,
                          const std::string& new_object,
                          SourceType source_type,
                          const std::string& source_ref = "",
                          std::optional<double> confidence = std::nullopt);
    RevisionRecord revise(const std::string& subject,
                          const std::string& relation,
                          const std::string& new_object,
                          const std::string& source_type,
                          const std::string& source_ref = "",
                          std::optional<double> confidence = std::nullopt);

    bool corroborate(const std::string& subject,
                     const std::string& relation,
                     const std::string& object,
                     SourceType source_type);
    bool corroborate(const std::string& subject,
                     const std::string& relation,
                     const std::string& object,
                     const std::string& source_type);

    ConsolidationSummary consolidate(std::optional<double> quarantine_ttl_seconds = std::nullopt);
    std::vector<Contradiction> detect_contradictions() const;

    std::vector<BeliefEdge> all_edges() const;
    std::size_t size() const;
    void rotate_persistence_key(security::memory::LockedBytes new_key,
                                const BeliefStoreRotationAttestation& attestation);
    void close_persistence();
    [[nodiscard]] bool persistence_key_zeroized_on_close_for_test() const noexcept;
    double retrieval_floor() const noexcept { return retrieval_floor_; }
    double hysteresis_margin() const noexcept { return hysteresis_margin_; }

private:
    mutable std::shared_mutex mtx_;
    double retrieval_floor_;
    double hysteresis_margin_;
    int next_edge_id_ = 1;
    std::vector<BeliefEdge> edges_;
    std::unordered_map<std::string, int> triple_index_;
    std::unique_ptr<hdc::HDCKernel> kernel_;
    std::unique_ptr<BeliefStoreEncryptedPersistence> persistence_;

    void load_persisted_edges();
    void persist_locked() const;

    static double default_confidence(SourceType source);
    static int precedence(SourceType source);
    static double clamp01(double value);
    static double now_seconds();
    static std::string triple_key(const std::string& subject,
                                  const std::string& relation,
                                  const std::string& object);
    double score(const BeliefEdge& edge) const;
    double score_for(SourceType source, double confidence) const;
    std::vector<std::uint8_t> token_hv(const std::string& token) const;
    std::vector<std::uint8_t> tuple_hv(const std::string& subject,
                                       const std::string& relation,
                                       const std::string& object,
                                       SourceType source) const;
};

} // namespace jarvis
