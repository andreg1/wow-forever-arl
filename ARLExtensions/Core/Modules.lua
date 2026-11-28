-- Packs and features.
--
-- A pack is a LoadOnDemand addon folder that extends one outside addon (or
-- none) and holds one or more features. Its toc lists them, so the panel can
-- show every feature before the pack is loaded:
--
--   ## X-ARLE-Pack: Questie
--   ## X-ARLE-Group: Questie
--   ## X-ARLE-Features: NewInForever, SubQuestFilter
--   ## X-ARLE-Feature-NewInForever: title=New in Forever; extends=Questie; cmd=new; default=off
--
-- default=off: the feature starts turned off until the player turns it on.
-- hidden=1: the feature isn't listed in the panel; another entry shows its
-- switch and settings on its own pages (the Auction House entry's parts).
-- Its commands, data and error reports work as usual.
--
-- A feature is what the player turns on and off. Its file calls
-- ARLE:RegisterModule(def) (or ARLE.Modules:NewFeature(def)); OnEnable runs
-- once the player is a guild member and the addon it extends is loaded.
--
-- Every feature gets helpers that are undone when it's turned off, so
-- OnDisable rarely has anything left to do:
--   self:On(event, fn)                 fn(self, event, ...)   (unregistered on disable)
--   self:OnUnit(event, unit, fn)
--   self:After(sec, fn) / self:Debounce(key, sec, fn) / self:Ticker(sec, fn)
--   self:Hook(target, name, fn)        post-hook that only runs while on
--   self:HookScript(frame, script, fn) the same for frame scripts
--   self:Wrap(tbl, name, wrapper)      wrapper(orig, ...) replaces tbl[name] while on
--   self:Command(cmd)                  an extra /arl command while on
--   self:Comm(kind, fn)                an addon message handler while on
--   self:OutOfCombat(fn)               now, or once combat ends
--   self:Alert(spec)                   the shared alert (UI/Alert.lua)
--   self:Print(msg)
--   self:Debug(fmt, ...)               a trace line while "/arl debug <feature>" is on
--   self:Script(frame, script, fn)     SetScript on its own frames, errors caught
-- Everything these run is error-checked per feature (Core/Debug.lua: recorded,
-- told in chat once, and a feature that keeps failing is turned off).
--   self.db (this character's settings and on/off switch), self.char (this
--   character's data), self.shared (data shared by all characters)
local ADDON_NAME, ns = ...
local ARLE = ns.ARLE
local API, Blank = ARLE.API, ARLE.Blank
local M = ARLE.Modules

-------------------------------------------------------------------------------
-- Feature helpers
-------------------------------------------------------------------------------

local Feature = {}
M.Feature = Feature

-- Runs feature code; an error is recorded under owner (Core/Debug.lua).
local Call = ARLE.Debug.Call
local function Safe(owner, fn, ...)
  Call(owner, fn, ...)
end
M.Safe = Safe

local function Pack(...)
  return { n = select("#", ...), ... }
end

local function EventFrame(self)
  if not self._eventFrame then
    local frame = CreateFrame("Frame")
    frame:SetScript("OnEvent", function(_, event, ...)
      local fn = self._events and self._events[event]
      if fn and self._active then
        Safe(self, fn, self, event, ...)
      end
    end)
    self._eventFrame = frame
  end
  return self._eventFrame
end

-- Returns false (and registers nothing) for an event this client doesn't
-- have: RegisterEvent throws on an unknown event (LEARNED_SPELL_IN_TAB on
-- Forever), which would otherwise fail the whole OnEnable.
function Feature:On(event, fn)
  local frame = EventFrame(self)
  if not pcall(frame.RegisterEvent, frame, event) then
    return false
  end
  self._events = self._events or {}
  self._events[event] = type(fn) == "string" and self[fn] or fn
  return true
end

function Feature:OnUnit(event, unit, fn)
  local frame = EventFrame(self)
  local ok
  if frame.RegisterUnitEvent then
    ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
  else
    ok = pcall(frame.RegisterEvent, frame, event)
  end
  if not ok then
    return false
  end
  self._events = self._events or {}
  self._events[event] = type(fn) == "string" and self[fn] or fn
  return true
end

function Feature:Off(event)
  if self._events then
    self._events[event] = nil
  end
  if self._eventFrame then
    self._eventFrame:UnregisterEvent(event)
  end
end

-- Timers only fire while the feature stays on, in the same session of
-- being on (turning it off and on again drops the old ones).
function Feature:After(delay, fn)
  local gen = self._gen
  C_Timer.After(delay or 0, function()
    if self._active and self._gen == gen then
      Safe(self, fn, self)
    end
  end)
end

function Feature:Debounce(key, delay, fn)
  self._debounce = self._debounce or {}
  if self._debounce[key] then
    return
  end
  self._debounce[key] = true
  -- (A disable drops the timer and Cleanup drops the whole _debounce table,
  -- so the key is free again after a re-enable.)
  self:After(delay, function()
    if self._debounce then
      self._debounce[key] = nil
    end
    fn(self)
  end)
end

-- Repeats every delay seconds while on. Returns a handle with :Cancel().
-- The next tick is scheduled before fn runs, so one error doesn't stop it.
function Feature:Ticker(delay, fn)
  local handle = { cancelled = false }
  function handle.Cancel()
    handle.cancelled = true
  end
  local function Tick()
    if handle.cancelled then
      return
    end
    self:After(delay, Tick)
    Safe(self, fn, self)
  end
  self:After(delay, Tick)
  return handle
end

-- hooksecurefunc can't be undone, so the hook stays but does nothing while
-- the feature is off. Hooking the same thing again replaces the handler.
-- Returns false when the target doesn't exist (yet): nothing is remembered,
-- so a later enable tries again.
function Feature:Hook(target, name, fn)
  if type(target) == "string" then
    target, name, fn = _G, target, name
  end
  if type(target) ~= "table" or type(target[name]) ~= "function" then
    self:Print("couldn't hook " .. tostring(name) .. " (missing; the addon it extends may have changed).")
    return false
  end
  self._hooks = self._hooks or {}
  local byTarget = self._hooks[target] or {}
  self._hooks[target] = byTarget
  if byTarget[name] ~= nil then
    byTarget[name] = fn
    return true
  end
  local function Call(...)
    local h = byTarget[name]
    if self._active and h then
      Safe(self, h, ...)
    end
  end
  local ok
  if target == _G then
    ok = pcall(hooksecurefunc, name, Call)
  else
    ok = pcall(hooksecurefunc, target, name, Call)
  end
  if not ok then
    return false
  end
  byTarget[name] = fn
  return true
end

-- Hooks are only added out of combat (a protected frame can't be hooked in
-- combat without taint risk); in combat the hook is added once it ends.
function Feature:HookScript(frame, script, fn)
  if not frame or not frame.HookScript then
    return false
  end
  self._scriptHooks = self._scriptHooks or {}
  local byFrame = self._scriptHooks[frame] or {}
  self._scriptHooks[frame] = byFrame
  if byFrame[script] ~= nil then
    byFrame[script] = fn
    return true
  end
  byFrame[script] = fn
  local function Install()
    local ok = pcall(frame.HookScript, frame, script, function(...)
      local h = byFrame[script]
      if self._active and h then
        Safe(self, h, ...)
      end
    end)
    if not ok then
      byFrame[script] = nil
    end
    return ok
  end
  if InCombatLockdown and InCombatLockdown() then
    ARLE.Secure:Run(Install)
    return true
  end
  return Install()
end

-- Replaces a function in another addon's table (Questie modules, EUI's
-- category manager). While the feature is off the original runs untouched.
-- Wrapping the same function again only swaps the wrapper. Never use this
-- on Blizzard's own functions: that taints them; use Hook instead.
function Feature:Wrap(tbl, name, wrapper)
  if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then
    return false
  end
  self._wraps = self._wraps or {}
  local byTable = self._wraps[tbl] or {}
  self._wraps[tbl] = byTable
  local rec = byTable[name]
  if rec and tbl[name] == rec.mine then
    rec.wrapper = wrapper
    return true
  end
  -- Another addon wrapped on top of ours: our old function is still in its
  -- chain, so it must turn into a plain pass-through, or the wrapper would
  -- run twice per call.
  if rec then
    rec.dead = true
  end
  local new = { wrapper = wrapper, orig = tbl[name] }
  new.mine = function(...)
    if self._active and not new.dead then
      -- A failing wrapper must not break the other addon: the error is
      -- recorded, and the call still gets the original's results (from the
      -- original run the wrapper already made, or from running it now).
      -- An error in the original itself is the other addon's: it isn't
      -- counted against the feature, and the original isn't run again.
      local origResults, origErr
      local function orig(...)
        local r = Pack(pcall(new.orig, ...))
        if not r[1] then
          origErr = r[2]
          error({ pass = ARLE.Debug.PASS }, 0)
        end
        origResults = r
        return unpack(r, 2, r.n)
      end
      local results = Pack(Call(self, new.wrapper, orig, ...))
      if results[1] then
        return unpack(results, 2, results.n)
      end
      if origResults then
        return unpack(origResults, 2, origResults.n)
      end
      if origErr ~= nil then
        error(origErr, 0)
      end
    end
    return new.orig(...)
  end
  rec = new
  byTable[name] = rec
  tbl[name] = rec.mine
  return true
