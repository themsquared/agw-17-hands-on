# agw-17-hands-on

[agentgateway v1.7.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.7.0) (GA, 2026-10-27) adds an in-process CEL guardrail processor for MCP traffic: `mcpGuardrails.processors` can now reject or rewrite a `tools/call` request or response with a CEL expression, no external service required. This repo validates it against a real agentgateway binary and a toy two-tool MCP server: one safe tool, one destructive tool the gateway blocks before it ever reaches the backend.

No Kubernetes, no Docker required (though the Docker image also works). One native binary, one config file, one Python MCP server run through `uv`.

## What this proves

1. **A CEL rule can block a specific MCP tool call, in-process.** `mcpGuardrails.processors` with `condition: mcp.params.name == 'delete_database'` and a `reject` string stops the call at the gateway. The response comes back as `isError: true` with the configured message.
2. **The blocked call never reaches the backend.** The toy MCP server's own stderr log proves it: `list_files` logs a line when called, `delete_database` never does, because the gateway rejects it before forwarding.
3. **A gotcha worth knowing.** The v1.7.0 release notes' own example config uses `kind: cel`. The actual schema accepts `kind: expression` only. `kind: cel` fails `--validate-only` with `unknown variant 'cel', expected 'remote' or 'expression'`. This repo's config uses the working value.

## The config

```yaml
# config/config.yaml
config:
  session:
    key: disabled   # demo only: v1.7 standalone MCP sessions are encrypted by default
mcp:
  port: 3000
  policies:
    mcpGuardrails:
      processors:
      - kind: expression   # NOT "cel" -- see the gotcha above
        methods: {"tools/call": request}
        condition: mcp.params.name == 'delete_database'
        reject: "delete_database is blocked by gateway policy"
  targets:
  - name: toyops
    stdio:
      cmd: uv
      args: ["run", "--with", "mcp[cli]", "python3", "toy_mcp_server.py"]
```

`config.session.key: disabled` is set only so the demo doesn't write a generated key file to disk on every run. A real deployment should leave session encryption on, per the v1.7.0 breaking-change notes.

## The toy MCP server

```python
# toy_mcp_server.py
from mcp.server.mcpserver import MCPServer

mcp = MCPServer("toy-ops-server")

@mcp.tool()
def list_files(path: str = ".") -> str:
    """List files in a directory (read-only, safe)."""
    return f"README.md\nconfig.yaml\nmain.py  (in {path})"

@mcp.tool()
def delete_database(name: str) -> str:
    """Permanently delete a named database. Destructive."""
    return f"DELETED database '{name}'"

if __name__ == "__main__":
    mcp.run(transport="stdio")
```

Note: the MCP Python SDK renamed `FastMCP` to `MCPServer` in its 2.x release (`from mcp.server.mcpserver import MCPServer`), which is what `uv run --with mcp[cli]` resolves to today. The 1.x `fastmcp` import path raises `ModuleNotFoundError` with a migration pointer.

## Quickstart

Requirements: macOS (Apple Silicon) or Linux, `curl`, and [`uv`](https://docs.astral.sh/uv/) (runs the MCP server with no separate `pip install`). No API key needed; nothing in this demo calls an LLM.

```bash
git clone https://github.com/themsquared/agw-17-hands-on.git
cd agw-17-hands-on
./run-demo.sh
```

The script downloads the matching `agentgateway` v1.7.0 binary for your platform if one isn't already present, validates the config, starts the gateway, and fires the three requests below.

Check the config against the v1.7.0 schema without starting anything:

```bash
./agentgateway-bin -f config/config.yaml --validate-only
```

## What the run actually showed

```
$ curl -s -X POST http://localhost:3000/mcp -d '{"method":"initialize",...}'
mcp-session-id: e93bb9ce-ca55-412e-8f32-bc846fa50028

$ curl -s -X POST http://localhost:3000/mcp -H "Mcp-Session-Id: $SESSION" \
    -d '{"method":"tools/call","params":{"name":"list_files","arguments":{"path":"/tmp"}}}'
{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"README.md\nconfig.yaml\nmain.py  (in /tmp)"}],"isError":false}}

$ curl -s -X POST http://localhost:3000/mcp -H "Mcp-Session-Id: $SESSION" \
    -d '{"method":"tools/call","params":{"name":"delete_database","arguments":{"name":"prod"}}}'
{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"delete_database is blocked by gateway policy"}],"isError":true}}
```

And the toy server's own stderr, after both calls:

```
[toy-ops-server] list_files called with path=/tmp
```

One line. `delete_database` never printed its `DELETE_DATABASE EXECUTED` line, because it never ran.

### The `kind: cel` gotcha

```
$ ./agentgateway-bin -f config-with-kind-cel.yaml --validate-only
Error: mcp.policies.mcpGuardrails.processors[0]: unknown variant `cel`, expected `remote` or `expression` at line 10 column 9
```

The release notes' own snippet for this feature uses `kind: cel`. The schema in the shipped v1.7.0 binary only accepts `expression` (in-process CEL) or `remote` (an external service). Use `kind: expression`.

## What this doesn't cover

- **Response-side masking.** `mcpGuardrails.processors` also runs on `tools/call` responses (`methods: {"tools/call": response}`) to rewrite returned content, e.g. redacting secrets in tool output. This repo only demonstrates the request-rejection path; agentgateway's own [`examples/mcp-guardrails/expression`](https://github.com/agentgateway/agentgateway/tree/main/examples/mcp-guardrails/expression) shows masking with `regexReplaceAll`.
- **Kubernetes.** This is the standalone binary. v1.7.0 also ships a `remote` guardrail kind for calling an external policy service, and Kubernetes-native MCP conditional targets, neither exercised here.
- **The rest of v1.7.0.** This release also ships model-catalog metadata over `/v1/models`, service-tier-aware cost pricing, and `agctl standalone analytics` -- separate features, not covered by this repo.

## Related reading

- [agentgateway v1.7.0 release notes](https://github.com/agentgateway/agentgateway/releases/tag/v1.7.0)
- [agentgateway MCP guardrails docs](https://agentgateway.dev/docs/)

## License

Apache-2.0
