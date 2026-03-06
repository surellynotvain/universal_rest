-- universal_rest.lua
-- Universal, environment-adaptive HTTP/REST client for Lua
-- Version 1.0.0
--
-- Features: multi-server failover, websocket adapter, retry with exponential
-- backoff, TTL caching (LRU), token-bucket rate limiting, middleware/interceptors,
-- configurable log levels, settings file loading, UDP hole-punch helpers,
-- signaling & TURN helpers, and localhost convenience.

-- Dependency detection

local socket_ok, http = pcall(require, "socket.http")
local ltn12_ok, ltn12 = pcall(require, "ltn12")
local json_ok, json = pcall(require, "dkjson")
local has_luasocket = socket_ok and ltn12_ok

local ok_resty_http, resty_http = pcall(require, "resty.http")
local ngx_available = (type(ngx) == "table" and ok_resty_http)

-- Optional websocket libs (try several common names)
local ws_client, ws_lib_name
do
  local ok_ws, ws_try = pcall(require, "websocket.client")
  if ok_ws then
    ws_client = ws_try
    ws_lib_name = "websocket.client"
  end
  if not ws_client then
    ok_ws, ws_try = pcall(require, "websocket")
    if ok_ws and type(ws_try) == "table" and ws_try.client then
      ws_client = ws_try.client
      ws_lib_name = "websocket"
    end
  end
end

-- JSON fallback (minimal; for production prefer dkjson / cjson)

