# Codex Recent Tasks Sidebar

[简体中文](README.md) | [English](README.en.md)

A native macOS menu bar companion for viewing recent Codex tasks, task states, and usage information next to the ChatGPT / Codex desktop app.

It groups tasks from the last 48 hours by project directory and provides exact task navigation, left or right docking, an independently pinned mode, project shortcuts, and window width presets. It never modifies Codex data or uploads task content.

> This is an unofficial project and is not affiliated with OpenAI. It supports macOS 13 or later and has been validated on Apple Silicon Macs.

## Preview

| Recent tasks and window controls | Expanded usage analytics |
| --- | --- |
| ![Codex Recent Tasks Sidebar with fixture task data](docs/images/sidebar-overview.jpg) | ![Codex Recent Tasks Sidebar with fixture usage data](docs/images/usage-analytics.jpg) |

### Smart work report

![Codex smart work report generated from deterministic fixture data](docs/images/work-report.png)

> All three screenshots were generated from repository QA fixtures. They contain no real tasks, project paths, or account usage.

## v1.5.1 highlights

- Adds Codex-generated daily and weekly reports with one-sentence outcomes, completion estimates, overall summaries, next-step suggestions, and Markdown export.
- Opening the report window or switching its period never starts generation. Selected, redacted context is read only after an explicit Generate Report action.
- Shows the current stage, estimated progress, and elapsed time while generating, with a local-summary fallback when Codex is unavailable.
- Expands usage analytics, reset-time and account-plan presentation, diagnostics, and database retry handling.
- Refines Docked/Pinned controls, left/right docking, project shortcuts, and window-width presets.

## Features

### Recent tasks

- Groups tasks by canonical project directory and sorts them by recent activity.
- Shows top-level, non-archived tasks active within the last 48 hours.
- Displays running, action-required, unread-update, and last-activity states.
- Picks up renamed tasks on the next refresh.
- Opens the exact Codex task using its unique thread ID.
- Searches across tasks and projects.

### Project shortcuts

Right-click a task to:

- Copy the project path
- Reveal the project in Finder
- Open the project in Terminal

The Terminal action uses the built-in macOS Terminal app and opens directly in the project directory.

### Automatic daily and weekly reports

- Opens a separate Work Report window from the sidebar header or menu bar.
- Filters tasks for today or the current week and groups them by project.
- Uses the user's requests as primary evidence and assistant outcomes as supporting evidence, then asks Codex for a one-sentence result and completion estimate.
- Generates an overall summary and suggested next steps.
- Shows the current stage, estimated percentage, and elapsed time while generating; it never displays 100% before the complete result arrives.
- Copies Markdown or exports a `.md` file.

Opening the report window or switching between daily and weekly reports does not generate anything. Generation starts only after the user explicitly clicks Generate Report or Regenerate. The app trims user requests and assistant outcomes to the selected period, removes tool records, code blocks, absolute paths, and obvious secrets, then runs an ephemeral structured Codex summary. If Codex is unavailable, times out, or returns invalid output, the app falls back to its local summary.

### Window and ChatGPT integration

- Switch between Docked and Pinned in one segmented control. When docked, choose Left or Right.
- Follows ChatGPT window movement, resizing, foreground changes, minimization, and restoration.
- Falls back to the other side when the preferred side does not have enough room, avoiding overlap and unintended placement on another display.
- Pinned mode remains independently movable and above other apps.
- Offers Narrow, Medium, and Wide presets from the menu bar.
- Runs as a menu bar app without a Dock icon.

### Usage information

- Preserves the official remaining-usage percentage.
- Shows reset times for available rate-limit windows. If the official service omits the five-hour window, only the weekly window is shown.
- Displays the account plan, including Plus, Pro, Pro Lite, and Pro Max.
- Expands to a 30-day token chart, estimated equivalent API input cost, reset credits, and the most-used model.
- Official daily usage can lag by one day. The UI shows the latest available date when today's bucket is unavailable.
- Cost values are estimates based on official model input prices, not billing statements.

Task loading and usage loading are independent. Recent tasks remain available when usage information cannot be loaded.

## Download and install

