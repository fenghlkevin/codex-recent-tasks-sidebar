---
name: codex-recent-tasks-sidebar
description: Build, customize, validate, or repair a native macOS Codex recent-tasks menu bar companion. Use when a user wants a SwiftUI utility that reads recent Codex tasks, running/attention/unread state, remaining usage, reset times, account plan, usage analytics, and Codex-generated daily or weekly reports with a local fallback; groups tasks by working folder; opens exact tasks; docks on either side of Codex; follows Codex window state; or stays independently pinned.
---

# Codex Recent Tasks Sidebar

Build from the bundled template instead of recreating the app. Preserve its read-only data boundary and complete the real macOS checks before delivery.

## Workflow

1. Confirm the machine is macOS 13 or newer and has `/usr/bin/swiftc`, `/usr/bin/sqlite3`, `/usr/bin/codesign`, and `/usr/bin/plutil`.
2. Confirm Codex or the ChatGPT desktop app has been used at least once. Locate its task database, `session_index.jsonl`, `.codex-global-state.json`, and per-task rollout file under `~/.codex/` without copying, printing, or committing task contents or task IDs. Normal task-state refresh reads only rollout event types, tool names, completion IDs, and the approval-policy field needed to distinguish running from waiting. An explicit daily/weekly report action may read user and assistant messages for the selected time range, trim and redact them, and send that minimized context to an ephemeral Codex process for structured summarization. Never send thread IDs, absolute project paths, tool logs, full code, or obvious secrets, and never log report input or raw model output. The global state is used only to match each visible top-level task's own Codex unread state; never promote a child thread's residual unread state to its parent. Remaining usage is enabled by default and requires the official bundled `codex app-server` plus the user's existing signed-in state.
3. Use `scripts/build_app.sh [output-directory]`. The script compiles the template for the current Mac architecture and creates an ad-hoc-signed `CodexRecentTasksSidebar.app` whose visible name is “Codex 最近任务”.
4. Run the repository-level `scripts/qa.sh` when working from the full repository. If the Skill is installed alone, run the built binary with `--self-test` against a disposable SQLite fixture and `--usage-self-test` against a fake executable supplied through `CODEX_APP_SERVER_OVERRIDE` before using real data.
5. Launch the app and verify the real UI:
   - the custom menu bar icon is present and the app does not occupy the Dock;
   - recent tasks are grouped by canonical working folder and sorted newest first;
   - renamed task notes from `session_index.jsonl` replace stale database titles on the next refresh;
   - status priority is “待操作 → 运行中 → 待查看 → time”: an active task never shows “待查看” early, a stopped unread task does, and opening it clears the label after refresh;
   - remaining usage, available reset windows, account plan, and expandable analytics appear; a usage failure leaves the task list usable;
   - opening the report window or switching its period never starts generation; an explicit Generate or Regenerate action switches between today and the current week, groups results by project, creates one concise sentence per task, and copies/exports Markdown;
   - left and right docking both work;
   - entering a native Codex/ChatGPT full-screen Space hides the sidebar, and leaving full screen restores its previous docked or pinned mode;
   - switching left or right between macOS Spaces hides the sidebar during the transition instead of flashing it onto the adjacent Space;
   - moving the Codex/ChatGPT window across displays hides the sidebar until the destination display and frame settle, then docks once without intermediate cross-screen frames;
   - docked mode follows the Codex foreground/background layer;
   - pinned mode stays above other apps and remains draggable;
   - clicking a task activates Codex and opens its exact `codex://threads/{id}` deep link;
   - switching to Codex does not close or terminate the companion app.
6. Install or replace an app in `/Applications` only when the user has authorized that write.

## Customization

Edit only files under `assets/app-template/` when the user asks for a different app name, bundle identifier, time window, colors, or layout. Keep the default behavior when no customization is requested.

The public template intentionally uses the generic bundle identifier `io.github.codexrecenttasks.sidebar`. Change it before distributing a separately branded fork.

## Safety boundaries

- Treat the Codex SQLite database, rollout files, `session_index.jsonl`, and `.codex-global-state.json` as read-only. Never migrate, vacuum, replace, upload, or write to them.
- Read user and assistant text only after an explicit report action. Minimize and redact it before an ephemeral Codex summary, keep generated results in memory for the visible report, and never include raw task text in diagnostics or QA output.
- Fetch remaining usage only through the official `codex app-server` using the existing login state. Do not read, print, persist, or commit auth files, tokens, raw account responses, or reset timestamps.
- Never commit a real `.sqlite` file, task title, thread ID, username path, API key, token, crash log, or local build cache.
- Keep task selection keyed by the unique thread ID; titles are not unique identifiers.
- Keep archived tasks, threads with a real parent edge, and internal agent records excluded. Do not exclude a root thread solely because `thread_source` is labeled `subagent`.
- Do not claim cross-platform support. The bundled app targets macOS 13+ and is validated on Apple Silicon; compile natively on the target Mac.
- Interpret blue “运行中” from the latest unmatched `task_started`, orange “待操作” from an unfinished explicit user-input or approval request, and green “待查看” only when the task is no longer active and has an unread update. Match unread by task ID directly and never infer it from child-thread state. These labels never mean the conversation is permanently completed or archived.
- If the Codex database schema, unread-state format, app-server rate-limit response, bundle identifier, or deep-link scheme changes, diagnose the current installation before patching the template.

## Delivery report

Report the output app path, macOS architecture, self-test result, UI checks, database read-only evidence, known issues, and unverified items. Do not mark delivery complete when a required real UI check is missing.
