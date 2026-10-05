#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-copilot-relay.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
SOCKET="$TEST_DIR/coucou.sock"
LOG="$TEST_DIR/received.log"

# Extract the embedded GitHub relay from HookServer.swift
RELAY_SOCKET="$SOCKET" python3 - "$TEST_DIR" <<'PYEOF'
import os, re, sys
src = open('NotchBuddy/Sources/App/HookServer.swift').read()
m = re.search(r'private let nbHookPythonGitHub = """\n(.*?)\n"""\n', src, re.S)
assert m, "nbHookPythonGitHub not found"
py = m.group(1).replace('\\\\', '\\')
# Point the relay at a socket we control
py = py.replace("'~/Library/Application Support/NotchBuddy/nb.sock'",
                "'" + os.environ['RELAY_SOCKET'] + "'")
open(os.path.join(sys.argv[1], 'nb-hook.py'), 'w').write(py)
PYEOF

FAKE_PID=""

cleanup() {
    if [ -n "$FAKE_PID" ]; then kill "$FAKE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Fake Coucou app: log every event, allow every PermissionRequest
cat > "$TEST_DIR/fake_app.py" <<'PYEOF'
import socket, os, sys, threading
path, log = sys.argv[1], sys.argv[2]
if os.path.exists(path): os.unlink(path)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(8)
def handle(c):
    buf = b''
    while b'\n' not in buf:
        d = c.recv(65536)
        if not d: return
        buf += d
    line = buf.split(b'\n')[0].decode()
    with open(log, 'a') as f: f.write(line + '\n')
    try:
        import json
        if json.loads(line).get('hook_event_name') == 'PermissionRequest':
            c.sendall(b'{"permissionDecision":"allow"}\n')
    except Exception: pass
    c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PYEOF
python3 "$TEST_DIR/fake_app.py" "$SOCKET" "$LOG" &
FAKE_PID=$!

# Wait for the fake app socket
for _ in $(seq 1 50); do [ -S "$SOCKET" ] && break; sleep 0.1; done

relay() { # relay <event> <payload-json> [expected-stdout]
    local event="$1" payload="$2" want="${3:-}"
    local out rc
    out=$(printf '%s' "$payload" | python3 "$TEST_DIR/nb-hook.py" --agent copilot "$event" 2>/dev/null) && rc=0 || rc=$?
    if [ "$want" = "" ]; then
        [ -z "$out" ] && [ "$rc" -eq 0 ] && echo "  ✓ $event: silent, exit 0" && return 0
        echo "  ✗ $event: expected silence, got '$out' (rc=$rc)"; return 1
    fi
    [ "$out" = "$want" ] && echo "  ✓ $event: $want" && return 0
    echo "  ✗ $event: expected '$want', got '$out' (rc=$rc)"; return 1
}

echo "Copilot relay — event forwarding"
relay SessionStart '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp","source":"new"}'
relay PreToolUse '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"ls"}}'
relay Stop '{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp","stop_reason":"end_turn"}'

sleep 0.3
events=$(python3 -c "
import json
names = [json.loads(l).get('hook_event_name') for l in open('$LOG')]
print(','.join(names))
")
[ "$events" = "SessionStart,PreToolUse,Stop" ] \
    && echo "  ✓ app received SessionStart,PreToolUse,Stop" \
    || { echo "  ✗ app received: $events"; exit 1; }

tags=$(python3 -c "
import json
ok = all(json.loads(l).get('coucou_agent') == 'copilot' for l in open('$LOG'))
print('ok' if ok else 'bad')
")
[ "$tags" = "ok" ] && echo "  ✓ every payload tagged coucou_agent=copilot" \
    || { echo "  ✗ missing coucou_agent tag"; exit 1; }

echo "Copilot relay — camelCase alias normalization"
> "$LOG"
printf '%s' '{"hook_event_name":"agentStop","session_id":"s1","cwd":"/tmp"}' \
    | python3 "$TEST_DIR/nb-hook.py" --agent copilot Stop
printf '%s' '{"hook_event_name":"errorOccurred","session_id":"s1","cwd":"/tmp"}' \
    | python3 "$TEST_DIR/nb-hook.py" --agent copilot ErrorOccurred
printf '%s' '{"hook_event_name":"userPromptSubmitted","session_id":"s1","cwd":"/tmp","prompt":"hi"}' \
    | python3 "$TEST_DIR/nb-hook.py" --agent copilot UserPromptSubmit
sleep 0.3
aliases=$(python3 -c "
import json
names = sorted(json.loads(l).get('hook_event_name') for l in open('$LOG'))
print(','.join(names))
")
[ "$aliases" = "Stop,StopFailure,UserPromptSubmit" ] \
    && echo "  ✓ agentStop→Stop, errorOccurred→StopFailure, userPromptSubmitted→UserPromptSubmit" \
    || { echo "  ✗ aliases produced: $aliases"; exit 1; }

echo "Copilot relay — permission decision translation"
relay PermissionRequest '{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"x"}}' \
    '{"behavior": "allow"}'

echo "Copilot relay — never blocks when the app is gone"
rm -f "$SOCKET"   # app disappears
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
relay SessionStart '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp"}'

echo "All Copilot relay tests passed."