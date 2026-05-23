import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

declare const process: { env: Record<string, string | undefined> };

const now = () => Date.now() / 1000;
const limit = (value: number | undefined, fallback = 50, maximum = 200) =>
  Math.max(1, Math.min(maximum, Math.floor(value ?? fallback)));
const tokenArgs = { clientToken: v.string() };

const requireToken = (clientToken: string) => {
  const expected = (process.env.JARVIS_CONVEX_REALTIME_TOKEN ?? "").trim();
  if (!expected || clientToken.trim() !== expected) {
    throw new Error("bad realtime token");
  }
};

export const publishState = mutation({
  args: {
    ...tokenArgs,
    key: v.string(),
    source: v.string(),
    updatedAt: v.optional(v.number()),
    payload: v.any(),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const row = {
      key: a.key,
      source: a.source,
      updatedAt: a.updatedAt ?? now(),
      payload: a.payload,
    };
    const existing = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", a.key))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, row);
      return { ok: true, key: a.key, id: existing._id };
    }
    const id = await ctx.db.insert("runtimeState", row);
    return { ok: true, key: a.key, id };
  },
});

export const state = query({
  args: { ...tokenArgs, key: v.string() },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    return await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", a.key))
      .unique();
  },
});

export const allState = query({
  args: tokenArgs,
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    return await ctx.db.query("runtimeState").collect();
  },
});

export const publishSkillCatalog = mutation({
  args: {
    ...tokenArgs,
    key: v.optional(v.string()),
    updatedAt: v.optional(v.number()),
    skills: v.array(v.any()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const key = a.key ?? "default";
    const row = { key, updatedAt: a.updatedAt ?? now(), skills: a.skills };
    const existing = await ctx.db.query("skillCatalog")
      .withIndex("by_key", (q) => q.eq("key", key))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, row);
      return { ok: true, key, id: existing._id };
    }
    const id = await ctx.db.insert("skillCatalog", row);
    return { ok: true, key, id };
  },
});

export const skillCatalog = query({
  args: { ...tokenArgs, key: v.optional(v.string()) },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    return await ctx.db.query("skillCatalog")
      .withIndex("by_key", (q) => q.eq("key", a.key ?? "default"))
      .unique();
  },
});

export const publishAmbientEvent = mutation({
  args: {
    ...tokenArgs,
    source: v.string(),
    deviceId: v.string(),
    kind: v.string(),
    timestamp: v.number(),
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    payload: v.any(),
    dream: v.optional(v.any()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const id = await ctx.db.insert("ambientEvents", a);
    return { ok: true, id };
  },
});

export const ambientEvents = query({
  args: {
    ...tokenArgs,
    source: v.optional(v.string()),
    deviceId: v.optional(v.string()),
    personId: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const take = limit(a.limit);
    if (a.deviceId) {
      return await ctx.db.query("ambientEvents")
        .withIndex("by_device_time", (q) => q.eq("deviceId", a.deviceId!))
        .order("desc")
        .take(take);
    }
    if (a.personId) {
      return await ctx.db.query("ambientEvents")
        .withIndex("by_person_time", (q) => q.eq("personId", a.personId!))
        .order("desc")
        .take(take);
    }
    if (a.source) {
      return await ctx.db.query("ambientEvents")
        .withIndex("by_source_time", (q) => q.eq("source", a.source!))
        .order("desc")
        .take(take);
    }
    return await ctx.db.query("ambientEvents")
      .withIndex("by_time")
      .order("desc")
      .take(take);
  },
});

export const requestControl = mutation({
  args: {
    ...tokenArgs,
    requestId: v.string(),
    requestedBy: v.string(),
    deviceId: v.optional(v.string()),
    name: v.string(),
    args: v.optional(v.any()),
    authorizationIntent: v.optional(v.string()),
    createdAt: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const existing = await ctx.db.query("controlRequests")
      .withIndex("by_request_id", (q) => q.eq("requestId", a.requestId))
      .unique();
    if (existing) {
      return { ok: true, requestId: a.requestId, status: existing.status, id: existing._id };
    }
    const id = await ctx.db.insert("controlRequests", {
      requestId: a.requestId,
      status: "pending",
      requestedBy: a.requestedBy,
      deviceId: a.deviceId,
      name: a.name,
      args: a.args ?? {},
      authorizationIntent: a.authorizationIntent,
      createdAt: a.createdAt ?? now(),
    });
    return { ok: true, requestId: a.requestId, status: "pending", id };
  },
});

export const pendingControlRequests = query({
  args: { ...tokenArgs, limit: v.optional(v.number()) },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    return await ctx.db.query("controlRequests")
      .withIndex("by_status_created", (q) => q.eq("status", "pending"))
      .order("asc")
      .take(limit(a.limit, 20, 50));
  },
});

