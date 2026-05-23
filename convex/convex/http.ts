import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api } from "./_generated/api";

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
        const status = /token|pairing|expired|missing/i.test(message) ? 401 : 400;
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

export default http;
