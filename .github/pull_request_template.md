## What

<!-- One unit of work. Describe the change, not the problem. -->

## Why

<!-- Problem context. Link related issues: "Fixes #123". -->

## How

<!-- Only if the approach needs explaining. Otherwise delete this section. -->

## Checklist

- [ ] Tests pass: `nvim --headless -c "luafile tests/run.lua" -c "qa!"`
- [ ] New behavior has test coverage
- [ ] `README.md` updated for new commands, options, or behavior changes
- [ ] `PROTOCOL.md` updated if the wire format changed
- [ ] No new dependencies, abstractions, or config options unless the change needs them
- [ ] Code avoids APIs newer than Neovim 0.8 (or gates them in `lua/nanocoder/compat.lua`)