end

function Feature:Command(c)
  c.section = c.section or self.commandSection or ARLE:GroupLabel(ARLE:GroupOf(self.id))
  c.module = c.module or self.id
  if not ARLE:RegisterCommand(c) then
    return
  end
  self._commands = self._commands or {}
  self._commands[#self._commands + 1] = c.name
end

function Feature:Comm(kind, fn)
  local handler = function(...)
    if self._active then
      Safe(self, fn, self, ...)
    end
  end
  ARLE:RegisterComm(kind, handler)
  self._comms = self._comms or {}
  self._comms[kind] = handler
end

-- Dropped if the feature is turned off (or off and on again) before it runs.
function Feature:OutOfCombat(fn)
  local gen = self._gen
  ARLE.Secure:Run(function()
    if self._active and self._gen == gen then
      Safe(self, fn, self)
    end
  end)
end

function Feature:Alert(spec)
  return ARLE.UI.Alert:Show(self, spec)
end

function Feature:Print(msg)
  ARLE:Print("|cffffd100" .. (self.title or self.id) .. "|r: " .. tostring(msg))
end

-- A trace line, only while "/arl debug <feature>" is on (otherwise free):
--   self:Debug("skipped slot %d: %s", slot, why)
function Feature:Debug(fmt, ...)
  if ARLE.Debug:Tracing(self.id) then
    ARLE.Debug:Trace(self, fmt, ...)
  end
end

-- SetScript on one of the feature's own frames, with errors caught and
-- recorded like the other helpers (frame scripts otherwise bypass them).
-- fn(frame, ...) as with SetScript; returns nothing.
function Feature:Script(frame, script, fn)
  frame:SetScript(script, fn and function(...)
    Safe(self, fn, ...)
  end or nil)
end

-- Clears everything the helpers set up; runs after OnDisable.
local function Cleanup(def)
  def._gen = (def._gen or 0) + 1
  if def._eventFrame then
    def._eventFrame:UnregisterAllEvents()
  end
  def._events = nil
  def._debounce = nil
  for _, name in ipairs(def._commands or {}) do
    ARLE:UnregisterCommand(name, def.id)
  end
  def._commands = nil
  for kind, handler in pairs(def._comms or {}) do
    ARLE:UnregisterComm(kind, handler)
  end
  def._comms = nil
  if ARLE.UI.Alert then
    pcall(ARLE.UI.Alert.Hide, ARLE.UI.Alert, def)
  end
end

local function Mixin(def)
  for k, fn in pairs(Feature) do
    if def[k] == nil then
      def[k] = fn
    elseif def[k] ~= fn then
      -- A feature's own method with a helper's name replaces the helper for
      -- that feature, and every call the framework or the feature makes to it
      -- (XP Food's Debug once dumped its whole state on every check). Said
      -- loudly so it is renamed.
      ARLE:Print("|cffff6060" .. tostring(def.id) .. " defines its own " .. k .. "|r, which replaces ARL's "
        .. k .. " helper for it. Rename the feature's method.")
    end
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function ARLE:ExtendsOf(id)
  local def, cat = self.modules[id], self.catalog[id]
  return Blank(def and def.extends) or (cat and cat.extends)
end

function ARLE:GroupOf(id)
  local def, cat = self.modules[id], self.catalog[id]
  return Blank(def and def.group) or (cat and cat.group) or self:ExtendsOf(id) or "General"
end

-- The outside addon a feature needs and can't use: title, why (or nil).
function ARLE:MissingFor(id)
  return self:RequirementProblem(self:ExtendsOf(id))
end

-- An option (or its page) that needs an outside addon that isn't there.
function ARLE:OptionProblem(def, opt)
  local req = opt.requires
  if not req and opt.page then
    for _, page in ipairs(def.pages or {}) do
      if page.key == opt.page then
        req = page.requires
      end
    end
  end
  return self:RequirementProblem(req)
end

-- The standalone addon a feature took over from (toc "replaces=" or
-- def.replaces). While that addon is still loaded both would run the same
-- thing twice (two alerts, two lock lists, two macros), so the feature
-- stays paused, and copies the old addon's saved data (def:Import, while
-- its saved variables are loaded) so nothing is lost when it's turned off.
function ARLE:ReplacesOf(id)
  local def, cat = self.modules[id], self.catalog[id]
  return Blank(def and def.replaces) or (cat and cat.replaces)
end

-- The loaded standalone addon that pauses feature id, or nil.
function ARLE:ConflictFor(id)
  local old = self:ReplacesOf(id)
  if old and self:IsAddonLoaded(old) then
    return old
  end
end

local toldConflict = {}

function ARLE:CallEnable(def)
  if def._active or not self.unlocked then
    return
  end
  local target = self:ExtendsOf(def.id)
  if target and not self:IsAddonLoaded(target) then
    def._waiting = target
    return
  end
  def._waiting = nil
  -- Features build frames, macros and secure attributes: never mid-combat.
  if InCombatLockdown and InCombatLockdown() then
    if not def._combatQueued then
      def._combatQueued = true
      ARLE.Secure:Run(function()
        def._combatQueued = nil
        if def.db and def.db.enabled ~= false then
          self:CallEnable(def)
          self:Changed()
        end
      end)
    end
    return
  end
  local old = self:ConflictFor(def.id)
  if old then
    def._conflict = old
    if def.Import and not def._imported then
      def._imported = true
      Safe(def, def.Import, def, old) -- an error is recorded and said in chat
    end
    if not toldConflict[def.id] then
      toldConflict[def.id] = true
      self:Print((def.title or def.id) .. " is paused: " .. (self:AddonTitle(old) or old)
        .. " is still turned on and does the same thing"
        .. (def.Import and " (its settings were copied over)" or "")
        .. ". Turn " .. old .. " off in the AddOns list and /reload to use this one.")
    end
    return
  end
  def._conflict = nil
  def._active = true
  def._gen = (def._gen or 0) + 1
  if def.OnEnable then
    local ok, err = Call(def, def.OnEnable, def) -- recorded and said in chat
    if not ok then
      def._active = false
      def._error = tostring(err)
      -- (what it made before the error, frames and buttons, is put away too)
      if def.OnDisable then
        Safe(def, def.OnDisable, def)
      end
      Cleanup(def)
    end
  end
end

function ARLE:CallDisable(def)
  def._waiting = nil
  if not def._active then
    return
  end
  def._active = false
  if def.OnDisable then
    Safe(def, def.OnDisable, def)
  end
  Cleanup(def)
end

function ARLE:Bind(def)
  def.db = self:EnsureDB(def.id, def.defaults) -- this character's settings
  def.char = self:CharDB(def.id)                -- this character's data
  def.shared = self:SharedDB(def.id)            -- data shared by all characters
  if def.OnBind then
    Safe(def, def.OnBind, def)
  end
  if self.unlocked and def.db.enabled ~= false then
    self:CallEnable(def)
  end
end

function ARLE:RegisterModule(def)
  if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
    self:Print("Refused a module with no id.")
    return
  end
  def.options = ARLE.Options.Flatten(def.options)
  -- Defaults come from def.defaults, then from each option's own default.
  def.defaults = def.defaults or {}
  for _, opt in ipairs(def.options) do
    if opt.key and opt.default ~= nil and def.defaults[opt.key] == nil and not opt.get then
      def.defaults[opt.key] = opt.default
    end
  end
  Mixin(def)
  self.modules[def.id] = def
  if def.command and self.RegisterFeatureCommand then
    self:RegisterFeatureCommand(def)
  end
  if not self.db then
    self:QueueBind(def)
    return def
  end
  self:Bind(def)
  self:Changed()
  return def
end

function M:NewFeature(def)
  return ARLE:RegisterModule(def)
end

-- Loads a feature's pack folder. Its features wait for their own outside
-- addon (ADDON_LOADED enables them once it's there).
function ARLE:LoadModuleAddon(id)
  local cat = self.catalog[id]
  if not cat or self:IsAddonLoaded(cat.addon) then
    return true
  end
  if API.EnableAddOn then
    API.EnableAddOn(cat.addon)
  end
  local loaded, reason = API.LoadAddOn(cat.addon)
  if not loaded then
    cat.loadError = tostring(reason)
    self:Print("Could not load " .. cat.addon .. " (" .. tostring(reason) .. ").")
    return false
  end
  return true
end

-- "title=New in Forever; extends=Questie; cmd=new" -> table.
local function ParseSpec(text)
  local spec = {}
  for part in tostring(text or ""):gmatch("[^;]+") do
    local k, v = part:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k then
      spec[k] = Blank(v)
    end
  end
  return spec
end

function ARLE:Scan()
  if not API.GetNumAddOns or not API.GetAddOnMetadata then
    return
  end
  local catalog = {}
  local meta = API.GetAddOnMetadata
  for index = 1, API.GetNumAddOns() do
    local name = API.GetAddOnInfo(index)
    local features = name and Blank(meta(name, "X-ARLE-Features"))
    if features then
      local group = Blank(meta(name, "X-ARLE-Group"))
      local version = Blank(meta(name, "Version"))
      for id in features:gmatch("[^,%s]+") do
        local spec = ParseSpec(meta(name, "X-ARLE-Feature-" .. id))
        local old = self.catalog[id]
        catalog[id] = {
          id = id,
          addon = name,
          title = spec.title or id,
          notes = spec.notes or "",
          extends = spec.extends,
          group = spec.group or group,
          cmd = spec.cmd,
          replaces = spec.replaces,
          off = spec.default == "off",
          hidden = spec.hidden == "1", -- (a part shown inside another entry's pages, not in the list)
          version = version,
          loadError = old and old.loadError,
        }
      end
    end
  end
  self.catalog = catalog
  self.version = Blank(meta(ADDON_NAME, "Version")) or self.version
end

-------------------------------------------------------------------------------
-- Descriptions for the panel and the commands
-------------------------------------------------------------------------------

function ARLE:FindOption(id, key)
  local def = self.modules[id]
  for _, o in ipairs(def and def.options or {}) do
    if o.key == key then
      return o
    end
  end
end

function ARLE:GetOption(id, opt)
  local def = self.modules[id]
  if opt.get then
    return opt.get(def)
  end
  return def and def.db and def.db[opt.key]
end

function ARLE:GetInfo(id)
  local cat = self.catalog[id]
  local def = self.modules[id]
  local db = self:ModuleDB(id)
  local extends = self:ExtendsOf(id)
  local group = self:GroupOf(id)
  local info = {
    id = id,
    addon = (cat and cat.addon) or (def and def.addon),
    title = (def and def.title) or (cat and cat.title) or id,
    notes = (def and def.description) or (cat and cat.notes) or "",
    version = (cat and cat.version) or (def and def.builtin and self.version) or nil,
    builtin = def and def.builtin or false,
    groupLabel = self:GroupLabel(group),
    extendsLabel = self:AddonTitle(extends),
    order = def and def.order or 1,
    group = group,
    extends = extends,
    command = (def and def.command) or (cat and cat.cmd),
    enabled = (def and def.builtin) or (not (db and db.enabled == false) and not self:MissingFor(id)),
    active = def and def._active or false,
    options = def and def.options or nil,
    loaded = def ~= nil,
  }
  -- state: active | off | locked | missing | conflict | waiting | error | pending
  info.missing, info.missingWhy = self:MissingFor(id)
  local guild = self:GuildState()
  if guild ~= "member" then
    info.state = "locked"
    info.status = guild == "checking" and "Waiting for guild check" or "Disabled: guild members only"
  elseif not info.enabled and not info.missing then
    info.state, info.status = "off", "Off"
  elseif self:MissingFor(id) then
    local title, why = self:MissingFor(id)
    info.state, info.status = "missing", "Needs " .. title .. " (" .. why .. ")"
  elseif self:ConflictFor(id) then
    local old = self:ConflictFor(id)
    info.state = "conflict"
    info.status = "Paused: turn off " .. (self:AddonTitle(old) or old) .. " (the standalone addon) and /reload"
  elseif extends and not self:IsAddonLoaded(extends) then
    info.state, info.status = "waiting", "Waiting for " .. (info.extendsLabel or extends) .. " to load"
  elseif def and def._error and not def._active then
    info.state, info.status = "error", "Error: " .. def._error
  elseif cat and cat.loadError and not def then
    info.state, info.status = "error", "Could not load: " .. cat.loadError
  elseif info.active then
    info.state, info.status = "active", "Active"
  else
    info.state, info.status = "pending", "Loads after /reload"
  end
  if info.active and def and def.GetStatus then
    local ok, extra = Call(def, def.GetStatus, def)
    if ok and extra then
      info.status = extra
    end
  end
  if info.state == "off" and def and def._tripped then
    info.status = "Off: turned itself off after repeated errors (/arl errors)"
  end
  info.errors = ARLE.Debug:SessionCount(id)
  if info.errors > 0 then
    info.status = info.status .. "  ·  |cffff6060" .. info.errors .. " error" .. (info.errors == 1 and "" or "s")
      .. " this session|r (/arl errors)"
  end
  return info
end

-- General (the addon's own settings) is pinned first; the rest go A-Z.
local function GroupRank(name)
  return name == "General" and 0 or 1
end

-- { { name=, addon=, loaded=, modules={info...} }, ... } in display order.
function ARLE:GetGroups()
  local byName, groups, seen = {}, {}, {}
  local function add(id)
    if seen[id] then
      return
    end
    seen[id] = true
    local def = self.modules[id]
    local cat = self.catalog[id]
    if (cat and cat.hidden) or (def and def.hidden) then
      return -- e.g. the Auction House entry's parts: their settings are its pages
    end
    if def and def.visible then
      local ok, show = pcall(def.visible)
      if not (ok and show) then
        return -- e.g. Officer Tools for anyone who isn't an officer
      end
    end
    local info = self:GetInfo(id)
    local group = byName[info.group]
    if not group then
      local addon = self:GroupAddon(info.group)
      group = {
        name = info.group,
        label = info.groupLabel,
        addon = addon,
        installed = addon == nil or self:AddonExists(addon),
        loaded = addon == nil or self:IsAddonLoaded(addon),
        modules = {},
      }
      byName[info.group] = group
      groups[#groups + 1] = group
    end
    group.modules[#group.modules + 1] = info
  end
  for id in pairs(self.catalog) do
    add(id)
  end
  for id in pairs(self.modules) do
    add(id)
  end
  table.sort(groups, function(a, b)
    local ra, rb = GroupRank(a.name), GroupRank(b.name)
    if ra ~= rb then
      return ra < rb
    end
    return a.label:lower() < b.label:lower()
  end)
  for _, group in ipairs(groups) do
    -- Built-in entries (Settings) first, then A-Z.
    table.sort(group.modules, function(a, b)
      if a.builtin ~= b.builtin then
        return a.builtin
      end
      if a.builtin and a.order ~= b.order then
        return a.order < b.order
      end
      return a.title:lower() < b.title:lower()
    end)
  end
  return groups
end

-------------------------------------------------------------------------------
-- Changing state
-------------------------------------------------------------------------------

function ARLE:SetModuleEnabled(id, enabled)
  if not self.db then
    self:Print("Still loading.")
    return
  end
  if self.modules[id] and self.modules[id].builtin then
    return -- built-in entries are always on
  end
  if not self:Allowed() then
    self:Changed() -- put any toggle that was clicked back
    return
  end
  local def = self.modules[id]
  if enabled and self:MissingFor(id) then
    local title, why = self:MissingFor(id)
    self:Print((def and def.title or (self.catalog[id] and self.catalog[id].title) or id) .. " needs " .. title
      .. " (" .. why .. ").")
    self:Changed()
    return
  end
  local db = self:EnsureDB(id, def and def.defaults)
  db.enabled = enabled and true or false
  if db.enabled then
    if not def then
      self:LoadModuleAddon(id)
      def = self.modules[id]
    end
    if def then
      def.db = db
      def._error = nil
      ARLE.Debug:Reset(id) -- turned back on by the player: a fresh start for the breaker
      self:CallEnable(def)
    end
  elseif def then
    self:CallDisable(def)
  end
  self:Changed()
end

function ARLE:SetOption(id, key, value)
  local def = self.modules[id]
  if not def or not def.db then
    return
  end
  if not self:Allowed() then
    self:Changed()
    return
  end
  -- An option may keep its value elsewhere (opt.set), e.g. the theme.
  local opt = self:FindOption(id, key)
  if opt and self:OptionProblem(def, opt) then
    local title, why = self:OptionProblem(def, opt)
    self:Print((opt.label or key) .. " needs " .. title .. " (" .. why .. ").")
    self:Changed()
    return
  end
  if opt and opt.set then
    opt.set(value, def)
  else
    def.db[key] = value
  end
  if def._active and def.OnOptionChanged then
    Safe(def, def.OnOptionChanged, def, key, value)
  end
  self:Changed()
end

-- Settings back to their defaults. Lists (watched names, ignored spells) and
-- feature data (records, locks) are kept.
function ARLE:ResetOptions(id)
  local def = self.modules[id]
  if not def or not def.db then
    return
  end
  if not self:Allowed() then
    return
  end
  for _, opt in ipairs(def.options or {}) do
    if opt.key and opt.type ~= "list" then
      local value = opt.default
      if def.defaults and def.defaults[opt.key] ~= nil then
        value = def.defaults[opt.key]
      end
      if value ~= nil then
        self:SetOption(id, opt.key, value)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------

function ARLE:Startup()
  if self.ready then
    return
  end
  self:InitDB()
  self:Scan()
  self.ready = true
  local modules = self:CharModules()
  for id, cat in pairs(self.catalog) do
    local saved = modules[id]
    if cat.off and (type(saved) ~= "table" or saved.enabled == nil) then
      modules[id] = type(saved) == "table" and saved or {}
      modules[id].enabled = false
    end
    self:EnsureDB(id)
  end
  if self.OnStartup then
    Safe(nil, self.OnStartup, self)
  end
  -- Packs load only once the player is confirmed in the guild.
  self:ApplyGuild()
  self:Changed()
  self:AnnounceLogin()
end

function ARLE:OnAddonLoaded(name)
  if not self.unlocked then
    return
  end
  local changed = false
  for _, def in pairs(self.modules) do
    if def._waiting == name and def.db and def.db.enabled ~= false then
      self:CallEnable(def)
      changed = true
    end
  end
  if changed then
    self:Changed()
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" then
    if name == ADDON_NAME then
      ARLE:InitDB()
    else
      ARLE:OnAddonLoaded(name)
    end
  elseif event == "PLAYER_LOGIN" then
    Safe(nil, ARLE.Startup, ARLE) -- recorded under "ARL" and said in chat
  end
end)
