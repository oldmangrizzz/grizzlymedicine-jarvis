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
});
