# Universal REST — HTTP/REST Client for Lua

A compact, single-file Lua HTTP/REST client built for **any** Lua project. Drop in one file, point it at a settings JSON, and start making requests — no complex setup, no framework lock-in.

**Version 1.0.0** — [Quick Start Guide](./QUICKSTART.md) · [Settings File](./universal_rest_settings.json)

### Highlights

- **Environment-adaptive** — auto-detects LuaSocket or lua-resty-http (OpenResty) at runtime
- **Multi-server failover** — configure N servers, the library cycles through them on failure
- **Retries with exponential backoff** — jitter prevents thundering-herd retries
- **TTL caching (LRU)** — cache GET responses in memory with automatic eviction
- **Token-bucket rate limiting** — per-host rate limits to avoid overwhelming APIs
- **Middleware / Interceptors** — hook into every request and response for logging, auth injection, transforms
- **Configurable log levels** — `debug`, `info`, `warn`, `error`, `none`
- **Settings file loading** — configure everything from a single JSON file, no Lua required
- **WebSocket support** — connect, send, receive with automatic reader coroutine
- **UDP hole-punching** — helpers for P2P connectivity
- **Signaling & TURN** — built-in helpers for WebRTC-style workflows

---

## Quick Start

> For a full step-by-step walkthrough, see [QUICKSTART.md](./QUICKSTART.md).

```bash
# 1. Install dependencies
luarocks install luasocket
luarocks install dkjson          # optional but recommended

# 2. Copy the library into your project
cp universal_rest.lua /path/to/your/project/
cp universal_rest_settings.json /path/to/your/project/   # optional
```

```lua
-- 3. Require and configure
local rest = require("universal_rest")

-- Option A: Load everything from JSON (recommended)
rest.load_settings("universal_rest_settings.json")

-- Option B: Configure in Lua
rest.init{
  timeout = 8000,
  retries = 3,
  log_level = "debug",
  rate_limits = {
    ["api.example.com"] = { capacity = 5, refill_per_sec = 1 }
  },
}

-- 4. Make a request
local status, body, headers, err = rest.get("https://httpbin.org/get")
if status then
  print("Status:", status)
  print("Body:", body)
else
  print("Error:", err)
end
```

---

## Settings File

All configuration lives in **`universal_rest_settings.json`**. Every key has a matching `_doc_*` field right above it explaining what it does, what values are valid, and what the default means. Open the file and read through it — there's no need to dig into Lua source to understand what's configurable.

Load it at startup:

```lua
local rest = require("universal_rest")
local ok, err = rest.load_settings("universal_rest_settings.json")
if not ok then print("Settings error:", err) end
```

You can also pass a custom path if your settings file lives elsewhere:

```lua
rest.load_settings("/etc/myapp/rest_config.json")
```

**Overriding individual settings** — `load_settings` calls `rest.init()` internally, so you can load the file first and then override specific values:

```lua
rest.load_settings("universal_rest_settings.json")
rest.init{ timeout = 15000 }  -- override just the timeout
```

### Settings Reference

| Key | Type | Default | What It Controls |
|-----|------|---------|-----------------|
| `timeout` | number | `5000` | Request timeout in milliseconds |
| `retries` | number | `2` | Retry attempts per request |
| `backoff_base` | number | `200` | Base backoff delay (ms) |
| `backoff_factor` | number | `2` | Exponential backoff multiplier |
| `jitter` | boolean | `true` | Add randomness to backoff delays |
| `user_agent` | string | `"universal_rest/1.0.0"` | User-Agent header value |
| `log_level` | string | `"info"` | Log verbosity: debug/info/warn/error/none |
| `cache_enabled` | boolean | `true` | Enable in-memory response caching |
| `cache_max_items` | number | `1000` | Max cached responses (LRU eviction) |
| `prefer_localhost` | boolean | `true` | Try localhost servers first in failover |
| `retry_on_status` | array | `[500,502,503,504,429]` | HTTP status codes that trigger retries |
| `servers` | array | `[]` | Base URLs for multi-server failover |
| `rate_limits` | object | `{}` | Per-host token-bucket rate limits |
| `websocket.enabled` | boolean | `true` | Enable WebSocket support |

