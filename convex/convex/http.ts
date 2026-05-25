import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";

declare const process: { env: Record<string, string | undefined> };

const http = httpRouter();

const jsonResponse = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });

const parseJson = async (request: Request) => {
  const text = await request.text();
  if (!text.trim()) {
    return {};
  }
  return JSON.parse(text);
};

const nativeRuntimeConfig = () => {
  const runtimeURL = (process.env.JARVIS_RUNTIME_PUBLIC_URL ?? "").trim().replace(/\/$/, "");
  const companionToken = (process.env.JARVIS_RUNTIME_COMPANION_TOKEN ?? "").trim();
  const runtimeKind = (process.env.JARVIS_RUNTIME_KIND ?? "").trim().toLowerCase();
  if (!runtimeURL || !companionToken || runtimeKind !== "native") {
    throw new Error("native JARVIS runtime unavailable");
  }
  return { runtimeURL, companionToken };
};

const forbiddenVoiceBackendPattern = /(nsspeech|avspeech|speechsynthesis|web speech|system voice|\bsay\b|tts_pocket|python|jarvis_bridge\.py)/i;

const voiceUnavailable = (reason: string, missing: string[] = []) => ({
  ok: false,
  code: "voice_unavailable",
  error: "voice_unavailable",
  reason,
  spoken: false,
  backend: "none",
  backend_kind: "native_jarvis_voice",
  content_type: "",
  audio_base64: "",
  synthesis_seconds: 0,
  missing,
  fallback_policy: "none",
  wrong_voice_fallback_allowed: false,
  system_voice_fallback_allowed: false,
  native_system_voice_allowed: false,
  python_tts_allowed: false,
  hard_voice_invariant: "jarvis_voice_or_no_voice",
});

const nativeVoicePolicy = () => {
  const runtimeKind = (process.env.JARVIS_RUNTIME_KIND ?? "").trim().toLowerCase();
  const backend = (process.env.JARVIS_NATIVE_VOICE_BACKEND ?? "").trim();
  const voice = (process.env.JARVIS_NATIVE_VOICE_ID ?? process.env.JARVIS_NATIVE_VOICE ?? "").trim();
  const confirmed = (process.env.JARVIS_NATIVE_VOICE_CONFIRMED ?? "").trim() === "1";
  const lowerBackend = backend.toLowerCase();
  const missing: string[] = [];
  if (runtimeKind !== "native") {
    missing.push("native_runtime_kind");
  }
  if (!backend) {
    missing.push("native_voice_backend");
  } else if (!lowerBackend.includes("native") || !lowerBackend.includes("jarvis") || forbiddenVoiceBackendPattern.test(backend)) {
    missing.push("native_jarvis_voice_backend");
  }
  if (!voice) {
    missing.push("native_jarvis_voice_id");
  }
  if (!confirmed) {
    missing.push("native_jarvis_voice_confirmed");
  }
  return { available: missing.length === 0, backend, voice, missing };
};

const assertNativeSpeechPayload = (payload: unknown) => {
  if (typeof payload !== "object" || payload === null) {
    throw new Error("voice policy violation: malformed speech payload");
  }
  const speech = payload as Record<string, unknown>;
  const backendText = [
    speech.backend,
    speech.backend_kind,
    speech.preferred_backend,
    speech.voice,
    speech.fallback_policy,
  ].map((value) => String(value ?? "")).join(" ");
  if (forbiddenVoiceBackendPattern.test(backendText)) {
    throw new Error("voice policy violation: forbidden voice fallback backend");
  }
  if (speech.wrong_voice_fallback_allowed === true ||
      speech.system_voice_fallback_allowed === true ||
      speech.native_system_voice_allowed === true ||
      speech.python_tts_allowed === true) {
    throw new Error("voice policy violation: fallback is enabled");
  }
  if (speech.spoken === true) {
    const audio = String(speech.audio_base64 ?? "");
    const contentType = String(speech.content_type ?? "");
    const backend = String(speech.backend ?? "");
    if (speech.ok !== true || !audio || !contentType.startsWith("audio/")) {
      throw new Error("voice policy violation: fake spoken=true without native audio");
    }
    const lowerBackend = backend.toLowerCase();
    if (!lowerBackend.includes("native") || !lowerBackend.includes("jarvis")) {
      throw new Error("voice policy violation: spoken audio was not a native JARVIS voice backend");
    }
  }
  return speech;
};

