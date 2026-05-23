// Convex schema for the stigmergent field. One row per (kind, topic) — sharded, never one
// hot document, so 30+ concurrent depositors don't collide on a single key (the OCC constraint).
// Decay is NOT stored: StigmergicField computes current strength from strength + last_t on read.
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  signals: defineTable({
    kind: v.string(),                 // trail | alarm | territory | recruit
    topic: v.string(),                // the key the signal sits on
    strength: v.number(),             // strength AT last deposit (decayed lazily on read)
    last_t: v.number(),               // deposit timestamp (client clock)
    depositors: v.array(v.string()),  // distinct agent ids that reinforced this shard
    vec: v.optional(v.array(v.number())), // optional semantic coordinate for gradient sensing
  })
    .index("by_kind_topic", ["kind", "topic"])
    .index("by_kind", ["kind"]),

  runtimeState: defineTable({
    key: v.string(),
    source: v.string(),
    updatedAt: v.number(),
    payload: v.any(),
  })
    .index("by_key", ["key"])
    .index("by_updated", ["updatedAt"]),

  ambientEvents: defineTable({
    source: v.string(),
    deviceId: v.string(),
    kind: v.string(),
    timestamp: v.number(),
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    payload: v.any(),
    dream: v.optional(v.any()),
  })
    .index("by_source_time", ["source", "timestamp"])
    .index("by_device_time", ["deviceId", "timestamp"])
    .index("by_person_time", ["personId", "timestamp"])
    .index("by_time", ["timestamp"]),

  controlRequests: defineTable({
    requestId: v.string(),
    status: v.string(), // pending | running | done | refused | error
    requestedBy: v.string(),
    deviceId: v.optional(v.string()),
    name: v.string(),
    args: v.any(),
    authorizationIntent: v.optional(v.string()),
    createdAt: v.number(),
    claimedAt: v.optional(v.number()),
    runner: v.optional(v.string()),
    completedAt: v.optional(v.number()),
    ok: v.optional(v.boolean()),
    output: v.optional(v.any()),
    refused: v.optional(v.boolean()),
    reason: v.optional(v.string()),
    error: v.optional(v.string()),
    authorizationRequired: v.optional(v.boolean()),
  })
    .index("by_request_id", ["requestId"])
    .index("by_status_created", ["status", "createdAt"])
    .index("by_requested_by_created", ["requestedBy", "createdAt"])
    .index("by_device_created", ["deviceId", "createdAt"]),

  skillCatalog: defineTable({
    key: v.string(),
    updatedAt: v.number(),
    skills: v.array(v.any()),
  })
    .index("by_key", ["key"]),

  onboardingEvidence: defineTable({
    recordId: v.string(),
    kind: v.string(),
    source: v.string(),
    timestamp: v.number(),
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    consentBasis: v.optional(v.string()),
    payloadDigestSHA256: v.string(),
    payloadSummary: v.string(),
    payload: v.any(),
  })
    .index("by_record_id", ["recordId"])
    .index("by_person_time", ["personId", "timestamp"])
    .index("by_memory_scope_time", ["memoryScopeId", "timestamp"])
    .index("by_kind_time", ["kind", "timestamp"]),
});
