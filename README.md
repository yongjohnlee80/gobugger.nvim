# gobugger.nvim

> *An opinionated Go debugger for Neovim: launch.json-driven, worktree-aware, delve-integrated, and pre-wired with the UI you actually want to look at.*

**gobugger** folds the boring parts of a Go debugging workflow into one plugin: resolves `launch.json` across worktrees, picks the right config with a session-cached prompt when there's more than one, scaffolds new entries from your current buffer, wires `nvim-dap-view` as the UI out of the box, and includes a doctor + `git worktree repair` helper for when bare+worktree setups go sideways.

Built for Go first; the language table leaves room for others.

## Table of contents

- [Features](#features)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Configuration](#configuration)
- [launch.json reference](#launchjson-reference)
- [Worktree / monorepo workflows](#worktree--monorepo-workflows)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)
- [License](#license)

## Features

- **Multi-config picker** with per-mode session caching. Press your "debug test" keymap in a repo with five test configs — picker once per session, pinned afterwards.
- **`mode=debug` execution** — drive main-program debug sessions from `launch.json` so multi-entry-point repos (`cmd/http`, `cmd/cli`, `cmd/worker`) each get their own args, env, and build tags.
- **Interactive scaffolder** — `:Gobugger new main` / `:Gobugger new test` from any Go buffer writes a new entry into `<project-root>/.vscode/launch.json`. Prompts for name, args (debug only), inline env, envFile, buildFlags. Pretty-printed in VSCode field order.
- **Upward-walking resolver** — share one `launch.json` across every worktree of a project by parking it at the project root (next to `.bare/` or `.git/`). `${workspaceFolder}` still resolves to the active worktree so envFiles can be per-branch.
- **Bundled UI (nvim-dap-view)** — auto-setup with sensible layout (watches / scopes / exceptions / breakpoints / threads / repl, right-side terminal). Auto-open on session start, auto-close on exit.
- **winfixbuf guard** — DAP's `jump_to_frame` stops exploding when a breakpoint hits while focus is on neo-tree or the dap-view panel.
- **Delve-friendly defaults** — scaffolder pre-fills `buildFlags = "-buildvcs=false"` so bare+worktree setups don't fail Go's VCS stamp.
- **Doctor + Fix** — `:Gobugger doctor` dumps the full resolution state (which `launch.json`, which project root, whether the cwd's `.git` is healthy, go module root, available configs, session picks). `:Gobugger fix` runs `git worktree repair` from the bare when you've got stale gitfile pointers.

## Install

### Dependencies

Hard deps (lazy.nvim installs them automatically):

- [`mfussenegger/nvim-dap`](https://github.com/mfussenegger/nvim-dap)
- [`leoluz/nvim-dap-go`](https://github.com/leoluz/nvim-dap-go)
- [`igorlfs/nvim-dap-view`](https://github.com/igorlfs/nvim-dap-view)

Soft deps (recommended):

- [`mason-org/mason.nvim`](https://github.com/mason-org/mason.nvim) with `delve` ensure-installed

### lazy.nvim

```lua
{
  "yongjohnlee80/gobugger.nvim",
  dependencies = {
    "mfussenegger/nvim-dap",
    "leoluz/nvim-dap-go",
    "igorlfs/nvim-dap-view",
  },
  event = "VeryLazy",
  opts = {
    -- Optional: restart workspace-rooted LSPs when cwd changes.
    -- Pair this with worktree.nvim or another switcher.
    lsp_servers_to_restart = { "gopls" },

    -- Optional: if your bare repos use `.git/` directly (instead of `.bare/`)
    -- bare_dir = ".git",
  },
  config = function(_, opts)
    require("gobugger").setup(opts)
    require("gobugger").default_keymaps()  -- optional; bind your own otherwise
  end,
}
```

### packer.nvim

```lua
use {
  "yongjohnlee80/gobugger.nvim",
  requires = {
    "mfussenegger/nvim-dap",
    "leoluz/nvim-dap-go",
    "igorlfs/nvim-dap-view",
  },
  config = function()
    require("gobugger").setup({})
    require("gobugger").default_keymaps()
  end,
}
```

### Delve

gobugger depends on `delve` being on `PATH`. Either install manually (`go install github.com/go-delve/delve/cmd/dlv@latest`), or let Mason handle it:

```lua
-- in your mason.nvim spec
opts = { ensure_installed = { "delve" } },
```

## Quick start

1. Open a Go main package (e.g. `cmd/myapp/main.go`).
2. `:Gobugger new main` — prompts for name, args, env, envFile, buildFlags. Writes `<project-root>/.vscode/launch.json`.
3. Open any file in the project, drop a breakpoint with `<leader>db`.
4. `:Gobugger run` (or `<leader>dm` with default keymaps) — picker shows your new config, launches delve, dap-view opens.
5. Step through, evaluate expressions, hit `<leader>dq` to terminate.

For tests: open a `*_test.go` file, cursor inside a test function, `:Gobugger test` (or `<leader>dt`). No `launch.json` required for a basic test debug — if one exists with a matching `mode=test` entry, its env/buildFlags get merged in automatically.

## Commands

Single user command with completion-aware subcommands:

| Subcommand | What it does |
|---|---|
| `:Gobugger test` | Debug the test under the cursor; picker over `mode=test` configs |
| `:Gobugger run` | Debug a main program; picker over `mode=debug` configs |
| `:Gobugger run-last` | `dap.run_last()` — re-run the most recent session |
| `:Gobugger new main` | Scaffold a new `mode=debug` entry |
| `:Gobugger new test` | Scaffold a new `mode=test` entry |
| `:Gobugger reload` | Clear launch.json cache + all session picks |
| `:Gobugger pick [test\|debug]` | Clear the session pick for one mode (default `test`) |
| `:Gobugger doctor` | Dump diagnostic report (launch.json / project root / git state / configs) |
| `:Gobugger fix` | `git worktree repair` from the current repo's common dir |

Tab-completion works at every level.

## Keymaps

`require("gobugger").default_keymaps()` wires the full set under `<leader>d*` + F-keys. Missing targets (e.g. dap-go not installed) skip their maps silently.

### Step / flow

| Key | Action |
|---|---|
| `<F9>` / `<leader>dc` | Continue / start |
| `<F8>` | Step over |
| `<F7>` | Step into |
| `<F10>` | Step out |
| `<leader>dr` | Run last |
| `<leader>dq` | Terminate |
| `<leader>dR` | Restart |

### Breakpoints

| Key | Action |
|---|---|
| `<leader>db` | Toggle breakpoint |
| `<leader>dB` | Conditional breakpoint (prompts) |
| `<leader>dC` | Clear all breakpoints |

### dap-view

| Key | Action |
|---|---|
| `<leader>dv` | Toggle inspection panel |
| `<leader>dw` | Add watch expression (normal + visual) |
| `<leader>de` | Evaluate expression (normal + visual) |

### launch.json-driven

| Key | Action |
|---|---|
| `<leader>dt` | Debug test under cursor (+launch.json) |
| `<leader>dm` | Debug main program (+launch.json) |
| `<leader>dT` | Run last |
| `<leader>dM` | **Scaffold** new main entry |
| `<leader>dN` | **Scaffold** new test entry |
| `<leader>dL` | Reload launch.json + clear picks |
| `<leader>dD` | Doctor |
| `<leader>dF` | Fix worktree (git worktree repair) |

### dap-go

| Key | Action |
|---|---|
| `<leader>da` | Attach to running process (delve PID picker) |

Override individual maps after `default_keymaps()` — your `vim.keymap.set` calls run last and win.

## Configuration

All options are optional. Defaults:

```lua
require("gobugger").setup({
  -- Notification title. Set false to omit.
  notify_title = "gobugger",

  -- Paths checked (in order) at each level of the upward walk.
  launch_paths = { ".vscode/launch.json", "launch.json" },

  -- Hard pin: skip the picker and always use this name. nil = use
  -- session cache + prompt.
  config_name = nil,

  -- Run vim.fn.expand() on inline env values too. Default false keeps
  -- literal `$` in bcrypt hashes, passwords, cron expressions.
  expand_env_values = false,

  -- Workspace-rooted LSPs to stop+restart when cwd switches. gobugger
  -- doesn't switch cwd itself; this is here for worktree-switcher
  -- integrations. Common: "gopls", "rust_analyzer", "pyright", "tsserver".
  lsp_servers_to_restart = {},

  -- Directory holding the bare repo in worktree setups. Two conventions:
  --   ".bare"  -- bare in .bare/, .git is a gitfile (canonical)
  --   ".git"   -- bare directly in .git/ (core.bare=true)
  -- Detection supports both regardless of this setting.
  bare_dir = ".bare",

  -- UI wiring:
  --   "dap-view"  -- bundled opinionated layout (default)
  --   false       -- no UI wiring; you handle it yourself
  --   <table>     -- passed verbatim as dap-view opts
  ui = "dap-view",

  -- DAP sign column glyphs. Set false to skip sign wiring entirely.
  sign_glyphs = {
    DapBreakpoint          = { text = "●", texthl = "DiagnosticError" },
    DapBreakpointCondition = { text = "◆", texthl = "DiagnosticError" },
    DapBreakpointRejected  = { text = "○", texthl = "DiagnosticWarn"  },
    DapLogPoint            = { text = "◆", texthl = "DiagnosticInfo"  },
    DapStopped             = { text = "▶", texthl = "DiagnosticWarn", linehl = "Visual" },
  },

  -- Per-language config. Add a table here for each language you want to
  -- target; only Go is filled out of the box.
  languages = {
    go = {
      filetype = "go",                       -- buffer filetype to match
      dap_type = "go",                       -- DAP adapter name
      default_build_flags = "-buildvcs=false", -- pre-filled in scaffolder
    },
  },
})
```

## launch.json reference

gobugger reads VSCode-compatible `launch.json` (JSONC + trailing commas tolerated). A minimal Go entry looks like:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Go: HTTP server",
      "type": "go",
      "request": "launch",
      "mode": "debug",
      "program": "${workspaceFolder}/cmd/http",
      "args": ["--port=8080"],
      "envFile": "${workspaceFolder}/.env",
      "env": { "LOG_LEVEL": "debug" },
      "buildFlags": "-buildvcs=false -tags=integration"
    },
    {
      "name": "Go: Debug Test (gold)",
      "type": "go",
      "request": "launch",
      "mode": "test",
      "program": "${workspaceFolder}",
      "buildFlags": "-tags=gold",
      "envFile": "${workspaceFolder}/.env.test"
    }
  ]
}
```

### Fields gobugger understands

| Field | Purpose | Substitution |
|---|---|---|
| `name` | Picker label + cache key | — |
| `type` | DAP adapter name (must match a registered `languages.*.dap_type`) | — |
| `request` | Always `"launch"` for gobugger flows | — |
| `mode` | `"test"` or `"debug"` — determines which picker this shows up in | — |
| `program` | Package path (`mode=debug`) or test target (`mode=test`) | `${workspaceFolder}` + shell expansion |
| `cwd` | Working directory for the program at runtime | `${workspaceFolder}` + shell expansion |
| `args` | Program arguments (array of strings) | `${workspaceFolder}` + shell expansion |
| `env` | Inline env vars (object) | `${workspaceFolder}` (shell off by default — see `expand_env_values`) |
| `envFile` | Path to a `.env`-style file | `${workspaceFolder}` + shell expansion |
| `buildFlags` | Flags passed to `go build` by delve | `${workspaceFolder}` |
| `output` | Output binary path | `${workspaceFolder}` + shell expansion |

### Substitution rules

- **`${workspaceFolder}`** resolves to the current Neovim cwd at load time (not at scaffold time). This is what makes one shared `launch.json` work across every worktree of a project.
- **Shell expansion** (`~`, `$VAR`) applies to path-like fields only (`program`, `cwd`, `output`, `args`, `envFile`). `buildFlags` and `env` values get `${workspaceFolder}` substitution only — literal `$` in passwords / hashes survives.
- **envFile + env merge** — envFile is parsed first, then `env` entries overlay. Last-write wins on duplicates.

### Comments + trailing commas

gobugger strips `//` and `/* */` comments before parsing, and trailing commas are forgiven. Same tolerance VSCode has.

## Worktree / monorepo workflows

### Shared launch.json across worktrees

Bare+worktree layout:

```
lm/
├── .bare/             # bare repo (or .git/ if you use that convention)
├── launch.json        # ← shared across all worktrees
├── main/              # worktree
│   ├── .git           # gitfile pointer
│   └── cmd/...
└── feature-x/         # worktree
    ├── .git
    └── cmd/...
```

The upward walk starts at your cwd and stops at `.bare/` or `.git/` as a directory. Gitfiles (linked worktrees) are transparent. So one `launch.json` at `lm/` covers every worktree; no copy-paste per branch.

Per-worktree overrides: drop a `.vscode/launch.json` inside a worktree and it wins the walk.

### Multi-entry-point repos

One `launch.json` entry per `cmd/*` binary. `<leader>dm` picker lets you switch between them with session caching so iterative debugging on the HTTP server doesn't keep re-prompting.

```json
{
  "configurations": [
    { "name": "HTTP",   "type": "go", "request": "launch", "mode": "debug",
      "program": "${workspaceFolder}/cmd/http",   "args": ["--port=8080"] },
    { "name": "Worker", "type": "go", "request": "launch", "mode": "debug",
      "program": "${workspaceFolder}/cmd/worker", "env": { "LOG_LEVEL": "debug" } },
    { "name": "CLI: migrate up", "type": "go", "request": "launch", "mode": "debug",
      "program": "${workspaceFolder}/cmd/cli",    "args": ["migrate", "up"] }
  ]
}
```

### Integration with worktree-switchers

gobugger doesn't switch cwd — that's a separate plugin concern. If you're using [`worktree.nvim`](https://github.com/yongjohnlee80/worktree.nvim), it handles `:cd`, stale-buffer cleanup, and LSP re-anchor. `lsp_servers_to_restart` here is provided so you can configure both in one place if you prefer; it's only acted on if something calls into the UI setup flow.

## Troubleshooting

### `error obtaining VCS status: exit status 128`

Go 1.18+ embeds VCS metadata into binaries via `-buildvcs=true`. In bare+worktree setups where a worktree's `.git` pointer is stale (or `git status` otherwise fails), the build aborts. Two fixes:

1. **Include `-buildvcs=false`** in the entry's `buildFlags`. This is the scaffolder default.
2. **Fix the underlying gitfile** — `:Gobugger fix` runs `git worktree repair` from the bare.

Run `:Gobugger doctor` to see which case you're in. The `cwd .git` line will show `MISSING` if the pointer is stale.

### `E1513: Cannot switch buffer. 'winfixbuf' is enabled`

DAP tries to show the source file in the current window; if that window has `winfixbuf` (neo-tree, dap-view panel, help), the set-buf fails. gobugger registers a `before.event_stopped` listener that redirects focus to a normal editing window before `jump_to_frame` fires. If you still see this, something is disabling or overriding the listener — re-run `require("gobugger").setup()`.

### Picker prompts every time

You're calling `reload` / the mtime changed. The session pick is cleared whenever `launch.json` is re-read. If you want a durable pin, set `config_name = "Go: Debug Main (http)"` in your setup opts.

### Scaffolder says "no project root"

The walk didn't find `.bare/` or `.git/` as a directory. Either:

- You're outside any git repo — scaffold wouldn't know where to put `.vscode/launch.json`.
- Your bare is named something else — set `bare_dir` in opts.

### Nothing happens on `<leader>dt`

Check `:messages` for a `[gobugger]` notification. Most likely: no matching `mode=test` config. Run `:Gobugger doctor` — the Configs section shows what's available.

## Examples

### Minimal Go main

```json
{
  "version": "0.2.0",
  "configurations": [
    { "name": "main", "type": "go", "request": "launch", "mode": "debug",
      "program": "${workspaceFolder}" }
  ]
}
```

### Polyglot setup extending to Rust (preview)

Language table makes room for more adapters once their language module lands:

```lua
require("gobugger").setup({
  languages = {
    go = { filetype = "go", dap_type = "go", default_build_flags = "-buildvcs=false" },
    -- example of what Rust could look like when the lang/rust.lua is written:
    -- rust = { filetype = "rust", dap_type = "codelldb", default_build_flags = "" },
  },
})
```

Go is first-class in v0.x; extensions welcome.

### Scaffolder flow in action

```
user opens cmd/gold-http/main.go
user presses <leader>dM
> Config name: Go: Debug Main (gold-http)
> Program args (space-separated, blank = none): start -c ../.config/gold-prod.toml
> env inline (KEY=VAL;KEY=VAL, blank = none): LOG_LEVEL=debug;PORT=5100
> envFile path (blank = none): ${workspaceFolder}/.env.local
> buildFlags (blank = none): -buildvcs=false
gobugger: added entry 'Go: Debug Main (gold-http)' (mode=debug, program=${workspaceFolder}/cmd/gold-http)
```

Resulting entry:

```json
{
  "name": "Go: Debug Main (gold-http)",
  "type": "go",
  "request": "launch",
  "mode": "debug",
  "program": "${workspaceFolder}/cmd/gold-http",
  "args": ["start", "-c", "../.config/gold-prod.toml"],
  "env": { "LOG_LEVEL": "debug", "PORT": "5100" },
  "envFile": "${workspaceFolder}/.env.local",
  "buildFlags": "-buildvcs=false"
}
```

## License

MIT.
