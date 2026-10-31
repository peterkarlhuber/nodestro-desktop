// Packaging spike (plan PR-5): the same process model as the Tauri spike, with Electron.
// Not a product: no launch secret, no restart, no logging setup.
const { app, BrowserWindow } = require("electron");
const { spawn } = require("node:child_process");
const net = require("node:net");
const http = require("node:http");

const started = Date.now();

function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

function healthy(port) {
  return new Promise((resolve) => {
    http
      .get({ host: "127.0.0.1", port, path: "/api/health", timeout: 500 }, (res) => {
        res.resume();
        resolve(res.statusCode === 200);
      })
      .on("error", () => resolve(false));
  });
}

let backend = null;

app.whenReady().then(async () => {
  const port = await freePort();
  const args = ["--no-browser", "--port", String(port)];
  if (process.env.NODESTRO_DATA_DIR) args.push("--data-dir", process.env.NODESTRO_DATA_DIR);
  backend = spawn(process.env.NODESTRO_BACKEND, args, { stdio: "inherit" });
  const deadline = Date.now() + 60000;
  while (!(await healthy(port))) {
    if (Date.now() > deadline) throw new Error("the backend did not answer within 60 s");
    await new Promise((r) => setTimeout(r, 50));
  }
  console.error(`spike: backend healthy after ${Date.now() - started} ms`);
  const window = new BrowserWindow({ width: 1280, height: 800, title: "Nodestro (spike)" });
  await window.loadURL(`http://127.0.0.1:${port}/`);
  console.error(`spike: page loaded after ${Date.now() - started} ms`);
  if (process.env.SPIKE_QUIT_AFTER_MS) setTimeout(() => app.quit(), Number(process.env.SPIKE_QUIT_AFTER_MS));
});

app.on("will-quit", (event) => {
  if (!backend || backend.exitCode !== null) return;
  event.preventDefault();
  backend.once("exit", () => {
    console.error("spike: backend stopped");
    backend = null;
    app.quit();
  });
  backend.kill("SIGINT");
  setTimeout(() => backend && backend.kill("SIGKILL"), 10000);
});
app.on("window-all-closed", () => app.quit());