local function simple_encode(val, indent)
  if val == nil then return "null" end

  local t = type(val)
  if t == "boolean" then return tostring(val) end
  if t == "number"  then
    -- Handle special float values
    if val ~= val then return "null" end            -- NaN
    if val == math.huge then return "1e+308" end
    if val == -math.huge then return "-1e+308" end
    return tostring(val)
  end

  if t == "string" then
    local escaped = val
      :gsub("\\", "\\\\")
      :gsub('"',  '\\"')
      :gsub("\b", "\\b")
      :gsub("\f", "\\f")
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
  end

  if t == "table" then
    local parts = {}
    -- Detect array vs object: check for sequential integer keys starting at 1
    local is_array = true
    local max_index = 0
    for k, _ in pairs(val) do
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        is_array = false
        break
      end
      if k > max_index then max_index = k end
    end
    -- Also verify there are no holes
    if is_array and max_index > 0 then
      for i = 1, max_index do
        if val[i] == nil then
          is_array = false
          break
        end
      end
    end
    if is_array and max_index == 0 then
      -- Empty table → default to object {}
      return "{}"
    end

    if is_array then
      for i = 1, max_index do
        parts[#parts + 1] = simple_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, v in pairs(val) do
        local key = type(k) == "string" and k or tostring(k)
        local escaped_key = key:gsub("\\", "\\\\"):gsub('"', '\\"')
        parts[#parts + 1] = '"' .. escaped_key .. '":' .. simple_encode(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end

  return '"' .. tostring(val) .. '"'
end

local function simple_decode(_)
  error("No JSON decoder available; install dkjson or cjson")
end

local JSON = (json_ok and json)
  and { encode = function(t) return json.encode(t) end,
        decode = function(s) return json.decode(s) end }
  or  { encode = simple_encode, decode = simple_decode }

local socket = nil
if has_luasocket then
  socket = require("socket")
end

-- Module table

local M = {}

M.VERSION     = "1.0.0"
M.VERSION_NUM = 10000   -- major*10000 + minor*100 + patch

-- Log levels

local LOG_LEVELS = { none = 0, error = 1, warn = 2, info = 3, debug = 4 }

local function log(level, ...)
  local threshold = LOG_LEVELS[M.config.log_level] or 3
  local msg_level = LOG_LEVELS[level] or 3
  if msg_level <= threshold then
    M.config.logger(level, ...)
  end
end

-- Default configuration

M.config = {
  timeout         = 5000,           -- ms
  retries         = 2,
  backoff_base    = 200,            -- ms
  backoff_factor  = 2,
  jitter          = true,
  user_agent      = "universal_rest/" .. M.VERSION,
  log_level       = "info",         -- "debug" | "info" | "warn" | "error" | "none"
  json            = JSON,
  logger          = function(...) io.write(table.concat({...}, " ") .. "\n") end,
  rate_limits     = {},             -- host -> {capacity=, refill_per_sec=}
  cache_enabled   = true,
  cache_max_items = 1000,
  servers         = {},             -- base URLs for failover
  prefer_localhost = true,
  retry_on_status = {500, 502, 503, 504, 429},
  websocket       = {
    enabled = true,
    library = ws_lib_name,
  },
  interceptors    = {               -- middleware hooks
    request  = {},                  -- list of fn(method, url, headers, body) -> method, url, headers, body
    response = {},                  -- list of fn(status, body, headers) -> status, body, headers
  },
}

-- Internal cache (LRU by last-access timestamp)

local cache = {}
local cache_index = {}  -- key -> last_access timestamp
local cache_hits = 0
local cache_misses = 0

local function cache_get(key)
  if not M.config.cache_enabled then return nil end
  local ent = cache[key]
  if not ent then
    cache_misses = cache_misses + 1
    return nil
  end
  if ent.expires and ent.expires <= os.time() then
    cache[key] = nil
    cache_index[key] = nil
    cache_misses = cache_misses + 1
    return nil
  end
  ent.last_access = os.time()
  cache_index[key] = ent.last_access
  cache_hits = cache_hits + 1
  return ent.value
end

local function cache_set(key, value, ttl)
  if not M.config.cache_enabled then return end
  if ttl and ttl <= 0 then
    log("warn", "cache_set called with invalid TTL (must be > 0):", ttl)
    return
  end

  -- Count current items
  local count = 0
  for _ in pairs(cache_index) do count = count + 1 end

  -- Prune oldest entries if at capacity
  while count >= M.config.cache_max_items do
    local oldest_k, oldest_t
    for k, t in pairs(cache_index) do
      if not oldest_t or t < oldest_t then
        oldest_t = t
        oldest_k = k
      end
    end
    if oldest_k then
      cache[oldest_k] = nil
      cache_index[oldest_k] = nil
      count = count - 1
    else
      break
    end
  end

  cache[key] = {
    value       = value,
    expires     = ttl and (os.time() + ttl) or nil,
    last_access = os.time(),
  }
  cache_index[key] = os.time()
end

--- Clear the entire cache.
function M.cache_clear()
  cache = {}
  cache_index = {}
  cache_hits = 0
  cache_misses = 0
  log("debug", "cache cleared")
end

--- Return cache statistics.
-- @return table {size, hits, misses, max_items, enabled}
function M.cache_stats()
  local size = 0
  for _ in pairs(cache) do size = size + 1 end
  return {
    size      = size,
    hits      = cache_hits,
    misses    = cache_misses,
    max_items = M.config.cache_max_items,
    enabled   = M.config.cache_enabled,
  }
end

-- Token-bucket rate limiter (per host)

local rate_state = {}

local function rate_acquire(host, cost)
  local cfg = M.config.rate_limits[host]
  if not cfg then return true end
  local st = rate_state[host]
  local now = os.time()
  if not st then
    st = { tokens = cfg.capacity, last = now }
    rate_state[host] = st
  end
  local elapsed = now - st.last
  st.tokens = math.min(cfg.capacity, st.tokens + elapsed * cfg.refill_per_sec)
  st.last = now
  cost = cost or 1
  if st.tokens >= cost then
    st.tokens = st.tokens - cost
    return true
  end
  return false
end

-- Backoff

local function backoff(attempt)
  local base   = M.config.backoff_base
  local factor = M.config.backoff_factor
  local ms = base * (factor ^ (attempt - 1))
  if M.config.jitter then
    ms = ms + math.random(0, base)
  end
  return ms / 1000  -- seconds
end

local function sleep(seconds)
  if ngx and ngx.sleep then
    ngx.sleep(seconds)
  elseif socket and socket.sleep then
    socket.sleep(seconds)
  end
end

-- URL utilities

--- URL-encode a string value for safe use in query parameters.
local function url_encode(str)
  str = tostring(str)
  return (str:gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Build a URL with properly encoded query parameters.
-- @param base string The base URL
-- @param params table Key-value pairs for the query string
-- @return string The full URL with query string
function M.build_url(base, params)
  if not params or next(params) == nil then return base end
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = url_encode(k) .. "=" .. url_encode(v)
  end
  local sep = base:find("?") and "&" or "?"
  return base .. sep .. table.concat(parts, "&")
end

-- Server failover: build candidate URLs

local function build_candidates(path_or_url)
  -- Full URL → return as-is
  if tostring(path_or_url):match("^https?://") then
    return { path_or_url }
  end

  local servers = M.config.servers or {}
  if #servers == 0 then return {} end

  local ordered = {}
  if M.config.prefer_localhost then
    -- Localhost entries first
    for _, s in ipairs(servers) do
      local sl = tostring(s)
      if sl:match("localhost") or sl:match("127%.0%.0%.1") then
        ordered[#ordered + 1] = s
      end
    end
    for _, s in ipairs(servers) do
      local sl = tostring(s)
      if not (sl:match("localhost") or sl:match("127%.0%.0%.1")) then
        ordered[#ordered + 1] = s
      end
    end
  else
    for _, s in ipairs(servers) do ordered[#ordered + 1] = s end
  end

  local out = {}
  for _, base in ipairs(ordered) do
    base = tostring(base)
    local sep = ""
    if not path_or_url:match("^/") and not base:match("/$") then sep = "/" end
    if path_or_url:match("^/") and base:match("/$") then
      base = base:sub(1, -2)  -- remove trailing slash to avoid double slash
    end
    out[#out + 1] = base .. sep .. path_or_url
  end
  return out
end

-- Retry status check

local function should_retry_status(status_num)
  for _, code in ipairs(M.config.retry_on_status or {}) do
    if status_num == code then return true end
  end
  return false
end

-- Raw HTTP request (adapter selection)

local function perform_raw_request(method, url, headers, body, timeout_ms)
  timeout_ms = timeout_ms or M.config.timeout

  -- ── OpenResty (lua-resty-http) ──
  if ngx_available then
    local httpc = resty_http.new()
    -- resty_http:set_timeout() expects milliseconds
    if timeout_ms then httpc:set_timeout(timeout_ms) end

    -- Parse URL — try resty's own parser first, fall back to socket.url
    local parsed
    local ok_parse, socket_url = pcall(require, "socket.url")
    if ok_parse then
      parsed = socket_url.parse(url)
    end
    if not parsed or not parsed.host then
      return nil, nil, nil, "url parse error: invalid url"
    end

    local host = parsed.host
    local port = tonumber(parsed.port) or (parsed.scheme == "https" and 443 or 80)

    local ok, err = httpc:connect(host, port)
    if not ok then return nil, nil, nil, "connect error: " .. tostring(err) end

    if parsed.scheme == "https" then
      local _, ssl_err = httpc:ssl_handshake(nil, host, false)
      if ssl_err then
        return nil, nil, nil, "ssl handshake error: " .. tostring(ssl_err)
      end
    end

    local res, req_err = httpc:request{
      method  = method,
      path    = (parsed.path or "/") .. (parsed.query and ("?" .. parsed.query) or ""),
      headers = headers,
      body    = body,
    }
    if not res then
      return nil, nil, nil, "request error: " .. tostring(req_err)
    end

    -- Read full body
    local res_body, read_err = res:read_body()
    if not res_body and read_err then
      return res.status, nil, res.headers, "read body error: " .. tostring(read_err)
    end

    -- Return connection to keepalive pool
    local ok_ka, ka_err = pcall(function()
      httpc:set_keepalive(60000, 100)
    end)
    if not ok_ka then
      log("warn", "keepalive_error", tostring(ka_err))
    end

    return res.status, res_body or "", res.headers, nil
  end

  -- ── LuaSocket (portable default) ──
  if has_luasocket then
    local resp_body = {}
    local req_ok, status_or_err, resp_headers = http.request{
      method   = method,
      url      = url,
      headers  = headers,
      source   = body and ltn12.source.string(body) or nil,
      sink     = ltn12.sink.table(resp_body),
      protocol = "any",
      redirect = false,
    }
    if not req_ok then
      -- When http.request fails, status_or_err contains the error message
      return nil, nil, nil, "socket error: " .. tostring(status_or_err)
    end
    local status_num = tonumber(status_or_err)
    return status_num, table.concat(resp_body), resp_headers or {}, nil
  end

  return nil, nil, nil, "no supported HTTP adapter (install luasocket or lua-resty-http)"
end

-- High-level request (retries, rate-limit, caching, failover, interceptors)

local function request(method, path_or_url, opts)
  opts = opts or {}
  local headers = opts.headers or {}
  headers["User-Agent"] = headers["User-Agent"] or M.config.user_agent

  -- JSON body encoding
  if opts.json and opts.body and type(opts.body) == "table" then
    headers["Content-Type"] = headers["Content-Type"] or "application/json"
    opts.body = M.config.json.encode(opts.body)
  end

  -- Content-Length for body
  if opts.body and type(opts.body) == "string" then
    headers["Content-Length"] = tostring(#opts.body)
  end

  -- Authentication
  if opts.bearer then
    headers["Authorization"] = "Bearer " .. opts.bearer
  end
  if opts.basic then
    local user = opts.basic.user or ""
    local pass = opts.basic.pass or ""
    local raw  = user .. ":" .. pass
    local enc, enc_err
    local ok_mime, mime = pcall(require, "mime")
    if ok_mime and mime and mime.b64 then
      enc = mime.b64(raw)
    else
      enc_err = "mime library not available or missing b64 function"
    end
    if enc then
      headers["Authorization"] = "Basic " .. enc
    else
      log("warn", "basic auth encoding failed:", enc_err or "unknown error")
    end
  end

  -- Build candidate full URLs
  local candidates = build_candidates(tostring(path_or_url))
  if #candidates == 0 then candidates = { tostring(path_or_url) } end

  if not tostring(path_or_url):match("^https?://") and #M.config.servers == 0 then
    log("warn", "no servers configured and relative path provided:", path_or_url)
  end

  -- Run request interceptors
  for _, interceptor in ipairs(M.config.interceptors.request) do
    local ok_int, new_method, new_url, new_headers, new_body = pcall(
      interceptor, method, candidates[1], headers, opts.body
    )
    if ok_int and new_method then
      method  = new_method
      headers = new_headers or headers
      if new_body ~= nil then opts.body = new_body end
    end
  end

  -- Cache key (null-separated to avoid collisions)
  local cache_key = method .. "\0" .. table.concat(candidates, "\0") .. "\0" .. (opts.body or "")

  if method == "GET" and opts.cache_ttl then
    local cached = cache_get(cache_key)
    if cached then
      log("debug", "cache_hit", candidates[1])
      return 200, cached, { from_cache = true }
    end
  end

  local max_attempts = (opts.retries ~= nil) and opts.retries or M.config.retries
  local attempt = 0

  while attempt < max_attempts do
    attempt = attempt + 1

    for _, url in ipairs(candidates) do
      local host = url:match("^https?://([^/:]+)") or "default"

      -- Rate limiting
      if not rate_acquire(host, opts.rate_cost or 1) then
        log("info", "rate_limited", host)
        sleep(backoff(attempt))
        goto continue_next_server
      end

      log("debug", "request", method, url, "attempt", attempt)

      local status, body, resp_headers, err = perform_raw_request(
        method, url, headers, opts.body, opts.timeout_ms
      )

      if err then
        log("error", "request_error", method, url, err, "attempt", attempt)
      else
        local status_num = tonumber(status) or 0

        -- Run response interceptors
        for _, interceptor in ipairs(M.config.interceptors.response) do
          local ok_int, new_status, new_body, new_headers = pcall(
            interceptor, status_num, body, resp_headers
          )
          if ok_int and new_status then
            status_num   = new_status
            body         = new_body or body
            resp_headers = new_headers or resp_headers
          end
        end

        -- Success (2xx)
        if status_num >= 200 and status_num < 300 then
          if method == "GET" and opts.cache_ttl then
            cache_set(cache_key, body, opts.cache_ttl)
          end
          return status_num, body, resp_headers, nil
        end

        -- Client errors (4xx except retryable ones) → don't retry
        if status_num >= 400 and status_num < 500 and not should_retry_status(status_num) then
          return status_num, body, resp_headers, nil
        end

        -- Retryable status
        if should_retry_status(status_num) then
          log("info", "retryable_status", status_num, "from", url, "attempt", attempt)
        else
          -- 5xx not in retry list or 3xx → return as-is
          return status_num, body, resp_headers, nil
        end
      end

      ::continue_next_server::
    end

    -- All servers failed for this attempt → backoff
    if attempt < max_attempts then
      local wait = backoff(attempt)
      log("debug", "backoff", wait, "seconds before attempt", attempt + 1)
      sleep(wait)
    end
  end

  return nil, nil, nil, "max attempts reached across servers"
end

-- Initialization

--- Initialize the library with configuration options.
-- Merges the provided options table into the current config.
-- Can also be called multiple times; each call merges on top of existing config.
-- @param opts table Configuration options (see README for full list)
function M.init(opts)
  if not opts then return end
  for k, v in pairs(opts) do
    if k == "interceptors" then
      -- Merge interceptor lists rather than replacing
      if type(v) == "table" then
        if v.request then
          M.config.interceptors.request = v.request
        end
        if v.response then
          M.config.interceptors.response = v.response
        end
      end
    elseif k == "rate_limits" and type(v) == "table" then
      -- Merge rate limits
      for host, limit in pairs(v) do
        M.config.rate_limits[host] = limit
      end
    else
      M.config[k] = v
    end
  end
  -- Seed random for jitter
  math.randomseed(os.time() + (os.clock() * 1000))
end

-- Settings file loading

--- Load configuration from a JSON settings file and apply via init().
-- @param path string Path to JSON settings file (default: "universal_rest_settings.json")
-- @return boolean, string|nil  true on success, or false + error message
function M.load_settings(path)
  path = path or "universal_rest_settings.json"
  local f, open_err = io.open(path, "r")
  if not f then
    return false, "cannot open settings file: " .. tostring(open_err)
  end
  local content = f:read("*a")
  f:close()

  if not content or content == "" then
    return false, "settings file is empty: " .. path
  end

  local ok, data = pcall(M.config.json.decode, content)
  if not ok then
    return false, "JSON parse error in settings file: " .. tostring(data)
  end
  if type(data) ~= "table" then
    return false, "settings file must contain a JSON object"
  end

  M.init(data)
  log("info", "loaded settings from", path)
  return true, nil
end

-- Middleware / Interceptors

--- Add a request or response interceptor.
-- Request interceptors:  fn(method, url, headers, body) -> method, url, headers, body
-- Response interceptors: fn(status, body, headers) -> status, body, headers
-- @param kind string "request" or "response"
-- @param fn function The interceptor function
function M.add_interceptor(kind, fn)
  if kind ~= "request" and kind ~= "response" then
    error("interceptor kind must be 'request' or 'response', got: " .. tostring(kind))
  end
  if type(fn) ~= "function" then
    error("interceptor must be a function")
  end
  table.insert(M.config.interceptors[kind], fn)
end

--- Remove all interceptors of a given kind (or all).
-- @param kind string|nil "request", "response", or nil for both
function M.clear_interceptors(kind)
  if kind then
    M.config.interceptors[kind] = {}
  else
    M.config.interceptors.request  = {}
    M.config.interceptors.response = {}
  end
end

-- Public HTTP methods

function M.request(method, path_or_url, opts)
  return request(method:upper(), path_or_url, opts)
end

function M.get(url, opts)    return M.request("GET",    url, opts) end
function M.post(url, opts)   return M.request("POST",   url, opts) end
function M.put(url, opts)    return M.request("PUT",    url, opts) end
function M.patch(url, opts)  return M.request("PATCH",  url, opts) end
function M.delete(url, opts) return M.request("DELETE", url, opts) end
function M.head(url, opts)   return M.request("HEAD",   url, opts) end

-- JSON convenience methods

function M.get_json(url, opts)
  opts = opts or {}
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.get(url, opts)
  if not status then return nil, nil, err end
  if not body or body == "" then
    log("warn", "empty response body for GET", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: " .. tostring(decoded) end
  return status, decoded, nil
end

function M.post_json(url, tbl, opts)
  opts = opts or {}
  opts.json = true
  opts.body = tbl
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.post(url, opts)
  if not status then return nil, nil, err end
  if not body or body == "" then
    log("warn", "empty response body for POST", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: " .. tostring(decoded) end
  return status, decoded, nil
end

function M.put_json(url, tbl, opts)
  opts = opts or {}
  opts.json = true
  opts.body = tbl
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.put(url, opts)
  if not status then return nil, nil, err end
  if not body or body == "" then
    log("warn", "empty response body for PUT", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: " .. tostring(decoded) end
  return status, decoded, nil
end

function M.patch_json(url, tbl, opts)
  opts = opts or {}
  opts.json = true
  opts.body = tbl
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.patch(url, opts)
  if not status then return nil, nil, err end
  if not body or body == "" then
    log("warn", "empty response body for PATCH", url)
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: " .. tostring(decoded) end
  return status, decoded, nil
end

function M.delete_json(url, opts)
  opts = opts or {}
  opts.headers = opts.headers or {}
  opts.headers["Accept"] = opts.headers["Accept"] or "application/json"
  local status, body, headers, err = M.delete(url, opts)
  if not status then return nil, nil, err end
  if not body or body == "" then
    return status, {}, nil
  end
  local ok, decoded = pcall(M.config.json.decode, body)
  if not ok then return status, nil, "json decode error: " .. tostring(decoded) end
  return status, decoded, nil
end

-- Batch requests

--- Execute multiple requests sequentially with full failover logic per request.
-- @param requests table Array of {method=, url=, opts=} tables
-- @return table Array of {status=, body=, headers=, err=} result tables
function M.batch(requests)
  local results = {}
  for i, r in ipairs(requests) do
    local st, body, hdrs, err = M.request(r.method or "GET", r.url, r.opts or {})
    results[i] = { status = st, body = body, headers = hdrs, err = err }
  end
  return results
end

-- WebSocket helper

--- Connect to a WebSocket endpoint.
-- @param full_url string WebSocket URL (ws:// or wss://)
-- @param handlers table {on_message=fn, on_close=fn, on_error=fn}
-- @param opts table Additional options (reserved for future use)
-- @return table|nil WebSocket object with send/close/raw, or nil
-- @return string|nil Error message if connection failed
function M.ws_connect(full_url, handlers, opts)
  opts = opts or {}
  if not M.config.websocket.enabled or not ws_client then
    return nil, "no websocket client library present or websocket disabled"
  end

  local ok, ws_or_err = pcall(ws_client.connect, full_url)
  if not ok or not ws_or_err then
    return nil, "ws connect failed: " .. tostring(ws_or_err)
  end
  local ws = ws_or_err
  local running = true

  -- Reader coroutine
  local function reader()
    while running do
      local ok2, msg = pcall(function() return ws:receive() end)
      if not ok2 then
        running = false
        if handlers and handlers.on_error then handlers.on_error(msg) end
        break
      end
      if not msg then
        running = false
        if handlers and handlers.on_close then handlers.on_close() end
        break
      end
      if handlers and handlers.on_message then handlers.on_message(msg) end
    end
  end

  -- Spawn reader thread
  if ngx and ngx.thread and ngx.thread.spawn then
    ngx.thread.spawn(reader)
  else
    local co = coroutine.create(reader)
    coroutine.resume(co)
  end

  local obj = {
    send = function(payload)
      return pcall(function() ws:send(payload) end)
    end,
    close = function()
      running = false
      pcall(function() ws:close() end)
      sleep(0.1)
    end,
    raw = ws,
  }
  return obj, nil
end

-- UDP hole-punch helper

--- Attempt UDP hole-punching by sending repeated empty packets to a peer.
-- @param local_port number Local UDP port to bind
-- @param peer_ip string Peer's IP address
-- @param peer_port number Peer's UDP port
-- @param attempts number Number of punch attempts (default: 5)
-- @param interval_s number Seconds between attempts (default: 0.2)
-- @return boolean, string|nil  true on success, or nil + error
function M.udp_holepunch(local_port, peer_ip, peer_port, attempts, interval_s)
  if not socket then return nil, "luasocket required for UDP holepunch" end
  attempts   = attempts or 5
  interval_s = interval_s or 0.2

  local udp = socket.udp()
  udp:settimeout(0.1)
  udp:setsockname("*", local_port or 0)

  for _ = 1, attempts do
    pcall(function() udp:sendto("", peer_ip, peer_port) end)
    socket.sleep(interval_s)
  end

  udp:close()
  return true, nil
end

-- Signaling helpers (use server endpoints; failover applies)

function M.signal_offer(room_or_path, payload)
  return M.post_json(room_or_path or "signal/offer", payload)
end

function M.signal_answer(room_or_path, payload)
  return M.post_json(room_or_path or "signal/answer", payload)
end

function M.signal_poll(path, query)
  local built = path
  if query and type(query) == "table" then
    built = M.build_url(path, query)
  end
  return M.get_json(built)
end

-- TURN allocator helper

function M.request_turn(path_or_url, body, opts)
  return M.post_json(path_or_url or "turn", body or {}, opts)
end

-- Export internals for testing / advanced use

M._internal = {
  perform_raw_request = perform_raw_request,
  cache_get           = cache_get,
  cache_set           = cache_set,
  rate_acquire        = rate_acquire,
  build_candidates    = build_candidates,
  url_encode          = url_encode,
  should_retry_status = should_retry_status,
  log                 = log,
  sleep               = sleep,
  config              = config,
  version             = version,
}

return M