const allowedAudioContentTypes = new Set(["audio/mp4", "audio/m4a", "audio/wav", "audio/x-m4a", "audio/aac"]);

const assertAudioPayload = (audioBase64: string, contentType: string) => {
  if (!audioBase64) {
    throw new Error("missing audio");
  }
  if (!allowedAudioContentTypes.has(contentType.toLowerCase())) {
    throw new Error("unsupported audio content type");
  }
  if (audioBase64.length > 8_000_000) {
    throw new Error("audio too large");
  }
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(audioBase64) || audioBase64.length % 4 !== 0) {
    throw new Error("invalid audio encoding");
  }
  const decodedBytes = Math.floor((audioBase64.length * 3) / 4) - (audioBase64.endsWith("==") ? 2 : audioBase64.endsWith("=") ? 1 : 0);
  if (decodedBytes < 128) {
    throw new Error("audio too short");
  }
  if (decodedBytes > 6_000_000) {
    throw new Error("audio too large");
  }
};

const stringArray = (value: unknown) =>
  Array.isArray(value) ? value.map((item) => String(item)) : [];

const route = (
  path: string,
  handler: (ctx: any, body: any) => Promise<unknown>,
) => {
  http.route({
    path,
    method: "POST",
    handler: httpAction(async (ctx, request) => {
      try {
        const body = await parseJson(request);
        const result = await handler(ctx, body);
        return jsonResponse(200, result);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const status = /timed out/i.test(message) ? 504 :
          /runtime unavailable/i.test(message) ? 503 :
          /bad device token|missing device token|pairing|expired/i.test(message) ? 401 : 400;
        return jsonResponse(status, { ok: false, error: message });
      }
    }),
  });
};

route("/app/pair", (ctx, body) => ctx.runMutation(api.companion.claimPairingSession, {
  code: String(body.code ?? ""),
  deviceId: String(body.deviceId ?? ""),
  label: body.label == null ? undefined : String(body.label),
  platform: body.platform == null ? undefined : String(body.platform),
  personId: body.person_id == null && body.personId == null ? undefined : String(body.person_id ?? body.personId),
  memoryScopeId: body.memory_scope_id == null && body.memoryScopeId == null ? undefined : String(body.memory_scope_id ?? body.memoryScopeId),
  role: body.role == null ? undefined : String(body.role),
}));

route("/app/register", (ctx, body) => ctx.runMutation(api.companion.registerDevice, {
  deviceId: String(body.deviceId ?? ""),
  label: body.label == null ? undefined : String(body.label),
  platform: body.platform == null ? undefined : String(body.platform),
  personId: body.person_id == null && body.personId == null ? undefined : String(body.person_id ?? body.personId),
  memoryScopeId: body.memory_scope_id == null && body.memoryScopeId == null ? undefined : String(body.memory_scope_id ?? body.memoryScopeId),
  role: body.role == null ? undefined : String(body.role),
}));

route("/app/status", (ctx, body) => ctx.runQuery(api.companion.status, {
  deviceToken: String(body.deviceToken ?? ""),
}));

route("/app/dream", (ctx, body) => ctx.runQuery(api.companion.dreamStatus, {
  deviceToken: String(body.deviceToken ?? ""),
}));

route("/app/dream/mark", (ctx, body) => ctx.runMutation(api.companion.markDream, {
  deviceToken: String(body.deviceToken ?? ""),
  kind: String(body.kind ?? "micro"),
  summary: body.summary == null ? undefined : String(body.summary),
  source: body.source == null ? undefined : String(body.source),
}));