---

## API Reference

### `rest.init(opts)`

Initialize or update configuration. Merges the provided table into the current config — you can call it multiple times and each call layers on top.

```lua
rest.init{
  timeout = 5000,
  retries = 2,
  backoff_base = 200,
  backoff_factor = 2,
  jitter = true,
  user_agent = "universal_rest/1.0.0",
  log_level = "info",

  -- Custom JSON codec (auto-detected if not provided)
  json = {
    encode = function(t) return cjson.encode(t) end,
    decode = function(s) return cjson.decode(s) end,
  },

  -- Custom logger function (receives level + message parts)
  logger = function(...) print(...) end,

  -- Rate limits keyed by hostname
  rate_limits = {
    ["api.example.com"] = { capacity = 10, refill_per_sec = 2 }
  },

  -- Response caching
  cache_enabled = true,
  cache_max_items = 1000,

  -- Multi-server failover
  servers = {
    "https://api1.example.com",
    "https://api2.example.com",
    "http://localhost:8000",
  },
  prefer_localhost = true,

  -- Which HTTP status codes should trigger a retry
  retry_on_status = {500, 502, 503, 504, 429},

  -- WebSocket toggle
  websocket = { enabled = true },
}
```

### `rest.load_settings(path)`

Load configuration from a JSON file. Returns `true` on success, or `false, error_message` on failure.

```lua
local ok, err = rest.load_settings("universal_rest_settings.json")
```

---

### HTTP Methods

Every method returns four values: `status, body, headers, err`. On network failure, `status` is `nil` and `err` contains the error message.

```lua
local status, body, headers, err = rest.get(url, opts)
local status, body, headers, err = rest.post(url, opts)
local status, body, headers, err = rest.put(url, opts)
local status, body, headers, err = rest.patch(url, opts)
local status, body, headers, err = rest.delete(url, opts)
local status, body, headers, err = rest.head(url, opts)

-- Any HTTP method
local status, body, headers, err = rest.request("OPTIONS", url, opts)
```

**Request Options:**

```lua
{
  headers     = { ["X-Custom"] = "value" },   -- extra headers
  body        = "raw string or table",         -- request body
  json        = true,                          -- auto-encode body as JSON + set Content-Type
  cache_ttl   = 300,                           -- cache GET response for N seconds
  retries     = 3,                             -- override default retry count
  timeout_ms  = 10000,                         -- override default timeout
  bearer      = "token",                       -- sets Authorization: Bearer <token>
  basic       = { user = "u", pass = "p" },    -- sets Authorization: Basic <base64>
  rate_cost   = 1,                             -- tokens consumed from rate limiter
}
```

---

### JSON Methods

These methods auto-set `Accept: application/json` and decode the response body. They return `status, decoded_table, err`.

```lua
-- GET and auto-decode JSON
local status, data, err = rest.get_json(url, opts)

-- POST with auto-encode + decode
local status, data, err = rest.post_json(url, { key = "value" }, opts)

-- PUT with auto-encode + decode
local status, data, err = rest.put_json(url, { key = "value" }, opts)

-- PATCH with auto-encode + decode
local status, data, err = rest.patch_json(url, { key = "value" }, opts)

-- DELETE with auto-decode
local status, data, err = rest.delete_json(url, opts)
```

---

### Batch Requests

Run multiple requests sequentially. Each request gets the full failover/retry treatment.

```lua
local results = rest.batch({
  { method = "GET", url = "https://api.example.com/users" },
  { method = "POST", url = "https://api.example.com/items",
    opts = { json = true, body = { name = "item" } }
  },
})

for i, result in ipairs(results) do
  print(i, result.status, result.err)
  if result.body then
    print("  Body:", result.body)
  end
end
```

---

### Middleware / Interceptors

Interceptors let you hook into every request or response without modifying your application code. Common uses: injecting auth headers, logging, response transformation.

**Request interceptor** — receives `(method, url, headers, body)`, returns modified versions:

```lua
-- Add a custom header to every request
rest.add_interceptor("request", function(method, url, headers, body)
  headers["X-Request-ID"] = tostring(math.random(100000, 999999))
  return method, url, headers, body
end)
```

**Response interceptor** — receives `(status, body, headers)`, returns modified versions:

```lua
-- Log every response status
rest.add_interceptor("response", function(status, body, headers)
  print("Response:", status)
  return status, body, headers
end)
```

**Remove interceptors:**

```lua
rest.clear_interceptors("request")   -- clear request interceptors only
rest.clear_interceptors("response")  -- clear response interceptors only
rest.clear_interceptors()            -- clear all
```

---

### Cache Management

The built-in cache stores GET responses in memory using LRU eviction. You enable caching per-request by passing `cache_ttl`:

```lua
-- Cache for 5 minutes
local status, data = rest.get_json(url, { cache_ttl = 300 })
```

**Inspect and manage the cache:**

```lua
-- Get cache statistics
local stats = rest.cache_stats()
print("Cached items:", stats.size)
print("Hits:", stats.hits, "Misses:", stats.misses)

-- Clear the entire cache
rest.cache_clear()
```

---

### WebSocket

Connect to a WebSocket endpoint with event handlers. The library spawns a reader coroutine automatically.

```lua
local ws, err = rest.ws_connect("ws://echo.websocket.org", {
  on_message = function(msg)
    print("Received:", msg)
  end,
  on_close = function()
    print("Connection closed")
  end,
  on_error = function(err)
    print("Error:", err)
  end,
})

if not ws then
  print("Connect failed:", err)
  return
end

ws.send("Hello, WebSocket!")
ws.close()
```

---

### Network Helpers

**UDP hole-punch** — sends repeated empty packets to a peer to establish a NAT traversal path:

```lua
local ok, err = rest.udp_holepunch(
  12345,               -- local port
  "203.0.113.45",      -- peer IP
  54321,               -- peer port
  5,                   -- attempts (default: 5)
  0.2                  -- interval in seconds (default: 0.2)
)
```

**Signaling** — POST offers/answers and poll for them (for WebRTC-style workflows):

```lua
rest.signal_offer("signal/offer", { from = "alice", to = "bob", sdp = offer_sdp })
rest.signal_answer("signal/answer", { from = "bob", to = "alice", sdp = answer_sdp })
local status, data = rest.signal_poll("signal/poll", { peer = "alice" })
```

**TURN allocator:**

```lua
local status, turn_data = rest.request_turn("turn", {})
```

---

### URL Utilities

Build URLs with properly encoded query parameters (spaces, special characters, unicode all handled):

```lua
local url = rest.build_url("https://api.example.com/search", {
  q = "lua http client",
  limit = 10,
  tags = "networking,http"
})
-- Result: https://api.example.com/search?q=lua%20http%20client&limit=10&tags=networking%2Chttp
```

---

## Configuration Examples

### Using cJSON (Best Performance)

```lua
local cjson = require("cjson")
rest.init{
  json = {
    encode = cjson.encode,
    decode = cjson.decode
  }
}
```

### Rate Limiting

Token-bucket rate limiting prevents your application from overwhelming external APIs. Configure per hostname:

```lua
rest.init{
  rate_limits = {
    ["api.example.com"] = {
      capacity = 100,         -- max burst of 100 requests
      refill_per_sec = 10     -- then 10 requests/second sustained
    },
    ["other-api.com"] = {
      capacity = 50,
      refill_per_sec = 1      -- 1 request per second
    }
  }
}
```

When rate-limited, the library backs off and retries automatically. You can also specify per-request cost:

```lua
rest.get("/expensive-endpoint", { rate_cost = 5 })  -- costs 5 tokens
```

### Multi-Server Failover

Configure multiple server URLs and the library automatically fails over between them:

```lua
rest.init{
  servers = {
    "https://api.example.com",         -- primary
    "https://api-backup.example.com",  -- secondary
    "http://localhost:3000",           -- local fallback
  },
  prefer_localhost = true              -- try localhost first
}

-- Requests automatically failover across all servers
local status, body = rest.get("/data")
```

