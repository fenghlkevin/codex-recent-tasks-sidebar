#!/bin/zsh
set -eu

sidebar_app="/Applications/CodexRecentTasksSidebar.app"
sidebar_bundle="io.github.codexrecenttasks.sidebar"

chatgpt_running=0
/usr/bin/pgrep -x "ChatGPT" >/dev/null 2>&1 && chatgpt_running=1
/usr/bin/pgrep -f "^/Applications/ChatGPT.app/Contents/MacOS/ChatGPT$" >/dev/null 2>&1 && chatgpt_running=1

if [[ "$chatgpt_running" -ne 1 ]]; then
  exit 0
fi

if /usr/bin/pgrep -f "$sidebar_bundle" >/dev/null 2>&1 ||
   /usr/bin/pgrep -f "CodexRecentTasksSidebar.app" >/dev/null 2>&1 ||
   /usr/bin/pgrep -x "Codex最近任务栏" >/dev/null 2>&1; then
  exit 0
fi

if [[ -d "$sidebar_app" ]]; then
  /usr/bin/open -a "$sidebar_app"
fi
