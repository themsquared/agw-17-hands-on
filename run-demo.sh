#!/usr/bin/env bash
# Runs agentgateway v1.7.0 standalone in front of a two-tool MCP server and
# fires the three requests this repo's README walks through: a safe tool call,
# a restricted tool call rejected by an in-process mcpGuardrails CEL/expression
# rule, and proof (the backend's own log) that the rejected call never reached
# the MCP server.
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

command -v uv >/dev/null 2>&1 || { echo "uv is required (https://docs.astral.sh/uv/)." >&2; exit 1; }

echo "=== config check against the real v1.7.0 schema ==="
"$BIN" -f config/config.yaml --validate-only

echo
echo "=== starting agentgateway on :3000 (MCP) ==="
"$BIN" -f config/config.yaml > gateway.log 2>&1 &
GW_PID=$!
trap 'kill "$GW_PID" 2>/dev/null || true' EXIT
sleep 2

req() {
  curl -sS -X POST http://localhost:3000/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d "$1"
}

echo
echo "=== initialize ==="
curl -sS -D /tmp/agw17-headers.txt -o /dev/null -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-06-18","capabilities":{},"clientInfo":{"name":"run-demo","version":"0.1"}}}'
SESSION="$(grep -i '^mcp-session-id' /tmp/agw17-headers.txt | awk '{print $2}' | tr -d '\r')"
echo "session: ${SESSION}"

echo
echo "=== tools/call list_files (safe tool, expect isError:false) ==="
req '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_files","arguments":{"path":"/tmp"}}}'
echo

echo
echo "=== tools/call delete_database (restricted tool, expect the guardrail's reject text) ==="
req '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_database","arguments":{"name":"prod"}}}'
echo

echo
echo "=== toy-ops-server's own log: list_files ran, delete_database never did ==="
grep "toy-ops-server" gateway.log || echo "(no lines yet, the MCP subprocess may still be starting -- rerun this grep)"

echo
echo "Gateway still running as PID ${GW_PID}. Ctrl-C to stop, or: kill ${GW_PID}"
wait "$GW_PID"