route("/app/event", (ctx, body) => ctx.runMutation(api.companion.publishAmbientEvent, {
  deviceToken: String(body.deviceToken ?? ""),
  source: String(body.source ?? "ios_companion"),
  deviceId: String(body.deviceId ?? ""),
  kind: String(body.kind ?? "companion_event"),
  timestamp: Number(body.timestamp ?? Date.now() / 1000),
  personId: body.personId == null ? undefined : String(body.personId),
  memoryScopeId: body.memoryScopeId == null ? undefined : String(body.memoryScopeId),
  payload: body.payload ?? {},
  dream: body.dream,
}));

route("/app/onboarding-evidence", (ctx, body) => ctx.runMutation(api.companion.publishOnboardingEvidence, {
  deviceToken: String(body.deviceToken ?? ""),
  recordId: String(body.record_id ?? body.recordId ?? ""),
  kind: String(body.kind ?? ""),
  source: String(body.source ?? "ios_companion_onboarding"),
  timestamp: Number(body.timestamp ?? Date.now() / 1000),
  personId: body.person_id == null && body.personId == null
    ? undefined
    : String(body.person_id ?? body.personId),
  memoryScopeId: body.memory_scope_id == null && body.memoryScopeId == null
    ? undefined
    : String(body.memory_scope_id ?? body.memoryScopeId),
  consentBasis: body.consent_basis == null && body.consentBasis == null
    ? undefined
    : String(body.consent_basis ?? body.consentBasis),
  payloadDigestSHA256: String(body.payload_digest_sha256 ?? body.payloadDigestSHA256 ?? ""),
  payloadSummary: String(body.payload_summary ?? body.payloadSummary ?? ""),
  payload: body.payload ?? {},
  actor: body.actor == null ? undefined : String(body.actor),
  provenance: body.provenance,
}));

route("/app/turn", (ctx, body) => ctx.runMutation(api.companion.requestTurn, {
  deviceToken: String(body.deviceToken ?? ""),
  requestId: String(body.requestId ?? ""),
  deviceId: String(body.deviceId ?? ""),
  requestedBy: body.requestedBy == null ? undefined : String(body.requestedBy),
  text: String(body.text ?? ""),
  createdAt: Number(body.createdAt ?? Date.now() / 1000),
}));

route("/app/control-status", (ctx, body) => ctx.runQuery(api.companion.controlRequest, {
  deviceToken: String(body.deviceToken ?? ""),
  requestId: String(body.requestId ?? ""),
}));

route("/app/realtime-turn", async (ctx, body) => {
  const deviceToken = String(body.deviceToken ?? "");
  await ctx.runQuery(api.companion.status, { deviceToken });
  const text = String(body.text ?? "").trim();
  if (!text) {
    throw new Error("no text");
  }
  await ctx.runMutation(api.companion.recordCompanionActivity, {
    deviceToken,
    deviceId: body.deviceId == null ? undefined : String(body.deviceId),
    event: "operator_turn",
  });

  const { runtimeURL, companionToken } = nativeRuntimeConfig();

  const response = await fetch(`${runtimeURL}/companion/turn`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "accept": "application/json",
      "x-jarvis-companion-token": companionToken,
    },
    body: JSON.stringify({ text }),
  });
  const responseText = await response.text();
  let payload: unknown = {};
  if (responseText.trim()) {
    payload = JSON.parse(responseText);
  }
  if (!response.ok) {
    const message = typeof payload === "object" && payload !== null && "error" in payload
      ? String((payload as { error?: unknown }).error)
      : `runtime HTTP ${response.status}`;
    throw new Error(message);
  }
  return payload;
});

