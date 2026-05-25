import { mutation, query } from "./_generated/server";
import { v } from "convex/values";
import {
  cleanAmbientEventArgs,
  deriveDreamStatus,
  markDream as markDreamState,
  publishDerivedDreamStatus,
  recordOperatorActivity,
} from "./_dream";

declare const process: { env: Record<string, string | undefined> };
declare const crypto: { getRandomValues: (array: Uint8Array) => Uint8Array };

const now = () => Date.now() / 1000;
const tokenAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const voiceEnrollmentStatuses = new Set([
  "not_started",
  "consented_pending_samples",
  "samples_captured_pending_model",
  "model_enrollment_blocked",
  "enrolled",
  "revoked",
]);

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

const optionalTrimmed = (value: string | undefined) => {
  const trimmed = (value ?? "").trim();
  return trimmed ? trimmed : undefined;
};

const normalizePersonScope = (personId?: string, memoryScopeId?: string, requirePair = true) => {
  const cleanPersonId = optionalTrimmed(personId)?.toLowerCase();
  const cleanMemoryScopeId = optionalTrimmed(memoryScopeId);
  if (requirePair && cleanPersonId && !cleanMemoryScopeId) {
    throw new Error("memory scope required with person id");
  }
  if (requirePair && cleanMemoryScopeId && !cleanPersonId) {
    throw new Error("person id required with memory scope");
  }
  if (cleanMemoryScopeId && !cleanMemoryScopeId.startsWith("person.")) {
    throw new Error("memory scope must use person.* namespace");
  }
  return { personId: cleanPersonId, memoryScopeId: cleanMemoryScopeId };
};

const assertSHA256Digest = (digest: string) => {
  if (!/^[a-f0-9]{64}$/.test(digest.trim().toLowerCase())) {
    throw new Error("invalid sha256 digest");
  }
};

const assertSHA256Digests = (digests: string[]) => {
  if (digests.length > 24) {
    throw new Error("too many voice sample digests");
  }
  for (const digest of digests) {
    if (!/^[a-f0-9]{64}$/.test(digest)) {
      throw new Error("invalid voice sample digest");
    }
  }
};

const upsertCompanionDevice = async (
  ctx: any,
  args: { deviceId: string; label?: string; platform?: string; personId?: string; memoryScopeId?: string; role?: string },
) => {
  const deviceId = args.deviceId.trim();
  if (!deviceId) {
    throw new Error("missing device id");
  }
  const personScope = normalizePersonScope(args.personId, args.memoryScopeId);
  const current = now();
  const existing = await ctx.db.query("companionDevices")
    .withIndex("by_device_id", (q: any) => q.eq("deviceId", deviceId))
    .unique();
  const deviceToken = existing?.deviceToken ?? `jd_${randomString(tokenAlphabet, 40)}`;
  const row = {
    deviceId,
    deviceToken,
    label: args.label ?? existing?.label,
    platform: args.platform ?? existing?.platform,
    personId: personScope.personId ?? existing?.personId,
    memoryScopeId: personScope.memoryScopeId ?? existing?.memoryScopeId,
    role: optionalTrimmed(args.role) ?? existing?.role,
    authorized: true,
    createdAt: existing?.createdAt ?? current,
    lastSeenAt: current,
  };
  if (existing) {
    await ctx.db.replace(existing._id, row);
  } else {
    await ctx.db.insert("companionDevices", row);
  }
  return {
    ok: true,
    deviceToken,
    deviceId,
    mode: "convex",
  };
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
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    role: v.optional(v.string()),
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

    const result = await upsertCompanionDevice(ctx, {
      deviceId: a.deviceId,
      label: a.label ?? session.label,
      platform: a.platform,
      personId: a.personId,
      memoryScopeId: a.memoryScopeId,
      role: a.role,
    });
    await ctx.db.patch(session._id, {
      claimedAt: current,
      claimedByDeviceId: a.deviceId,
    });
    return result;
  },
});