export const claimControlRequest = mutation({
  args: {
    ...tokenArgs,
    requestId: v.string(),
    runner: v.string(),
    claimedAt: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const existing = await ctx.db.query("controlRequests")
      .withIndex("by_request_id", (q) => q.eq("requestId", a.requestId))
      .unique();
    if (!existing || existing.status !== "pending") {
      return null;
    }
    await ctx.db.patch(existing._id, {
      status: "running",
      runner: a.runner,
      claimedAt: a.claimedAt ?? now(),
    });
    return { ...existing, status: "running", runner: a.runner, claimedAt: a.claimedAt ?? now() };
  },
});

export const completeControlRequest = mutation({
  args: {
    ...tokenArgs,
    requestId: v.string(),
    status: v.string(),
    completedAt: v.optional(v.number()),
    ok: v.boolean(),
    output: v.optional(v.any()),
    refused: v.optional(v.boolean()),
    reason: v.optional(v.string()),
    error: v.optional(v.string()),
    authorizationRequired: v.optional(v.boolean()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const existing = await ctx.db.query("controlRequests")
      .withIndex("by_request_id", (q) => q.eq("requestId", a.requestId))
      .unique();
    if (!existing) {
      return { ok: false, error: "unknown requestId" };
    }
    await ctx.db.patch(existing._id, {
      status: a.status,
      completedAt: a.completedAt ?? now(),
      ok: a.ok,
      output: a.output,
      refused: a.refused,
      reason: a.reason,
      error: a.error,
      authorizationRequired: a.authorizationRequired,
    });
    return { ok: true, requestId: a.requestId, status: a.status };
  },
});

export const controlRequests = query({
  args: {
    ...tokenArgs,
    requestedBy: v.optional(v.string()),
    deviceId: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const take = limit(a.limit);
    if (a.deviceId) {
      return await ctx.db.query("controlRequests")
        .withIndex("by_device_created", (q) => q.eq("deviceId", a.deviceId!))
        .order("desc")
        .take(take);
    }
    if (a.requestedBy) {
      return await ctx.db.query("controlRequests")
        .withIndex("by_requested_by_created", (q) => q.eq("requestedBy", a.requestedBy!))
        .order("desc")
        .take(take);
    }
    return await ctx.db.query("controlRequests").order("desc").take(take);
  },
});

export const publishOnboardingEvidence = mutation({
  args: {
    ...tokenArgs,
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
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const existing = await ctx.db.query("onboardingEvidence")
      .withIndex("by_record_id", (q) => q.eq("recordId", a.recordId))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, a);
      return { ok: true, recordId: a.recordId, id: existing._id };
    }
    const id = await ctx.db.insert("onboardingEvidence", a);
    return { ok: true, recordId: a.recordId, id };
  },
});

export const onboardingEvidence = query({
  args: {
    ...tokenArgs,
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    kind: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireToken(a.clientToken);
    const take = limit(a.limit);
    if (a.memoryScopeId) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_memory_scope_time", (q) => q.eq("memoryScopeId", a.memoryScopeId!))
        .order("desc")
        .take(take);
    }
    if (a.personId) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_person_time", (q) => q.eq("personId", a.personId!))
        .order("desc")
        .take(take);
    }
    if (a.kind) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_kind_time", (q) => q.eq("kind", a.kind!))
        .order("desc")
        .take(take);
    }
    return await ctx.db.query("onboardingEvidence").order("desc").take(take);
  },
});
