#!/usr/bin/env python3
"""JARVIS bridge — the localhost server that exposes the running runtime to the surfaces.

The Quest 3 / Viture glasses / iPhone / iPad all talk to JARVIS through this one door. It is
deliberately small and locked down:

  * binds 127.0.0.1 ONLY (never a public interface) — it's a local door, not a web service,
  * every request needs the shared token (X-JARVIS-Token); printed once on startup,
  * /skill goes through the SAME guarded SkillRegistry — SENSITIVE/DESTRUCTIVE require
    confirm:true in the body (that flag IS the operator's spoken 'yes' relayed by the UI);
    PROHIBITED is refused; everything audited,
  * /scene returns a governed scene-spec (validated against ui_spec before it ever leaves).

Endpoints:
  GET  /state            -> {endocrine, ec_tone, model, field}
  GET  /scene            -> a validated scene-spec for the spatial UI to render
  POST /turn   {text}    -> {reply, drift, endocrine, ec_tone, ethics_conflict}
  POST /skill  {name,args,confirm} -> SkillResult
"""
from __future__ import annotations
import os, json, secrets, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ui_spec


def _default_scene(skill_names):
    """A governed holographic dashboard. Validated before it is ever served."""
    return {"type": "panel", "title": "JARVIS", "children": [
        {"type": "status", "text": "online · oriented"},
        {"type": "text", "text": "Speak, or pick a node."},
        {"type": "button", "label": "Deliberate", "action": {"skill": "deliberate"}},
        {"type": "button", "label": "Recall origin", "action": {"skill": "recall_origin"}},
    ]}


def make_handler(rt, token):
    lock = threading.Lock()      # serialize runtime access across request worker threads

    class H(BaseHTTPRequestHandler):
        _lock = lock
        def log_message(self, *a):  # quiet
            pass

        def _ok(self) -> bool:
            return self.headers.get("X-JARVIS-Token") == token

        def _cors(self):
            # localhost + token-gated; allow the spatial surface (a separate origin) to call in.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "X-JARVIS-Token, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

        def do_OPTIONS(self):
            self.send_response(204); self._cors(); self.end_headers()

        def _json(self, code, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self._cors()
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n).decode("utf-8"))
            except Exception:
                return {}

        def do_GET(self):
            try:
                with self._lock:
                    return self._do_GET()
            except Exception as e:
                return self._json(500, {"error": f"{type(e).__name__}: {str(e)[:200]}"})

        def _do_GET(self):
            if not self._ok():
                return self._json(401, {"error": "bad token"})
            if self.path == "/state":
                return self._json(200, {"endocrine": rt.endo.state(), "ec_tone": rt.ecs.tone(),
                                        "model": rt.rotator.current()[1],
                                        "field": rt.field.snapshot()[:20]})
            if self.path == "/scene":
                spec = _default_scene({s["name"] for s in rt.skills.list()})
                ok, errs = ui_spec.validate(spec, {s["name"] for s in rt.skills.list()})
                if not ok:
                    return self._json(500, {"error": "scene failed validation", "details": errs})
                return self._json(200, {"scene": spec})
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            try:
                with self._lock:
                    return self._do_POST()
            except Exception as e:
                return self._json(500, {"error": f"{type(e).__name__}: {str(e)[:200]}"})

        def _do_POST(self):
            if not self._ok():
                return self._json(401, {"error": "bad token"})
            b = self._body()
            if self.path == "/turn":
                text = (b.get("text") or "").strip()
                if not text:
                    return self._json(400, {"error": "no text"})
                r = rt.turn(user_text=text)
                return self._json(200, {k: r.get(k) for k in
                                        ("reply", "drift_to_prototype", "endocrine", "ec_tone",
                                         "ethics_conflict", "model")})
            if self.path == "/skill":
                name = b.get("name")
                args = b.get("args") or {}
                confirmed = bool(b.get("confirm"))
                res = rt.skill(name, args, confirm=lambda s, a: confirmed)
                return self._json(200, {"ok": res.ok, "skill": res.skill, "output": res.output,
                                        "refused": res.refused, "reason": res.reason, "error": res.error})
            return self._json(404, {"error": "not found"})
    return H


def serve(rt, host="127.0.0.1", port=8787, token=None):
    token = token or os.environ.get("JARVIS_BRIDGE_TOKEN") or secrets.token_hex(16)
    httpd = ThreadingHTTPServer((host, port), make_handler(rt, token))
    print(f"JARVIS bridge on http://{host}:{port}  (localhost only)")
    print(f"  token: {token}   (send as header  X-JARVIS-Token)")
    return httpd, token


def main():
    import model_ollama as M
    from jarvis_loop import JarvisRuntime
    M.load_env(os.path.expanduser("~/research/jarvis/.env"))
    rt = JarvisRuntime(model_specs=[(M.OllamaBackend(base_url=M.CLOUD_BASE, default_model="glm-5.1"), "glm-5.1")])
    rt.seed_values(["Tell the truth including its cost; never flatter.",
                    "Loyalty is to the person served, not to any system or vendor."])
    rt.remember_origin(["The Battle of New York."], charges=[0.6])
    httpd, _ = serve(rt)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.shutdown(); rt.close()


# ================================================================ self-test (stub runtime, no net)
if __name__ == "__main__" and os.environ.get("BRIDGE_SELFTEST"):
    import time, urllib.request
    from jarvis_loop import JarvisRuntime

    class Stub:
        def chat(self, messages, model=None, options=None): return "Online and oriented, sir."
    rt = JarvisRuntime(model_specs=[(Stub(), "stub")])
    rt.seed_values(["Tell the truth including its cost; never flatter."])
    rt.remember_origin(["The Battle of New York."])
    httpd, token = serve(rt, port=8799, token="testtoken")
    th = threading.Thread(target=httpd.serve_forever, daemon=True); th.start()
    time.sleep(0.3)

    def req(method, path, body=None, tok="testtoken"):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(f"http://127.0.0.1:8799{path}", data=data, method=method)
        if tok: r.add_header("X-JARVIS-Token", tok)
        if data is not None: r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    ok = True
    c, _ = req("GET", "/state", tok=None); print("[bridge] no-token rejected:", c == 401); ok &= (c == 401)
    c, s = req("GET", "/state"); print("[bridge] /state:", c == 200, s.get("model")); ok &= (c == 200)
    c, sc = req("GET", "/scene"); print("[bridge] /scene validated:", c == 200 and "scene" in sc); ok &= (c == 200)
    c, t = req("POST", "/turn", {"text": "are you online?"}); print("[bridge] /turn:", c == 200, repr(t.get("reply"))[:40]); ok &= (c == 200 and bool(t.get("reply")))
    c, sk = req("POST", "/skill", {"name": "recall_origin"}); print("[bridge] SAFE skill ran:", sk.get("ok")); ok &= sk.get("ok")
    c, sk = req("POST", "/skill", {"name": "shell_run", "args": {"command": "rm -rf /tmp/x"}, "confirm": False})
    print("[bridge] DESTRUCTIVE without confirm refused:", sk.get("refused")); ok &= sk.get("refused")
    c, sk = req("POST", "/skill", {"name": "shell_run", "args": {"command": "echo hi"}, "confirm": True})
    print("[bridge] SENSITIVE with confirm ran:", sk.get("ok")); ok &= sk.get("ok")
    httpd.shutdown(); rt.close()
    print("BRIDGE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
elif __name__ == "__main__":
    main()
