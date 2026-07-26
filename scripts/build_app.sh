#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
exec "$ROOT/skills/codex-recent-tasks-sidebar/scripts/build_app.sh" "$ROOT/build"
