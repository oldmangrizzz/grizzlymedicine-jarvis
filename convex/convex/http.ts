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

const sleep = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));
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
}));

route("/app/register", (ctx, body) => ctx.runMutation(api.companion.registerDevice, {
  deviceId: String(body.deviceId ?? ""),
  label: body.label == null ? undefined : String(body.label),
  platform: body.platform == null ? undefined : String(body.platform),
}));

route("/app/status", (ctx, body) => ctx.runQuery(api.companion.status, {
  deviceToken: String(body.deviceToken ?? ""),
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

  const runtimeURL = (process.env.JARVIS_RUNTIME_PUBLIC_URL ?? "").trim().replace(/\/$/, "");
  const companionToken = (process.env.JARVIS_RUNTIME_COMPANION_TOKEN ?? "").trim();
  if (runtimeURL && companionToken) {
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
  }

  const requestId = `realtime-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  await ctx.runMutation(api.companion.requestTurn, {
    deviceToken,
    requestId,
    deviceId: String(body.deviceId ?? ""),
    requestedBy: "ios_companion_realtime",
    text,
    createdAt: Date.now() / 1000,
  });
  const startedAt = Date.now();
  while (Date.now() - startedAt < 90_000) {
    const request = await ctx.runQuery(api.companion.controlRequest, { deviceToken, requestId });
    if (request?.status === "done") {
      return request.output ?? { ok: true, reply: "" };
    }
    if (request?.status === "error") {
      throw new Error(request.error ?? "runtime error");
    }
    if (request?.status === "refused") {
      throw new Error(request.reason ?? "runtime refused command");
    }
    await sleep(250);
  }
  throw new Error("runtime timed out before JARVIS answered");
});

route("/app/speech", async (ctx, body) => {
  const deviceToken = String(body.deviceToken ?? "");
  await ctx.runQuery(api.companion.status, { deviceToken });
  const text = String(body.text ?? "").trim();
  if (!text) {
    throw new Error("no text");
  }

  const runtimeURL = (process.env.JARVIS_RUNTIME_PUBLIC_URL ?? "").trim().replace(/\/$/, "");
  const companionToken = (process.env.JARVIS_RUNTIME_COMPANION_TOKEN ?? "").trim();
  if (!runtimeURL || !companionToken) {
    throw new Error("JARVIS voice runtime unavailable");
  }

  const response = await fetch(`${runtimeURL}/companion/speech`, {
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

route("/app/transcribe", async (ctx, body) => {
  const deviceToken = String(body.deviceToken ?? "");
  await ctx.runQuery(api.companion.status, { deviceToken });
  const audioBase64 = String(body.audio_base64 ?? body.audioBase64 ?? "").trim();
  const contentType = String(body.content_type ?? body.contentType ?? "audio/mp4").trim().toLowerCase();
  assertAudioPayload(audioBase64, contentType);

  const runtimeURL = (process.env.JARVIS_RUNTIME_PUBLIC_URL ?? "").trim().replace(/\/$/, "");
  const companionToken = (process.env.JARVIS_RUNTIME_COMPANION_TOKEN ?? "").trim();
  if (!runtimeURL || !companionToken) {
    throw new Error("JARVIS voice runtime unavailable");
  }

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

export default http;
