const DREAM_KEY = "dream";
const RUNTIME_KEY = "runtime";

const RECENT_WINDOW_SECONDS = 15 * 60;
const EVENT_LIMIT = 200;
const DEFAULT_MICRO_IDLE_MINUTES = 7;
const DEFAULT_DEEP_IDLE_MINUTES = 45;
const DEFAULT_DEEP_OVERDUE_HOURS = 20;

type JsonRecord = Record<string, any>;

const now = () => Date.now() / 1000;

const asRecord = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as JsonRecord
    : undefined;

const text = (value: unknown, limit = 160) => String(value ?? "").trim().slice(0, limit);

const lowerText = (value: unknown, limit = 160) => text(value, limit).toLowerCase();

const numberish = (value: unknown): number | undefined => {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
};

const timestampSeconds = (value: unknown): number | undefined => {
  const parsed = numberish(value);
  if (parsed === undefined) {
    return undefined;
  }
  return parsed > 10_000_000_000 ? parsed / 1000 : parsed;
};

const boolish = (value: unknown): boolean | undefined => {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return value !== 0;
  }
  if (typeof value === "string") {
    const lowered = value.trim().toLowerCase();
    if (["1", "true", "yes", "y", "on"].includes(lowered)) {
      return true;
    }
    if (["0", "false", "no", "n", "off"].includes(lowered)) {
      return false;
    }
  }
  return undefined;
};

const eventPayload = (event: JsonRecord) => asRecord(event.payload) ?? {};
const eventExtra = (event: JsonRecord) => asRecord(eventPayload(event).extra) ?? {};

const field = (event: JsonRecord, ...keys: string[]) => {
  const payload = eventPayload(event);
  const extra = eventExtra(event);
  for (const key of keys) {
    if (event[key] !== undefined) {
      return event[key];
    }
    if (payload[key] !== undefined) {
      return payload[key];
    }
    if (extra[key] !== undefined) {
      return extra[key];
    }
  }
  return undefined;
};

const sourceOf = (event: JsonRecord) => text(field(event, "source"), 80) || "companion";
const kindOf = (event: JsonRecord) => lowerText(field(event, "kind"), 80) || "state";
const eventTimestamp = (event: JsonRecord) => timestampSeconds(field(event, "timestamp")) ?? 0;

const uniqueSorted = (values: string[]) => Array.from(new Set(values.filter(Boolean))).sort();

const runtimePayload = async (ctx: any, key: string) => {
  const state = await ctx.db.query("runtimeState")
    .withIndex("by_key", (q: any) => q.eq("key", key))
    .unique();
  return {
    state,
    payload: asRecord(state?.payload) ?? {},
  };
};

const upsertRuntimePayload = async (ctx: any, key: string, source: string, payload: JsonRecord, updatedAt = now()) => {
  const existing = await ctx.db.query("runtimeState")
    .withIndex("by_key", (q: any) => q.eq("key", key))
    .unique();
  const row = { key, source, updatedAt, payload };
  if (existing) {
    await ctx.db.replace(existing._id, row);
    return existing._id;
  }
  return await ctx.db.insert("runtimeState", row);
};

export const cleanAmbientEventArgs = (a: JsonRecord) => ({
  source: text(a.source, 80) || "companion",
  deviceId: text(a.deviceId ?? a.device_id, 120) || text(a.source, 80) || "companion",
  kind: text(a.kind, 80) || "state",
  timestamp: timestampSeconds(a.timestamp) ?? now(),
  personId: a.personId == null ? undefined : text(a.personId, 120),
  memoryScopeId: a.memoryScopeId == null ? undefined : text(a.memoryScopeId, 120),
  payload: a.payload ?? {},
  dream: a.dream,
});

