// JARVIS desktop control surface.
//
// The app owns one child process: the localhost bridge (jarvis_bridge.py), which
// in turn hosts the live runtime. The power button spawns it; OFF kills it.
//
// The bridge needs a shared token (X-JARVIS-Token). Instead of making the operator
// copy it out of a terminal, the APP mints the token and injects it into the child
// via the JARVIS_BRIDGE_TOKEN env var, then hands the same token to the webview so
// the cockpit can call /state, /turn, /skill. Nothing leaves 127.0.0.1.
#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tauri::{Manager, State};

const BRIDGE_PORT: u16 = 8787;

struct AppState {
    child: Mutex<Option<Child>>,
    token: Mutex<Option<String>>,
    log: Arc<Mutex<VecDeque<String>>>,
}

/// Drain a child pipe into the shared ring buffer so the cockpit can show what
/// the bridge actually said — boot progress on success, the traceback on a crash.
fn drain<R: Read + Send + 'static>(reader: R, tag: &'static str, log: Arc<Mutex<VecDeque<String>>>) {
    thread::spawn(move || {
        let r = BufReader::new(reader);
        for line in r.lines() {
            match line {
                Ok(l) => {
                    if let Ok(mut q) = log.lock() {
                        q.push_back(format!("[{tag}] {l}"));
                        while q.len() > 200 {
                            q.pop_front();
                        }
                    }
                }
                Err(_) => break,
            }
        }
    });
}

#[derive(Serialize, Clone)]
struct StartResult {
    token: String,
    pid: u32,
    port: u16,
}

#[derive(Serialize, Clone)]
struct StatusResult {
    running: bool,
    token: Option<String>,
    port: u16,
}

/// 16 random bytes, hex — same shape as the bridge's own secrets.token_hex(16).
fn gen_token() -> String {
    let mut buf = [0u8; 16];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    }
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Where the runtime lives. Override with JARVIS_BASELINE; default is the repo path.
fn baseline_dir() -> PathBuf {
    if let Ok(d) = std::env::var("JARVIS_BASELINE") {
        return PathBuf::from(d);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join("research/jarvis/_baseline")
}

/// Python that owns the runtime deps. Prefer an explicit override, then the
/// project venv so GUI launches do not inherit Apple's Python 3.9 by accident.
fn python_exe() -> PathBuf {
    if let Ok(p) = std::env::var("JARVIS_PYTHON") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let venv_python = PathBuf::from(home).join("research/jarvis/.venv/bin/python");
    if venv_python.exists() {
        return venv_python;
    }
    PathBuf::from("python3")
}

fn is_alive(child: &mut Option<Child>) -> bool {
    match child.as_mut() {
        Some(c) => matches!(c.try_wait(), Ok(None)),
        None => false,
    }
}

fn bridge_port_in_use() -> bool {
    let addr: SocketAddr = ([127, 0, 0, 1], BRIDGE_PORT).into();
    TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok()
}

#[tauri::command]
fn start_jarvis(state: State<'_, AppState>) -> Result<StartResult, String> {
    let mut guard = state.child.lock().map_err(|e| e.to_string())?;
    if is_alive(&mut guard) {
        return Err("JARVIS is already running.".into());
    }
    // reap any exited child
    if let Some(mut old) = guard.take() {
        let _ = old.wait();
    }

    if bridge_port_in_use() {
        return Err(format!(
            "JARVIS bridge port {BRIDGE_PORT} is already in use by another process. Stop the stale listener before powering on."
        ));
    }

    let dir = baseline_dir();
    let bridge = dir.join("jarvis_bridge.py");
    if !bridge.exists() {
        return Err(format!("bridge not found at {}", bridge.display()));
    }

    let python = python_exe();
    let token = gen_token();
    let mut child = Command::new(&python)
        .arg("-u") // unbuffered: bridge output reaches us line-by-line, not in a lump
        .arg("jarvis_bridge.py")
        .current_dir(&dir)
        .env("JARVIS_BRIDGE_TOKEN", &token)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not start {}: {e}", python.display()))?;

    // fresh log for this boot, then start draining the child's pipes
    if let Ok(mut q) = state.log.lock() {
        q.clear();
    }
    if let Some(out) = child.stdout.take() {
        drain(out, "out", state.log.clone());
    }
    if let Some(err) = child.stderr.take() {
        drain(err, "err", state.log.clone());
    }

    let pid = child.id();
    *guard = Some(child);
    *state.token.lock().map_err(|e| e.to_string())? = Some(token.clone());

    Ok(StartResult { token, pid, port: BRIDGE_PORT })
}

#[tauri::command]
fn stop_jarvis(state: State<'_, AppState>) -> Result<(), String> {
    let mut guard = state.child.lock().map_err(|e| e.to_string())?;
    if let Some(mut c) = guard.take() {
        let _ = c.kill();
        let _ = c.wait();
    }
    *state.token.lock().map_err(|e| e.to_string())? = None;
    Ok(())
}

#[tauri::command]
fn jarvis_status(state: State<'_, AppState>) -> StatusResult {
    let mut guard = state.child.lock().expect("child lock");
    let running = is_alive(&mut guard);
    let token = state.token.lock().expect("token lock").clone();
    StatusResult {
        running,
        token: if running { token } else { None },
        port: BRIDGE_PORT,
    }
}

/// Everything the bridge has printed this boot — boot lines on success, traceback on crash.
#[tauri::command]
fn bridge_log(state: State<'_, AppState>) -> Vec<String> {
    state
        .log
        .lock()
        .map(|q| q.iter().cloned().collect())
        .unwrap_or_default()
}

#[derive(Serialize, Clone)]
struct BridgeResponse {
    status: u16,
    body: String,
}

/// Make an HTTP call to the bridge from native Rust (not the webview). macOS WKWebView
/// can refuse plain-http calls to loopback; doing it here over a raw socket sidesteps that
/// entirely, and the token is injected here so it never has to live in the web layer.
#[tauri::command]
fn bridge_request(
    state: State<'_, AppState>,
    method: String,
    path: String,
    body: Option<String>,
) -> Result<BridgeResponse, String> {
    let token = state
        .token
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
        .ok_or("runtime not running")?;

    let addr: SocketAddr = ([127, 0, 0, 1], BRIDGE_PORT).into();
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(3))
        .map_err(|e| format!("connect: {e}"))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(300))); // /turn waits on model inference; /speak may cold-load TTS
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));

    let payload = body.unwrap_or_default();
    let req = format!(
        "{method} {path} HTTP/1.0\r\nHost: 127.0.0.1:{port}\r\nX-JARVIS-Token: {token}\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{payload}",
        method = method,
        path = path,
        port = BRIDGE_PORT,
        token = token,
        len = payload.as_bytes().len(),
        payload = payload,
    );
    stream
        .write_all(req.as_bytes())
        .map_err(|e| format!("write: {e}"))?;

    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| format!("read: {e}"))?;

    let pos = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("malformed response (no header terminator)")?;
    let head = String::from_utf8_lossy(&raw[..pos]);
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse::<u16>().ok())
        .ok_or("malformed status line")?;
    Ok(BridgeResponse {
        status,
        body: String::from_utf8_lossy(&raw[pos + 4..]).to_string(),
    })
}

