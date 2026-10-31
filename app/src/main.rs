//! Nodestro Desktop: one window for the bundled studio backend.
//!
//! The window first shows its own start page, the backend starts on a free loopback port with a new
//! per-launch secret (`NODESTRO_LAUNCH_SECRET`), and once `/api/health` answers the window opens the
//! one-time launch URL, which the backend exchanges for a session cookie. Only this window can use the
//! studio API afterwards. Closing the window stops the backend (SIGINT, killed after 10 s).
//!
//! The studio page is a remote origin for Tauri and gets no Tauri commands (`capabilities/default.json`).
//! Links to other sites open in the system browser; the window itself never leaves the backend's origin.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod backend;
mod vault;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use backend::{Backend, START_TIMEOUT, STOP_TIMEOUT};
use tauri::{Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

/// The shell's own page as the web view loads it (Linux and macOS, Windows).
const LOCAL_PREFIXES: [&str; 2] = ["tauri://localhost", "http://tauri.localhost"];

#[derive(Default)]
struct State {
    child: Mutex<Option<std::process::Child>>,
    origin: Mutex<Option<String>>,
    stopping: AtomicBool,
}

fn local_page(fragment: &str) -> Url {
    let base = if cfg!(windows) { "http://tauri.localhost" } else { "tauri://localhost" };
    Url::parse(&format!("{base}/index.html#{fragment}")).expect("a valid URL")
}

fn show_error(window: &WebviewWindow, error: &str, detail: &str, log: &std::path::Path) {
    let fragment = format!(
        "error={}&detail={}&log={}",
        backend::encode(error),
        backend::encode(detail),
        backend::encode(&log.display().to_string())
    );
    let _ = window.navigate(local_page(&fragment));
}

fn open_externally(url: &str) {
    // Only web links leave the window; everything else (file:, custom schemes) is dropped.
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return;
    }
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(windows)]
    let _ = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn();
}

fn log_file(app: &tauri::AppHandle) -> PathBuf {
    app.path().app_log_dir().unwrap_or_else(|_| std::env::temp_dir().join("nodestro-desktop")).join("backend.log")
}

/// How long the keychain may take (an unlock prompt nobody answers must not keep the backend from starting).
const KEYCHAIN_TIMEOUT: Duration = Duration::from_secs(15);

/// The MCP token vault key: the operator's `NODESTRO_VAULT_KEY` if set, otherwise the keychain's (created on first
/// use). `None` (tokens kept for the session only) when the keychain cannot be used in time.
fn vault_key() -> Option<String> {
    if let Some(key) = std::env::var(vault::VAULT_KEY_ENV).ok().filter(|key| !key.trim().is_empty()) {
        return Some(key);
    }
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(vault::vault_key(&vault::SystemKeychain));
    });
    let reason = match receiver.recv_timeout(KEYCHAIN_TIMEOUT) {
        Ok(Ok(key)) => return Some(key),
        Ok(Err(reason)) => reason,
        Err(_) => "no answer in time".to_string(),
    };
    eprintln!("nodestro-desktop: keychain not usable ({reason}); MCP tokens are kept for the session only");
    None
}

/// Start the backend, wait for it, open the launch URL; then watch it until the app quits.
fn run_backend(window: WebviewWindow, state: Arc<State>, log: PathBuf) {
    let exe = std::env::current_exe().unwrap_or_default();
    let command = backend::backend_command(&exe, std::env::var(backend::BACKEND_ENV).ok());
    let data_dir = std::env::var("NODESTRO_DATA_DIR").ok();
    let started = std::time::Instant::now();
    let port = match backend::free_port() {
        Ok(port) => port,
        Err(error) => return show_error(&window, "start_failed", &error.to_string(), &log),
    };
    let vault_key = vault_key();
    let running = match Backend::start(&command, port, data_dir, vault_key.as_deref(), &log) {
        Ok(running) => running,
        Err(error) => return show_error(&window, "start_failed", &error.detail(), &log),
    };
    let launch = running.launch_url();
    let origin = running.origin();
    // Owned by the state from the start, so quitting during the start stops it too.
    *state.child.lock().unwrap() = Some(running.child);
    let deadline = std::time::Instant::now() + START_TIMEOUT;
    loop {
        if state.stopping.load(Ordering::SeqCst) {
            // The app quit before the child was handed over: stop it here.
            if let Some(mut child) = state.child.lock().unwrap().take() {
                backend::stop(&mut child, STOP_TIMEOUT);
            }
            return;
        }
        if let Some(child) = state.child.lock().unwrap().as_mut() {
            if let Ok(Some(status)) = child.try_wait() {
                let detail = backend::StartError::Exited(status.code()).detail();
                return show_error(&window, "start_failed", &detail, &log);
            }
        }
        if backend::healthy(port) {
            break;
        }
        if std::time::Instant::now() >= deadline {
            if let Some(mut child) = state.child.lock().unwrap().take() {
                backend::stop(&mut child, STOP_TIMEOUT);
            }
            return show_error(&window, "start_failed", &backend::StartError::Timeout.detail(), &log);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    *state.origin.lock().unwrap() = Some(origin);
    eprintln!("nodestro-desktop: backend ready on port {port} after {} ms", started.elapsed().as_millis());
    let _ = window.navigate(Url::parse(&launch).expect("a valid URL"));
    loop {
        std::thread::sleep(Duration::from_millis(500));
        if state.stopping.load(Ordering::SeqCst) {
            return;
        }
        let mut guard = state.child.lock().unwrap();
        let Some(child) = guard.as_mut() else { return };
        if let Ok(Some(status)) = child.try_wait() {
            guard.take();
            drop(guard);
            *state.origin.lock().unwrap() = None;
            let detail = backend::StartError::Exited(status.code()).detail();
            return show_error(&window, "stopped", &detail, &log);
        }
    }
}

fn main() {
    let state = Arc::new(State::default());
    let navigation_state = state.clone();
    let exit_state = state.clone();
    tauri::Builder::default()
        .setup(move |app| {
            let watched = navigation_state.clone();
            let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                // The version names a preview build as such (0.2.0-preview.1).
                .title(concat!("Nodestro ", env!("CARGO_PKG_VERSION")))
                .inner_size(1280.0, 800.0)
                .min_inner_size(800.0, 560.0)
                .on_navigation(move |url| {
                    let origin = watched.origin.lock().unwrap().clone();
                    let allowed = backend::allowed_navigation(url.as_str(), origin.as_deref(), &LOCAL_PREFIXES);
                    if !allowed {
                        open_externally(url.as_str());
                    }
                    allowed
                })
                .build()?;
            let log = log_file(app.handle());
            let running = navigation_state.clone();
            std::thread::spawn(move || run_backend(window, running, log));
            if let Ok(wait) = std::env::var("NODESTRO_DESKTOP_QUIT_AFTER_MS") {
                // Smoke tests: quit after a while, as a person closing the window would.
                let handle = app.handle().clone();
                let wait: u64 = wait.parse().unwrap_or(10_000);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(wait));
                    handle.exit(0);
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build the Nodestro window")
        .run(move |_app, event| {
            if let RunEvent::Exit = event {
                exit_state.stopping.store(true, Ordering::SeqCst);
                if let Some(mut child) = exit_state.child.lock().unwrap().take() {
                    backend::stop(&mut child, STOP_TIMEOUT);
                    eprintln!("nodestro-desktop: backend stopped");
                }
            }
        });
}
