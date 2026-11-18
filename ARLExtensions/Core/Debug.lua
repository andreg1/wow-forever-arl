-- ARLE.Debug: catches errors per feature, and traces what features decide.
--
-- Every piece of feature code the framework runs (events, timers, tickers,
-- hooks, enable/disable, imports, option changes, status lines, commands,
-- addon messages, Wrap wrappers) goes through Debug.Call(owner, fn, ...):
--   * the error and its stack are kept per feature in ARLExtensionsCharDB.debug
--     (repeats folded into one entry with a count), so they survive /reload;
--   * the first time an error happens this session, one chat line says so;
--   * it still goes to the game's error handler (General.log, scriptErrors);
--   * circuit breaker: a feature with BREAK_COUNT errors inside
--     BREAK_WINDOW seconds is turned off (and says so), so a broken feature
--     can't flood the client into "your AddOns are experiencing a large number
--     of errors".
-- Tracing: self:Debug(fmt, ...) in a feature is free while off; once
-- "/arl debug <feature>" turns it on (saved per character), the lines go to
-- chat and to a buffer that /arl report includes.
-- Not covered: scripts a feature sets on its own frames with SetScript (use
-- self:Script(frame, script, fn) for those).
local _, ns = ...
local ARLE = ns.ARLE
local D = {}
ARLE.Debug = D

local MAX_PER_FEATURE = 10 -- distinct errors kept per feature
local MAX_STACK = 2000
local MAX_TRACE = 300
local BREAK_COUNT, BREAK_WINDOW = 20, 60

D.session = {}  -- id -> errors this session
D.trace = {}    -- recent trace lines (this session)
local told = {} -- id .. msg -> said in chat this session
local recent = {} -- id -> times of recent errors (breaker)

local function Store()
  local sv = _G.ARLExtensionsCharDB
  if type(sv) ~= "table" then
    return nil
  end
  if type(sv.debug) ~= "table" then
    sv.debug = {}
  end
  local d = sv.debug
  if type(d.errors) ~= "table" then
    d.errors = {}
  end
  if type(d.tracing) ~= "table" then
    d.tracing = {}
  end
  return d
end
D.Store = Store

-- owner: a feature definition, a feature id, or nil (the framework itself).
local function Owner(owner)
  if type(owner) == "table" then
    return owner.id or "ARL", owner
  end
  local id = type(owner) == "string" and owner or "ARL"
  return id, ARLE.modules and ARLE.modules[id]
end

local function Title(id, def)
  return (def and def.title) or (ARLE.catalog and ARLE.catalog[id] and ARLE.catalog[id].title)
    or (id == "ARL" and "ARL Extensions") or id
end
D.Title = Title

