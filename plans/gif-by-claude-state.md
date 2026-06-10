# Plan — GIF-by-Claude-State for the PowerShell Overlay

**Repo:** `D:\Code\ClaudeSessionMonitor` (single-file WPF overlay, `overlay.ps1`, Windows PowerShell 5.1)
**Reference design:** `D:\Code\MyClaudeMonitor` (Tauri/React — already ships an equivalent per-state floating GIF window)
**Created:** 2026-06-10

## Goal

Add a **separate floating GIF window** to the overlay that displays a different animated GIF
depending on the overall Claude state across all sessions. The GIF reacts live as sessions
move between busy / waiting-for-input / idle.

## Locked design decisions

| Decision | Choice |
|---|---|
| Target codebase | Port into `overlay.ps1` (this repo), using MyClaudeMonitor as the design reference |
| GIF placement | Separate floating, borderless, always-on-top window (not inline in the list panel) |
| State set | `running` · `needs_input` · `idle` (**no `error`** state — dropped per user) |
| State source | Read the session JSON `status` field directly (`busy`→running, `needs_input`→needs_input, else idle). No hooks, no transcript parsing. |
| Aggregate priority | `needs_input` > `running` > `idle` (mirrors MyClaudeMonitor minus error) |
| GIF source | User-configured file path/URL per state in `settings.json`; **empty by default** (no bundled assets) |
| Animation engine | Zero-dependency WPF frame animator: `GifBitmapDecoder` → frames + `DispatcherTimer`. No external DLL (honors "built-in PowerShell 5.1 only"). |

## What already exists (reuse, don't rebuild)

- `Update-List` (overlay.ps1:612) already reads every `~/.claude/sessions/<pid>.json`, computes
  per-session `color`/`status` and `busy`/`alive`, and runs on a 2s `DispatcherTimer`. **The GIF
  aggregate is computed here** — one new block, no second file scan.
- `WinTools.SetNoActivate`, `VD.Follow`, `Pinner.Pin` (overlay.ps1:43/116/175) — the GIF window
  reuses these for no-activate + show-on-all-desktops behavior.
- `settings.json` load/save (overlay.ps1:270–284) — extend the same struct; no new persistence layer.
- Per-session `status` already passes through untouched (`$color = $s.status`, overlay.ps1:634), so
  `needs_input` already renders (currently as the default orange dot). We formalize it.

## Overall-state aggregation (the core mapping)

```
foreach session:
  effective = if (process dead) -> "idle"            # 'stale' counts as not-active for the GIF
              elif status == "needs_input" -> "needs_input"
              elif status == "busy"        -> "running"
              else                         -> "idle"

overall = if any "needs_input" -> "needs_input"
          elif any "running"   -> "running"
          else                 -> "idle"
```

