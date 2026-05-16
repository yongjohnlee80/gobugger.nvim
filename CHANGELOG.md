# Changelog

All notable changes to `gobugger.nvim` are documented here.

## [v0.1.4] — 2026-05-16 — ADR 0021 Phase 2 wrapper

Internal refactor. Every previously bare `vim.notify("[gobugger]
…")` and local-`notify()`-helper call now flows through
`lua/gobugger/log.lua` so the auto-core ring captures the entry
for `:AutoCoreLog` triage. Toast surface is unchanged at every
call site.

### Added — `lua/gobugger/log.lua`

Per ADR 0021 §6, every auto-family plugin owns one
`lua/<plugin>/log.lua` that delegates to `auto-core.log`. Feature
code in gobugger now calls `require("gobugger.log")` exclusively;
`auto-core.log` is reachable only through the wrapper.

Exposes:

```lua
local log = require("gobugger.log")

log.error / .warn / .info / .debug / .trace  -- with gobugger.* component prefix
log.notify(msg, opts?)                        -- force-toast single emission
log.notifyIf(event, msg, opts?)               -- toast iff event subscribed
log.register_events(events)                   -- declare at setup
log.is_level_enabled(name)                    -- predicate
```

Soft-dep tolerant: when running against an auto-core older than
v0.1.11 (no `notify` / `notifyIf` / `events.register`), the
wrapper degrades to ring-only emissions and a
`[gobugger.<component>] <msg>` bare `vim.notify` fallback that
honors the pre-existing `gobugger.config.options.notify_title`
config so users without auto-core keep the v0.x toast surface.

### Changed — swept 8 active emission sites

- `lua/gobugger/run.lua` — the local `notify` helper (signature
  preserved: `notify(msg, level?)`) now delegates to
  `gobugger.log.<level>` with component `run`. Callers
  unchanged.
- `lua/gobugger/launch.lua` — same pattern, component `launch`.
- `lua/gobugger/ui.lua:54` — the dap-view soft-dep WARN now
  routes through `log.warn("ui", …)`.
- `lua/gobugger/init.lua:87` — `attach_remote` invalid-port WARN
  → `log.warn("attach_remote", …)`.
- `lua/gobugger/init.lua:172` — `attach` no-config WARN →
  `log.warn("attach", …)`.
- `lua/gobugger/errors.lua:51` — the scheduled error toast →
  `log.error("errors", …)`.
- `lua/gobugger/errors.lua:113` — no-captured-output INFO →
  `log.info("errors", …)`.

Hand-prefixed `"[gobugger]"` literals dropped from message
bodies — auto-core formats as
`[AutoCore] [gobugger.<component>] [LEVEL] <msg>`.

### Migration

Soft. Consumers pin gobugger.nvim via `version = "^0.1.0"` (when
they pin) and auto-update. The wrapper soft-deps against
pre-Phase-1 auto-core so consumers can stage the upgrade in any
order.

## Earlier versions

Pre-v0.1.4 history lives in git tags only — `v0.1.0` through
`v0.1.3`. Headline highlights:

- `v0.1.3` — `<leader>da` fix, remote-attach, failed-start error capture
- `v0.1.2` — `run_test` falls through to dap-go defaults when no test config exists
- `v0.1.1` — keymaps skip when dap symbols aren't loaded
- `v0.1.0` — initial release
