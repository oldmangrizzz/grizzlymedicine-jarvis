// JARVIS cockpit logic. Talks to the Rust core (start/stop/status/xr) via Tauri,
// and to the running bridge over localhost using the token the core minted.
const invoke = window.__TAURI__.core.invoke;

let TOKEN = null;
let PORT = 8787;
let RUNNING = false;
let busy = false;
let statePoll = null;
let voiceReplies = true;
let voiceLoop = false;
let voiceMode = "sentry";
let sendingTurn = false;
let speaking = false;
let authActive = false;
let loopRestart = null;
let ttsBlockedNoted = false;

const $ = (id) => document.getElementById(id);

function log(msg, cls = "") {
  const box = $("log");
  const t = new Date().toLocaleTimeString();
  const line = document.createElement("div");
  line.innerHTML = `<span class="t">${t}</span> <span class="${cls}">${escapeHtml(msg)}</span>`;
  box.prepend(line);
  while (box.children.length > 60) box.removeChild(box.lastChild);
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ---- bridge HTTP, via the Rust core (native socket) ----
// Never fetch() from the webview: macOS WKWebView can block plain-http calls to
// loopback. The Rust side makes the call and injects the token.
async function bridge(method, path, body) {
  const res = await invoke("bridge_request", {
    method,
    path,
    body: body !== undefined ? JSON.stringify(body) : null,
  });
  let data = {};
  if (res.body) { try { data = JSON.parse(res.body); } catch (_) {} }
  if (res.status < 200 || res.status >= 300) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

// ---- power ----
async function powerOn() {
  if (busy) return;
  busy = true; setBusy(true);
  log("Booting runtime…");
  try {
    const r = await invoke("start_jarvis");
    TOKEN = r.token; PORT = r.port;
    log(`Bridge spawned (pid ${r.pid}) on 127.0.0.1:${r.port}. Booting runtime — this loads HoloGraph and dials the cloud, give it a moment…`, "ok");
    // heavy runtime: HoloGraph + Ollama-cloud + Convex. Wait up to ~50s, and
    // bail early (with the bridge's own output) if the process dies.
    await waitForState(60);
    setRunning(true);
    startStatePoll();
    log("Online and oriented.", "ok");
    await refreshTtsStatus();
  } catch (e) {
    log("Start failed: " + e.message, "err");
    await dumpBridgeLog();
    try { await invoke("stop_jarvis"); } catch (_) {}
    setRunning(false);
  } finally {
    busy = false; setBusy(false);
  }
}

async function powerOff() {
  if (busy) return;
  busy = true; setBusy(true);
  setVoiceLoop(false);
  stopSpeaking();
  stopStatePoll();
  try {
    await invoke("stop_jarvis");
    log("Runtime stopped.", "ok");
  } catch (e) {
    log("Stop error: " + e.message, "err");
  }
  TOKEN = null;
  setRunning(false);
  busy = false; setBusy(false);
}

async function waitForState(tries) {
  let shown = 0;
  for (let i = 0; i < tries; i++) {
    // if the python process died, stop waiting and surface its output now
    const st = await invoke("jarvis_status");
    if (!st.running) throw new Error("bridge process exited during boot");
    try { await bridge("GET", "/state"); return true; }
    catch (_) { /* not up yet */ }
    // stream new bridge output as it boots, so the panel isn't a frozen wait
    shown = await streamBridgeLog(shown);
    if (i > 0 && i % 8 === 0) log(`…still booting (${Math.round((i * 0.8))}s)`);
    await sleep(800);
  }
  throw new Error("bridge did not answer /state in time");
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// show bridge lines past the count we've already shown; returns new count
async function streamBridgeLog(already) {
  try {
    const lines = await invoke("bridge_log");
    for (let i = already; i < lines.length; i++) {
      log(lines[i], lines[i].includes("[err]") ? "err" : "");
    }
    return lines.length;
  } catch (_) { return already; }
}

async function dumpBridgeLog() {
  try {
    const lines = await invoke("bridge_log");
    if (!lines || !lines.length) {
      log("(bridge printed nothing before it stopped — python may have failed to launch, or the env is missing)", "err");
      return;
    }
    log("— last bridge output —", "err");
    for (const l of lines.slice(-40)) log(l, l.includes("[err]") ? "err" : "");
  } catch (e) { log("could not read bridge log: " + e.message, "err"); }
}

// ---- telemetry ----
function startStatePoll() {
  stopStatePoll();
  refreshState();
  statePoll = setInterval(refreshState, 2000);
}
function stopStatePoll() { if (statePoll) { clearInterval(statePoll); statePoll = null; } }

async function refreshState() {
  if (!TOKEN) return;
  try {
    const s = await bridge("GET", "/state");
    $("model").textContent = s.model || "—";
    const e = s.endocrine || {};
    setGauge("cortisol", e.cortisol);
    setGauge("dopamine", e.dopamine);
    setGauge("adrenaline", e.adrenaline);
    setGauge("ectone", s.ec_tone);
    $("v-field").textContent = Array.isArray(s.field) ? s.field.length : "0";
  } catch (e) {
    log("state: " + e.message, "err");
  }
}

async function refreshTtsStatus() {
  try {
    const s = await bridge("GET", "/tts/status");
    if (s.safe_to_speak) {
      log(`voice path: confirmed ${s.backend || s.preferred_backend || "local"} voice ready (${s.voice}).`, "ok");
    } else {
      log(`voice path blocked: no wrong-voice fallback. Missing: ${(s.missing || []).join(", ") || "unknown"}. Voice ref: ${s.voice}`, "err");
    }
  } catch (e) {
    log("voice path status: " + e.message, "err");
  }
}
function setGauge(name, v) {
  if (typeof v !== "number") return;
  const pct = Math.max(0, Math.min(100, v * 100));
  $("g-" + name).style.width = pct.toFixed(0) + "%";
  $("v-" + name).textContent = v.toFixed(2);
}

// ---- talk ----
async function send() {
  const input = $("say");
  const text = input.value.trim();
  if (!text) return;
  if (!RUNNING) { log("JARVIS is offline.", "err"); return; }
  sendingTurn = true;
  stopTurnListening();
  input.value = "";
  log("» " + text);
  try {
    const r = await bridge("POST", "/turn", { text });
    const reply = $("reply");
    reply.classList.remove("hidden");
    reply.textContent = r.reply || "(no reply)";
    const meta = [];
    if (typeof r.drift_to_prototype === "number") meta.push(`drift ${r.drift_to_prototype.toFixed(3)}`);
    if (r.model) meta.push(r.model);
    let html = meta.map((m) => `<span>${escapeHtml(m)}</span>`).join("");
    if (r.ethics_conflict) html += `<span class="flag">⚑ ethics conflict</span>`;
    $("turnmeta").innerHTML = html;
    if (voiceReplies && r.reply) await speakOut(r.reply);
    refreshState();
  } catch (e) {
    log("turn: " + e.message, "err");
  } finally {
    sendingTurn = false;
    if (voiceLoop && RUNNING) startTurnListening(450);
  }
}

// ---- skills ----
function authorizationNeeded(result) {
  return Boolean(result && (result.authorization_required ||
    (result.refused && /requires authorization/i.test(result.reason || ""))));
}

async function dispatchSkill(name, args = {}, authorizationCode = null) {
  const body = { name, args };
  if (authorizationCode) body.authorization_code = authorizationCode;
  return bridge("POST", "/skill", body);
}

function speakOut(text) {
  return new Promise(async (resolve) => {
    if (!text) { resolve(); return; }
    speaking = true;
    try {
      const r = await bridge("POST", "/speak", { text });
      speaking = false;
      if (r && r.spoken) { resolve(); return; }
    } catch (e) {
      speaking = false;
      if (!ttsBlockedNoted) {
        ttsBlockedNoted = true;
        log("voice output blocked: " + e.message, "err");
      }
      resolve();
      return;
    }
    speaking = false;
    resolve();
  });
}

function stopSpeaking() {
  try { window.speechSynthesis?.cancel(); } catch (_) {}
  speaking = false;
}

function stopMediaStream(stream) {
  if (!stream) return;
  stream.getTracks().forEach((track) => track.stop());
}

function permissionError(e) {
  return e?.message || e?.name || String(e);
}

async function requestAudioAccess() {
  if (!navigator.mediaDevices?.getUserMedia) {
    log("audio access: media device API unavailable in this webview", "err");
    return;
  }
  let stream = null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    log("Audio recording permission granted.", "ok");
  } catch (e) {
    log(`audio recording permission: ${permissionError(e)}`, "err");
    await invoke("open_privacy_settings", { pane: "microphone" });
  } finally {
    stopMediaStream(stream);
  }
}

async function requestVideoAccess() {
  if (!navigator.mediaDevices?.getUserMedia) {
    log("video access: media device API unavailable in this webview", "err");
    return;
  }
  let stream = null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: true });
    log("Video recording permission granted. Local camera remains optional; Blink/HomeKit can carry lab visuals.", "ok");
  } catch (e) {
    log(`video recording permission: ${permissionError(e)}`, "err");
    await invoke("open_privacy_settings", { pane: "camera" });
  } finally {
    stopMediaStream(stream);
  }
}

