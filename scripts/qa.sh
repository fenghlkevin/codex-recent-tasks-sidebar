#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/CodexRecentTasksSidebar.app"
BINARY="$APP_DIR/Contents/MacOS/Codex最近任务栏"
FIXTURE_DIR="$BUILD_DIR/qa-fixture"
FIXTURE_DB="$FIXTURE_DIR/state.sqlite"
FIXTURE_INDEX="$FIXTURE_DIR/session_index.jsonl"
FIXTURE_GLOBAL_STATE="$FIXTURE_DIR/codex-global-state.json"
FIXTURE_RUNNING_ROLLOUT="$FIXTURE_DIR/running-rollout.jsonl"
FIXTURE_ACTION_ROLLOUT="$FIXTURE_DIR/action-rollout.jsonl"
FIXTURE_USAGE_SERVER="$FIXTURE_DIR/fake-codex"

"$ROOT/scripts/build_app.sh"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/file "$BINARY" "$APP_DIR/Contents/Resources/AppIcon.icns"

rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
/usr/bin/sqlite3 "$FIXTURE_DB" <<'SQL'
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  title TEXT,
  cwd TEXT,
  git_branch TEXT,
  updated_at_ms INTEGER,
  updated_at INTEGER,
  archived INTEGER DEFAULT 0,
  thread_source TEXT,
  source TEXT,
  agent_path TEXT,
  rollout_path TEXT
);
CREATE TABLE thread_spawn_edges (
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
INSERT INTO threads VALUES
  ('00000000-0000-0000-0000-000000000001', 'Original example task', '/tmp/example-project-a', 'main', 4102444800000, 4102444800, 0, '', '', '', ''),
  ('00000000-0000-0000-0000-000000000002', 'Second example task', '/tmp/example-project-b', '', 4102444700000, 4102444700, 0, '', '', '', ''),
  ('00000000-0000-0000-0000-000000000003', 'Excluded internal agent task', '/tmp/example-project-a', '', 4102444600000, 4102444600, 0, 'subagent', '{"subagent":true}', '/tmp/agent', ''),
  ('00000000-0000-0000-0000-000000000004', 'Recovered root task', '/tmp/example-project-a', '', 4102444500000, 4102444500, 0, 'subagent', '', '', ''),
  ('00000000-0000-0000-0000-000000000005', 'Excluded child task', '/tmp/example-project-a', '', 4102444400000, 4102444400, 0, 'subagent', '', '', '');
INSERT INTO thread_spawn_edges VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', 'running');
SQL

cat > "$FIXTURE_INDEX" <<'JSONL'
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Earlier example name","updated_at":"2099-12-31T23:59:00Z"}
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Renamed example task","updated_at":"2100-01-01T00:00:00Z"}
{"id":"00000000-0000-0000-0000-000000000002","thread_name":"   ","updated_at":"2100-01-01T00:00:00Z"}
{"id":"partial"
JSONL

cat > "$FIXTURE_GLOBAL_STATE" <<'JSON'
{
  "electron-persisted-atom-state": {
    "unread-thread-ids-by-host-v1": {
      "local": [
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000005",
        "invalid"
      ]
    }
  }
}
JSON

cat > "$FIXTURE_RUNNING_ROLLOUT" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message"}}
JSONL

cat > "$FIXTURE_ACTION_ROLLOUT" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
JSONL

/usr/bin/sqlite3 "$FIXTURE_DB" \
  ".parameter init" \
  ".parameter set @running \"$FIXTURE_RUNNING_ROLLOUT\"" \
  ".parameter set @action \"$FIXTURE_ACTION_ROLLOUT\"" \
  "UPDATE threads SET rollout_path=@running WHERE id='00000000-0000-0000-0000-000000000002';" \
  "UPDATE threads SET rollout_path=@action WHERE id='00000000-0000-0000-0000-000000000001';"

cat > "$FIXTURE_USAGE_SERVER" <<'ZSH'
#!/bin/zsh
request_count=0
while IFS= read -r line; do
  (( request_count += 1 ))
  if (( request_count == 1 )); then
    print '{"id":1,"result":{"serverInfo":{"name":"fake-codex","version":"1"}}}'
  elif (( request_count >= 2 )); then
    print '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":35,"windowDurationMins":300},"secondary":{"usedPercent":90,"windowDurationMins":10080}}}}'
  fi
done
ZSH
chmod +x "$FIXTURE_USAGE_SERVER"

before_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
before_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"
before_global_state_hash="$(/usr/bin/shasum "$FIXTURE_GLOBAL_STATE")"
before_running_rollout_hash="$(/usr/bin/shasum "$FIXTURE_RUNNING_ROLLOUT")"
before_action_rollout_hash="$(/usr/bin/shasum "$FIXTURE_ACTION_ROLLOUT")"
self_test_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_GLOBAL_STATE" \
  CODEX_ROLLOUT_ROOT_OVERRIDE="$FIXTURE_DIR" \
  CODEX_SELF_TEST_EXPECT_TITLE="Renamed example task" \
  CODEX_SELF_TEST_EXPECT_UNREAD_ID="00000000-0000-0000-0000-000000000002" \
  CODEX_SELF_TEST_EXPECT_READ_ID="00000000-0000-0000-0000-000000000001" \
  CODEX_SELF_TEST_EXPECT_RUNNING_ID="00000000-0000-0000-0000-000000000002" \
  CODEX_SELF_TEST_EXPECT_ACTION_ID="00000000-0000-0000-0000-000000000001" \
  "$BINARY" --self-test
)"
after_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
after_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"
after_global_state_hash="$(/usr/bin/shasum "$FIXTURE_GLOBAL_STATE")"
after_running_rollout_hash="$(/usr/bin/shasum "$FIXTURE_RUNNING_ROLLOUT")"
after_action_rollout_hash="$(/usr/bin/shasum "$FIXTURE_ACTION_ROLLOUT")"

[[ "$self_test_output" == *"SELF_TEST_OK count=3 title_override=ok unread_override=ok read_override=ok runtime_override=ok action_override=ok usage=ok unread_state=ok runtime_state=ok display_state=ok unread_update_count=1"* ]] || {
  print -u2 "固定测试库自检失败：$self_test_output"
  exit 3
}

usage_test_output="$(
  CODEX_APP_SERVER_OVERRIDE="$FIXTURE_USAGE_SERVER" \
  "$BINARY" --usage-self-test
)"
[[ "$usage_test_output" == "USAGE_SELF_TEST_OK windows=2" ]] || {
  print -u2 "Codex 用量协议自检失败：$usage_test_output"
  exit 9
}

