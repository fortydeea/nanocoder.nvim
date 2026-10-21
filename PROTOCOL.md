# nanocoder.nvim Companion Protocol

This document specifies the wire protocol implemented by nanocoder.nvim: the
WebSocket companion that pairs the [nanocoder](https://github.com/Nano-Collective/nanocoder)
CLI with Neovim. It mirrors the structure of `coder/claudecode.nvim`'s
`PROTOCOL.md`, but the protocol itself is nanocoder's.

## TL;DR

**The roles are inverted relative to Claude Code.** Here the CLI hosts the
WebSocket server and the editor connects to it:

1. `nanocoder --vscode` binds a loopback port and writes a discovery file.
2. The plugin reads the discovery file and connects as a WebSocket **client**.
3. Messages are plain typed JSON text frames (not JSON-RPC).

There is no MCP tool server on the editor side. The parity with
claudecode.nvim is UX-level (diffs, context, status), not protocol-level.

## Discovery

### 1. The CLI starts a WebSocket server

`nanocoder --vscode` binds `127.0.0.1` on an ephemeral port (or a fixed one
with `--vscode-port N`). **Loopback only** — never expose this on a network.

### 2. Discovery file

The CLI writes `vscode-server.json` in its config directory:

```json
{
  "version": 1,
  "port": 51820,
  "token": "a3f1c2d4...64 hex chars...",
  "pid": 12345,
  "cliVersion": "1.2.3",
  "startedAt": 1735689600000
}
```

Location (first match wins):

- `$NANOCODER_CONFIG_DIR/vscode-server.json`
- `$XDG_CONFIG_HOME|~/.config/nanocoder/` (Linux)
- `~/Library/Preferences/nanocoder/` (macOS)
- `%APPDATA%\nanocoder\` (Windows)

The file is written atomically (temp file + rename, mode 0600) and removed on
clean shutdown.

**Reader rules** (mirrored from the CLI's own reader):

- Missing, corrupt, or shape-invalid file: treat as "not ready", never fatal.
- `version > 1`: refuse — the schema is newer than we understand.
- Stale detection: if `pid` is not alive, treat the file as missing so a
  crashed CLI cannot hold the port hostage.

Manual fallback: `setup({ port = ..., token = ... })` bypasses the discovery
file entirely (for SSH/remote setups where the file is not readable locally).

## Authentication

The token is a 256-bit value (32 random bytes, hex-encoded) minted per CLI
session. The client presents it during the WebSocket upgrade:

```http
Authorization: Bearer a3f1c2d4...64 hex chars...
```

The bare token (without `Bearer`) is also accepted. The server compares in
constant time.

**No `Origin` header may be sent.** The server rejects any upgrade request
carrying one (a browser tab is the only thing that would send one, and the
legitimate client is a Neovim `vim.uv` TCP connection).

## The Protocol

Messages are WebSocket **text frames**, one JSON object per frame. No JSON-RPC
envelope — each message has a `type` field.

`protocolVersion` is `"1.0.0"`.

### CLI to Neovim (ServerMessage)

- `connection_ack` — sent immediately on connect:
  `{ "type": "connection_ack", "protocolVersion": "1.0.0", "cliVersion": "1.2.3" }`
- `status` — connection/model state:
  `{ "type": "status", "connected": true, "model": "...", "provider": "...", "workingDirectory": "/path" }`
- `file_change` — a proposed edit (the diff review surface):
  `{ "type": "file_change", "id": "<uuid>", "filePath": "/abs/path", "originalContent": "...", "newContent": "...", "toolName": "write_file", "toolArgs": {} }`
  An empty `originalContent` means a new file.
- `tool_call` — tool activity for visibility:
  `{ "type": "tool_call", "id": "<uuid>", "toolName": "...", "toolArgs": {}, "status": "pending" | "executing" | "completed" | "rejected", "result": "..." }`
- `assistant_message` — assistant text (streaming flag):
  `{ "type": "assistant_message", "content": "...", "isGenerating": false }`
- `diagnostics_request` — the CLI wants LSP diagnostics:
  `{ "type": "diagnostics_request", "filePath": "/abs/path" }` (`filePath`
  optional; omit for all files)
- `close_diff` — close a diff view: `{ "type": "close_diff", "id": "<uuid>" }`
- `open_file` — open a file in the editor: `{ "type": "open_file", "filePath": "/abs/path" }`

### Neovim to CLI (ClientMessage)

- `send_prompt` — user input with context:
  `{ "type": "send_prompt", "prompt": "...", "context": { "filePath": "...", "fileName": "...", "selection": "...", "startLine": 0, "endLine": 10, "cursorPosition": {"line": 3, "character": 0} } }`
- `apply_change` — the user accepted a diff: `{ "type": "apply_change", "id": "<uuid>" }`
- `reject_change` — the user rejected a diff: `{ "type": "reject_change", "id": "<uuid>" }`
- `get_status` — request a `status` message: `{ "type": "get_status" }`
- `context` — workspace state: `{ "type": "context", "workspaceFolder": "/path", "openFiles": ["/a", "/b"], "activeFile": "/a", "diagnostics": [...] }`
- `diagnostics_response` — reply to `diagnostics_request`:
  `{ "type": "diagnostics_response", "diagnostics": [ ... ] }`
- `active_editor` — continuous editor state (debounced):
  `{ "type": "active_editor", "filePath": "/abs/path", "fileName": "file.lua", "selection": "...", "startLine": 0, "endLine": 4 }`
  `filePath` is cleared when no editor is active; `selection` is populated only
  for a non-empty selection.

### DiagnosticInfo

```json
{
  "filePath": "/abs/path",
  "line": 0,
  "character": 0,
  "message": "unused variable",
  "severity": "error" | "warning" | "info" | "hint",
  "source": "luacheck"
}
```

`line`/`character` are 0-based, matching `vim.diagnostic`.

## WebSocket details

- **Handshake**: standard RFC 6455 upgrade on `GET /`. The client computes
  `Sec-WebSocket-Accept` with SHA-1 over `Sec-WebSocket-Key` + the RFC GUID
  (`258EAFA5-E914-47DA-95CA-C5AB0DC85B11`), base64-encoded.
- **Client frames must be masked** (RFC 6455 §5.3); server frames are not.
- **Fragmentation**: text messages may arrive across continuation frames
  (large diffs will). The parser reassembles them, allows control frames to be
  interleaved between fragments, and enforces a 16 MB message cap.
- **Control frames**: `ping` is answered with `pong` automatically; `close`
  ends the connection and triggers a fixed-delay reconnect.

## Building your own integration

The minimum client is: read the discovery file, open a TCP socket to
`127.0.0.1:<port>`, complete the WebSocket upgrade with the bearer token and no
`Origin` header, then exchange typed JSON text frames. Everything else is
optional polish.

Security: **never bind or connect to anything but 127.0.0.1.** The token is
the only gate between a local process and a full agent takeover.

## Differences from claudecode.nvim

- claudecode.nvim: the **editor** hosts the server, writes a lock file, sets
  `CLAUDE_CODE_SSE_PORT`, and exposes MCP tools (`openFile`, `openDiff`, ...)
  for the CLI to call.
- nanocoder.nvim: the **CLI** hosts the server and writes the discovery file;
  the editor connects as a client. There are no MCP tools — the editor answers
  `diagnostics_request` and reads `file_change` / `open_file` instead.

The resulting UX is the same: live context sharing, native diff review,
diagnostics in the loop, and terminal integration.