function requestSpeechRecognitionAccess() {
  const r = newRecognizer();
  if (!r) {
    log("speech recognition access: Web Speech recognizer unavailable in this webview", "err");
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let done = false;
    const finish = (message, cls = "") => {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      try { r.stop(); } catch (_) {}
      if (message) log(message, cls);
      resolve();
    };
    const timeout = setTimeout(() => finish("speech recognition prompt timed out", "err"), 8000);
    r.onstart = () => finish("Speech recognition permission granted.", "ok");
    r.onerror = (e) => {
      log(`speech recognition permission: ${e.error || permissionError(e)}`, "err");
      invoke("open_privacy_settings", { pane: "speech_recognition" }).catch((err) =>
        log("speech settings: " + permissionError(err), "err")
      );
      finish("");
    };
    r.onend = () => finish("");
    try {
      r.start();
    } catch (e) {
      finish("speech recognition permission: " + permissionError(e), "err");
    }
  });
}

function newRecognizer() {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR) return null;
  const r = new SR();
  r.lang = "en-US";
  r.interimResults = false;
  r.maxAlternatives = 1;
  return r;
}

function listenOnce(promptText) {
  const r = newRecognizer();
  if (!r) {
    const typed = window.prompt(promptText);
    return Promise.resolve(typed && typed.trim() ? typed.trim() : "");
  }
  return new Promise((resolve) => {
    let done = false;
    const finish = (value = "") => {
      if (done) return;
      done = true;
      try { r.stop(); } catch (_) {}
      $("mic").classList.remove("live");
      resolve(value.trim());
    };
    r.onresult = (ev) => finish(ev.results[0][0].transcript || "");
    r.onerror = (e) => { log("voice auth mic: " + e.error, "err"); finish(""); };
    r.onend = () => finish("");
    $("mic").classList.add("live");
    try { r.start(); } catch (e) { log("voice auth mic: " + e.message, "err"); finish(""); }
    setTimeout(() => finish(""), 15000);
  });
}

