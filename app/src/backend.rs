//! The bundled backend: where it is, how it is started with a per-launch secret, when it is ready,
//! and how it is stopped. Nothing here depends on Tauri, so it is unit-tested directly.
//!
//! The secrets (the per-launch secret and the MCP token vault key) reach the backend through a pipe, never through
//! its environment or command line: every process of the same OS user can read another process's initial
//! environment and arguments (`sysctl` `KERN_PROCARGS2` on macOS, `/proc/<pid>/environ` on Linux; review MS-1).
//! The backend is started with `--secrets-fd 0` and a pipe as its standard input; the shell writes one JSON object
//! (`{"launch_secret": …, "vault_key": … | null}`) and closes its end. The backend reads it before anything else,
//! replaces its standard input by the null device and keeps the values in memory (`nodestro_api.handoff`), so no
//! process it starts inherits them. Standard input is a pipe the same way on Linux, macOS and Windows.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::vault::VAULT_KEY_ENV;

/// Overrides the backend command (development, tests): the path of a `nodestro` executable.
pub const BACKEND_ENV: &str = "NODESTRO_BACKEND";
/// The local model runtime (Ollama) bundled next to the backend, passed to it by path (not a secret): nodestro-runtime
/// runs it as a managed child process (`docs/local-models.md`). An operator's own value is kept.
pub const OLLAMA_ENV: &str = "NODESTRO_OLLAMA_BINARY";
/// The operator's variable for the per-launch secret (`nodestro_api.launch`); removed from the backend's
/// environment, which gets the secret through the handoff pipe instead.
pub const SECRET_ENV: &str = "NODESTRO_LAUNCH_SECRET";
/// The backend's option that names the descriptor of the handoff (0: its standard input).
pub const SECRETS_FD_OPTION: &str = "--secrets-fd";
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

/// A backend log larger than this is moved to `<log>.1` (replacing the previous one), when the backend starts and
/// as soon as it grows past it while the backend runs.
pub const LOG_ROTATE_BYTES: u64 = 10 * 1024 * 1024;

fn private_file(options: &mut OpenOptions) -> &mut OpenOptions {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

/// The backend's log file: `log`, rotated once it exceeds `rotate_bytes`, readable by the user only. If it cannot be
/// opened, a new file with an unpredictable name in the temporary directory (never an existing file or a link
/// someone placed there). The backend's own log is a [`RotatingLog`] on top of this.
#[cfg_attr(not(test), allow(dead_code))]
pub fn open_log(log: &Path, rotate_bytes: u64) -> std::io::Result<File> {
    open_log_at(log, rotate_bytes).map(|(file, _)| file)
}

/// [`open_log`], and the path of the file it opened (`log` or the fallback file).
fn open_log_at(log: &Path, rotate_bytes: u64) -> std::io::Result<(File, PathBuf)> {
    if let Some(parent) = log.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if fs::symlink_metadata(log).map(|meta| meta.is_file() && meta.len() > rotate_bytes).unwrap_or(false) {
        let mut rotated = log.as_os_str().to_owned();
        rotated.push(".1");
        let _ = fs::rename(log, rotated);
    }
    private_file(OpenOptions::new().create(true).append(true))
        .open(log)
        .and_then(|file| {
            // The create mode does not apply to a log an older version left behind; tighten it on the open file.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
            }
            Ok((file, log.to_path_buf()))
        })
        .or_else(|_| {
            let name = format!("nodestro-desktop-backend-{}-{}.log", std::process::id(), &new_secret()[..16]);
            let path = std::env::temp_dir().join(name);
            private_file(OpenOptions::new().write(true).create_new(true)).open(&path).map(|file| (file, path))
        })
}

/// The folder for the backend log when the system has no log folder for the app: a new folder in the temporary
/// directory with an unpredictable name, readable by the user only (never a folder someone else created there).
pub fn fallback_log_dir() -> std::io::Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!("nodestro-desktop-{}", &new_secret()[..16]));
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&dir)?; // fails if it exists
    Ok(dir)
}

/// The backend log while the backend runs: its output is copied in by the shell (see [`Backend::start`]), so the
/// log is rotated to `<log>.1` as soon as it grows past the limit, not only at the next start.
pub struct RotatingLog {
    path: PathBuf,
    file: File,
    written: u64,
    limit: u64,
}

impl RotatingLog {
    pub fn open(path: &Path, limit: u64) -> std::io::Result<RotatingLog> {
        let (file, path) = open_log_at(path, limit)?;
        let written = file.metadata().map(|meta| meta.len()).unwrap_or(0);
        Ok(RotatingLog { path, file, written, limit })
    }