set +e
missing_usage_output="$({
  CODEX_APP_SERVER_OVERRIDE="$FIXTURE_DIR/missing-codex" \
  "$BINARY" --usage-self-test
} 2>&1)"
missing_usage_status=$?
set -e
[[ $missing_usage_status -eq 12 && "$missing_usage_output" == *"USAGE_SELF_TEST_FAILED"* ]] || {
  print -u2 "Codex 用量程序缺失边界测试失败"
  exit 10
}
[[ "$before_hash" == "$after_hash" ]] || {
  print -u2 "自检修改了固定测试库"
  exit 4
}
[[ "$before_index_hash" == "$after_index_hash" ]] || {
  print -u2 "自检修改了固定任务备注索引"
  exit 7
}
[[ "$before_global_state_hash" == "$after_global_state_hash" ]] || {
  print -u2 "自检修改了固定未读状态文件"
  exit 11
}
[[ "$before_running_rollout_hash" == "$after_running_rollout_hash" ]] || {
  print -u2 "自检修改了固定运行中事件文件"
  exit 12
}
[[ "$before_action_rollout_hash" == "$after_action_rollout_hash" ]] || {
  print -u2 "自检修改了固定待操作事件文件"
  exit 13
}

fallback_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_DIR/missing-session-index.jsonl" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_DIR/missing-global-state.json" \
  "$BINARY" --self-test
)"
[[ "$fallback_output" == *"SELF_TEST_OK count=3"* ]] || {
  print -u2 "缺失任务备注索引或未读状态回退测试失败：$fallback_output"
  exit 8
}

set +e
missing_output="$(CODEX_TASK_DB_OVERRIDE="$FIXTURE_DIR/missing.sqlite" "$BINARY" --self-test 2>&1)"
missing_status=$?
set -e
[[ $missing_status -eq 1 && "$missing_output" == *"SELF_TEST_FAILED"* ]] || {
  print -u2 "缺失数据库边界测试失败"
  exit 5
}

personal_path="/Users/"'chuanfan'
personal_bundle='com\.''chuanfan'
if /usr/bin/grep -R -n -E \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude='*.icns' \
  "(${personal_path}|${personal_bundle}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA |OPENSSH )?PRIVATE KEY)" \
  "$ROOT"; then
  print -u2 "脱敏扫描失败"
  exit 6
fi

print "$self_test_output"
print "$usage_test_output"
print "QA_OK app=$APP_DIR"