async function requestVoiceAuthorization(name, reason) {
  const promptText = `${name} requires authorization. Speak the private authorization code now.`;
  log(`voice auth requested for ${name}: ${reason || "authorization required"}`);
  authActive = true;
  stopTurnListening();
  await speakOut(promptText);
  const heard = await listenOnce(`Speak or type the private authorization code for ${name}.`);
  authActive = false;
  if (!heard || /^(cancel|stop|no)$/i.test(heard)) {
    log(`skill ${name} cancelled: authorization code required`, "err");
    return null;
  }
  log(`voice auth captured for ${name}.`, "ok");
  return heard;
}

async function runSkill(name, args = {}) {
  if (!RUNNING) { log("JARVIS is offline.", "err"); return; }
  log("skill → " + name);
  try {
    let r = await dispatchSkill(name, args);
    if (authorizationNeeded(r)) {
      const authorizationCode = await requestVoiceAuthorization(name, r.reason);
      if (!authorizationCode) return;
      r = await dispatchSkill(name, args, authorizationCode);
    }
    if (r.refused) log(`skill ${name} refused: ${r.reason || ""}`, "err");
    else if (r.ok) log(`skill ${name}: ${typeof r.output === "string" ? r.output : JSON.stringify(r.output)}`, "ok");
    else log(`skill ${name} error: ${r.error || r.reason || "?"}`, "err");
  } catch (e) {
    log("skill: " + e.message, "err");
  } finally {
    if (voiceLoop && RUNNING && !sendingTurn && !authActive) startTurnListening(450);
  }
}