Download the latest macOS archive from [Releases](https://github.com/fenghlkevin/codex-recent-tasks-sidebar/releases), extract it, and move `CodexRecentTasksSidebar.app` to `/Applications`.

Docking and window tracking require Accessibility permission:

`System Settings > Privacy & Security > Accessibility`

Allow “Codex 最近任务” to control the computer. The app uses an ad-hoc signature and is not Apple-notarized, so the first launch may require confirmation under Privacy & Security.

## Build from source

Requirements:

- macOS 13 or later
- Xcode Command Line Tools
- ChatGPT / Codex desktop used at least once

```bash
git clone https://github.com/fenghlkevin/codex-recent-tasks-sidebar.git
cd codex-recent-tasks-sidebar
./scripts/qa.sh
open build/CodexRecentTasksSidebar.app
```

`./scripts/qa.sh` builds and validates the app. The output is:

```text
build/CodexRecentTasksSidebar.app
```

After validating the local build, replace `/Applications/CodexRecentTasksSidebar.app` manually. The build scripts never overwrite an installed app.

## Start with ChatGPT

The app does not present itself automatically at system login. The included [`scripts/watch-chatgpt.sh`](scripts/watch-chatgpt.sh) can be invoked periodically by a macOS LaunchAgent:

- It starts the sidebar only when the main `/Applications/ChatGPT.app` process is running.
- It does not mistake Codex background helpers for the ChatGPT window.
- It does nothing while ChatGPT is not running.
- The sidebar exits when ChatGPT quits.

The script expects the sidebar at:

```text
/Applications/CodexRecentTasksSidebar.app
```

LaunchAgent integration is optional. Even when an existing agent uses `RunAtLoad`, the watcher checks for the main ChatGPT process before opening the sidebar.

## Menu bar

The menu bar icon provides:

- Show Sidebar
- Work Report
- Refresh
- Request Accessibility Permission
- Window Width: Narrow / Medium / Wide
- Quit

## Data sources and privacy

The app reads local Codex data in read-only mode:

- `~/.codex/state_5.sqlite` or a compatible database location
- `~/.codex/session_index.jsonl`
- `~/.codex/.codex-global-state.json`
- Each task's event stream under `~/.codex/sessions/`

Usage, reset times, and plan information come from the official `codex app-server` bundled with ChatGPT / Codex and use the existing signed-in session.

Privacy boundaries:

- Never modifies, migrates, vacuums, or replaces the Codex database.
- The normal task list never uploads task titles, task content, thread IDs, project paths, or event-stream payloads.
- Only after the user explicitly clicks Generate Report or Regenerate are trimmed and redacted user requests and assistant outcomes sent to Codex through the current signed-in account. Thread IDs, absolute project paths, tool logs, and full code are excluded.
- Smart reports use a temporary read-only directory and an ephemeral session, create no persistent Codex task, never write back to Codex data, and never log report input or raw model output.
- Never prints or persists login tokens or raw account responses.
- Diagnostic logs contain candidate database paths, file status, SQLite error codes, and retry outcomes only. They do not contain task content.
- `UserDefaults` stores only window placement, width, dock side, display mode, and usage-panel state.
- CI and QA use generated fixtures only.

## Refresh intervals

- Runtime state: approximately 5 seconds
- Tasks and names: approximately 30 seconds
- Usage and account information: approximately 60 seconds
- Top-right refresh button: immediate refresh with a visible rotation animation

The footer text “Tasks 30s · Usage 60s” describes automatic refresh intervals, not reporting periods.

## Validation

```bash
./scripts/qa.sh
```

QA covers:

- Native Swift build
- Info.plist, architecture, and code-signing checks
- A generated SQLite fixture
- Running, action-required, and unread-update state priority
- Task-name index and unread-state checks
- Read-only hash checks across five fixture data sources
- Usage windows, account plan, reset credits, and analytics protocol checks
- Daily/weekly filtering, context redaction, staged progress, structured Codex output, and local fallback checks
- Missing database, index, state, and usage-service boundaries
- Dock placement boundaries
- Secret and personal-data scanning

QA does not read real task content or connect to a real account.

## Troubleshooting

### The sidebar does not follow ChatGPT

Confirm that “Codex 最近任务” is enabled under Accessibility. If macOS treats a replaced build as a new app, remove the stale permission entry and add `/Applications/CodexRecentTasksSidebar.app` again.

### Tasks temporarily fail to load

Use Retry or the top-right refresh button. Diagnostic logs are stored at:

```text
~/Library/Logs/CodexRecentTasksSidebar/task-store.log
```

The log does not contain task titles or task content.

### Tasks exist but the list is empty

The list includes only top-level, non-archived tasks active in the last 48 hours. Also verify that the current Codex database is in a supported location and inspect the diagnostic log for candidate database status.

### Usage information is missing

Confirm that ChatGPT / Codex is signed in and that a compatible official `codex app-server` is installed. The app does not fabricate a rate-limit window or daily bucket that the official service did not return.

## Repository layout

```text
.
├── README.md
├── README.en.md
├── AGENTS.md
├── CLAUDE.md
├── scripts/
│   ├── build_app.sh
│   ├── qa.sh
│   └── watch-chatgpt.sh
└── skills/codex-recent-tasks-sidebar/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/build_app.sh
    └── assets/app-template/
        ├── Codex最近任务栏.swift
        ├── Info.plist
        └── AppIcon.icns
```

## Known limitations

- macOS only.
- The release archive targets Apple Silicon. Build from source on the target Mac for other architectures.
- macOS full-screen Spaces limit side-by-side windows from separate apps.
- Changes to the Codex database schema, unread-state format, `app-server` protocol, bundle identifier, or deep-link scheme may require an update.
- Usage analytics depend on official data and can be delayed or temporarily unavailable.

## Origin and credits

The original version of this project came from [chuanfan-ai/codex-recent-tasks-sidebar-skill](https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill.git). Thanks to the original author for the foundational implementation and open-source template.

## License

[MIT](LICENSE)