### Custom Logging

Replace the default logger with your own function. The first argument is always the log level:

```lua
rest.init{
  log_level = "debug",
  logger = function(level, ...)
    local args = {...}
    local msg = table.concat(args, " ")
    io.stderr:write(
      os.date("%Y-%m-%d %H:%M:%S"),
      " [", level, "] ",
      msg, "\n"
    )
  end
}
```

---

## Common Patterns

### Retrying Failed Requests

The library retries automatically based on `retries` and `retry_on_status`. You can override per-request:

```lua
-- This request will retry up to 5 times on 500/502/503/504/429
local status, body = rest.get("https://api.example.com/data", {
  retries = 5,
  timeout_ms = 10000,
})

if not status then
  print("All retries exhausted:", err)
end
```

### JSON API Workflow

```lua
local rest = require("universal_rest")
rest.load_settings("universal_rest_settings.json")

-- List users
local status, users, err = rest.get_json("https://api.example.com/users")
if status == 200 then
  for i, user in ipairs(users) do
    print(i, user.id, user.name)
  end
end

-- Create user
local status, created = rest.post_json(
  "https://api.example.com/users",
  { name = "John Doe", email = "john@example.com" }
)
if status == 201 then
  print("Created user:", created.id)
end

-- Update user
local status, updated = rest.patch_json(
  "https://api.example.com/users/42",
  { name = "Jane Doe" }
)

-- Delete user
local status = rest.delete_json("https://api.example.com/users/42")
```

### Robust Error Handling

```lua
local function safe_api_call(url)
  local status, body, headers, err = rest.get(url)

  if not status then
    return nil, "network_error", err
  end

  if status >= 400 and status < 500 then
    return nil, "client_error", status
  end

  if status >= 500 then
    return nil, "server_error", status
  end

  return body, nil
end
```

### Authenticated Requests

```lua
-- Bearer token (JWT, API keys, etc.)
local status, data = rest.get_json("https://api.example.com/profile", {
  bearer = os.getenv("API_TOKEN")
})

-- Basic authentication
local status, data = rest.get_json("https://api.example.com/data", {
  basic = {
    user = os.getenv("API_USER"),
    pass = os.getenv("API_PASS"),
  }
})
```

---

## Dependencies

### Required
- **Lua 5.1+** (5.3+ recommended for full integer support)

### Optional (Auto-Detected)
| Dependency | Purpose | Install |
|---|---|---|
| **luasocket** + **ltn12** | Default HTTP adapter | `luarocks install luasocket` |
| **luasec** | HTTPS support for LuaSocket | `luarocks install luasec` |
| **lua-resty-http** | OpenResty/nginx HTTP adapter | `opm get openresty/lua-resty-http` |
| **dkjson** or **cjson** | JSON codec (fallback encoder included) | `luarocks install dkjson` |
| **lua-websocket** | WebSocket support | `luarocks install lua-websocket` |
| **mime** | Base64 for Basic auth | Included with luasocket |

---

## Troubleshooting

### "no supported HTTP adapter"

Neither luasocket nor lua-resty-http could be loaded.

```bash
luarocks install luasocket
# Or for OpenResty:
opm get openresty/lua-resty-http
```

### Timeout errors

Increase the timeout globally or per-request:

```lua
rest.init{ timeout = 15000 }                   -- 15 seconds globally
rest.get(url, { timeout_ms = 30000 })          -- 30 seconds for this request
```

### "rate_limited" in logs

Your configured rate limits are too restrictive for your usage pattern. Either increase the capacity/refill or remove the limit:

```lua
rest.init{
  rate_limits = {
    ["api.example.com"] = { capacity = 100, refill_per_sec = 20 }
  }
}
```

### JSON decode errors

The response body isn't valid JSON. Debug by inspecting the raw response:

```lua
local status, body = rest.get(url)
print("Raw:", body)  -- see what the server actually returned
```

Or switch to a more robust JSON library:

