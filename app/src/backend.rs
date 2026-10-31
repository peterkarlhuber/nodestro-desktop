//! The bundled backend: where it is, how it is started with a per-launch secret, when it is ready,
//! and how it is stopped. Nothing here depends on Tauri, so it is unit-tested directly.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Overrides the backend command (development, tests): the path of a `nodestro` executable.
pub const BACKEND_ENV: &str = "NODESTRO_BACKEND";
/// The variable through which the backend receives the per-launch secret (`nodestro_api.launch`).
pub const SECRET_ENV: &str = "NODESTRO_LAUNCH_SECRET";
/// How long the backend may take to answer `/api/health`.
pub const START_TIMEOUT: Duration = Duration::from_secs(90);
/// How long the backend may take to shut down after SIGINT before it is killed.
pub const STOP_TIMEOUT: Duration = Duration::from_secs(10);

/// A random 256-bit secret, hex-encoded (64 characters), from the operating system's generator.
pub fn new_secret() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("the operating system's random number generator");
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// How the backend is started: a program and the arguments before the command line options.
#[derive(Debug, PartialEq, Eq)]
pub struct Launcher {
    pub program: PathBuf,
    pub prefix: Vec<String>,
}

/// The bundled interpreter next to this executable (`backend/python/bin/python3`, on Windows
/// `backend\python\python.exe`) running `-I -m nodestro_studio`, or the `nodestro` command named by
/// `NODESTRO_BACKEND`.
///
/// The interpreter is called directly because the `nodestro` script of an installed wheel names the
/// interpreter by the absolute path it was built at, which a moved bundle does not have. `-I` (isolated
/// mode) ignores `PYTHONPATH`, `PYTHONHOME` and the user's site packages, so nothing outside the bundle is
/// imported.
pub fn backend_command(exe: &Path, override_: Option<String>) -> Launcher {
    if let Some(path) = override_.filter(|value| !value.is_empty()) {
        return Launcher { program: PathBuf::from(path), prefix: Vec::new() };
    }
    let python = exe.parent().unwrap_or(Path::new(".")).join("backend").join("python");
    let program = if cfg!(windows) { python.join("python.exe") } else { python.join("bin").join("python3") };
    Launcher { program, prefix: vec!["-I".into(), "-m".into(), "nodestro_studio".into()] }
}

/// A free port on the loopback interface (the backend binds it right after; a race with another
/// program taking it in between shows up as a start failure).
pub fn free_port() -> std::io::Result<u16> {
    Ok(TcpListener::bind("127.0.0.1:0")?.local_addr()?.port())
}

/// `true` when `GET /api/health` answers 200.
pub fn healthy(port: u16) -> bool {
    let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)) else { return false };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let request = format!("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut answer = Vec::new();
    let _ = stream.read_to_end(&mut answer);
    answer.starts_with(b"HTTP/1.1 200")
}

/// Why the backend is not available.
#[derive(Debug, PartialEq, Eq)]
pub enum StartError {
    /// The command does not exist or cannot be executed.
    Missing(String),
    /// It ended before it answered (exit code, if any).
    Exited(Option<i32>),
    /// It did not answer within [`START_TIMEOUT`].
    Timeout,
}

impl StartError {
    pub fn detail(&self) -> String {
        match self {
            StartError::Missing(why) => format!("backend: {why}"),
            StartError::Exited(Some(code)) => format!("backend ended with exit code {code}"),
            StartError::Exited(None) => "backend ended by a signal".to_string(),
            StartError::Timeout => format!("backend did not answer within {} s", START_TIMEOUT.as_secs()),
        }
    }
}

/// A running backend and the URL the window opens once to receive its session.
pub struct Backend {
    pub child: Child,
    pub port: u16,
    secret: String,
}