route("/app/speech", async (ctx, body) => {
  const deviceToken = String(body.deviceToken ?? "");
  await ctx.runQuery(api.companion.status, { deviceToken });
  const text = String(body.text ?? "").trim();
  if (!text) {
    throw new Error("no text");
  }

  const voicePolicy = nativeVoicePolicy();
  if (!voicePolicy.available) {
    return voiceUnavailable(
      "Native JARVIS voice backend is not configured; returning silence instead of a wrong voice.",
      voicePolicy.missing,
    );
  }

  const { runtimeURL, companionToken } = nativeRuntimeConfig();

  const response = await fetch(`${runtimeURL}/companion/speech`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "accept": "application/json",
      "x-jarvis-companion-token": companionToken,
    },
    body: JSON.stringify({
      text,
      voice_policy: {
        require_jarvis_voice: true,
        require_native_backend: true,
        forbid_python_tts: true,
        forbid_system_voice: true,
        fallback_policy: "none",
      },
    }),
  });
  const responseText = await response.text();
  let payload: unknown = {};
  if (responseText.trim()) {
    payload = JSON.parse(responseText);
  }
  if (!response.ok) {
    if (typeof payload === "object" && payload !== null) {
      const code = String((payload as { code?: unknown; error?: unknown }).code ?? (payload as { error?: unknown }).error ?? "");
      if (code === "voice_unavailable") {
        return {
          ...voiceUnavailable("Native JARVIS voice service returned voice_unavailable.", []),
          ...(payload as Record<string, unknown>),
          spoken: false,
        };
      }
    }
    const message = typeof payload === "object" && payload !== null && "error" in payload
      ? String((payload as { error?: unknown }).error)
      : `runtime HTTP ${response.status}`;
    throw new Error(message);
  }
  const speech = assertNativeSpeechPayload(payload);
  if (speech.ok === false || speech.spoken === false) {
    return { ...speech, spoken: false };
  }
  return speech;
});

route("/app/transcribe", async (ctx, body) => {
  const deviceToken = String(body.deviceToken ?? "");
  await ctx.runQuery(api.companion.status, { deviceToken });
  const audioBase64 = String(body.audio_base64 ?? body.audioBase64 ?? "").trim();
  const contentType = String(body.content_type ?? body.contentType ?? "audio/mp4").trim().toLowerCase();
  assertAudioPayload(audioBase64, contentType);

  const { runtimeURL, companionToken } = nativeRuntimeConfig();

  const response = await fetch(`${runtimeURL}/companion/transcribe`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "accept": "application/json",
      "x-jarvis-companion-token": companionToken,
    },
    body: JSON.stringify({
      audio_base64: audioBase64,
      content_type: contentType,
    }),
  });
  const responseText = await response.text();
  let payload: unknown = {};
  if (responseText.trim()) {
    payload = JSON.parse(responseText);
  }
  if (!response.ok) {
    const message = typeof payload === "object" && payload !== null && "error" in payload
      ? String((payload as { error?: unknown }).error)
      : `runtime HTTP ${response.status}`;
    throw new Error(message);
  }
  return payload;
});

route("/app/voice-enrollment", (ctx, body) => ctx.runMutation(api.companion.recordVoiceEnrollmentStatus, {
  deviceToken: String(body.deviceToken ?? ""),
  personId: String(body.person_id ?? body.personId ?? ""),
  memoryScopeId: body.memory_scope_id == null && body.memoryScopeId == null
    ? undefined
    : String(body.memory_scope_id ?? body.memoryScopeId),
  status: String(body.status ?? ""),
  sampleCount: Number(body.sample_count ?? body.sampleCount ?? 0),
  sampleDigestsSHA256: stringArray(body.sample_digests_sha256 ?? body.sampleDigestsSHA256),
  backend: body.backend == null ? undefined : String(body.backend),
  handoffId: body.handoff_id == null && body.handoffId == null
    ? undefined
    : String(body.handoff_id ?? body.handoffId),
  modelId: body.model_id == null && body.modelId == null
    ? undefined
    : String(body.model_id ?? body.modelId),
  blockedReason: body.blocked_reason == null && body.blockedReason == null
    ? undefined
    : String(body.blocked_reason ?? body.blockedReason),
  storagePolicy: body.storage_policy ?? body.storagePolicy ?? {},
  revokedAt: body.revoked_at == null && body.revokedAt == null
    ? undefined
    : Number(body.revoked_at ?? body.revokedAt),
}));

export default http;