export const registerDevice = mutation({
  args: {
    deviceId: v.string(),
    label: v.optional(v.string()),
    platform: v.optional(v.string()),
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    role: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    return upsertCompanionDevice(ctx, {
      deviceId: a.deviceId,
      label: a.label,
      platform: a.platform,
      personId: a.personId,
      memoryScopeId: a.memoryScopeId,
      role: a.role,
    });
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
    const dreamStatus = await deriveDreamStatus(ctx);
    return {
      ok: true,
      mode: "convex",
      deviceId: device.deviceId,
      runtime,
      ambient,
      dream: dream
        ? { ...dream, payload: dreamStatus }
        : { key: "dream", source: "convex_companion", updatedAt: now(), payload: dreamStatus },
      tts,
      latestTurn,
      skillCatalog,
    };
  },
});

export const dreamStatus = query({
  args: {
    deviceToken: v.string(),
  },
  handler: async (ctx, a) => {
    await activeDevice(ctx, a.deviceToken);
    return await deriveDreamStatus(ctx);
  },
});

export const markDream = mutation({
  args: {
    deviceToken: v.string(),
    kind: v.string(),
    summary: v.optional(v.string()),
    source: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const device = await activeDevice(ctx, a.deviceToken);
    await ctx.db.patch(device._id, { lastSeenAt: now() });
    return await markDreamState(ctx, {
      kind: a.kind,
      summary: a.summary,
      source: a.source ?? "ios_companion",
    });
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
    const personScope = normalizePersonScope(a.personId, a.memoryScopeId);
    await ctx.db.patch(device._id, { lastSeenAt: current });
    const id = await ctx.db.insert("ambientEvents", cleanAmbientEventArgs({
      source: a.source,
      deviceId: a.deviceId || device.deviceId,
      kind: a.kind,
      timestamp: a.timestamp || current,
      personId: personScope.personId,
      memoryScopeId: personScope.memoryScopeId,
      payload: a.payload,
      dream: a.dream,
    }));
    const dream = await publishDerivedDreamStatus(ctx, "companion_event");
    return { ok: true, id, dream };
  },
});

export const recordCompanionActivity = mutation({
  args: {
    deviceToken: v.string(),
    deviceId: v.optional(v.string()),
    event: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const device = await activeDevice(ctx, a.deviceToken);
    await ctx.db.patch(device._id, { lastSeenAt: now() });
    const dream = await recordOperatorActivity(ctx, a.event ?? "operator_turn", "ios_companion");
    return { ok: true, deviceId: a.deviceId ?? device.deviceId, dream };
  },
});

export const publishOnboardingEvidence = mutation({
  args: {
    deviceToken: v.string(),
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
    actor: v.optional(v.string()),
    provenance: v.optional(v.any()),
  },
  handler: async (ctx, a) => {
    const device = await activeDevice(ctx, a.deviceToken);
    const recordId = a.recordId.trim().toLowerCase();
    if (!recordId) {
      throw new Error("missing evidence record id");
    }
    const kind = a.kind.trim();
    if (!kind) {
      throw new Error("missing evidence kind");
    }
    const digest = a.payloadDigestSHA256.trim().toLowerCase();
    assertSHA256Digest(digest);
    const personScope = normalizePersonScope(a.personId, a.memoryScopeId, false);
    const current = now();
    await ctx.db.patch(device._id, { lastSeenAt: current });
    const row = {
      recordId,
      kind,
      source: a.source.trim() || "ios_companion_onboarding",
      timestamp: a.timestamp || current,
      personId: personScope.personId,
      memoryScopeId: personScope.memoryScopeId,
      consentBasis: optionalTrimmed(a.consentBasis),
      deviceId: device.deviceId,
      actor: optionalTrimmed(a.actor),
      provenance: a.provenance,
      payloadDigestSHA256: digest,
      payloadSummary: a.payloadSummary.trim().slice(0, 500),
      payload: a.payload,
    };
    const existing = await ctx.db.query("onboardingEvidence")
      .withIndex("by_record_id", (q) => q.eq("recordId", recordId))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, row);
      return { ok: true, recordId, id: existing._id };
    }
    const id = await ctx.db.insert("onboardingEvidence", row);
    return { ok: true, recordId, id };
  },
});