async function connectGmail() {
  if (!RUNNING) { log("JARVIS is offline.", "err"); return; }
  sendingTurn = true;
  stopTurnListening();
  log("gmail oauth → connect");
  try {
    let r = await dispatchSkill("gmail_oauth_connect");
    if (authorizationNeeded(r)) {
      const authorizationCode = await requestVoiceAuthorization("gmail_oauth_connect", r.reason);
      if (!authorizationCode) return;
      if (voiceReplies) await speakOut("Opening Google sign in. Use Apple Passwords, passkey, or your browser autofill there.");
      r = await dispatchSkill("gmail_oauth_connect", {}, authorizationCode);
    }
    if (r.refused) {
      log(`gmail oauth refused: ${r.reason || ""}`, "err");
    } else if (r.ok) {
      log(`gmail oauth connected: ${JSON.stringify(r.output)}`, "ok");
      if (voiceReplies) await speakOut("Gmail is connected. I received OAuth tokens, not your Google password.");
    } else {
      log(`gmail oauth error: ${r.error || "?"}`, "err");
    }
  } catch (e) {
    log("gmail oauth: " + e.message, "err");
  } finally {
    sendingTurn = false;
    if (voiceLoop && RUNNING && !authActive) startTurnListening(450);
  }
}

async function disconnectGmail() {
  await runSkill("gmail_oauth_disconnect");
}

// ---- voice (Web Speech, on-device) ----
let recog = null;
function setupMic() {
  recog = newRecognizer();
  if (!recog) {
    $("mic").style.display = "none";
    $("voice-loop").style.display = "none";
    updateVoiceStatus();
    return;
  }
  recog.onresult = (ev) => handleVoiceTranscript(ev.results[0][0].transcript || "");
  recog.onend = () => {
    $("mic").classList.remove("live");
    if (voiceLoop && RUNNING && !sendingTurn && !speaking && !authActive) startTurnListening(450);
  };
  recog.onerror = (e) => {
    if (e.error !== "no-speech") log("mic: " + e.error, "err");
    $("mic").classList.remove("live");
  };
  updateVoiceStatus();
}
function toggleMic() {
  if (!recog) return;
  if ($("mic").classList.contains("live")) { stopTurnListening(); return; }
  startTurnListening();
}

function startTurnListening(delay = 0) {
  if (!recog || !RUNNING || sendingTurn || speaking || authActive) return;
  clearTimeout(loopRestart);
  loopRestart = setTimeout(() => {
    if (!recog || !RUNNING || sendingTurn || speaking || authActive) return;
    $("mic").classList.add("live");
    try { recog.start(); } catch (_) { $("mic").classList.remove("live"); }
  }, delay);
}

function stopTurnListening() {
  clearTimeout(loopRestart);
  if (!recog) return;
  try { recog.stop(); } catch (_) {}
  $("mic").classList.remove("live");
}