-- Marks an error that only passes through ARL (a wrapped addon's own): not recorded.
local PASS = {}
D.PASS = PASS

local function Handler(err)
  if type(err) == "table" and err.pass == PASS then
    return err
  end
  return { msg = tostring(err), stack = debugstack and debugstack(2) or "" }
end

function D:Record(owner, e)
  local id, def = Owner(owner)
  local msg = type(e) == "table" and e.msg or tostring(e)
  local stack = type(e) == "table" and e.stack or ""
  self.session[id] = (self.session[id] or 0) + 1

  local d = Store()
  if d then
    local list = d.errors[id]
    if type(list) ~= "table" then
      list = {}
      d.errors[id] = list
    end
    local entry
    for _, x in ipairs(list) do
      if x.msg == msg then
        entry = x
        break
      end
    end
    if not entry then
      entry = { msg = msg, count = 0, first = time() }
      table.insert(list, 1, entry)
      while #list > MAX_PER_FEATURE do
        table.remove(list)
      end
    end
    entry.count = entry.count + 1
    entry.last = time()
    entry.version = ARLE.version
    entry.stack = stack:sub(1, MAX_STACK)
  end

  -- The game's own handler too (General.log, and the error frame with
  -- scriptErrors on), as before.
  local handler = geterrorhandler and geterrorhandler()
  if handler then
    pcall(handler, msg)
  end

  if not told[id .. msg] then
    told[id .. msg] = true
    ARLE:Print("|cffff6060" .. Title(id, def) .. " hit an error:|r " .. msg:gsub("^Interface[/\\]AddOns[/\\]", "")
      .. "  |cff9d9d9d(/arl errors, /arl report)|r")
  end

  -- Circuit breaker (features only; the framework itself is never turned off).
  if def and not def.builtin and def._active then
    local now = GetTime()
    local times = recent[id] or {}
    recent[id] = times
    times[#times + 1] = now
    while times[1] and times[1] < now - BREAK_WINDOW do
      table.remove(times, 1)
    end
    if #times >= BREAK_COUNT and not def._tripped then
      def._tripped = msg
      recent[id] = nil
      -- Next frame: not from inside the feature's own failing call.
      C_Timer.After(0, function()
        if def._active then
          ARLE:SetModuleEnabled(id, false)
          if def._active then
            -- (refused, e.g. during the guild check after a loading screen: off all the same)
            if type(def.db) == "table" then
              def.db.enabled = false
            end
            ARLE:CallDisable(def)
            if ARLE.Changed then
              ARLE:Changed()
            end
          end
          def._tripped = msg
          ARLE:Print("|cffff6060" .. Title(id, def) .. " was turned off|r after " .. BREAK_COUNT
            .. " errors in " .. BREAK_WINDOW .. " seconds. /arl errors shows them; /arl "
            .. (def.command or "enable " .. id) .. " on turns it back on.")
        end
      end)
    end
  end
  return msg
end

-- Does xpcall pass extra arguments on to the function? (It does on modern
-- clients; checked once instead of assumed.)
local XPCALL_ARGS
do
  local ok, v = xpcall(function(a)
    return a
  end, Handler, 1)
  XPCALL_ARGS = ok and v == 1
end

local function Finish(owner, ok, ...)
  if ok then
    return true, ...
  end
  local e = (...)
  if type(e) == "table" and e.pass == PASS then
    return false, "passed on"
  end
  return false, D:Record(owner, e)
end

-- Runs fn(...); returns true, results... or false, message (recorded).
function D.Call(owner, fn, ...)
  if XPCALL_ARGS then
    return Finish(owner, xpcall(fn, Handler, ...))
  end
  local n, args = select("#", ...), { ... }
  return Finish(owner, xpcall(function()
    return fn(unpack(args, 1, n))
  end, Handler))
end

-- Errors this session for a feature (for the panel's status line).
function D:SessionCount(id)
  return self.session[id] or 0
end

-- A feature was turned on again by the player: give it a fresh start.
function D:Reset(id)
  recent[id] = nil
  local def = ARLE.modules and ARLE.modules[id]
  if def then
    def._tripped = nil
  end
end

function D:Clear()
  local d = Store()
  if d then
    d.errors = {}
  end
  wipe(self.session)
  wipe(told)
  wipe(recent)
end

-------------------------------------------------------------------------------
-- Tracing
-------------------------------------------------------------------------------

function D:Tracing(id)
  local d = Store()
  return d and d.tracing[id] == true or false
end

function D:SetTracing(id, on)
  local d = Store()
  if d then
    d.tracing[id] = on and true or nil
  end
end

function D:TracedIds()
  local d, out = Store(), {}
  for id in pairs(d and d.tracing or {}) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

function D:Trace(owner, fmt, ...)
  local id, def = Owner(owner)
  local text = tostring(fmt)
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, text, ...)
    if ok then
      text = formatted
    else
      local parts = { text }
      for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
      end
      text = table.concat(parts, " ")
    end
  end
  local line = date("%H:%M:%S") .. " " .. id .. ": " .. text
  self.trace[#self.trace + 1] = line
  if #self.trace > MAX_TRACE then
    table.remove(self.trace, 1)
  end
  print("|cff9d9d9d[ARL " .. Title(id, def) .. "]|r " .. text)
end
