# agw-17-hands-on

[agentgateway v1.7.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.7.0) (GA, 2026-10-27) auto-detects which coding-agent session a request belongs to, from headers like Claude Code's `x-claude-code-session-id`, and exposes it to CEL and access logs as `request.agent.session`. This repo validates the detection rule against a real agentgateway binary and a mock LLM backend: which headers count, which don't, and the exact length/character rule that silently drops a session id that looks fine at a glance.

No Kubernetes, no API key, no network calls. One native binary, one 40-line mock backend, five curl requests.

## What this proves

1. **Any `x-<vendor>-session-id` header is detected, not just Claude Code's.** A request with `x-cursor-session-id` gets `request.agent.session` populated exactly like `x-claude-code-session-id` does. The mechanism is generic across coding agents, not a Claude-specific special case.
2. **A session id under 8 characters is silently ignored.** `short1` (6 characters) on an otherwise-valid `x-claude-code-session-id` header never shows up as `agent.session` in the log. No error, no rejection, the request just has no detected session.
3. **No header means no session field at all**, not an empty string. `agent.session` is absent from the log line entirely rather than `agent.session=""`.

## The config

```yaml
# config/config.yaml
config:
  session:
    key: disabled   # demo only: v1.7 standalone always provisions a session key on first run
frontendPolicies:
  accessLog:
    add:
      agent.session: request.agent.session
llm:
  port: 4000
  models:
  - name: mock
    provider:
      custom:
        formats:
        - type: completions
    params:
      baseUrl: http://127.0.0.1:8091/v1
      model: mock-model
```

`provider: custom` with `formats: [{type: completions}]` points agentgateway at any OpenAI-compatible Chat Completions endpoint, in this case a mock server on localhost, so this demo needs no real provider API key. `request.agent.session` is a new CEL field in v1.7.0; `accessLog.add` is how you get a CEL value into the structured request log, the same mechanism the [v1.6.0 cost-tracking demo](https://webofmike.com/agentgateway-v16-cost-tracking/) used for `llm.cost.total`.

## The mock backend

```python
# mock_llm.py
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        resp = {
            "id": "chatcmpl-mock-1", "object": "chat.completion", "created": 0,
            "model": req.get("model", "mock-model"),
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "mock reply"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7},
        }
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8091), Handler).serve_forever()
```

A fixed OpenAI-shaped response, no model call, no cost. The feature under test lives entirely in agentgateway's request handling, before the backend ever sees the request, so a real LLM backend would show the identical `agent.session` behavior.

## Quickstart

Requirements: macOS (Apple Silicon) or Linux, `curl`, Python 3. No API key.

```bash
git clone https://github.com/themsquared/agw-17-hands-on.git
cd agw-17-hands-on
./run-demo.sh
```

The script downloads the matching `agentgateway` v1.7.0 binary for your platform if one isn't already present, starts the mock backend and the gateway, and fires the five requests below.

## What the run actually showed

```
$ curl -s -X POST http://localhost:4000/v1/chat/completions \
    -H "x-claude-code-session-id: 79291636abc123" -d '{...}'
$ curl -s -X POST http://localhost:4000/v1/chat/completions \
    -H "x-claude-code-session-id: 79291636abc123" -d '{...}'
$ curl -s -X POST http://localhost:4000/v1/chat/completions \
    -H "x-cursor-session-id: cursorsession999" -d '{...}'
$ curl -s -X POST http://localhost:4000/v1/chat/completions -d '{...}'
$ curl -s -X POST http://localhost:4000/v1/chat/completions \
    -H "x-claude-code-session-id: short1" -d '{...}'
```

All five return `HTTP 200`. The access log tells the real story:

```
http.path=/v1/chat/completions agent.session="79291636abc123"
http.path=/v1/chat/completions agent.session="79291636abc123"
http.path=/v1/chat/completions agent.session="cursorsession999"
http.path=/v1/chat/completions
http.path=/v1/chat/completions
```

Requests 1 and 2 share a session, matching the header. Request 3's completely different vendor header still gets picked up. Requests 4 and 5 have no `agent.session` field at all: one sent no header, the other's `short1` is 6 characters, under the minimum of 8.

### The validation rule, from the source

agentgateway's session detection (`crates/agentgateway/src/http/session.rs` in the v1.7.0 tag) requires a header shaped `x-<vendor>-session-id`, with a value that is at least 8 characters and only letters, digits, hyphens, or underscores. Anything shorter, or containing another character, is treated as if the header were absent, not as an error. If you're wondering why a session id isn't showing up in your own logs, check length and character set before anything else: there's no rejection or warning to point you at it.

### Overriding detection

`config.standardAttributes.session` takes a CEL expression that runs before the header-based fallback. Returning `null` from that expression marks the request as having no session even if a valid vendor header is present; this repo doesn't set it, so detection falls through to the header scan described above.

## What this doesn't cover

- **Codex's session headers.** v1.7.0 also recognizes Codex's unprefixed `session-id`/`conversation_id` headers, but only when the `User-Agent` string starts with `codex`. Not exercised here.
- **A real LLM provider.** The mock backend proves the gateway-side behavior; it doesn't exercise agentgateway's real Anthropic, OpenAI, Bedrock, or Gemini integrations.
- **The rest of v1.7.0.** This release also ships `mcpGuardrails` CEL rules for MCP tool calls (see [MCP Tool-Call Guardrails](https://webofmike.com/tool-call-guardrails/), written against a pre-release build), model-catalog metadata over `/v1/models`, service-tier-aware cost pricing, and `agctl standalone analytics` -- separate features, not covered by this repo.

## Related reading

- [agentgateway v1.7.0 release notes](https://github.com/agentgateway/agentgateway/releases/tag/v1.7.0)
- [agentgateway v1.6.0: Cost Tracking With No Catalog Config](https://webofmike.com/agentgateway-v16-cost-tracking/) (the same `accessLog.add` CEL-to-log mechanism)

## License

Apache-2.0
