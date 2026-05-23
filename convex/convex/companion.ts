import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

declare const process: { env: Record<string, string | undefined> };
declare const crypto: { getRandomValues: (array: Uint8Array) => Uint8Array };

const now = () => Date.now() / 1000;
const tokenAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

const requireAdminToken = (clientToken: string) => {
  const expected = (process.env.JARVIS_CONVEX_REALTIME_TOKEN ?? "").trim();
  if (!expected || clientToken.trim() !== expected) {
    throw new Error("bad realtime token");
  }
};

const randomString = (alphabet: string, length: number) => {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
};

const activeDevice = async (ctx: any, deviceToken: string) => {
  const token = deviceToken.trim();
  if (!token) {
    throw new Error("missing device token");
  }
  const device = await ctx.db.query("companionDevices")
    .withIndex("by_device_token", (q: any) => q.eq("deviceToken", token))
    .unique();
  if (!device || !device.authorized) {
    throw new Error("bad device token");
  }
  return device;
};

export const createPairingSession = mutation({
  args: {
    clientToken: v.string(),
    label: v.optional(v.string()),
    ttlSeconds: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    requireAdminToken(a.clientToken);
    const createdAt = now();
    const ttl = Math.max(60, Math.min(3600, Math.floor(a.ttlSeconds ?? 900)));
    for (let attempts = 0; attempts < 10; attempts += 1) {
      const code = randomString(codeAlphabet, 6);
      const existing = await ctx.db.query("pairingSessions")
        .withIndex("by_code", (q) => q.eq("code", code))
        .unique();
      if (!existing) {
        await ctx.db.insert("pairingSessions", {
          code,
          label: a.label,
          createdAt,
          expiresAt: createdAt + ttl,
        });
        return { ok: true, code, expiresAt: createdAt + ttl };
      }
    }
    throw new Error("could not allocate pairing code");
  },
});

export const claimPairingSession = mutation({
  args: {
    code: v.string(),
    deviceId: v.string(),
    label: v.optional(v.string()),
    platform: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const code = a.code.trim().toUpperCase();
    const session = await ctx.db.query("pairingSessions")
      .withIndex("by_code", (q) => q.eq("code", code))
      .unique();
    const current = now();
    if (!session || session.claimedAt || session.expiresAt < current) {
      throw new Error("invalid or expired pairing code");
    }

    const existing = await ctx.db.query("companionDevices")
      .withIndex("by_device_id", (q) => q.eq("deviceId", a.deviceId))
      .unique();
    const deviceToken = `jd_${randomString(tokenAlphabet, 40)}`;
    const row = {
      deviceId: a.deviceId,
      deviceToken,
      label: a.label ?? session.label,
      platform: a.platform,
      authorized: true,
      createdAt: existing?.createdAt ?? current,
      lastSeenAt: current,
    };
    if (existing) {
      await ctx.db.replace(existing._id, row);
    } else {
      await ctx.db.insert("companionDevices", row);
    }
    await ctx.db.patch(session._id, {
      claimedAt: current,
      claimedByDeviceId: a.deviceId,
    });
    return {
      ok: true,
      deviceToken,
      deviceId: a.deviceId,
      mode: "convex",
    };
  },
});

export const status = query({
  args: {
    deviceToken: v.string(),
  },
  handler: async (ctx, a) => {
    const device = await activeDevice(ctx, a.deviceToken);
    const runtime = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", "runtime"))
      .unique();
    const ambient = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", "ambient"))
      .unique();
    const dream = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", "dream"))
      .unique();
    const tts = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", "tts"))
      .unique();
    const latestTurn = await ctx.db.query("runtimeState")
      .withIndex("by_key", (q) => q.eq("key", "latest_turn"))
      .unique();
    const skillCatalog = await ctx.db.query("skillCatalog")
      .withIndex("by_key", (q) => q.eq("key", "default"))
      .unique();
    return {
      ok: true,
      mode: "convex",
      deviceId: device.deviceId,
      runtime,
      ambient,
      dream,
      tts,
      latestTurn,
      skillCatalog,
    };
  },
});

export const publishAmbientEvent = mutation({
  args: {
    deviceToken: v.string(),
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
    const device = await activeDevice(ctx, a.deviceToken);
    const current = now();
    await ctx.db.patch(device._id, { lastSeenAt: current });
    const id = await ctx.db.insert("ambientEvents", {
      source: a.source,
      deviceId: a.deviceId || device.deviceId,
      kind: a.kind,
      timestamp: a.timestamp || current,
      personId: a.personId,
      memoryScopeId: a.memoryScopeId,
      payload: a.payload,
      dream: a.dream,
    });
    return { ok: true, id };
  },
});

export const requestTurn = mutation({
  args: {
    deviceToken: v.string(),
    requestId: v.string(),
    deviceId: v.string(),
    requestedBy: v.optional(v.string()),
    text: v.string(),
    createdAt: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    const device = await activeDevice(ctx, a.deviceToken);
    const text = a.text.trim();
    if (!text) {
      throw new Error("no text");
    }
    const existing = await ctx.db.query("controlRequests")
      .withIndex("by_request_id", (q) => q.eq("requestId", a.requestId))
      .unique();
    if (existing) {
      return { ok: true, requestId: a.requestId, status: existing.status };
    }
    const current = now();
    await ctx.db.patch(device._id, { lastSeenAt: current });
    await ctx.db.insert("controlRequests", {
      requestId: a.requestId,
      status: "pending",
      requestedBy: a.requestedBy ?? "ios_companion",
      deviceId: a.deviceId || device.deviceId,
      name: "jarvis_turn",
      args: { text, source: "ios_companion" },
      createdAt: a.createdAt ?? current,
    });
    return { ok: true, requestId: a.requestId, status: "pending" };
  },
});

export const controlRequest = query({
  args: {
    deviceToken: v.string(),
    requestId: v.string(),
  },
  handler: async (ctx, a) => {
    await activeDevice(ctx, a.deviceToken);
    const request = await ctx.db.query("controlRequests")
      .withIndex("by_request_id", (q) => q.eq("requestId", a.requestId))
      .unique();
    if (!request) {
      return null;
    }
    return request;
  },
});
