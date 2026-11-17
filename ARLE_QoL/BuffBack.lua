-- Buff Back: one key buffs back whoever buffed you, gives a buff to whoever
-- asks for it in chat, and keeps your group's buffs up, with a class x buff
-- grid deciding who gets what.
--
-- The idea and the Forever-specific know-how come from Manners by Sacha (MIT;
-- its spell data is in BuffBackData.lua with its notice). This file is ours,
-- written for ARL, and much smaller: no spoken lines, no thank-yous, no looks.
--
-- What WoW Forever allows, learned from Manners' notes:
--  * No combat log for addons. A favour is spotted when one of your buffs
--    appears (UNIT_AURA's addedAuras, never a full update: a loading screen
--    hands back everything you wear) and its sourceUnit names a player. A
--    stranger the client has no unit for (no nameplate) can't be named: that
--    favour is lost, which is a hard limit (friendly nameplates help).
--  * Conditional targeting ([@unit], [@name]) doesn't resolve, so the macro
--    targets by name: /targetexact <name>, /cast <spell>, then hands your
--    target back (/targetlasttarget [help], or /cleartarget if you had none).
--  * A macro doesn't lower the rank for a low-level target, and a cast lands
--    only within ten levels of its rank: the macro names "Spell(Rank N)".
--  * Chat text and aura fields can be secret values: never compared or kept.
--
-- The key is the host's secure macro button "BuffBack" (CLICK binding). Its
-- macro is re-armed out of combat on a ticker and again in PreClick (out of
-- combat), so a press casts on the best candidate at that moment; in combat the
-- last macro stays (secure attributes can't change there). A cast that
-- succeeds (UNIT_SPELLCAST_SUCCEEDED) settles the entry; three presses at the
-- same person that don't land drop them.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Data = ns.BuffBackData
local Skin, Kit, Secure = ARLE.Skin, ARLE.UI.Kit, ARLE.Secure

local MY_CLASS = select(2, UnitClass("player"))
local MY_BUFFS = Data.BUFFS[MY_CLASS] or {}
local EXCLUSIVE = MY_BUFFS.exclusive == true

local OWED_SECONDS = 180      -- a favour is returned by name for this long
local ASK_SECONDS = 60        -- an ask stands this long
local MAX_TRIES = 3           -- presses at one person that don't land
local GROUP_COOLDOWN = 60     -- a group member whose buff failed waits this long

local F = {
  id = "BuffBack",
  addon = ADDON,
  title = "Buff Back",
  group = "QualityOfLife",
  command = "buff",
  commandHelp = "one key buffs back whoever buffed you",
  description = "Somebody buffed you, asked for a buff, or is missing yours: one key casts it on them and gives "
    .. "your target back. Which buffs each class gets is set on Buffs by class.",
  pages = {
    { key = "who", label = "Who to buff" },
    { key = "classes", label = "Buffs by class",
      notes = "Tick the buffs each class gets from you. Paladins: one blessing per person, the first ticked "
        .. "one they don't already have." },
  },
  panePage = "classes",
  options = {
    { type = "info", text = function(def) return def:StatusLine() end },
    { type = "keybind", binding = Secure:Binding("BuffBack"), label = "Buff the next person" },
    { key = "display", type = "boolean", label = "Show what the key will do (movable line)", default = true },
    { key = "restoreTarget", type = "boolean", label = "Give my target back after the buff", default = true,
      cmd = "restore" },
    ARLE.Options.Preset.ResetPosition(),

    { key = "owed", type = "boolean", label = "People who buff me", default = true, page = "who" },
    { key = "asked", type = "boolean", label = "People who ask in chat (\"int pls\", \"buff pf\")", default = true,
      page = "who" },
    { key = "askStrangers", type = "boolean", label = "...also people outside my group", default = true,
      page = "who", cmd = "strangers", disabled = function(def) return not def.db.asked end },
    { key = "rebuff", type = "boolean", label = "My group: missing buffs", default = true, page = "who" },
    { key = "rebuffMinutes", type = "range", label = "...and mine with less than (minutes, 0 = only missing)",
      min = 0, max = 10, step = 1, default = 2, page = "who", cmd = "refresh",
      disabled = function(def) return not def.db.rebuff end },
    { key = "pvpSafe", type = "boolean", label = "Skip PvP-flagged players unless I'm flagged",
      default = true, page = "who", cmd = "pvp" },

    { type = "info", page = "classes", text = function(def) return def:GridNote() end },
    { type = "button", label = "Reset to defaults", page = "classes", nocmd = true, confirm = "Click again to reset",
      run = function(def)
        def.db.grid = {}
        def:RefreshGrid()
        def:Print("buffs by class reset to the defaults.")
      end },
  },
}

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

local issecret = _G.issecretvalue or function()
  return false
end
local function plain(v)
  if issecret(v) then
    return nil
  end
  return v
end

-- A table from the client that can be read (a secret one says "table" to
-- type() but throws when indexed or walked).
local function Readable(t)
  return type(t) == "table" and not issecret(t)
end

local myRealm
local function Realm()
  if not myRealm then
    myRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName():gsub("%s", ""))
  end
  return myRealm