const signalContext = (event: JsonRecord, current: number) => {
  const source = sourceOf(event);
  const kind = kindOf(event);
  const timestamp = eventTimestamp(event);
  const recent = timestamp > 0 && timestamp >= current - RECENT_WINDOW_SECONDS;
  const motion = lowerText(field(event, "motion"), 120);
  const focus = lowerText(field(event, "focus"), 120);
  const location = lowerText(field(event, "location"), 160);
  const checkIn = lowerText(field(event, "check_in", "checkIn"), 160);
  const vehicleMotion = lowerText(field(event, "vehicle_motion", "vehicleMotion"), 120);
  const routeState = lowerText(field(event, "route_state", "routeState"), 120);
  const interactionMode = lowerText(field(event, "interaction_mode", "interactionMode"), 120);
  const active = boolish(field(event, "active"));
  const driving = boolish(field(event, "driving"));
  const carPlayConnected = boolish(field(event, "carplay_connected", "carPlayConnected"));
  const sleepFocus = boolish(field(event, "sleep_focus", "sleepFocus"));
  const charging = boolish(field(event, "charging"));
  const activeSignals: string[] = [];
  const quietSignals: string[] = [];

  if (recent) {
    if (active === true || ["operator_turn", "voice", "screen_active", "device_action"].includes(kind)) {
      activeSignals.push(`${source}:active`);
    }
    if (["walking", "running", "driving", "workout", "high", "lab_active"].includes(motion)) {
      activeSignals.push(`${source}:motion=${motion}`);
    }
    if (driving === true) {
      activeSignals.push(`${source}:driving`);
    }
    if (carPlayConnected === true && !["parked", "stopped", "idle"].includes(vehicleMotion)) {
      activeSignals.push(`${source}:carplay`);
    }
    if (["moving", "driving", "highway", "city", "traffic"].includes(vehicleMotion)) {
      activeSignals.push(`${source}:vehicle=${vehicleMotion}`);
    }
    if (["navigating", "rerouting", "guidance_active"].includes(routeState)) {
      activeSignals.push(`${source}:route=${routeState}`);
    }
    if (["carplay", "driving"].includes(interactionMode) && !["parked", "stopped", "idle"].includes(vehicleMotion)) {
      activeSignals.push(`${source}:mode=${interactionMode}`);
    }
    if (["needs_attention", "responded", "awake"].includes(checkIn)) {
      activeSignals.push(`${source}:check_in=${checkIn}`);
    }
  }

  if (sleepFocus === true || ["sleep", "do not disturb", "dnd", "rest"].includes(focus)) {
    quietSignals.push(`${source}:focus=${focus || "sleep"}`);
  }
  if (charging === true) {
    quietSignals.push(`${source}:charging`);
  }
  if (["still", "resting", "low", "none", "sleeping"].includes(motion)) {
    quietSignals.push(`${source}:motion=${motion}`);
  }
  if (["home", "bedroom", "office", "lab"].includes(location)) {
    quietSignals.push(`${source}:location=${location}`);
  }

  const operatorActivity =
    active === true ||
    ["operator_turn", "voice", "screen_active", "device_action"].includes(kind) ||
    ["watch_check_in", "needs_attention", "responded", "awake"].includes(checkIn);

  return {
    activeSignals,
    quietSignals,
    operatorActivityAt: operatorActivity && timestamp > 0 ? timestamp : undefined,
  };
};