impl Backend {
    /// Start `command` on `port` with a new secret; its output goes to `log`.
    pub fn start(command: &Launcher, port: u16, data_dir: Option<String>, log: &Path) -> Result<Backend, StartError> {
        let secret = new_secret();
        if let Some(parent) = log.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let output = OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .or_else(|_| File::create(std::env::temp_dir().join("nodestro-desktop-backend.log")))
            .map_err(|error| StartError::Missing(error.to_string()))?;
        let errors = output.try_clone().map_err(|error| StartError::Missing(error.to_string()))?;
        let mut args = command.prefix.clone();
        args.extend([
            "--no-browser".to_string(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            port.to_string(),
        ]);
        if let Some(dir) = data_dir.filter(|value| !value.is_empty()) {
            args.extend(["--data-dir".to_string(), dir]);
        }
        let child = Command::new(&command.program)
            .args(&args)
            // Passed in the environment, never on the command line (visible to every user in the process list).
            .env(SECRET_ENV, &secret)
            .env_remove("NODESTRO_HOST")
            .env_remove("NODESTRO_ALLOWED_HOSTS")
            .stdin(Stdio::null())
            .stdout(output)
            .stderr(errors)
            .spawn()
            .map_err(|error| StartError::Missing(format!("{}: {error}", command.program.display())))?;
        Ok(Backend { child, port, secret })
    }

    #[cfg_attr(not(test), allow(dead_code))]
    /// Wait until `/api/health` answers, the process ends, or the time is up.
    pub fn wait_until_ready(&mut self, timeout: Duration) -> Result<(), StartError> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Ok(Some(status)) = self.child.try_wait() {
                return Err(StartError::Exited(status.code()));
            }
            if healthy(self.port) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(StartError::Timeout);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The one-time launch URL (`/api/launch?token=…`); the backend redirects it to the studio.
    pub fn launch_url(&self) -> String {
        format!("http://127.0.0.1:{}/api/launch?token={}", self.port, self.secret)
    }

    /// The origin the window may navigate within.
    pub fn origin(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
}

/// Stop the backend: SIGINT runs the application's shutdown (exit code 0); killed after `timeout`.
pub fn stop(child: &mut Child, timeout: Duration) {
    if let Ok(Some(_)) = child.try_wait() {
        return;
    }
    #[cfg(unix)]
    {
        extern "C" {
            fn kill(pid: i32, sig: i32) -> i32;
        }
        // SAFETY: plain libc call with our own child's process id.
        unsafe {
            kill(child.id() as i32, 2);
        }
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Ok(Some(_)) = child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    #[cfg(not(unix))]
    let _ = timeout;
    let _ = child.kill();
    let _ = child.wait();
}

/// Percent-encode a value for a URL fragment parameter.
pub fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// Whether a navigation target belongs to the backend's origin (the studio) or to the shell's own page.
pub fn allowed_navigation(url: &str, origin: Option<&str>, local_prefixes: &[&str]) -> bool {
    if local_prefixes.iter().any(|prefix| url.starts_with(prefix)) {
        return true;
    }
    match origin {
        Some(origin) => url == origin || url.starts_with(&format!("{origin}/")),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets_are_long_and_different() {
        let first = new_secret();
        assert_eq!(first.len(), 64);
        assert!(first.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(first, new_secret());
    }

    #[test]
    fn the_backend_is_next_to_the_executable_unless_overridden() {
        let exe = Path::new("/opt/nodestro/nodestro-desktop");
        let found = backend_command(exe, None);
        assert_eq!(found.prefix, ["-I", "-m", "nodestro_studio"]);
        if !cfg!(windows) {
            assert_eq!(found.program, PathBuf::from("/opt/nodestro/backend/python/bin/python3"));
        }
        let named = backend_command(exe, Some("/x/nodestro".into()));
        assert_eq!(named, Launcher { program: PathBuf::from("/x/nodestro"), prefix: Vec::new() });
        assert_eq!(backend_command(exe, Some(String::new())), found);
    }

    #[test]
    fn navigation_stays_on_the_backend_or_the_start_page() {
        let origin = Some("http://127.0.0.1:4711");
        let local = ["tauri://localhost", "http://tauri.localhost"];
        assert!(allowed_navigation("http://127.0.0.1:4711/", origin, &local));
        assert!(allowed_navigation("http://127.0.0.1:4711/workflows/a", origin, &local));
        assert!(allowed_navigation("tauri://localhost/index.html#error=stopped", origin, &local));
        assert!(!allowed_navigation("http://127.0.0.1:47110/", origin, &local));
        assert!(!allowed_navigation("http://127.0.0.1:4711.evil.example/", origin, &local));
        assert!(!allowed_navigation("https://example.com/", origin, &local));
        assert!(!allowed_navigation("http://127.0.0.1:4711/", None, &local));
    }

    #[test]
    fn fragment_values_are_encoded() {
        assert_eq!(encode("a b/ü&#"), "a%20b%2F%C3%BC%26%23");
    }

    #[test]
    fn a_missing_backend_is_reported() {
        let log = std::env::temp_dir().join(format!("nodestro-desktop-test-{}.log", std::process::id()));
        let error =
            Backend::start(&backend_command(Path::new("/x"), Some("/nonexistent/nodestro".into())), 1, None, &log)
                .err()
                .unwrap();
        assert!(matches!(error, StartError::Missing(_)));
        let _ = fs::remove_file(log);
    }

    #[cfg(unix)]
    #[test]
    fn an_early_exit_is_reported_and_the_secret_is_not_an_argument() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("nodestro");
        // Records its arguments and whether the secret arrived, then fails.
        fs::write(&script, "#!/bin/sh\necho \"args=$*\"\necho \"secret=${#NODESTRO_LAUNCH_SECRET}\"\nexit 3\n")
            .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let log = dir.join("backend.log");
        let mut backend = Backend::start(
            &backend_command(Path::new("/x"), Some(script.display().to_string())),
            free_port().unwrap(),
            Some("/tmp/data".into()),
            &log,
        )
        .unwrap();
        assert_eq!(backend.wait_until_ready(Duration::from_secs(10)), Err(StartError::Exited(Some(3))));
        let written = fs::read_to_string(&log).unwrap();
        assert!(written.contains("--host 127.0.0.1"));
        assert!(written.contains("--data-dir /tmp/data"));
        assert!(written.contains("secret=64"));
        assert!(!written.contains(&backend.secret));
        assert!(backend.launch_url().ends_with(&backend.secret));
        let _ = fs::remove_dir_all(dir);
    }
}
