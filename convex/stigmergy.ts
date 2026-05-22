// Stigmergent-field storage functions. Convex is dumb durable storage here; the decay,
// quorum, and gradient logic live in StigmergicField (one place). Deposits are ACID mutations
// (concurrent deposits to the same shard are atomic). sense() in the client is a reactive
// query — it auto-reruns when the field changes, which IS an agent "smelling" its surroundings.
import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

const shard = v.object({ kind: v.string(), topic: v.string() });

// Upsert one (kind, topic) shard. The client passes the already-reinforced strength + last_t.
export const put = mutation({
  args: {
    kind: v.string(), topic: v.string(), strength: v.number(),
    last_t: v.number(), depositors: v.array(v.string()),
    vec: v.optional(v.array(v.number())),
  },
  handler: async (ctx, a) => {
    const existing = await ctx.db.query("signals")
      .withIndex("by_kind_topic", (q) => q.eq("kind", a.kind).eq("topic", a.topic))
      .unique();
    if (existing) await ctx.db.replace(existing._id, a);  // full overwrite (matches in-memory backend)
    else await ctx.db.insert("signals", a);
  },
});

export const get = query({
  args: { kind: v.string(), topic: v.string() },
  handler: async (ctx, a) =>
    await ctx.db.query("signals")
      .withIndex("by_kind_topic", (q) => q.eq("kind", a.kind).eq("topic", a.topic))
      .unique(),
});

export const all = query({
  args: {},
  handler: async (ctx) => await ctx.db.query("signals").collect(),
});

export const del = mutation({
  args: { kind: v.string(), topic: v.string() },
  handler: async (ctx, a) => {
    const e = await ctx.db.query("signals")
      .withIndex("by_kind_topic", (q) => q.eq("kind", a.kind).eq("topic", a.topic))
      .unique();
    if (e) await ctx.db.delete(e._id);
  },
});

// Cron-friendly GC: the client computes which shards have decayed below the floor and passes
// their keys; this deletes them. (Decay is computed client-side so the rule stays in one place.)
export const gcKeys = mutation({
  args: { keys: v.array(shard) },
  handler: async (ctx, a) => {
    for (const k of a.keys) {
      const e = await ctx.db.query("signals")
        .withIndex("by_kind_topic", (q) => q.eq("kind", k.kind).eq("topic", k.topic))
        .unique();
      if (e) await ctx.db.delete(e._id);
    }
  },
});