```lua
local cjson = require("cjson")
rest.init{ json = { encode = cjson.encode, decode = cjson.decode } }
```

### WebSocket connection fails

Install a WebSocket library:

```bash
luarocks install lua-websocket
```

---

## Performance Tips

1. **Connection pooling** — Automatic on OpenResty via keepalive (60s, 100 connections)
2. **Response caching** — Use `cache_ttl` on GET requests that don't change often
3. **Batch requests** — Group multiple requests into `rest.batch()` for cleaner code
4. **Rate limiting** — Prevents 429 errors and API bans
5. **Prefer localhost** — Set `prefer_localhost = true` when you have a local cache/proxy

---

## Use Cases

### Mobile App Backend
```lua
rest.init{
  timeout = 10000,
  retries = 3,
  servers = { "https://api.myapp.com", "https://api-backup.myapp.com" }
}
-- Handles poor connectivity with automatic retries and failover
local data = rest.get_json("/user/profile")
```

### Game Server
```lua
rest.init{
  rate_limits = { ["matchmaker.game.com"] = { capacity = 100, refill_per_sec = 10 } }
}
-- Rate-limited matchmaking requests
rest.post_json("/match/find", { player_id = 123 })
```

### IoT Device
```lua
rest.init{
  timeout = 5000,
  cache_enabled = true,
  servers = { "http://192.168.1.100:8000" }
}
-- Cache config fetches to save bandwidth
local config = rest.get_json("/device/config", { cache_ttl = 600 })
```

### Web Service with Failover
```lua
rest.init{
  servers = { "http://localhost:3000", "http://api.external.com" },
  prefer_localhost = true
}
-- Transparent failover to external API
local data = rest.get_json("/data")
```

---

## What's NOT Included

This library is for **control-plane** tasks (config, auth, signaling, API calls). For **data-plane** use dedicated tools:

- **Real-time chat** → Use WebSocket library directly
- **File streaming** → Use dedicated HTTP client with streaming support
- **P2P video** → Use WebRTC library
- **Game networking** → Use ENet or QUIC library

---

## Architecture

### Request Flow

```
rest.get(url, opts)
  │
  ├─ run request interceptors
  ├─ build_candidates(url)       → failover URL list
  ├─ cache_get(key)              → check cache (GET only)
  ├─ for each attempt:
  │    ├─ for each candidate URL:
  │    │    ├─ rate_acquire(host) → token-bucket check
  │    │    ├─ perform_raw_request()
  │    │    │    ├─ OpenResty path (lua-resty-http)
  │    │    │    └─ LuaSocket path (socket.http)
  │    │    ├─ run response interceptors
  │    │    └─ return on success or non-retryable status
  │    └─ backoff before next attempt
  ├─ cache_set(key, body, ttl)   → cache on success
  └─ return status, body, headers, err
```

### Adapters
- **OpenResty** — Uses `lua-resty-http` with connection keepalive (high performance)
- **LuaSocket** — Uses `socket.http` (portable, works everywhere)
- **Fallback** — Returns error if neither adapter is available

### Version Info
```lua
print(rest.VERSION)      -- "1.0.0"
print(rest.VERSION_NUM)  -- 10000  (major*10000 + minor*100 + patch)
```

---

## Migration from v0.2.1

If you're upgrading from v0.2.1:

- **No breaking changes** — all existing `rest.get()`, `rest.post()`, `rest.init()` calls work as before
- **New methods** — `rest.patch()`, `rest.head()`, `rest.put_json()`, `rest.patch_json()`, `rest.delete_json()`
- **Settings file** — `rest.load_settings()` is new; configure everything from JSON
- **Interceptors** — `rest.add_interceptor()` is new; use for middleware-style hooks
- **Log levels** — `log_level` config is new; defaults to `"info"` (same verbosity as before)
- **Retry control** — `retry_on_status` is new; defaults include the same codes that were previously hardcoded
- **Cache management** — `rest.cache_clear()` and `rest.cache_stats()` are new
- **Version constant** — `rest.VERSION` and `rest.VERSION_NUM` are new

---

## License

MIT — Adapt and reuse freely.
