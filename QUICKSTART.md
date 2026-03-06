# Universal REST — Quick Start Guide

Get up and running in under 5 minutes.

---

## Step 1 — Install Dependencies

You need **Lua 5.1+** and at least one HTTP adapter:

```bash
# Ubuntu / Debian
sudo apt-get install lua5.3 lua-socket lua-sec
# rhel based
sudo dnf install lua5.3 lua-socket lua-sec
#arch based
sudo pacman -S lua5.3 lua-socket lua-sec
#freebsd based
sudo pkg install lua53-lua-socket lua53-lua-sec
#openbsd based
sudo doas pkg_add lua53-lua-socket lua53-lua-sec
#netbsd based
sudo pkg_add lua53-lua-socket lua53-lua-sec
#alpine linux based
sudo apk add lua53-lua-socket lua53-lua-sec
#gentoo based
sudo emerge --ask dev-lua/lua-socket dev-lua/lua-sec
#slackware based
sudo slackpkg install lua-socket lua-sec
#windows
choco install lua53-lua-socket lua53-lua-sec
#macos
brew install lua53-lua-socket lua53-lua-sec


# Or via LuaRocks (any OS)
luarocks install luasocket
luarocks install luasec          # for HTTPS

# Optional (better JSON performance)
luarocks install dkjson          # or: luarocks install lua-cjson

```

> **OpenResty users:** You already have `lua-resty-http` — no extra install needed.

---

## Step 2 — Add the Library to Your Project

Copy a single file:

```bash
cp universal_rest.lua /path/to/your/project/
```

Optionally copy the settings file too:

```bash
cp universal_rest_settings.json /path/to/your/project/
```

---

## Step 3 — Load and Configure

**Option A — Settings JSON (recommended)**

Edit `universal_rest_settings.json` to your needs (every key is documented inside the file), then:

```lua
local rest = require("universal_rest")

-- Load all config from the JSON file
local ok, err = rest.load_settings("universal_rest_settings.json")
if not ok then print("Settings error:", err) end
```

That's it — you don't need to touch any Lua config unless you want to add something the JSON doesn't cover (like custom interceptor functions).

**Option B — Lua-only**

```lua
local rest = require("universal_rest")

rest.init{
  timeout = 8000,
  retries = 3,
  log_level = "debug",
}
```

---

## Step 4 — Make Your First Request

```lua
-- Simple GET
local status, body, headers, err = rest.get("https://httpbin.org/get")
if status then
  print("Status:", status)
  print("Body:", body)
else
  print("Error:", err)
end
```

```lua
-- GET with automatic JSON decoding
local status, data, err = rest.get_json("https://httpbin.org/json")
if status == 200 then
  print("Decoded JSON:", data)
end
```

```lua
-- POST JSON
local status, response, err = rest.post_json(
  "https://httpbin.org/post",
  { name = "Lua", version = 5.4 }
)
if status == 200 then
  print("Server echoed:", response.data)
end
```

---

## Step 5 — Common Patterns

### Multi-server failover

```lua
rest.init{
  servers = {
    "http://localhost:3000",       -- tried first (prefer_localhost = true)
    "https://api.example.com",    -- fallback
  },
}

-- No need for a full URL — the library prepends each server and fails over
local status, body = rest.get("/health")
```

### Authenticated requests

```lua
-- Bearer token
local status, data = rest.get_json("https://api.example.com/me", {
  bearer = "your-token-here"
})

-- Basic auth
local status, data = rest.get_json("https://api.example.com/data", {
  basic = { user = "admin", pass = "secret" }
})
```

### Caching responses

```lua
-- Cache this GET for 5 minutes (300 seconds)
local status, data = rest.get_json("https://api.example.com/config", {
  cache_ttl = 300
})
-- Second call within 5 minutes returns instantly from cache
```

---

## Next Steps

- Read the full [README.md](./README.md) for the complete API reference
- Edit [universal_rest_settings.json](./universal_rest_settings.json) — every single option is documented inline
- Check `rest.VERSION` to confirm you're on **1.0.0**