export const deriveDreamStatus = async (ctx: any, current = now()) => {
  const { payload: dreamPayload } = await runtimePayload(ctx, DREAM_KEY);
  const { payload: runtime } = await runtimePayload(ctx, RUNTIME_KEY);
  const events = await ctx.db.query("ambientEvents")
    .withIndex("by_time")
    .order("desc")
    .take(EVENT_LIMIT);

  const latestByDevice = new Map<string, JsonRecord>();
  const recent: JsonRecord[] = [];
  for (const event of events as JsonRecord[]) {
    const timestamp = eventTimestamp(event);
    if (timestamp >= current - RECENT_WINDOW_SECONDS) {
      recent.push(event);
    }
    const deviceId = text(field(event, "deviceId", "device_id"), 120) || sourceOf(event);
    if (!latestByDevice.has(deviceId)) {
      latestByDevice.set(deviceId, event);
    }
  }

  const observations = [...recent, ...latestByDevice.values()];
  const activeSignals: string[] = [];
  const quietSignals: string[] = [];
  const activityCandidates: number[] = [];
  const runtimeActivity = timestampSeconds(runtime.last_operator_activity_at);
  if (runtimeActivity !== undefined) {
    activityCandidates.push(runtimeActivity);
  }

  for (const event of observations) {
    const context = signalContext(event, current);
    activeSignals.push(...context.activeSignals);
    quietSignals.push(...context.quietSignals);
    if (context.operatorActivityAt !== undefined) {
      activityCandidates.push(context.operatorActivityAt);
    }
  }

  const lastActivity = activityCandidates.length > 0 ? Math.max(...activityCandidates) : undefined;
  const idleSeconds = lastActivity === undefined ? null : Math.max(0, current - lastActivity);
  const microIdleSeconds = (numberish(dreamPayload.micro_idle_minutes) ?? DEFAULT_MICRO_IDLE_MINUTES) * 60;
  const deepIdleSeconds = (numberish(dreamPayload.deep_idle_minutes) ?? DEFAULT_DEEP_IDLE_MINUTES) * 60;
  const deepOverdueSeconds = (numberish(dreamPayload.deep_overdue_hours) ?? DEFAULT_DEEP_OVERDUE_HOURS) * 3600;
  const lastDeepDreamAt = timestampSeconds(dreamPayload.last_deep_dream_at);
  const deepAge = lastDeepDreamAt === undefined ? undefined : Math.max(0, current - lastDeepDreamAt);
  const deepOverdue = deepAge === undefined || deepAge >= deepOverdueSeconds;
  const cleanActiveSignals = uniqueSorted(activeSignals);
  const cleanQuietSignals = uniqueSorted(quietSignals);
  const idleForMicro = idleSeconds !== null && idleSeconds >= microIdleSeconds;
  const idleForDeep = idleSeconds !== null && idleSeconds >= deepIdleSeconds;
  const quietEnough = cleanQuietSignals.length > 0 && cleanActiveSignals.length === 0;

  return {
    micro_ready: idleForMicro && cleanActiveSignals.length === 0,
    deep_ready: idleForDeep && quietEnough && deepOverdue,
    quiet_enough: quietEnough,
    deep_overdue: deepOverdue,
    idle_seconds: idleSeconds,
    active_signals: cleanActiveSignals,
    quiet_signals: cleanQuietSignals,
    last_micro_dream_at: timestampSeconds(dreamPayload.last_micro_dream_at) ?? null,
    last_deep_dream_at: lastDeepDreamAt ?? null,
    last_transition_dream_at: timestampSeconds(dreamPayload.last_transition_dream_at) ?? null,
    decision_boundary: "observable companion context only; schedule from idle/readiness signals, not app close events",
  };
};

export const publishDerivedDreamStatus = async (ctx: any, source = "convex_companion") => {
  const current = now();
  const { payload } = await runtimePayload(ctx, DREAM_KEY);
  const status = await deriveDreamStatus(ctx, current);
  await upsertRuntimePayload(ctx, DREAM_KEY, source, { ...payload, ...status }, current);
  return status;
};

export const recordOperatorActivity = async (ctx: any, event: string, source = "convex_companion") => {
  const current = now();
  const { payload } = await runtimePayload(ctx, RUNTIME_KEY);
  await upsertRuntimePayload(ctx, RUNTIME_KEY, source, {
    ...payload,
    last_operator_activity_at: current,
    last_runtime_event: text(event, 120) || "operator_activity",
  }, current);
  return await publishDerivedDreamStatus(ctx, source);
};

export const markDream = async (
  ctx: any,
  args: { kind?: string; summary?: string; source?: string },
) => {
  const kind = lowerText(args.kind || "micro", 40);
  if (!["micro", "deep", "transition"].includes(kind)) {
    throw new Error("kind must be micro, deep, or transition");
  }
  const current = now();
  const source = text(args.source, 80) || "convex_companion";
  const { payload } = await runtimePayload(ctx, DREAM_KEY);
  const key = kind === "micro"
    ? "last_micro_dream_at"
    : kind === "deep"
      ? "last_deep_dream_at"
      : "last_transition_dream_at";
  await upsertRuntimePayload(ctx, DREAM_KEY, source, {
    ...payload,
    [key]: current,
  }, current);
  await ctx.db.insert("ambientEvents", {
    source,
    deviceId: "jarvis",
    kind: `dream_${kind}`,
    timestamp: current,
    payload: {
      kind,
      summary: text(args.summary, 500),
      source,
    },
  });
  const dream = await publishDerivedDreamStatus(ctx, source);
  return { ok: true, kind, timestamp: current, dream };
};