function handleVoiceTranscript(transcript) {
  const text = transcript.trim();
  if (!text) return;
  const hasWakeword = /^\s*jarvis\b[,\s]*/i.test(text);
  const commandText = hasWakeword ? text.replace(/^\s*jarvis\b[,\s]*/i, "").trim() : text;
  const clean = commandText.toLowerCase();
  if (voiceMode === "sentry" && !hasWakeword) return;
  if (/^(stop listening|stop voice loop|go quiet|stand down)$/.test(clean)) {
    setVoiceLoop(false);
    log("voice loop off.", "ok");
    return;
  }
  if (/^(stop talking|mute|voice off)$/.test(clean)) {
    stopSpeaking();
    setVoiceReplies(false);
    log("voice replies off.", "ok");
    return;
  }
  if (/^(voice on|speak replies|talk to me)$/.test(clean)) {
    setVoiceReplies(true);
    log("voice replies on.", "ok");
    if (voiceLoop && RUNNING) startTurnListening(450);
    return;
  }
  if (/^(sentry mode|go sentry|wakeword mode)$/.test(clean)) {
    setVoiceMode("sentry");
    log("sentry mode: wakeword required.", "ok");
    if (voiceLoop && RUNNING) startTurnListening(450);
    return;
  }
  if (/^(live mode|open comms|open communications|no wakeword)$/.test(clean)) {
    setVoiceMode("live");
    log("live mode: wakeword not required.", "ok");
    if (voiceLoop && RUNNING) startTurnListening(450);
    return;
  }
  if (/^(connect gmail|gmail login|authorize gmail|log in to gmail|login to gmail)$/.test(clean)) {
    connectGmail();
    return;
  }
  if (/^(disconnect gmail|gmail logout|log out of gmail|logout of gmail)$/.test(clean)) {
    disconnectGmail();
    return;
  }
  const intro = parseIntroduction(commandText);
  if (intro) {
    introducePerson(intro);
    return;
  }
  $("say").value = commandText || text;
  send();
}

function parseIntroduction(text) {
  const patterns = [
    { re: /^introduce yourself to my wife\s+(.+)$/i, relationship: "wife" },
    { re: /^introduce yourself to my daughter\s+(.+)$/i, relationship: "daughter" },
    { re: /^this is my wife\s+(.+)$/i, relationship: "wife" },
    { re: /^this is my daughter\s+(.+)$/i, relationship: "daughter" },
    { re: /^introduce yourself to\s+(.+)$/i, relationship: "" },
    { re: /^meet\s+(.+)$/i, relationship: "" },
    { re: /^this is\s+(.+)$/i, relationship: "" },
    { re: /^my name is\s+(.+)$/i, relationship: "" },
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern.re);
    if (match) {
      const name = match[1].replace(/[.?!]+$/, "").trim();
      if (name) return { name, relationship: pattern.relationship, spoken_intro: text };
    }
  }
  return null;
}

async function introducePerson(intro) {
  if (!RUNNING) { log("JARVIS is offline.", "err"); return; }
  sendingTurn = true;
  stopTurnListening();
  log(`introduction → ${intro.name}`);
  try {
    const r = await dispatchSkill("person_introduce", intro);
    if (r.refused) {
      log(`introduction refused: ${r.reason || ""}`, "err");
    } else if (r.ok) {
      const greeting = r.output?.greeting || `Hello, ${intro.name}. I'm JARVIS.`;
      log(`introduced ${intro.name}: ${JSON.stringify(r.output?.voice_recognition || {})}`, "ok");
      if (voiceReplies) await speakOut(greeting);
    } else {
      log(`introduction error: ${r.error || "?"}`, "err");
    }
  } catch (e) {
    log("introduction: " + e.message, "err");
  } finally {
    sendingTurn = false;
    if (voiceLoop && RUNNING) startTurnListening(450);
  }
}

function setVoiceReplies(on) {
  voiceReplies = Boolean(on);
  $("voice-out").classList.toggle("active", voiceReplies);
  if (!voiceReplies) stopSpeaking();
  updateVoiceStatus();
}

