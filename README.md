# Nodestro Desktop

Nodestro as a desktop application: the studio and its runtime with a bundled Python, without a separate Python,
Node.js, PostgreSQL or Docker installation. The architecture and plan are in
`nodestro-studio/docs/desktop-server/` (ADR-0005: desktop packaging).

Status: **no release yet.** `spike/` holds the packaging spike (plan PR-5): measurements on Linux x86_64 and the
decision for the host shell (Tauri 2). macOS and Windows are not tested; there are no signed builds.

## License

MIT, see `LICENSE`.