/// Open the holographic XR surface in the default browser (Quest 3 / Viture / Apple AR
/// connect to it; on desktop this is a flat preview).
#[tauri::command]
fn open_xr() -> Result<(), String> {
    let html = baseline_dir().join("jarvis_xr.html");
    if !html.exists() {
        return Err(format!("XR surface not found at {}", html.display()));
    }
    Command::new("open")
        .arg(html)
        .spawn()
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn open_privacy_settings(pane: String) -> Result<(), String> {
    let target = match pane.as_str() {
        "full_disk" => "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "accessibility" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "screen_recording" => "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        "microphone" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "camera" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
        "speech_recognition" => {
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        }
        other => return Err(format!("unknown privacy pane: {other}")),
    };

    Command::new("open")
        .arg(target)
        .spawn()
        .map_err(|e| format!("could not open privacy settings: {e}"))?;
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .manage(AppState {
            child: Mutex::new(None),
            token: Mutex::new(None),
            log: Arc::new(Mutex::new(VecDeque::new())),
        })
        .invoke_handler(tauri::generate_handler![
            start_jarvis,
            stop_jarvis,
            jarvis_status,
            bridge_log,
            bridge_request,
            open_xr,
            open_privacy_settings
        ])
        .on_window_event(|window, event| {
            // Never leave an orphaned runtime when the cockpit closes.
            // Pull state straight off the window (it implements Manager) — avoids
            // depending on app_handle()'s borrow shape, which differs across 2.x points.
            if let tauri::WindowEvent::Destroyed = event {
                if let Some(state) = window.try_state::<AppState>() {
                    if let Ok(mut guard) = state.child.lock() {
                        if let Some(mut c) = guard.take() {
                            let _ = c.kill();
                            let _ = c.wait();
                        }
                    }
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running JARVIS control app");
}
