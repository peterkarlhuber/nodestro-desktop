//! Packaging spike (plan PR-5): start the bundled backend on a free loopback port, wait for
//! /api/health, show it in the system web view and stop the backend when the window closes.
//! Not a product: no launch secret, no restart, no logging setup.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command};
use std::sync::Mutex;
use std::time::{Duration, Instant};

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn healthy(port: u16) -> bool {
    let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)) else { return false };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let request = format!("GET /api/health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut answer = String::new();
    let _ = stream.read_to_string(&mut answer);
    answer.starts_with("HTTP/1.1 200")
}

fn stop(child: &mut Child) {
    // SIGINT lets uvicorn run the application shutdown (Workspace.aclose); kill only as a fallback.
    #[cfg(unix)]
    unsafe {
        extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
        kill(child.id() as i32, 2);
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Ok(Some(_)) = child.try_wait() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn main() {
    let started = Instant::now();
    let backend = std::env::var("NODESTRO_BACKEND").expect("NODESTRO_BACKEND: path to the bundled nodestro command");
    let port = free_port();
    let mut args = vec!["--no-browser".to_string(), "--port".to_string(), port.to_string()];
    if let Ok(dir) = std::env::var("NODESTRO_DATA_DIR") {
        args.extend(["--data-dir".to_string(), dir]);
    }
    let child = Command::new(backend).args(&args).spawn().expect("start the backend");
    let deadline = Instant::now() + Duration::from_secs(60);
    while !healthy(port) {
        assert!(Instant::now() < deadline, "the backend did not answer within 60 s");
        std::thread::sleep(Duration::from_millis(50));
    }
    eprintln!("spike: backend healthy after {} ms", started.elapsed().as_millis());
    let child = Mutex::new(Some(child));
    let url = format!("http://127.0.0.1:{port}/");
    tauri::Builder::default()
        .setup(move |app| {
            let window = tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::External(url.parse().unwrap()))
                .title("Nodestro (spike)")
                .inner_size(1280.0, 800.0)
                .build()?;
            let _ = window;
            eprintln!("spike: window created after {} ms", started.elapsed().as_millis());
            if std::env::var("SPIKE_QUIT_AFTER_MS").is_ok() {
                let handle = app.handle().clone();
                let wait: u64 = std::env::var("SPIKE_QUIT_AFTER_MS").unwrap().parse().unwrap_or(3000);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(wait));
                    handle.exit(0);
                });
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build the app")
        .run(move |_app, event| {
            if let tauri::RunEvent::Exit = event {
                if let Some(mut child) = child.lock().unwrap().take() {
                    stop(&mut child);
                    eprintln!("spike: backend stopped");
                }
            }
        });
}