export const onboardingEvidence = query({
  args: {
    deviceToken: v.string(),
    personId: v.optional(v.string()),
    memoryScopeId: v.optional(v.string()),
    kind: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    await activeDevice(ctx, a.deviceToken);
    const take = Math.max(1, Math.min(100, Math.floor(a.limit ?? 50)));
    const personScope = normalizePersonScope(a.personId, a.memoryScopeId);
    if (personScope.memoryScopeId) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_memory_scope_time", (q) => q.eq("memoryScopeId", personScope.memoryScopeId!))
        .order("desc")
        .take(take);
    }
    if (personScope.personId) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_person_time", (q) => q.eq("personId", personScope.personId!))
        .order("desc")
        .take(take);
    }
    const kind = optionalTrimmed(a.kind);
    if (kind) {
      return await ctx.db.query("onboardingEvidence")
        .withIndex("by_kind_time", (q) => q.eq("kind", kind))
        .order("desc")
        .take(take);
    }
    return await ctx.db.query("onboardingEvidence").order("desc").take(take);
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
    await recordOperatorActivity(ctx, "operator_turn", a.requestedBy ?? "ios_companion");
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

export const recordVoiceEnrollmentStatus = mutation({
  args: {
    deviceToken: v.string(),
    personId: v.string(),
    memoryScopeId: v.optional(v.string()),
    status: v.string(),
    sampleCount: v.number(),
    sampleDigestsSHA256: v.array(v.string()),
    backend: v.optional(v.string()),
    handoffId: v.optional(v.string()),
    modelId: v.optional(v.string()),
    blockedReason: v.optional(v.string()),
    storagePolicy: v.any(),
    revokedAt: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    await activeDevice(ctx, a.deviceToken);
    const personScope = normalizePersonScope(a.personId, a.memoryScopeId);
    const personId = personScope.personId ?? "";
    if (!personId) {
      throw new Error("missing person id");
    }
    if (!voiceEnrollmentStatuses.has(a.status)) {
      throw new Error("invalid voice enrollment status");
    }
    const sampleCount = Math.max(0, Math.min(24, Math.floor(a.sampleCount)));
    const sampleDigestsSHA256 = a.sampleDigestsSHA256.map((digest) => digest.trim().toLowerCase());
    assertSHA256Digests(sampleDigestsSHA256);
    if (sampleDigestsSHA256.length > sampleCount && sampleCount > 0) {
      throw new Error("sample digest count exceeds sample count");
    }
    if (a.status === "enrolled" && !optionalTrimmed(a.modelId)) {
      throw new Error("enrolled voice status requires model id");
    }
    if (a.status === "model_enrollment_blocked" && !optionalTrimmed(a.blockedReason)) {
      throw new Error("blocked voice status requires reason");
    }

    const current = now();
    const row = {
      personId,
      memoryScopeId: personScope.memoryScopeId,
      status: a.status,
      sampleCount,
      sampleDigestsSHA256,
      backend: optionalTrimmed(a.backend),
      handoffId: optionalTrimmed(a.handoffId),
      modelId: optionalTrimmed(a.modelId),
      blockedReason: optionalTrimmed(a.blockedReason),
      storagePolicy: a.storagePolicy,
      updatedAt: current,
      revokedAt: a.revokedAt,
    };
    const existing = await ctx.db.query("voiceEnrollmentRecords")
      .withIndex("by_person_id", (q) => q.eq("personId", personId))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, row);
      return { ok: true, person_id: personId, status: a.status, id: existing._id };
    }
    const id = await ctx.db.insert("voiceEnrollmentRecords", row);
    return { ok: true, person_id: personId, status: a.status, id };
  },
});

export const voiceEnrollmentStatus = query({
  args: {
    deviceToken: v.string(),
    personId: v.optional(v.string()),
    status: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, a) => {
    await activeDevice(ctx, a.deviceToken);
    const take = Math.max(1, Math.min(100, Math.floor(a.limit ?? 50)));
    const personId = optionalTrimmed(a.personId)?.toLowerCase();
    if (personId) {
      return await ctx.db.query("voiceEnrollmentRecords")
        .withIndex("by_person_id", (q) => q.eq("personId", personId))
        .take(take);
    }
    const status = optionalTrimmed(a.status);
    if (status) {
      return await ctx.db.query("voiceEnrollmentRecords")
        .withIndex("by_status_updated", (q) => q.eq("status", status))
        .order("desc")
        .take(take);
    }
    return await ctx.db.query("voiceEnrollmentRecords").order("desc").take(take);
  },
});