end

-- "Name" for your own realm, "Name-Realm" otherwise.
local function NormalName(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local short, realm = name:match("^([^%-]+)%-(.+)$")
  if short and realm == Realm() then
    return short
  end
  return name
end

local function UnitFullName(unit)
  local ok, name, realm = pcall(UnitName, unit)
  name, realm = ok and plain(name), ok and plain(realm)
  if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
    return nil
  end
  if type(realm) == "string" and realm ~= "" then
    return NormalName(name .. "-" .. realm)
  end
  return name
end

local function Ask(fn, ...)
  if not fn then
    return nil
  end
  local ok, v = pcall(fn, ...)
  return ok and plain(v) or nil
end

local SpellName = function(id)
  if C_Spell and C_Spell.GetSpellName then
    return Ask(C_Spell.GetSpellName, id)
  end
  return Ask(GetSpellInfo, id)
end

local function SpellSubtext(id)
  return Ask(C_Spell and C_Spell.GetSpellSubtext or _G.GetSpellSubtext, id)
end

local function Knows(id)
  if IsPlayerSpell and Ask(IsPlayerSpell, id) then
    return true
  end
  return IsSpellKnown and Ask(IsSpellKnown, id) and true or false
end

local function InRange(id, unit)
  if C_Spell and C_Spell.IsSpellInRange then
    local r = Ask(C_Spell.IsSpellInRange, id, unit)
    if r ~= nil then
      return r == true or r == 1
    end
  end
  if _G.IsSpellInRange then
    local r = Ask(_G.IsSpellInRange, SpellName(id), unit)
    if r ~= nil then
      return r == 1 or r == true
    end
  end
  return nil -- the client won't say
end

local function Ignored(name)
  if C_FriendList and C_FriendList.IsIgnored then
    return Ask(C_FriendList.IsIgnored, name) == true
  end
  return false
end

-------------------------------------------------------------------------------
-- Your buffs: which you know, at which ranks
-------------------------------------------------------------------------------

local knownCache -- [buff] = { known rank ids, highest first } or false

local function KnownRanks(buff)
  knownCache = knownCache or {}
  local k = knownCache[buff]
  if k == nil then
    k = {}
    for _, id in ipairs(buff.ranks) do
      if Knows(id) then
        k[#k + 1] = id
      end
    end
    if #k == 0 then
      k = false
    end
    knownCache[buff] = k
  end
  return k or nil
end

local function KnownBuffs()
  local out = {}
  for _, buff in ipairs(MY_BUFFS) do
    if KnownRanks(buff) then
      out[#out + 1] = buff
    end
  end
  return out
end

local function BuffLabel(buff)
  return SpellName(buff.ranks[#buff.ranks]) or SpellName(buff.ranks[1]) or buff.key
end

-- The rank that lands on somebody of `level` (within ten levels), and the
-- name the macro casts it by; nil when even the lowest is too high.
local function CastFor(buff, level)
  local ranks = KnownRanks(buff)
  if not ranks then
    return nil
  end
  local top = ranks[1]
  local name = SpellName(top)
  if not name then
    return nil
  end
  if type(level) ~= "number" or level < 1 then
    return top, name
  end
  for i, id in ipairs(ranks) do
    if (Data.RANK_LEVEL[id] or 1) - 10 <= level then
      if i == 1 then
        return id, name -- the plain name casts your best rank
      end
      local sub = SpellSubtext(id)
      return id, sub and sub ~= "" and (name .. "(" .. sub .. ")") or name
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- The grid: which classes get which of your buffs
-------------------------------------------------------------------------------

local function Default(class, buff)
  if buff.optIn then
    return false
  end
  if buff.manaOnly and not Data.MANA[class] then
    return false
  end
  if buff.meleeOnly and Data.CASTERS[class] then
    return false
  end
  if buff.tanks and not Data.TANKS[class] then
    return false
  end
  return true
end

-- class may be nil (somebody whose class nobody could read): the buff's own
-- opt-in decides.
function F:Gets(class, buff)
  if not class then
    return not buff.optIn
  end
  local row = type(self.db.grid) == "table" and self.db.grid[class] or nil
  local v = nil
  if type(row) == "table" then
    v = row[buff.key]
  end
  if v ~= nil then
    return v == true
  end
  return Default(class, buff)
end

function F:SetGets(class, buff, on)
  if type(self.db.grid) ~= "table" then
    self.db.grid = {}
  end
  local row = self.db.grid[class] or {}
  self.db.grid[class] = row
  if on == Default(class, buff) then
    row[buff.key] = nil -- back to the default
  else
    row[buff.key] = on and true or false
  end
end

-------------------------------------------------------------------------------
-- Reading somebody's buffs
-------------------------------------------------------------------------------

-- { ids = { [spellId] = true }, mine = { [spellId] = expirationTime },
--   unreadable = true when any field was secret }
local function ReadAuras(unit)
  local out = { ids = {}, mine = {} }
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    out.unreadable = true
    return out
  end
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
    if not ok then
      out.unreadable = true
      break
    end
    if not aura then
      break
    end
    local id = Readable(aura) and plain(aura.spellId)
    if not id then
      out.unreadable = true
    else
      out.ids[id] = true
      local src = plain(aura.sourceUnit)
      if src == "player" then
        out.mine[id] = plain(aura.expirationTime) or 0
      end
    end
  end
  return out
end

local function Wears(auras, buff)
  for _, list in ipairs({ buff.ranks, buff.group or {}, buff.blockers or {} }) do
    for _, id in ipairs(list) do
      if auras.ids[id] then
        return true, id
      end
    end
  end
end

-- Yours, on them, ending within `lead` seconds (0: never counts as ending).
local function Ending(auras, buff, lead)
  if lead <= 0 then
    return false
  end
  local now = GetTime()
  for _, list in ipairs({ buff.ranks, buff.group or {} }) do
    for _, id in ipairs(list) do
      local exp = auras.mine[id]
      if exp and exp > 0 and exp - now < lead then
        return true
      end
    end
  end
  return false
end

-- A paladin: one of your blessings is on them already.
local function HasMyBlessing(auras)
  for _, buff in ipairs(MY_BUFFS) do
    for _, list in ipairs({ buff.ranks, buff.group or {} }) do
      for _, id in ipairs(list) do
        if auras.mine[id] then
          return buff
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Finding people
-------------------------------------------------------------------------------

local function GroupUnits()
  local out = {}
  if IsInRaid and IsInRaid() then
    for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do
      out[#out + 1] = "raid" .. i
    end
  else
    for i = 1, (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0) do
      out[#out + 1] = "party" .. i
    end
  end
  return out
end

-- A unit token that is `name` right now, or nil.
local function FindUnit(name)
  for _, unit in ipairs(GroupUnits()) do
    if UnitFullName(unit) == name then
      return unit
    end
  end
  for _, unit in ipairs({ "target", "mouseover", "focus" }) do
    if Ask(UnitExists, unit) and Ask(UnitIsPlayer, unit) and UnitFullName(unit) == name then
      return unit
    end
  end
  for i = 1, 40 do
    local unit = "nameplate" .. i
    if Ask(UnitExists, unit) and Ask(UnitIsPlayer, unit) and UnitFullName(unit) == name then
      return unit
    end
  end
end

local function InGroup(unit)
  return (Ask(UnitInParty, unit) or Ask(UnitInRaid, unit)) and true or false
end

-------------------------------------------------------------------------------
-- The queue
-------------------------------------------------------------------------------

local owed = {}     -- [name] = { name, class, level, at, pvp }
local asked = {}    -- [name] = { name, at, keys = {[key]=true} | nil (any), group = chat was group chat }
local tries = {}    -- [name] = presses that didn't land
local resting = {}  -- [name] = GetTime() until which a group member is skipped
local pending       -- the entry the last press was for
local current       -- the entry armed on the key now

local function Forget(name)
  owed[name], asked[name], tries[name] = nil, nil, nil
end

-- The buff for somebody, or nil and why. who = { name, class, level, unit,
-- reason = "asked" | "owed" | "group", keys = asked-for set or nil }
function F:Choose(who)
  local auras = who.unit and ReadAuras(who.unit)
  if auras and auras.unreadable and who.reason == "group" then
    return nil, "their buffs can't be read here"
  end
  -- (Asked for a blessing by name: they get it, even over yours.)
  if EXCLUSIVE and not who.keys and auras and not auras.unreadable and HasMyBlessing(auras) then
    -- One blessing from you at a time: refresh only the one they have.
    local mine = HasMyBlessing(auras)
    if who.reason == "group" and Ending(auras, mine, (self.db.rebuffMinutes or 0) * 60) then
      local id, cast = CastFor(mine, who.level)
      if id then
        return mine, cast, id
      end
    end
    return nil, "already has your blessing"
  end
  local why = "nothing they need"
  for _, buff in ipairs(MY_BUFFS) do
    local ranks = KnownRanks(buff)
    local named = who.keys and who.keys[buff.key]
    local skip
    if not ranks then
      skip = "unknown"
    elseif who.keys and not named then
      skip = "not asked for"
    elseif not named and not self:Gets(who.class, buff) then
      skip = "off for the class"
    elseif buff.returnOnly and who.reason == "group" then
      skip = "return only"
    elseif buff.returnOnly and who.reason == "asked" and not named then
      skip = "return only"
    elseif (buff.membersOnly or buff.selfCast) and not who.inGroup then
      skip = "group only"
    elseif buff.selfCast and who.reason == "group" then
      skip = "a shout isn't kept up"
    end
    if not skip and auras and not auras.unreadable then
      local wears = Wears(auras, buff)
      if wears and not (who.reason == "group" and Ending(auras, buff, (self.db.rebuffMinutes or 0) * 60)) then
        skip = "has it"
      end
    end
    if not skip then
      local id, cast = CastFor(buff, who.level)
      if not id then
        skip = "too low level"
      elseif who.unit and not buff.selfCast and InRange(id, who.unit) == false then
        skip = "out of range"
      else
        return buff, cast, id
      end
    end
    why = skip
  end
  return nil, why
end

local function UsableUnit(self, unit)
  if not unit then
    return true
  end
  if Ask(UnitIsDeadOrGhost, unit) or Ask(UnitIsConnected, unit) == false then
    return false, "dead or offline"
  end
  if Ask(UnitCanAssist, "player", unit) == false then
    return false, "can't be helped"
  end
  if self.db.pvpSafe and Ask(UnitIsPVP, unit) and not Ask(UnitIsPVP, "player") then
    return false, "PvP flagged"
  end
  return true
end

-- Somebody in the queue with what to cast on them, best first: asked, owed
-- (oldest first), then the group.
function F:Next()
  if InCombatLockdown() then
    return current
  end
  local now = GetTime()
  local list = {}
  for name, a in pairs(asked) do
    if now - a.at > ASK_SECONDS then
      asked[name] = nil
    else
      list[#list + 1] = { name = name, reason = "asked", keys = a.keys, at = a.at }
    end
  end
  for name, o in pairs(owed) do
    if now - o.at > OWED_SECONDS then
      owed[name] = nil
    else
      list[#list + 1] = { name = name, reason = "owed", class = o.class, level = o.level, at = o.at }
    end
  end
  table.sort(list, function(a, b)
    if a.reason ~= b.reason then
      return a.reason == "asked"
    end
    return a.at < b.at
  end)
  for _, who in ipairs(list) do
    who.unit = FindUnit(who.name)
    if who.unit then
      who.class = plain(select(2, UnitClass(who.unit))) or who.class
      local level = Ask(UnitLevel, who.unit)
      who.level = type(level) == "number" and level > 0 and level or who.level
      who.inGroup = InGroup(who.unit)
    end
    if who.reason == "asked" and not who.unit then
      -- An ask names no place: only somebody the client can see is answered.
      self:Debug("%s asked, but isn't in view", who.name)
    else
      local ok, why = UsableUnit(self, who.unit)
      if ok then
        local buff, cast, id = self:Choose(who)
        if buff then
          who.buff, who.cast, who.spell = buff, cast, id
          return who
        end
        why = cast
      end
      self:Debug("%s (%s): skipped, %s", who.name, who.reason, tostring(why))
    end
  end
  if self.db.rebuff then
    for _, unit in ipairs(GroupUnits()) do
      local name = UnitFullName(unit)
      if name and not (resting[name] and now < resting[name]) and Ask(UnitIsVisible, unit) then
        local who = { name = name, unit = unit, reason = "group", inGroup = true,
          class = plain(select(2, UnitClass(unit))) }
        local level = Ask(UnitLevel, unit)
        who.level = type(level) == "number" and level > 0 and level or nil
        if UsableUnit(self, unit) then
          local buff, cast, id = self:Choose(who)
          if buff then
            who.buff, who.cast, who.spell = buff, cast, id
            return who
          end
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- The key
-------------------------------------------------------------------------------

local function Macro(who)
  if who.buff.selfCast then
    return "/cast " .. who.cast
  end
  local lines = { "/targetexact " .. who.name, "/cast " .. who.cast }
  if F.db.restoreTarget then
    if not Ask(UnitExists, "target") then
      lines[#lines + 1] = "/cleartarget"
    elseif UnitFullName("target") ~= who.name then
      -- Only when the /targetexact found them (a friendly target now): if it
      -- didn't, your own target is still there and stays.
      lines[#lines + 1] = "/targetlasttarget [help]"
    end
  end
  return table.concat(lines, "\n")
end

local armedText

function F:Arm()
  local button = Secure:Button("BuffBack")
  if not button or InCombatLockdown() then
    return
  end
  current = self:Next()
  local text = current and Macro(current) or nil
  if text ~= armedText then
    armedText = text
    button:SetAttribute("type", "macro")
    button:SetAttribute("macrotext", text)
    if current then
      self:Debug("armed: %s -> %s (%s)", current.cast, current.name, current.reason)
    else
      self:Debug("armed: nothing")
    end
  end
  self:Paint()
end

local function Settle(self, spellID)
  local p = pending
  if not p or GetTime() - p.at > 5 then
    return
  end
  for _, id in ipairs(p.buff.ranks) do
    if id == spellID then
      pending = nil
      self:Debug("landed: %s on %s", p.cast, p.name)
      tries[p.name] = nil
      if p.reason == "owed" then
        owed[p.name] = nil -- returned (by name, we can't always read their buffs again)
      elseif p.reason == "asked" and asked[p.name] then
        -- Asked: they're in view, so their buffs say what's still missing;
        -- a buff asked for by name is done once it lands.
        local keys = asked[p.name].keys
        if keys then
          keys[p.buff.key] = nil
          if next(keys) == nil then
            asked[p.name] = nil
          end
        end
      end
      self:Debounce("arm", 0.3, self.Arm)
      return
    end
  end
end

local function Pressed(self)
  local who = current
  if not who then
    return
  end
  pending = { name = who.name, reason = who.reason, buff = who.buff, cast = who.cast, at = GetTime() }
  local n = (tries[who.name] or 0) + 1
  tries[who.name] = n
  if n >= MAX_TRIES then
    -- Three presses and nothing landed: out of reach, gone, or refused.
    self:Debug("%s: %d presses without a cast, dropped", who.name, n)
    if who.reason == "group" then
      resting[who.name] = GetTime() + GROUP_COOLDOWN
      tries[who.name] = nil
    else
      Forget(who.name)
    end
  end
  self:Debounce("arm", 1, self.Arm)
end

local function SetupButton(self)
  local b = Secure:Button("BuffBack")
  if not b then
    return
  end
  b:SetAttribute("type", "macro")
  b:SetAttribute("macrotext", nil)
  armedText = nil
  -- Re-armed at the last moment out of combat, so the press is for whoever
  -- is best now (a target changed, somebody walked out of range).
  b:SetScript("PreClick", function()
    if F._active and not InCombatLockdown() then
      ARLE.Debug.Call(F, F.Arm, F)
    end
  end)
  b:SetScript("PostClick", function()
    if F._active then
      ARLE.Debug.Call(F, Pressed, F)
    end
  end)
end

local function ReleaseButton()
  local b = Secure:Button("BuffBack")
  if not b or F._active then
    return
  end
  b:SetAttribute("macrotext", nil)
  b:SetScript("PreClick", nil)
  b:SetScript("PostClick", nil)
  armedText = nil
end

-------------------------------------------------------------------------------
-- Noticing favours
-------------------------------------------------------------------------------

local function Noticed(self, aura)
  local id = Readable(aura) and plain(aura.spellId)
  if not id or not Data.FAVOUR_IDS[id] then
    return
  end
  local source = plain(aura.sourceUnit)
  if not source or source == "player" or Ask(UnitIsUnit, source, "player") then
    if not source then
      self:Debug("buffed with %s by somebody the client can't name", tostring(SpellName(id) or id))
    end
    return
  end
  if not Ask(UnitIsPlayer, source) then
    return
  end
  local name = UnitFullName(source)
  if not name or Ignored(name) then
    return
  end
  local level = Ask(UnitLevel, source)
  owed[name] = {
    name = name,
    class = plain(select(2, UnitClass(source))),
    level = type(level) == "number" and level > 0 and level or nil,
    at = GetTime(),
  }
  tries[name] = nil
  self:Debug("%s buffed you (%s)", name, tostring(SpellName(id) or id))
  self:Debounce("arm", 0.2, self.Arm)
end

-- Fallback for a UNIT_AURA without its update info: auras by instance id,
-- the first reading after a zone change taken as the baseline.
local seenIds, baselined = {}, false
-- Just after a loading screen the client may hand back what you wear as new.
local quietUntil = 0

local function WalkOwn(self)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    return
  end
  local now = {}
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
    if not ok or not aura then
      break
    end
    local inst = Readable(aura) and plain(aura.auraInstanceID)
    if inst then
      now[inst] = true
      if baselined and not seenIds[inst] then
        Noticed(self, aura)
      end
    end
  end
  seenIds, baselined = now, true
end

function F:OnOwnAura(_, _, info)
  if not self.db.owed or #MY_BUFFS == 0 then
    return
  end
  if GetTime() < quietUntil then
    baselined = false
    return
  end
  -- The client can hand back the update, or its list of added auras, as a
  -- secret table (in combat, in an instance): type() says "table", but it
  -- can't be read or walked. Then the walk by instance id decides instead.
  local added = Readable(info) and Readable(info.addedAuras) and info.addedAuras
  if Readable(info) and not plain(info.isFullUpdate) and added then
    for _, aura in ipairs(added) do
      if Readable(aura) and not plain(aura.isHarmful) then
        Noticed(self, aura)
      end
    end
  elseif Readable(info) and plain(info.isFullUpdate) then
    -- A full update (zoning, a reload): what is on you now is no favour.
    baselined = false
    WalkOwn(self)
  else
    WalkOwn(self)
  end
end

-------------------------------------------------------------------------------
-- Asks in chat
-------------------------------------------------------------------------------

-- name -> buff key, for the buffs you know; loose names flagged.
local askIndex

local function BuildAskIndex()
  askIndex = { words = {}, phrases = {} }
  for _, buff in ipairs(KnownBuffs()) do
    for _, raw in ipairs(Data.ASK_NAMES[buff.key] or {}) do
      local loose = raw:sub(1, 1) == "~"
      local name = loose and raw:sub(2) or raw
      if name:find(" ", 1, true) then
        askIndex.phrases[#askIndex.phrases + 1] = { text = name, key = buff.key, loose = loose }
      else
        askIndex.words[name] = { key = buff.key, loose = loose }
      end
    end
    -- The spell's own name on this client (any language).
    local own = BuffLabel(buff):lower()
    askIndex.phrases[#askIndex.phrases + 1] = { text = own, key = buff.key }
  end
end

-- The buffs a message asks for: a set of keys, or "any" for "buff pls"; nil
-- when it isn't a request.
local function ParseAsk(text, groupChat)
  if not askIndex then
    BuildAskIndex()
  end
  local lower = " " .. text:lower():gsub("[%p]", function(c)
    return c == "?" and " ? " or " "
  end) .. " "
  lower = lower:gsub("%s+", " ")
  local words = {}
  for w in lower:gmatch("%S+") do
    words[#words + 1] = w
  end
  if #words == 0 or #words > 8 then
    return nil
  end
  local keys, named, generic, please, loose = {}, false, false, false, false
  local covered = {} -- word positions that are part of a buff name
  for _, p in ipairs(askIndex.phrases) do
    local s = lower:find(" " .. p.text .. " ", 1, true)
    if s and not (p.loose and groupChat) then
      keys[p.key] = true
      named = true
      loose = loose or p.loose
      for w in p.text:gmatch("%S+") do
        covered[w] = true
      end
    end
  end
  local filler = true
  for _, w in ipairs(words) do
    local entry = askIndex.words[w]
    if Data.NO[w] then
      return nil
    elseif entry and not (entry.loose and groupChat) then
      keys[entry.key] = true
      named = true
      loose = loose or entry.loose
    elseif Data.GENERIC[w] then
      generic = true
    elseif Data.PLEASE[w] then
      please = true
    elseif w ~= "?" and not covered[w] and not Data.FILLER[w] then
      filler = false
    end
  end
  if not named and not generic then
    return nil
  end
  local question = words[#words] == "?" and named and not loose and words[1] ~= "who" and words[1] ~= "quem"
  if not (please or filler or question) then
    return nil
  end
  if loose and not (please or #words == 1) then
    return nil
  end
  if generic and not named then
    return "any"
  end
  return keys
end

local GROUP_CHAT = { CHAT_MSG_PARTY = true, CHAT_MSG_PARTY_LEADER = true, CHAT_MSG_RAID = true,
  CHAT_MSG_RAID_LEADER = true, CHAT_MSG_INSTANCE_CHAT = true, CHAT_MSG_INSTANCE_CHAT_LEADER = true }

function F:OnChat(event, text, sender)
  if not self.db.asked or #MY_BUFFS == 0 then
    return
  end
  text, sender = plain(text), plain(sender)
  if type(text) ~= "string" or type(sender) ~= "string" then
    return
  end
  local name = NormalName(sender)
  if not name or name == UnitFullName("player") or Ignored(name) then
    return
  end
  local groupChat = GROUP_CHAT[event] or false
  if not self.db.askStrangers and not groupChat then
    local unit = FindUnit(name)
    if not (unit and InGroup(unit)) then
      return
    end
  end
  local keys = ParseAsk(text, groupChat)
  if not keys then
    return
  end
  asked[name] = { name = name, at = GetTime(), keys = keys ~= "any" and keys or nil }
  tries[name] = nil
  self:Debug("%s asked: \"%s\"", name, text)
  self:Debounce("arm", 0.2, self.Arm)
end

-------------------------------------------------------------------------------
-- The line that shows what the key will do
-------------------------------------------------------------------------------

local line
local placeLine -- Kit.Movable's

local function PlaceLine()
  if placeLine then
    placeLine()
  end
end

local REASON = { asked = "asked", owed = "buffed you", group = "group" }

local function BuildLine()
  local f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetSize(320, 26)
  f:SetFrameStrata("MEDIUM")
  placeLine = Kit.Movable(f, F, { y = -160 })
  f.text = Kit.Text(f, "GameFontHighlightSmall")
  f.text:SetPoint("LEFT", 8, 0)
  f.text:SetPoint("RIGHT", -8, 0)
  f.text:SetWordWrap(false)
  f:Hide()
  line = f
end

local function QueueCount()
  local n = 0
  for _ in pairs(owed) do
    n = n + 1
  end
  for name in pairs(asked) do
    if not owed[name] then
      n = n + 1
    end
  end
  return n
end

function F:Paint()
  if not self.db.display or not current then
    if line then
      line:Hide()
    end
    return
  end
  if not line then
    BuildLine()
  end
  local key = Secure:BoundKey("BuffBack")
  local more = QueueCount() - ((current.reason ~= "group") and 1 or 0)
  line.text:SetText(string.format("%s%s |cffffffff→ %s|r |cff9d9d9d(%s)%s|r",
    key and ("|cffffd100[" .. key .. "]|r ") or "|cffff6060[no key]|r ", current.cast, current.name,
    REASON[current.reason] or current.reason, more > 0 and ("  +" .. more) or ""))
  line:SetWidth(math.min(460, line.text:GetStringWidth() + 18))
  line:Show()
end

function F:OnResetPosition()
  PlaceLine()
end

-------------------------------------------------------------------------------
-- The grid pane (Buffs by class)
-------------------------------------------------------------------------------

-- Narrow columns: a paladin's three fit the panel; long spell names wrap
-- onto two lines (whatever the client's language).
local ROW_H, LABEL_W, COL_W, HEAD_H = 21, 84, 86, 26

function F:GridNote()
  if #MY_BUFFS == 0 then
    return "Your class has no buffs to give others, so there is nothing to set here."
  end
  local known = KnownBuffs()
  if #known == 0 then
    return "You don't know any of your class's buffs for others yet."
  end
  return "Defaults: Intellect and Wisdom go to classes with mana, Might skips casters, Thorns goes to tanks, "
    .. "and Shadow Protection and Detect Invisibility are off until ticked."
end

function F:CreatePane(pane)
  pane.cells = {}
  if #MY_BUFFS == 0 then
    return
  end
  for c, buff in ipairs(MY_BUFFS) do
    local head = Kit.Text(pane, "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", LABEL_W + (c - 1) * COL_W, 0)
    head:SetSize(COL_W - 6, HEAD_H)
    head:SetJustifyV("BOTTOM")
    head:SetWordWrap(true)
    head:SetText(BuffLabel(buff))
    pane["head" .. c] = head
  end
  for r, class in ipairs(Data.CLASSES) do
    local y = -(HEAD_H + 4) - (r - 1) * ROW_H
    local label = Kit.Text(pane, "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, y - 4)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local text = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
    label:SetText(color and ("|c" .. (color.colorStr or "ffffffff") .. text .. "|r") or text)
    for c, buff in ipairs(MY_BUFFS) do
      local check = Kit.Check(pane)
      check:SetPoint("TOPLEFT", LABEL_W + (c - 1) * COL_W - 2, y)
      -- HookScript, not SetScript: the theme's switch moves its knob from
      -- its own OnClick hook, which SetScript would throw away.
      check:HookScript("OnClick", function(btn)
        ARLE.Debug.Call(F, function()
          F:SetGets(class, buff, btn:GetChecked() and true or false)
          btn:SetChecked(F:Gets(class, buff)) -- what's stored now, and repaints the switch
          if F._active then
            F:Debounce("arm", 0.2, F.Arm)
          end
        end)
      end)
      pane.cells[#pane.cells + 1] = { check = check, class = class, buff = buff }
    end
  end
  self.pane = pane
end

function F:RefreshPane(pane)
  for _, cell in ipairs(pane.cells or {}) do
    cell.check:SetChecked(self:Gets(cell.class, cell.buff))
    local known = KnownRanks(cell.buff) ~= nil
    cell.check:SetAlpha(known and 1 or 0.4)
  end
end

function F:RefreshGrid()
  if self.pane then
    self:RefreshPane(self.pane)
  end
  ARLE:Changed()
end

-------------------------------------------------------------------------------
-- Status
-------------------------------------------------------------------------------

function F:StatusLine()
  if #MY_BUFFS == 0 then
    return "Your class has no buffs for others: nothing to do."
  end
  local key = Secure:BoundKey("BuffBack")
  local head = key and ("Key: " .. key) or "|cffff6060No key set|r (Key bindings > AddOns > Buff Back)"
  if current then
    return head .. "  ·  next: " .. current.cast .. " → " .. current.name .. " (" .. (REASON[current.reason] or "")
      .. ")"
  end
  return head .. "  ·  nobody to buff right now"
end

function F:GetStatus()
  return "Active · " .. self:StatusLine()
end

function F:PrintQueue()
  local now = GetTime()
  local any = false
  for name, a in pairs(asked) do
    any = true
    self:Print(string.format("asked: %s, %ds ago", name, now - a.at))
  end
  for name, o in pairs(owed) do
    any = true
    self:Print(string.format("buffed you: %s (%s, level %s), %ds ago", name, tostring(o.class),
      tostring(o.level or "?"), now - o.at))
  end
  if not any then
    self:Print("nobody waiting. " .. self:StatusLine())
  else
    self:Print(self:StatusLine())
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Relearn(self)
  knownCache, askIndex = nil, nil
  self:Debounce("arm", 0.5, self.Arm)
end

function F:OnEnable()
  wipe(owed)
  wipe(asked)
  wipe(tries)
  wipe(resting)
  pending, current = nil, nil
  seenIds, baselined = {}, false
  knownCache, askIndex = nil, nil
  if type(self.db.grid) ~= "table" then
    self.db.grid = {}
  end
  SetupButton(self)
  self:OnUnit("UNIT_AURA", "player", self.OnOwnAura)
  self:OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(def, _, _, _, spellID)
    Settle(def, plain(spellID))
  end)
  self:On("PLAYER_ENTERING_WORLD", function(def)
    baselined = false
    quietUntil = GetTime() + 3
    def:Debounce("baseline", 3.5, WalkOwn)
  end)
  for _, e in ipairs({ "SPELLS_CHANGED", "PLAYER_LEVEL_UP", "LEARNED_SPELL_IN_SKILL_LINE" }) do
    self:On(e, Relearn)
  end
  for _, e in ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER" }) do
    self:On(e, self.OnChat)
  end
  self:On("GROUP_ROSTER_UPDATE", function(def)
    def:Debounce("arm", 0.5, def.Arm)
  end)
  self:On("PLAYER_TARGET_CHANGED", function(def)
    def:Debounce("arm", 0.2, def.Arm) -- the hand-back line depends on it
  end)
  self:On("UPDATE_BINDINGS", function(def)
    def:Paint()
  end)
  self:On("PLAYER_REGEN_ENABLED", function(def)
    def:Arm()
  end)
  -- Range, levels, expiring buffs and old entries change without events.
  self:Ticker(1, function(def)
    if not InCombatLockdown() then
      def:Arm()
    end
  end)
  WalkOwn(self)
  self:Arm()
end

function F:OnDisable()
  wipe(owed)
  wipe(asked)
  pending, current = nil, nil
  if line then
    line:Hide()
  end
  -- (Secure:Run, not OutOfCombat: OutOfCombat drops work once the feature is off.)
  Secure:Run(ReleaseButton)
end

function F:OnOptionChanged()
  self:Arm()
end

-- Manners keeps an AceDB profile per character (MannersDB.profileKeys).
-- Taken: buffs it skips or opted into (as the grid, for every class), whether
-- it gives your target back, and whether it answers strangers.
function F:Import()
  local db = _G.MannersDB
  if type(db) ~= "table" or type(db.profiles) ~= "table" then
    return
  end
  local charKey = (UnitName("player") or "") .. " - " .. (GetRealmName and GetRealmName() or "")
  local profileName = type(db.profileKeys) == "table" and db.profileKeys[charKey] or "Default"
  local profile = db.profiles[profileName]
  if type(profile) ~= "table" then
    return
  end
  local buff = type(profile.buff) == "table" and profile.buff or {}
  for _, b in ipairs(MY_BUFFS) do
    local off = type(buff.skip) == "table" and buff.skip[b.key]
    local on = type(buff.optIn) == "table" and buff.optIn[b.key]
    if off or on then
      for _, class in ipairs(Data.CLASSES) do
        self:SetGets(class, b, on and not off)
      end
    end
  end
  local filters = type(profile.filters) == "table" and profile.filters or {}
  if type(filters.restoreTarget) == "boolean" then
    self.db.restoreTarget = filters.restoreTarget
  end
  local sources = type(profile.sources) == "table" and profile.sources or {}
  if sources.strangers == false then
    self.db.askStrangers = false
  end
end

F.commands = {
  { name = "queue", help = "who is waiting for a buff, and what the key will do", always = true,
    run = function(self) self:PrintQueue() end },
  { name = "clear", help = "empties the queue", run = function(self)
    wipe(owed)
    wipe(asked)
    wipe(tries)
    self:Arm()
    self:Print("queue cleared.")
  end },
}

ARLE:RegisterModule(F)
