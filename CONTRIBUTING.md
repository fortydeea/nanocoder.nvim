# Contributing to nanocoder.nvim

Thanks for helping out. This is a small, dependency-free pure-Lua plugin —
keep it that way.

## Development setup

No build step, no tooling. Clone the repo and add it to your `runtimepath`, or
point your plugin manager at a local checkout:

```lua
-- lazy.nvim
{
  dir = "~/path/to/nanocoder.nvim",
  opts = {},
}
```

Requirements are the same as for users: Neovim >= 0.8 and the nanocoder CLI.
CI also tests against Neovim stable and nightly, so avoid APIs newer than 0.8
(or gate them in `lua/nanocoder/compat.lua`).

## Tests

Tests are plain Lua asserts with a tiny runner — no busted, no plenary.

```sh
nvim --headless -c "luafile tests/run.lua" -c "qa!"
```

- One test file per module: `lua/nanocoder/foo.lua` gets `tests/test_foo.lua`.
- Register cases with `test("description", function() ... end)` and assert with
  `eq(expected, actual)`, `ok(value)`, `fails(fn, needle)`.
- New logic ships with tests. Never disable a test to make a change pass.

## Project layout

- `lua/nanocoder/` — all plugin code. `init.lua` is the public `setup()`.
- `tests/` — test files plus `run.lua` (the runner).
- `PROTOCOL.md` — the wire spec. Update it when messages change.
- `README.md` — user-facing docs. Update it for new commands, options, or
  behavior changes.

## Branches and commits

Branch names use `{prefix}/{unit}-{description}`, where `unit` is the file or
module the branch changes:

- `bugfix/diff-buffer-selection`
- `feature/terminal-split-width`
- `docs/readme-add-new-section`

Prefixes: `bugfix/`, `feature/`, `docs/`. Skip the unit when the change spans
multiple modules.

Commit subjects use `{unit}: {description}` — describe the change, not the
problem:

- `diff: Only choose normal file windows to show diff`
- `terminal: Default vertical split to 40 columns`
- `commands: NanocoderSelectModel must not relaunch on cancel`

Put problem context in the commit body when it helps.

## Pull requests

1. Branch from `main`.
2. Make the smallest change that fully solves the problem. No new
   dependencies, abstractions, or config options unless the change needs them.
3. Run the test suite before pushing.
4. Update `README.md` and `PROTOCOL.md` when behavior or the wire format
   changes.
5. Keep the PR focused — one unit of work per PR.

CI runs the test suite on Neovim v0.8.3, stable, and nightly. It must pass
before merge.

## Code style

- Pure Lua, no runtime dependencies. Vendored helpers live alongside the code
  (`base64.lua`, `sha1.lua`) — do not add libraries.
- Match the surrounding code: 2-space indent, `local function` for module
  internals, `---@param`/`---@return` annotations on exported functions.
- Fail fast with descriptive errors. Do not silently swallow errors.
- Public behavior (commands, `setup()` options, `User` autocmds) is API —
  changing it is a breaking change and needs a clear PR description.

## Reporting bugs

Open an issue with:

- Neovim version (`nvim --version`) and OS
- nanocoder CLI version
- Relevant `:checkhealth nanocoder` output
- Log excerpt with `log_level = "debug"` from
  `stdpath("cache")/nanocoder.log`

## License

By contributing you agree that your contributions are licensed under the MIT
license (see `LICENSE`).
