#!/usr/bin/env bash
# Runs agentgateway v1.7.0 standalone in front of a mock OpenAI-compatible
# backend (no API key, no network) and fires five requests this repo's
# README walks through, to prove v1.7's new agent-session detection:
# two requests sharing a vendor session header, one from a different
# vendor header, one with no session header, and one with a too-short
# session id that fails validation.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="v1.7.0"
OS="$(uname -s)"
ARCH="$(uname -m)"
BIN="./agentgateway-bin"

if [ ! -x "$BIN" ]; then
  case "${OS}-${ARCH}" in
    Darwin-arm64)  ASSET="agentgateway-darwin-arm64" ;;
    Linux-x86_64)  ASSET="agentgateway-linux-amd64" ;;
    Linux-aarch64) ASSET="agentgateway-linux-arm64" ;;
    *)
      echo "No prebuilt agentgateway binary for ${OS}-${ARCH}." >&2
      echo "Download one from https://github.com/agentgateway/agentgateway/releases/tag/${VERSION} or use the Docker image cr.agentgateway.dev/agentgateway:${VERSION}." >&2
      exit 1
      ;;
  esac
  echo "Downloading agentgateway ${VERSION} (${ASSET})..."
  curl -sSL -o "$BIN" "https://github.com/agentgateway/agentgateway/releases/download/${VERSION}/${ASSET}"
  chmod +x "$BIN"
fi

python3 mock_llm.py &
MOCK_PID=$!
trap 'kill "$MOCK_PID" "${GW_PID:-}" 2>/dev/null || true' EXIT
sleep 1

echo "=== config check against the real v1.7.0 schema ==="
"$BIN" -f config/config.yaml --validate-only

echo
echo "=== starting agentgateway on :4000 (LLM), backend is the mock on :8091 ==="
"$BIN" -f config/config.yaml > gateway.log 2>&1 &
GW_PID=$!
sleep 2

req() {
  # $1 = session header name (or "" for none), $2 = session id, $3 = message text
  local -a hdrs=(-H "Content-Type: application/json")
  if [ -n "$1" ]; then
    hdrs+=(-H "$1: $2")
  fi
  curl -sS -X POST http://localhost:4000/v1/chat/completions \
    "${hdrs[@]}" \
    -d "{\"model\":\"mock\",\"messages\":[{\"role\":\"user\",\"content\":\"$3\"}]}" \
    -o /dev/null -w "HTTP %{http_code}\n"
}

echo
echo "=== request 1: x-claude-code-session-id ==="
req "x-claude-code-session-id" "79291636abc123" "hi"

echo "=== request 2: same session id again ==="
req "x-claude-code-session-id" "79291636abc123" "hi again"

echo "=== request 3: a different vendor header entirely (x-cursor-session-id) ==="
req "x-cursor-session-id" "cursorsession999" "other agent"

echo "=== request 4: no session header at all ==="
req "" "" "no session"

echo "=== request 5: a session id under 8 characters (fails validation) ==="
req "x-claude-code-session-id" "short1" "short id"

sleep 1
echo
echo "=== access log lines (agent.session is present on requests 1-3, absent on 4 and 5) ==="
grep "route=internal" gateway.log | awk '{for(i=1;i<=NF;i++) if ($i ~ /^(http.path|agent.session)=/) printf "%s ", $i; print ""}'

echo
echo "Tear down already handled by the EXIT trap. Logs are in gateway.log."
