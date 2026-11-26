-- Saved variables:
--   ARLExtensionsCharDB (this character)
--     .modules[id]   each feature's settings and its on/off switch (def.db)
--     .features[id]  each feature's data: item locks, gear set links,
--                    remembered weapons (def.char)
--     .settingsCopyStamp  the settings copy (below) this character has applied
--   ARLExtensionsDB (account wide)
--     theme, accent, loginMessage (how the window looks)
--     .settingsCopy  settings one character copied to all the others
--     .modules[id]   data a feature shares between characters (def.shared),
--                    e.g. Darkmoon ticket counts learned from quest windows.
--                    Before 0.2 this also held every feature's settings;
--                    each character starts from a copy of those.
local _, ns = ...
local ARLE = ns.ARLE

local pending -- features registered before the saved variables loaded

local function DeepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = DeepCopy(v)
  end
  return out
end

-- self.shared keys (Layer Bridge's books, book (before 0.14) and asked,
-- Darkmoon's learned counts, Dungeon Helper's board): data, not settings.
local SHARED_ONLY = { book = true, books = true, asked = true, learned = true, board = true }

local function CharSV()
  local sv = _G.ARLExtensionsCharDB
  if type(sv) ~= "table" then
    sv = {}
    _G.ARLExtensionsCharDB = sv
  end
  return sv
end

-- This character's settings for every feature. The first time a character
-- logs in with per-character settings it gets a copy of the account-wide
-- ones, so nothing it had resets.
function ARLE:CharModules()
  local sv = CharSV()
  if type(sv.modules) ~= "table" then
    local account = self.db and self.db.modules
    sv.modules = type(account) == "table" and DeepCopy(account) or {}
    -- The same account table also holds data all characters share (self.shared):
    -- that stays there, not copied into every new character's settings.
    for _, t in pairs(sv.modules) do
      if type(t) == "table" then
        for key in pairs(SHARED_ONLY) do
          t[key] = nil
        end
      end
    end
  end
  return sv.modules
end

-- The account-wide table of feature id (shared between characters).
function ARLE:SharedDB(id)
  local modules = self.db.modules
  local t = modules[id]
  if type(t) ~= "table" then
    t = {}
    modules[id] = t
  end
  return t
end

-- A feature's settings on this character, or nil when it has none yet.
function ARLE:ModuleDB(id)
  if not self.db then
    return nil
  end
  local db = self:CharModules()[id]
  return type(db) == "table" and db or nil
end

function ARLE:EnsureDB(id, defaults)
  local modules = self:CharModules()
  local db = modules[id]
  if type(db) ~= "table" then
    db = {}
    modules[id] = db
  end
  if defaults then
    for key, value in pairs(defaults) do
      if db[key] == nil then
        if type(value) == "table" then
          -- Tables (lists, maps) are copied so features never share one.
          local copy = {}
          for k, v in pairs(value) do
            copy[k] = v
          end
          db[key] = copy
        else
          db[key] = value
        end
      end
    end
  end
  if db.enabled == nil then
    db.enabled = true
  end
  return db
end

-- This character's table for one feature.
function ARLE:CharDB(id)
  local sv = CharSV()
  sv.features = type(sv.features) == "table" and sv.features or {}
  local t = sv.features[id]
  if type(t) ~= "table" then
    t = {}
    sv.features[id] = t
  end
  return t
end

-------------------------------------------------------------------------------
-- Copying settings to every character
-------------------------------------------------------------------------------
-- A character's file can only be written while it is logged in, so a copy is
-- a snapshot in the account table (ARLExtensionsDB.settingsCopy = { stamp,
-- from, at, modules }) that every other character applies once at its next
-- load (ARLExtensionsCharDB.settingsCopyStamp), before any feature binds.
-- Only settings (modules[id], the on/off switches included) are copied, never
-- a character's data (features[id]: item locks, positions, gear set links).

-- A list (lists of names, Rare Objectives' manual list) is replaced whole.
local function IsList(t)
  return type(t) == "table" and (next(t) == nil or t[1] ~= nil)
end

-- Copies `from` into `into` key by key, so keys only the target has stay
-- (Buff Back's grid holds a row per class: another class's row is kept).
local function Merge(into, from)
  for key, value in pairs(from) do
    if type(value) == "table" and not IsList(value) and type(into[key]) == "table" and not IsList(into[key]) then
      Merge(into[key], value)
    else
      into[key] = DeepCopy(value)
    end
  end
end

-- Takes a snapshot of this character's settings for the others. Returns how
-- many features it holds.
function ARLE:CopySettingsToAll()
  local modules = DeepCopy(self:CharModules())
  local count = 0
  for _, t in pairs(modules) do
    if type(t) == "table" then
      count = count + 1
      for key in pairs(SHARED_ONLY) do
        t[key] = nil
      end
    end
  end
  local now = time()
  local from = self:MyName() or "?"
  local stamp = now .. ":" .. from
  self.db.settingsCopy = { stamp = stamp, from = from, at = now, modules = modules }
  CharSV().settingsCopyStamp = stamp -- (its own settings already are these)
  return count
end

-- The copy waiting in the account table, and whether this character has it.
function ARLE:SettingsCopyInfo()
  local copy = self.db and self.db.settingsCopy
  if type(copy) ~= "table" or type(copy.modules) ~= "table" then
    return nil
  end
  return copy, CharSV().settingsCopyStamp == copy.stamp
end

local function ApplySettingsCopy()
  local copy, applied = ARLE:SettingsCopyInfo()
  if not copy or applied then
    return
  end
  Merge(ARLE:CharModules(), copy.modules)
  CharSV().settingsCopyStamp = copy.stamp
  ARLE.settingsCopiedFrom = tostring(copy.from or "another character") -- said at login (AnnounceLogin)
end

function ARLE:QueueBind(def)
  pending = pending or {}
  pending[#pending + 1] = def
end

function ARLE:InitDB()
  if self.db then
    return
  end
  local sv = _G.ARLExtensionsDB
  if type(sv) ~= "table" then
    sv = {}
    _G.ARLExtensionsDB = sv
  end
  if type(sv.modules) ~= "table" then
    sv.modules = {}
  end
  -- ARL is the default theme. Versions before 0.3.0 wrote "auto" for
  -- everyone who never picked one, so that moves to ARL once.
  if sv.theme == nil or (sv.theme == "auto" and not sv.themeV3) then
    sv.theme = "arl"
  end
  sv.themeV3 = true
  self.db = sv
  self:CharModules() -- seeds this character's settings once
  ApplySettingsCopy() -- (before any feature reads its settings)
  if pending then
    local queued = pending
    pending = nil
    for i = 1, #queued do
      self:Bind(queued[i])
    end
  end
end