function setVoiceLoop(on) {
  voiceLoop = Boolean(on);
  $("voice-loop").classList.toggle("active", voiceLoop);
  updateVoiceStatus();
  if (voiceLoop && RUNNING) startTurnListening(150);
  else stopTurnListening();
}

function setVoiceMode(mode) {
  voiceMode = mode === "live" ? "live" : "sentry";
  $("voice-mode").textContent = voiceMode === "live" ? "Live" : "Sentry";
  $("voice-mode").classList.toggle("active", voiceMode === "sentry");
  $("voice-mode").title = voiceMode === "sentry"
    ? "Sentry mode requires the JARVIS wakeword"
    : "Live mode sends every transcript without the wakeword";
  updateVoiceStatus();
}

function updateVoiceStatus() {
  $("voice-status").textContent =
    `${voiceReplies ? "Voice replies on" : "Voice replies off"} · ` +
    `${voiceMode} mode · ${voiceLoop ? "loop on" : "loop off"} · ` +
    "input uses macOS default microphone";
}

// ---- ui state ----
function setRunning(on) {
  RUNNING = on;
  $("power").classList.toggle("on", on);
  $("power").classList.toggle("off", !on);
  $("statusline").textContent = on ? "ONLINE" : "OFFLINE";
  $("statusline").classList.toggle("on", on);
  $("telemetry").classList.toggle("dim", !on);
  $("talk").classList.toggle("dim", !on);
  $("skills").classList.toggle("dim", !on);
  if (!on) { $("model").textContent = "—"; }
  if (!on) setVoiceLoop(false);
}
function setBusy(b) { $("power").classList.toggle("busy", b); }

// ---- wire up ----
$("power").addEventListener("click", () => (RUNNING ? powerOff() : powerOn()));
$("send").addEventListener("click", send);
$("say").addEventListener("keydown", (e) => { if (e.key === "Enter") send(); });
$("mic").addEventListener("click", toggleMic);
$("voice-out").addEventListener("click", () => setVoiceReplies(!voiceReplies));
$("voice-mode").addEventListener("click", () => setVoiceMode(voiceMode === "sentry" ? "live" : "sentry"));
$("voice-loop").addEventListener("click", () => setVoiceLoop(!voiceLoop));
$("openxr").addEventListener("click", async () => {
  try { await invoke("open_xr"); log("Opened XR surface.", "ok"); }
  catch (e) { log("xr: " + e.message, "err"); }
});
document.querySelectorAll(".chip.privacy[data-pane]").forEach((b) =>
  b.addEventListener("click", async () => {
    try {
      await invoke("open_privacy_settings", { pane: b.dataset.pane });
      log(`Opened macOS ${b.textContent} settings. Add/enable JARVIS there.`, "ok");
    } catch (e) {
      log("privacy settings: " + e.message, "err");
    }
  })
);
document.querySelectorAll(".chip.privacy[data-request]").forEach((b) =>
  b.addEventListener("click", async () => {
    const request = b.dataset.request;
    try {
      if (request === "microphone") await requestAudioAccess();
      else if (request === "camera") await requestVideoAccess();
      else if (request === "speech_recognition") await requestSpeechRecognitionAccess();
    } catch (e) {
      log("access request: " + permissionError(e), "err");
    }
  })
);
document.querySelectorAll(".chip[data-skill]").forEach((b) =>
  b.addEventListener("click", () => runSkill(b.dataset.skill))
);

// reconcile with the core on launch (in case a child is already alive)
(async function init() {
  setupMic();
  log("macOS access prompt ready: Full Disk, Accessibility, Screen Recording, Audio Recording, optional Video Recording, and Speech Recognition.");
  try {
    const s = await invoke("jarvis_status");
    PORT = s.port;
    if (s.running && s.token) {
      TOKEN = s.token;
      setRunning(true);
      startStatePoll();
      log("Reconnected to running runtime.", "ok");
      await refreshTtsStatus();
    } else {
      setRunning(false);
      log("Ready. Press power to bring JARVIS online.");
    }
  } catch (e) {
    setRunning(false);
    log("init: " + e.message, "err");
  }
})();
