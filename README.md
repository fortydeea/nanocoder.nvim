# nanocoder.nvim

Pure-Lua Neovim extension for the [nanocoder](https://github.com/Nano-Collective/nanocoder)
coding agent. This project was heavily modeled the approach in `coder/claudecode.nvim`.
Zero dependencies, Neovim 0.8+.

nanocoder runs in a `:terminal` window and starts a local WebSocket companion
(`nanocoder --vscode`). This plugin connects to that companion as a WebSocket
client and shares editor context both ways: your selection and diagnostics go
to the agent, and proposed file changes open as native Neovim diffs you can
accept or reject.

> **How it works, in one line**: the CLI hosts the server and writes a
> discovery file; this plugin reads it and connects. The inverse of the
> Claude Code protocol. See [PROTOCOL.md](PROTOCOL.md) for the full spec.

## Requirements

- Neovim >= 0.8
- [nanocoder CLI](https://github.com/Nano-Collective/nanocoder)
- A configured provider (see nanocoder's `agents.config.json` docs)

## Installation

### lazy.nvim

```lua
{
  "fortydeea/nanocoder.nvim",
  cmd = {
    "Nanocoder", "NanocoderFocus", "NanocoderSelectModel", "NanocoderAdd",
    "NanocoderSend", "NanocoderSendText", "NanocoderTreeAdd", "NanocoderStatus",
    "NanocoderStart", "NanocoderStop", "NanocoderOpen", "NanocoderClose",
    "NanocoderDiffAccept", "NanocoderDiffDeny", "NanocoderCloseAllDiffs",
  },
  keys = {
    { "<leader>a", nil, desc = "AI/nanocoder" },
    { "<leader>ac", "<cmd>Nanocoder<cr>", desc = "Toggle nanocoder" },
    { "<leader>af", "<cmd>NanocoderFocus<cr>", desc = "Focus nanocoder" },
    { "<leader>am", "<cmd>NanocoderSelectModel<cr>", desc = "Select model" },
    { "<leader>ab", "<cmd>NanocoderAdd %<cr>", desc = "Add current buffer" },
    { "<leader>as", "<cmd>NanocoderSend<cr>", mode = "v", desc = "Send to nanocoder" },
    { "<leader>aa", "<cmd>NanocoderDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>NanocoderDiffDeny<cr>", desc = "Deny diff" },
  },
  opts = {},
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add("https://github.com/fortydeea/nanocoder.nvim")
require("nanocoder").setup()
```

### packer.nvim

```lua
use({
  "fortydeea/nanocoder.nvim",
  config = function()
    require("nanocoder").setup()
  end,
})
```

### vim-plug

```vim
Plug 'fortydeea/nanocoder.nvim'
```

then, in your Lua config (or `lua << EOF` in vimscript):

```lua
require("nanocoder").setup()
```

### Manual

Clone into your `packpath`/`runtimepath`, then call
`require("nanocoder").setup()` from your config. No other setup is needed —
the plugin auto-starts the companion connection.

## Usage

1. **Launch**: `:Nanocoder` opens a terminal running `nanocoder --vscode`.
2. **Send context**: select text and press `<leader>as` — the terminal is
   prefilled with `@file#L{start}-L{end}` and you type the instruction after
   it. Or `:NanocoderAdd` for a file/range, `:NanocoderTreeAdd` from a file
   tree.
3. **Review diffs**: proposed changes open as native diffs — `:w` accepts,
   `:q` rejects. Your decision is mirrored onto the CLI's own "Tool Approval"
   prompt, so one decision is enough: accept runs the tool, reject cancels it.

## Commands

- `:Nanocoder` — toggle the nanocoder terminal
- `:NanocoderFocus` — focus the terminal (opens when closed)
- `:NanocoderStart` / `:NanocoderStop` — start/stop the terminal and connection
- `:NanocoderOpen` / `:NanocoderClose` — open/close the terminal window
- `:NanocoderStatus` — show connection state, model, provider
- `:NanocoderSend` — prefill the terminal with the selection reference (`@file#L{start}-L{end}`, does not submit; you type the instruction after it), or prompt for a message when nothing is selected
- `:NanocoderSendText {text}` — type text into the terminal (`!` inserts without submitting)
- `:NanocoderAdd [start] [end]` — add the current file/range to context
- `:NanocoderTreeAdd` — add the file under the cursor in a file tree
- `:NanocoderSelectModel` — choose provider/model, relaunch the terminal
- `:NanocoderDiffAccept` / `:NanocoderDiffDeny` — accept/reject the diff under the cursor
- `:NanocoderCloseAllDiffs` — close all pending diffs without accepting

## Configuration

```lua
require("nanocoder").setup({
  log_level = "info",          -- trace|debug|info|warn|error
  terminal_cmd = "nanocoder",  -- binary or full path
  auto_connect = true,         -- connect to the companion automatically
  discovery_path = nil,        -- override vscode-server.json location
  port = nil, token = nil,     -- manual fallback (SSH/remote setups)
  diff_opts = {
    layout = "vertical",       -- "vertical"|"horizontal"|"unified"
    answer_tool_prompt = true, -- mirror accept/reject onto the CLI's tool prompt
  },
  terminal = {
    provider = "native",       -- "native"|"external"|"none"|custom-table
    split_direction = "vert botright",  -- :split modifiers ("botright" for bottom)
    split_width_percentage = 0.3,
    split_height_percentage = 0.3,  -- used for horizontal splits
    focus_after_send = true,
    auto_insert = true,
    provider_opts = {
      external_terminal_cmd = nil,  -- e.g. "alacritty -e %s"
    },
    cwd = nil,
    git_repo_cwd = false,
    cwd_provider = nil,        -- function(ctx) -> dir
  },
})
```

See `lua/nanocoder/config.lua` for the complete schema.

## Tool approval

The CLI has its own "Tool Approval" prompt for every tool call, including the
one behind a proposed diff — nothing is written to disk until it is answered.
With `diff_opts.answer_tool_prompt = true` (default) the plugin answers it in
the direction of your diff decision: accept sends Enter (runs the tool),
reject sends Escape (cancels the tool call entirely, so a rejected diff is
never applied). Closing a diff without deciding (`:NanocoderCloseAllDiffs`,
a `close_diff` from the CLI) answers nothing.

Details of the watch: it only sends a keystroke when that prompt is on screen
for the accepted tool and the terminal has been quiet for a moment, so a
different tool's prompt is never touched and Escape can never cancel an
unrelated generation. For accept it additionally needs "Yes" to be the
selected entry — if you move the selection, your choice stands and it waits
(it never sends Enter on "No"; reject is indifferent to the selection, since
Escape cancels either way). It gives up after 10 seconds and sends nothing.

The auto-answer needs a `native` terminal; with the `external` or `none`
provider there is no channel to type into, so answer the prompt in that
terminal yourself.

## Diff lifecycle events

`User` autocmds fire when diffs open and close:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "NanocoderDiffOpened",
  callback = function(ev)
    print(ev.data.file_path, ev.data.is_new_file)
  end,
})
```

Events: `NanocoderDiffOpened` (tab_name, file_path, new_file_path,
is_new_file, diff_window, target_window, terminal_window, tab_number),
`NanocoderDiffClosed` (same fields plus a diagnostic `reason` string).

## Terminal providers

- `native` (default) — built-in `:terminal` in a split
- `external` — spawn a terminal app (set `provider_opts.external_terminal_cmd`)
- `none` — no terminal at all (you run `nanocoder --vscode` yourself)
- custom table — implement `open`, `close`, `focus`, `is_open`, `send_text`

## Troubleshooting

- **First stop**: `:checkhealth nanocoder` — verifies the CLI, discovery file,
  WebSocket connection, and terminal provider.
- **Not connecting?** Check `:NanocoderStatus` and that
  `vscode-server.json` exists in your nanocoder config dir
  (`~/.config/nanocoder/` on Linux, `~/Library/Preferences/nanocoder/` on
  macOS, or `$NANOCODER_CONFIG_DIR`).
- **SSH / remote?** Set `port` and `token` manually in `setup()` — the
  discovery file is local to the machine running the CLI.
- **Debug logs**: `log_level = "debug"`, written to
  `stdpath("cache")/nanocoder.log`.

## Protocol

See [PROTOCOL.md](PROTOCOL.md) for the complete wire specification: discovery
file schema, WebSocket handshake (bearer token auth, no `Origin` header), and
every message type in both directions.

## Development

Tests run headlessly with no extra tooling:

```sh
nvim --headless -c "luafile tests/run.lua" -c "qa!"
```

## Limitations

This project interfaces with nanocoder's vscode support.
If you do not have a vscode in your path, you may get a warning message during startup.

## License

MIT