GIF shown = `settings.gifPaths[overall]`; if that path is empty/unloadable → window hidden (or
"No GIF" fallback, matching MyClaudeMonitor's `GifArea`).

---

## Phase 1 — Settings schema + state aggregation (data layer)

**Files:** `overlay.ps1` (settings block ~270–311, `Update-List` ~612–666)

Tasks:
1. Extend the `$script:UI` settings struct and `settings.json` shape with:
   - `gifEnabled` (bool, default `true`)
   - `gifPaths` = `{ running = ""; needs_input = ""; idle = "" }` (empty default)
   - `gifWindow` = `{ left; top; width=200; height=200 }` (persist GIF window position/size)
2. Update `Save-UISettings` to round-trip the new fields (keep existing width/opacity).
3. In `Update-List`, after building `$rows`, compute `$script:OverallState` using the mapping above.
   Expose it as a script-scope variable the GIF window timer reads (no extra disk scan).
4. Recognize `needs_input` in `New-Row`'s dot-color switch (overlay.ps1:556) → distinct color
   (e.g. yellow `#FFE6A23C`) so the list and GIF agree.

**Verify:** Launch overlay; with a real session, confirm `$script:OverallState` transitions
busy↔idle correctly (temporary debug write to `CountText`). Confirm a session in an approval
prompt reports `status:"needs_input"` in its `~/.claude/sessions/<pid>.json` — **this validates the
core assumption that Claude Code emits `needs_input`** (see Risk R1).

## Phase 2 — Zero-dependency WPF GIF frame animator

**Files:** `overlay.ps1` (new helper section, ~after line 406)

Tasks:
1. Write `New-GifAnimator($imageControl, $path)`:
   - Load bytes → `GifBitmapDecoder` (`PresentationCore`, already loaded).
   - Extract each `decoder.Frames[i]` and its per-frame delay from frame metadata
     (`/grctlext/Delay`, in 1/100s; default to ~10 = 100 ms when absent).
   - Drive a `DispatcherTimer` that advances `imageControl.Source` through frames, looping.
   - Return a controller object with `.Stop()` / `.Dispose()` (stop timer, null the Source, free frames).
2. Handle load failure (bad path / not a GIF / single-frame) gracefully → return `$null`
   so the caller shows the fallback. Never throw into the UI thread.
3. Guard against re-entrancy: switching GIFs must `.Stop()` the previous animator before
   starting a new one (prevents two timers fighting over `Source`).

**Verify:** Point at a known multi-frame GIF; confirm smooth looping at roughly correct speed
and that `.Stop()` halts cleanly with no leaked `DispatcherTimer` (re-switch 20×, watch memory).

## Phase 3 — Floating GIF window + state wiring

**Files:** `overlay.ps1` (new XAML + handlers, ~after main window setup line 317)

Tasks:
1. Add a second borderless/transparent/topmost/no-activate WPF `Window` (its own XAML string):
   `WindowStyle=None`, `AllowsTransparency=True`, `Background=Transparent`, `Topmost=True`,
   `ShowInTaskbar=False`, `ResizeMode=NoResize`, sized/positioned from `settings.gifWindow`.
   Contains a single `<Image x:Name="GifImage" Stretch="Uniform"/>` + the whole surface is a drag region.
2. On `SourceInitialized`: capture its hwnd, call `WinTools.SetNoActivate`, and include it in the
   `Pinner.Pin` / `VD.Follow` flow so the GIF window also shows on all desktops (extend the
   `pinTimer`/`followTimer` to pin both hwnds).
3. Add a GIF refresh tick (reuse the existing 2s timer or a dedicated one): when
   `$script:OverallState` changes value, look up `settings.gifPaths[overall]`; if non-empty and
   different from the currently-loaded path, `.Stop()` the old animator and start a new one via
   `New-GifAnimator`. If empty/unloadable → hide the window (or show fallback).
4. Honor `gifEnabled`: when false (or all paths empty), keep the GIF window hidden.
5. Persist GIF window move/resize back into `settings.json` (drag region → `LocationChanged` → debounce → `Save-UISettings`).

**Verify:** Configure three distinct GIFs; drive a real session through busy→idle and (if reachable)
an approval prompt; confirm the floating window swaps GIFs within ≤2s, stays on top, never steals
focus (typing in the terminal is unaffected), and follows across virtual desktops.

## Phase 4 — Settings UI + persistence + docs

**Files:** `overlay.ps1` (header controls ~224–242 + new settings popup), `README.md`

Tasks:
1. Add a small **GIF** button to the header (next to Close) opening a lightweight settings popup
   (a child WPF window or an inline expander) with three path fields (running / needs_input / idle),
   a "GIF enabled" checkbox, and Save/Reset. Mirror MyClaudeMonitor's `SettingsModal` field layout.
   Reset → clears all three paths (empty = the documented default).
2. Wire Save → update `$script:UI`, call `Save-UISettings`, and immediately re-evaluate the GIF.
3. Update `README.md`: new "Status GIF" feature bullet, how to configure per-state GIFs, the
   transparency caveat (R3), and that empty paths = feature off.

**Verify:** Set paths via the UI, restart the overlay, confirm paths persist and the correct GIF
shows for the current state on cold start.

## Phase 5 — Integration hardening & final verification

**Files:** `overlay.ps1`

Tasks:
1. Full run-through: 0 sessions (idle GIF / hidden), 1 busy, mixed busy+idle, a needs_input session.
2. Confirm `Window.Add_Closed` stops the new GIF timer(s) + animator (extend overlay.ps1:698).
3. Stale/dead-process sessions don't pin the GIF to a non-idle state.
4. Bad GIF path, 1-frame GIF, huge GIF, and `file://` vs local path all degrade gracefully.
5. Confirm no regression to the existing list, focus, link, resize, opacity, pin/follow behavior.

**Verify:** Two-cycle batch check — run the whole scenario list once, fix all issues found, run once more clean.

---

## Risk Assessment

| Risk | Likelihood (1-5) | Impact (1-5) | Score | Mitigation |
|------|-----------------|--------------|-------|------------|
| R1: Claude Code does **not** actually emit `needs_input` in `~/.claude/sessions/<pid>.json` (sample only showed busy/idle) | 3 | 4 | 12 | Phase 1 verify step confirms it live during an approval prompt. If absent, needs_input silently collapses into running — feature still ships with 2 visible states; revisit detection only if confirmed missing. |
| R2: GIF animation in WPF without an external DLL is fiddly (per-frame delay metadata, looping, disposal) | 3 | 3 | 9 | Phase 2 is an isolated, independently-testable animator. Fallback: fixed ~10fps if per-frame delay parse fails; last resort `WpfAnimatedGif.dll` (rejected unless 2 isolated attempts fail). |
| R3: Transparent topmost window + GIFs with a baked (non-transparent) background look boxed. WPF has no CSS `mix-blend-mode: screen` (MyClaudeMonitor's trick) | 3 | 2 | 6 | Document: prefer transparent GIFs. Optionally add a configurable window background or an opacity-key; do NOT block the feature on it. |
| R4: Second always-on-top no-activate window mis-pins / fights the main window for desktop-follow | 2 | 3 | 6 | Reuse the proven `Pinner`/`VD` path; pin both hwnds in the same one-shot timer; test across ≥2 virtual desktops. |
| R5: Leaked `DispatcherTimer`/frames on rapid state flips → memory growth over a long session | 2 | 3 | 6 | Strict `.Stop()`/`.Dispose()` on every GIF switch + on window close; Phase 2 includes a 20×-switch leak check. |
| R6: `settings.json` schema change breaks existing installs (currently only `{width,opacity}`) | 2 | 2 | 4 | Additive, defensive load (missing keys → defaults), matching the existing `if ($cfg.width)` guard style. |

No score ≥ 15. R1 is the highest and is gated by an explicit Phase 1 verification before downstream work depends on it.

## Timeline

| Phase | Effort | Notes |
|-------|--------|-------|
| Phase 1: Settings + aggregation | S (~1d) | Foundation; unblocks all others. Includes R1 verification. |
| Phase 2: GIF frame animator | M (~2d) | Highest technical risk (R2); independently testable. |
| Phase 3: Floating window + wiring | M (~2d) | Depends on 1 + 2. Pin/follow integration (R4). |
| Phase 4: Settings UI + docs | S (~1d) | Depends on 1. |
| Phase 5: Hardening + verify | S (~1d) | Two-cycle batch verification. |
| **Total** | **~7d** | Critical path: Phase 1 → 2 → 3 → 5. Phase 4 can run parallel to 2/3. |

## Out of scope (explicit)

- `error` state / GIF (dropped per user).
- Bundling default GIF assets (paths are user-configured, empty default).
- Hook/transcript-based state detection (session `status` field is the sole source).
- Any change to how `~/.claude/sessions/*.json` are written (Claude Code owns that).