    /// Append `bytes`, rotating first when they would take the log past the limit (a single larger write still goes
    /// into one file).
    pub fn write(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        if self.written > 0 && self.written + bytes.len() as u64 > self.limit {
            self.rotate();
        }
        self.file.write_all(bytes)?;
        self.written += bytes.len() as u64;
        Ok(())
    }

    fn rotate(&mut self) {
        let mut rotated = self.path.as_os_str().to_owned();
        rotated.push(".1");
        if fs::rename(&self.path, &rotated).is_err() {
            return; // keep writing to the current file
        }
        if let Ok((file, path)) = open_log_at(&self.path, u64::MAX) {
            self.file = file;
            self.path = path;
            self.written = 0;
        }
    }
}

/// Copy one output stream of the backend into the log until it ends; then say so on `done`.
fn copy_to_log(mut from: impl Read, log: Arc<Mutex<RotatingLog>>, done: Sender<()>) {
    let mut buffer = [0u8; 8192];
    loop {
        match from.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                if let Ok(mut log) = log.lock() {
                    let _ = log.write(&buffer[..count]);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    let _ = done.send(());
}

/// The threads that copy the backend's output into its log.
pub struct LogCopy {
    done: Receiver<()>,
    streams: usize,
}

impl LogCopy {
    /// Wait until the backend's output streams ended and everything is in the log, at most `timeout` (a process the
    /// backend started may keep a stream open).
    pub fn finish(&mut self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        while self.streams > 0 {
            let left = deadline.saturating_duration_since(Instant::now());
            if self.done.recv_timeout(left).is_err() {
                return;
            }
            self.streams -= 1;
        }
    }
}

/// How the backend is started: a program and the arguments before the command line options.
#[derive(Debug, PartialEq, Eq)]
pub struct Launcher {
    pub program: PathBuf,
    pub prefix: Vec<String>,
    /// The bundled Ollama executable (`backend/ollama/...`, `scripts/fetch_ollama.py`), if the bundle has one.
    pub ollama: Option<PathBuf>,
}

/// The Ollama executable in an unpacked release under `root` (the layouts of the Linux, macOS and Windows archives).
pub fn bundled_ollama(root: &Path) -> Option<PathBuf> {
    [root.join("bin").join("ollama"), root.join("ollama"), root.join("ollama.exe")]
        .into_iter()
        .find(|path| path.is_file())
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
        return Launcher { program: PathBuf::from(path), prefix: Vec::new(), ollama: None };
    }
    let backend = exe.parent().unwrap_or(Path::new(".")).join("backend");
    let python = backend.join("python");
    let program = if cfg!(windows) { python.join("python.exe") } else { python.join("bin").join("python3") };
    let ollama = bundled_ollama(&backend.join("ollama"));
    Launcher { program, prefix: vec!["-I".into(), "-m".into(), "nodestro_studio".into()], ollama }
}

/// A JSON string literal of `value` (quotes, backslashes and control characters escaped).
fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The handoff the backend reads on its standard input: one JSON object with the launch secret and the vault key.
pub fn handoff(secret: &str, vault_key: Option<&str>) -> String {
    let key = vault_key.map(json_string).unwrap_or_else(|| "null".to_string());
    format!("{{\"launch_secret\":{},\"vault_key\":{key}}}", json_string(secret))
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
    /// The copy of the backend's output into its log; [`LogCopy::finish`] after the backend ended.
    pub log: LogCopy,
    secret: String,
}

impl Backend {
    /// The backend's command: the options and an environment without any secret; its standard input is the pipe.
    fn command(command: &Launcher, port: u16, data_dir: Option<String>) -> Command {
        let mut args = command.prefix.clone();
        args.extend([
            "--no-browser".to_string(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            port.to_string(),
            SECRETS_FD_OPTION.into(),
            "0".into(),
        ]);
        if let Some(dir) = data_dir.filter(|value| !value.is_empty()) {
            args.extend(["--data-dir".to_string(), dir]);
        }
        let mut process = Command::new(&command.program);
        process
            .args(&args)
            // Never in the environment (readable by every process of this user, see the module comment), also not
            // when the operator set them for the shell itself.
            .env_remove(SECRET_ENV)
            .env_remove(VAULT_KEY_ENV)
            .env_remove("NODESTRO_HOST")
            .env_remove("NODESTRO_ALLOWED_HOSTS")
            .stdin(Stdio::piped());
        if let Some(ollama) = &command.ollama {
            if std::env::var_os(OLLAMA_ENV).is_none() {
                process.env(OLLAMA_ENV, ollama);
            }
        }
        process
    }

    /// Start `command` on `port` with a new secret; its output goes to `log` (a [`RotatingLog`], copied by two
    /// threads of the shell). `vault_key` seals MCP tokens (see `vault`); without it the backend keeps them for the
    /// session only. Both secrets are written to the backend's standard input (see the module comment), which is
    /// closed right after.
    pub fn start(
        command: &Launcher,
        port: u16,
        data_dir: Option<String>,
        vault_key: Option<&str>,
        log: &Path,
    ) -> Result<Backend, StartError> {
        let secret = new_secret();
        let output =
            RotatingLog::open(log, LOG_ROTATE_BYTES).map_err(|error| StartError::Missing(error.to_string()))?;
        let output = Arc::new(Mutex::new(output));
        let mut child = Self::command(command, port, data_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| StartError::Missing(format!("{}: {error}", command.program.display())))?;
        let (done, finished) = mpsc::channel();
        let mut streams = 0;
        if let Some(stdout) = child.stdout.take() {
            let (log, done) = (output.clone(), done.clone());
            std::thread::spawn(move || copy_to_log(stdout, log, done));
            streams += 1;
        }
        if let Some(stderr) = child.stderr.take() {
            let (log, done) = (output.clone(), done.clone());
            std::thread::spawn(move || copy_to_log(stderr, log, done));
            streams += 1;
        }
        let log_copy = LogCopy { done: finished, streams };
        if let Some(mut pipe) = child.stdin.take() {
            let mut payload = handoff(&secret, vault_key).into_bytes();
            // The payload is far below a pipe's buffer, so this does not wait for the backend. A backend that ended
            // already closed its end; `wait_until_ready` reports its exit.
            let _ = pipe.write_all(&payload);
            payload.fill(0);
            // Dropping the write end is the backend's end of input.
            drop(pipe);
        }
        Ok(Backend { child, port, log: log_copy, secret })
    }

    #[cfg_attr(not(test), allow(dead_code))]
    /// Wait until `/api/health` answers, the process ends, or the time is up.
    pub fn wait_until_ready(&mut self, timeout: Duration) -> Result<(), StartError> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Ok(Some(status)) = self.child.try_wait() {
                self.log.finish(Duration::from_secs(2));
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
        assert_eq!(named, Launcher { program: PathBuf::from("/x/nodestro"), prefix: Vec::new(), ollama: None });
        assert_eq!(backend_command(exe, Some(String::new())), found);
        assert_eq!(found.ollama, None, "no runtime in this bundle");
    }

    #[test]
    fn the_bundled_ollama_is_passed_by_path() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-ollama-{}", std::process::id()));
        let binary = dir.join("backend").join("ollama").join("bin").join("ollama");
        fs::create_dir_all(binary.parent().unwrap()).unwrap();
        fs::write(&binary, b"").unwrap();
        let launcher = backend_command(&dir.join("nodestro-desktop"), None);
        assert_eq!(launcher.ollama.as_deref(), Some(binary.as_path()));
        let process = Backend::command(&launcher, 4711, None);
        let value = process.get_envs().find(|(name, _)| *name == std::ffi::OsStr::new(OLLAMA_ENV)).and_then(|(_, v)| v);
        if std::env::var_os(OLLAMA_ENV).is_none() {
            assert_eq!(value, Some(binary.as_os_str()));
        } else {
            assert_eq!(value, None, "an operator's own value is kept");
        }
        // Windows and macOS archives put the executable at the top.
        fs::remove_dir_all(dir.join("backend").join("ollama").join("bin")).unwrap();
        fs::write(dir.join("backend").join("ollama").join("ollama.exe"), b"").unwrap();
        assert_eq!(bundled_ollama(&dir.join("backend").join("ollama")), Some(dir.join("backend/ollama/ollama.exe")));
        fs::remove_dir_all(&dir).unwrap();
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
        let error = Backend::start(
            &backend_command(Path::new("/x"), Some("/nonexistent/nodestro".into())),
            1,
            None,
            None,
            &log,
        )
        .err()
        .unwrap();
        assert!(matches!(error, StartError::Missing(_)));
        let _ = fs::remove_file(log);
    }

    #[test]
    fn a_large_log_is_rotated_and_the_log_is_private() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-log-{}", std::process::id()));
        let log = dir.join("logs").join("backend.log");
        let mut file = open_log(&log, 8).unwrap();
        file.write_all(b"first run, longer than eight bytes\n").unwrap();
        drop(file);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let mut file = open_log(&log, 8).unwrap();
        file.write_all(b"second\n").unwrap();
        drop(file);
        assert_eq!(
            fs::read_to_string(dir.join("logs").join("backend.log.1")).unwrap(),
            "first run, longer than eight bytes\n"
        );
        assert_eq!(fs::read_to_string(&log).unwrap(), "second\n");
        // Below the limit the log is appended to.
        let mut file = open_log(&log, 1024).unwrap();
        file.write_all(b"third\n").unwrap();
        drop(file);
        assert_eq!(fs::read_to_string(&log).unwrap(), "second\nthird\n");
        let _ = fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn an_existing_readable_log_is_made_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-oldlog-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("backend.log");
        fs::write(&log, "left by an older version\n").unwrap();
        fs::set_permissions(&log, fs::Permissions::from_mode(0o644)).unwrap();
        drop(open_log(&log, LOG_ROTATE_BYTES).unwrap());
        assert_eq!(fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::read_to_string(&log).unwrap(), "left by an older version\n");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn an_unusable_log_falls_back_to_a_new_private_file() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-fallback-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        // A directory where the log file should be: it cannot be opened as a file.
        let log = dir.join("backend.log");
        fs::create_dir_all(&log).unwrap();
        let mut file = open_log(&log, LOG_ROTATE_BYTES).unwrap();
        file.write_all(b"x").unwrap();
        assert!(log.is_dir());
        let prefix = format!("nodestro-desktop-backend-{}-", std::process::id());
        let fallbacks: Vec<_> = fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().starts_with(&prefix))
            .collect();
        assert!(!fallbacks.is_empty());
        for entry in fallbacks {
            let _ = fs::remove_file(entry.path());
        }
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn the_log_is_rotated_while_the_backend_runs() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-rotating-{}", std::process::id()));
        let path = dir.join("backend.log");
        let mut log = RotatingLog::open(&path, 16).unwrap();
        log.write(b"0123456789\n").unwrap(); // 11 bytes
        log.write(b"abcdefghij\n").unwrap(); // would make 22 > 16: rotated first
        assert_eq!(fs::read_to_string(dir.join("backend.log.1")).unwrap(), "0123456789\n");
        assert_eq!(fs::read_to_string(&path).unwrap(), "abcdefghij\n");
        // A single write larger than the limit still goes into one file, after a rotation.
        let big = vec![b'x'; 40];
        log.write(&big).unwrap();
        assert_eq!(fs::read_to_string(dir.join("backend.log.1")).unwrap(), "abcdefghij\n");
        assert_eq!(fs::read(&path).unwrap(), big);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_long_running_backend_cannot_grow_its_log_without_limit() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-growing-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("nodestro");
        // Writes 1.5 times the rotation limit on stdout and stderr in one session, then ends.
        let half = LOG_ROTATE_BYTES * 3 / 4;
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncat > /dev/null\nhead -c {half} /dev/zero | tr '\\0' o\n\
                 head -c {half} /dev/zero | tr '\\0' e >&2\necho done\nexit 5\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let log = dir.join("backend.log");
        let mut backend = Backend::start(
            &backend_command(Path::new("/x"), Some(script.display().to_string())),
            free_port().unwrap(),
            None,
            None,
            &log,
        )
        .unwrap();
        assert_eq!(backend.wait_until_ready(Duration::from_secs(60)), Err(StartError::Exited(Some(5))));
        let current = fs::metadata(&log).unwrap().len();
        let rotated = fs::metadata(dir.join("backend.log.1")).unwrap().len();
        assert!(current <= LOG_ROTATE_BYTES && rotated <= LOG_ROTATE_BYTES, "{current} {rotated}");
        assert_eq!(current + rotated, 2 * half + "done\n".len() as u64, "nothing was lost");
        let both = fs::read_to_string(&log).unwrap() + &fs::read_to_string(dir.join("backend.log.1")).unwrap();
        assert!(both.contains("done\n"), "the last line arrived");
        assert_eq!(fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn the_fallback_log_folder_is_new_private_and_unpredictable() {
        let first = fallback_log_dir().unwrap();
        let second = fallback_log_dir().unwrap();
        assert_ne!(first, second);
        assert!(first.starts_with(std::env::temp_dir()));
        let name = first.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with("nodestro-desktop-") && name.len() == "nodestro-desktop-".len() + 16, "{name}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&first).unwrap().permissions().mode() & 0o777, 0o700);
        }
        let _ = fs::remove_dir(first);
        let _ = fs::remove_dir(second);
    }

    #[test]
    fn the_handoff_is_one_json_object() {
        assert_eq!(handoff(&"a".repeat(4), None), r#"{"launch_secret":"aaaa","vault_key":null}"#);
        assert_eq!(handoff("s", Some("k+/=")), r#"{"launch_secret":"s","vault_key":"k+/="}"#);
        // An operator's key with unusual characters stays valid JSON.
        assert_eq!(json_string("a\"b\\c\nd\u{1}é"), r#""a\"b\\c\u000ad\u0001é""#);
    }

    #[test]
    fn the_environment_carries_no_secret_and_stdin_is_the_handoff() {
        let launcher = backend_command(Path::new("/x"), Some("/x/nodestro".into()));
        let process = Backend::command(&launcher, 4711, Some("/tmp/data".into()));
        let envs: Vec<_> = process.get_envs().collect();
        for name in [SECRET_ENV, VAULT_KEY_ENV, "NODESTRO_HOST", "NODESTRO_ALLOWED_HOSTS"] {
            // `None`: removed, also when the shell's own environment has it.
            assert!(envs.contains(&(std::ffi::OsStr::new(name), None)), "{name}");
        }
        assert!(envs.iter().all(|(_, value)| value.is_none()), "nothing is added to the environment");
        let args: Vec<_> = process.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect();
        let at = args.iter().position(|arg| arg == SECRETS_FD_OPTION).unwrap();
        assert_eq!(args[at + 1], "0");
    }

    #[cfg(unix)]
    #[test]
    fn an_early_exit_is_reported_and_the_secrets_arrive_only_on_stdin() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("nodestro");
        let received = dir.join("received");
        // Records its arguments, whether either secret is in its environment and what arrived on standard input
        // (into a file of its own, so the log can be checked for the secrets), then fails.
        fs::write(
            &script,
            format!(
                "#!/bin/sh\necho \"args=$*\"\necho \"secret=${{#NODESTRO_LAUNCH_SECRET}}\"\n\
                 echo \"vault=${{#NODESTRO_VAULT_KEY}}\"\ncat > '{}'\nexit 3\n",
                received.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let log = dir.join("backend.log");
        let key = "k".repeat(44);
        let mut backend = Backend::start(
            &backend_command(Path::new("/x"), Some(script.display().to_string())),
            free_port().unwrap(),
            Some("/tmp/data".into()),
            Some(&key),
            &log,
        )
        .unwrap();
        assert_eq!(backend.wait_until_ready(Duration::from_secs(10)), Err(StartError::Exited(Some(3))));
        let written = fs::read_to_string(&log).unwrap();
        assert!(written.contains("--host 127.0.0.1"));
        assert!(written.contains("--secrets-fd 0"));
        assert!(written.contains("--data-dir /tmp/data"));
        assert!(written.contains("secret=0"), "{written}");
        assert!(written.contains("vault=0"), "{written}");
        assert!(!written.contains(&key));
        assert!(!written.contains(&backend.secret));
        // Read to its end: the shell closed the pipe after writing the handoff.
        assert_eq!(fs::read_to_string(&received).unwrap(), handoff(&backend.secret, Some(&key)));
        assert!(backend.launch_url().ends_with(&backend.secret));
        let _ = fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn without_a_vault_key_the_handoff_says_so() {
        let dir = std::env::temp_dir().join(format!("nodestro-desktop-test-nokey-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("nodestro");
        let received = dir.join("received");
        fs::write(&script, format!("#!/bin/sh\ncat > '{}'\nexit 4\n", received.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mut backend = Backend::start(
            &backend_command(Path::new("/x"), Some(script.display().to_string())),
            free_port().unwrap(),
            None,
            None,
            &dir.join("backend.log"),
        )
        .unwrap();
        assert_eq!(backend.wait_until_ready(Duration::from_secs(10)), Err(StartError::Exited(Some(4))));
        assert_eq!(fs::read_to_string(&received).unwrap(), handoff(&backend.secret, None));
        assert!(fs::read_to_string(&received).unwrap().ends_with("\"vault_key\":null}"));
        let _ = fs::remove_dir_all(dir);
    }
}
