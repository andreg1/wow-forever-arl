-- ARLE.Lib: small helpers shared by every feature (no UI here).
local _, ns = ...
local ARLE = ns.ARLE
local L = ARLE.Lib

-- Strings ---------------------------------------------------------------------

function L.Trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

-- "Some Thing!" -> "something": for matching names typed in chat.
function L.Key(s)
  return (tostring(s or ""):lower():gsub("[^%w]", ""))
end

function L.Split(s, sep)
  local out = {}
  for part in tostring(s or ""):gmatch("[^" .. (sep or ",") .. "]+") do
    out[#out + 1] = L.Trim(part)
  end
  return out
end

function L.Plural(n, one, many)
  return n .. " " .. (n == 1 and one or (many or (one .. "s")))
end

-- Colours ---------------------------------------------------------------------

function L.ClassColor(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c then
    return c.r, c.g, c.b, c.colorStr or "ffffffff"
  end
  return 1, 1, 1, "ffffffff"
end

-- member = { name, class }
function L.ColorName(member)
  local _, _, _, hex = L.ClassColor(member.class)
  return "|c" .. hex .. member.name .. "|r"
end

function L.QualityColor(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then
    return c.r, c.g, c.b
  end
  return 1, 1, 1
end

function L.Hex(r, g, b)
  return string.format("ff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5))
end

-- Time and money ----------------------------------------------------------------

-- 754 -> "12:34", 3754 -> "1:02:34".
function L.FormatTime(secs)
  if not secs then
    return "--:--"
  end
  secs = math.max(0, math.floor(secs + 0.5))
  local h, m, s = math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

-- A difference against a record: "-0:12" green (faster), "+0:08" red.
function L.FormatDelta(delta)
  if not delta then
    return ""
  end
  local sign = delta < 0 and "-" or "+"
  local color = delta < 0 and "ff40ff60" or (delta > 0 and "ffff5040" or "ffaaaaaa")
  return "|c" .. color .. sign .. L.FormatTime(math.abs(delta)) .. "|r"
end

-- 2h 05m, 12m, 45s.
function L.FormatDuration(secs)
  secs = math.max(0, math.floor((secs or 0) + 0.5))
  if secs >= 3600 then
    return string.format("%dh %02dm", math.floor(secs / 3600), math.floor(secs / 60) % 60)
  elseif secs >= 60 then
    return string.format("%dm", math.floor(secs / 60))
  end
  return secs .. "s"
end

-- Copper -> "1g 23s 45c" (no icons, so it works in any font).
function L.FormatMoney(copper)
  if not copper then
    return "?"
  end
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then
    return string.format("|cffffd100%dg|r %02ds", g, s)
  elseif s > 0 then
    return string.format("%ds %02dc", s, c)
  end
  return c .. "c"
end

function L.Now()
  return (GetServerTime and GetServerTime()) or time()
end

-- Group -----------------------------------------------------------------------

-- Our name as our addon messages carry it ("First Surname" on Forever), so
-- that our own entry and the ones partymates keep for us use the same key.
function L.Me()
  return ARLE:ShortName(ARLE:MyName())
end

-- Group members as { {name, class, unit}, ... }, the player first.
function L.Members()
  local list = { { name = L.Me(), class = select(2, UnitClass("player")), unit = "player" } }
  local prefix, count = "party", GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
  if IsInRaid and IsInRaid() then
    prefix, count = "raid", GetNumGroupMembers()
  end
  for i = 1, count do
    local unit = prefix .. i
    if UnitExists(unit) and not UnitIsUnit(unit, "player") then
      list[#list + 1] = { name = ARLE:UnitShortName(unit), class = select(2, UnitClass(unit)), unit = unit }
    end
  end
  return list
end

-- Secret values (12.x clients): never compare or index with one.
function L.IsSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- The value, or nil when the client hides it.
function L.Plain(v)
  if issecretvalue ~= nil and issecretvalue(v) then
    return nil
  end
  return v
end

-- A table from the client that can be read: a secret one says "table" to
-- type() but throws when indexed or walked.
function L.Readable(t)
  return type(t) == "table" and not L.IsSecret(t)
end

-- A non-empty string the client doesn't hide, or nil.
function L.Str(v)
  return not L.IsSecret(v) and type(v) == "string" and v ~= "" and v or nil
end

local function PlainAll(n, ...)
  if n <= 0 then
    return
  end
  return L.Plain((...)), PlainAll(n - 1, select(2, ...))
end

local function Results(ok, ...)
  if not ok then
    return nil
  end
  return PlainAll(select("#", ...), ...)
end

-- Calls an API that may be missing, throw, or differ between clients:
-- nothing when it's missing or throws, and hidden values come back as nil.
function L.Call(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  return Results(pcall(fn, ...))
end

-- A spell's name on this client (C_Spell or the old GetSpellInfo), or nil.
function L.SpellName(id)
  local name
  if C_Spell and C_Spell.GetSpellName then
    name = L.Call(C_Spell.GetSpellName, id)
  end
  if type(name) ~= "string" then
    name = L.Call(_G.GetSpellInfo, id)
  end
  return L.Str(name)
end

-- A unit's name as chat, addon messages and /targetexact know it. On Forever
-- UnitName gives the first name and the surname apart ("Haru", "Pala"), and
-- players are named "Haru Pala"; there are no realms.
function L.UnitFullName(unit)
  local first, surname = L.Call(UnitName, unit)
  first, surname = L.Str(first), L.Str(surname)
  if not first or first == UNKNOWNOBJECT then
    return nil
  end
  if surname then
    local c = Constants and Constants.CharacterNameSeparatorConsts
    local sep = c and L.Str(c.CHARACTERNAME_SURNAME_SEPARATOR) or " "
    return first .. sep .. surname
  end
  return first
end

-- "Name-Realm" -> "Name" (any realm), as other addons' messages name players.
function L.StripRealm(name)
  name = L.Str(name)
  return name and (name:match("^([^%-]+)") or name) or nil
end

-- The chat box the player is typing in (or the last one opened), or nil.
function L.ActiveChatBox()
  local util = rawget(_G, "ChatFrameUtil")
  if type(util) == "table" and type(util.GetActiveWindow) == "function" then
    return (L.Call(util.GetActiveWindow))
  end
  local get = rawget(_G, "ChatEdit_GetActiveWindow")
  return type(get) == "function" and (L.Call(get)) or nil
end

-- Talents ----------------------------------------------------------------------
-- Forever has no GetNumTalentTabs / GetTalentTabInfo any more (calling them
-- gives "attempt to call a nil value", ForeverDungeonJournal's notes, 20 Nov
-- 2026). Its talent window is the trait tree (C_Traits, Camelot's
-- Blizzard_ClassTalentsFrame): one tree per class, with the three talent
-- trees as its groups (C_Traits.GetGroupDisplayInfoByTreeID, tab order =
-- orderIndex). The talent set is C_SpecializationInfo.GetActiveSpecGroup(),
-- and a set swap ends on ACTIVE_COMBAT_CONFIG_CHANGED; ACTIVE_TALENT_GROUP_CHANGED
-- has not been seen to fire there (Forever Leveling BiS's notes). The old
-- functions are still tried on a client that has them.

-- The talent events a feature listens for to see a swap or a respec (self:On
-- skips the ones this client lacks).
L.TALENT_EVENTS = { "ACTIVE_COMBAT_CONFIG_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE",
  "ACTIVE_TALENT_GROUP_CHANGED", "CHARACTER_POINTS_CHANGED" }

-- The active talent set (1 or 2).
function L.TalentGroup()
  local S = C_SpecializationInfo
  local g = S and (L.Call(S.GetActiveSpecGroup))
  if type(g) ~= "number" then
    g = (L.Call(_G.GetActiveTalentGroup))
  end
  return type(g) == "number" and g or 1
end

-- The trait config of talent set `group`.
local function TalentConfig(group)
  local S = C_SpecializationInfo
  local id = S and (L.Call(S.GetCombatConfigIDForSpecGroup, group))
  if type(id) ~= "number" and group == L.TalentGroup() and C_ClassTalents then
    id = (L.Call(C_ClassTalents.GetActiveConfigID))
  end
  return type(id) == "number" and id or nil
end

local function Num(t, key)
  local v = L.Plain(t[key])
  return type(v) == "number" and v or nil
end

local function TraitTrees(group)
  local T = C_Traits
  if type(T) ~= "table" or not T.GetConfigInfo or not T.GetTreeNodes or not T.GetNodeInfo
    or not T.GetGroupDisplayInfoByTreeID then
    return nil
  end
  local configID = TalentConfig(group)
  local config = configID and (L.Call(T.GetConfigInfo, configID))
  local treeIDs = L.Readable(config) and config.treeIDs
  local treeID = L.Readable(treeIDs) and L.Plain(treeIDs[1])
  if type(treeID) ~= "number" then
    return nil
  end
  local displays = L.Call(T.GetGroupDisplayInfoByTreeID, treeID)
  if not L.Readable(displays) then
    return nil
  end
  local trees, byGroup = {}, {}
  for _, d in ipairs(displays) do
    local gid = L.Readable(d) and Num(d, "groupID")
    if gid then
      local tree = { name = L.Str(d.displayName), points = 0, order = Num(d, "orderIndex") or #trees }
      trees[#trees + 1] = tree
      byGroup[gid] = tree
    end
  end
  if #trees == 0 then
    return nil
  end
  table.sort(trees, function(a, b)
    return a.order < b.order
  end)
  local nodes = L.Call(T.GetTreeNodes, treeID)
  if not L.Readable(nodes) then
    return nil
  end
  for _, nodeID in ipairs(nodes) do
    local info = L.Call(T.GetNodeInfo, configID, nodeID)
    if L.Readable(info) and L.Readable(info.groupIDs) then
      local pts = Num(info, "ranksPurchased") or Num(info, "activeRank") or 0
      if pts > 0 then
        for _, gid in ipairs(info.groupIDs) do
          local tree = byGroup[L.Plain(gid)]
          if tree then
            tree.points = tree.points + pts
            break
          end
        end
      end
    end
  end
  return trees
end

local function LegacyTrees(group)
  local tabs = (L.Call(_G.GetNumTalentTabs))
  if type(tabs) ~= "number" or tabs < 1 or type(_G.GetTalentTabInfo) ~= "function" then
    return nil
  end
  local trees = {}
  for tab = 1, tabs do
    local ok, a, b, c, _, e = pcall(GetTalentTabInfo, tab, false, false, group)
    if not ok then
      ok, a, b, c, _, e = pcall(GetTalentTabInfo, tab)
    end
    if not ok then
      return nil
    end
    if type(L.Plain(a)) == "number" then
      trees[tab] = { name = L.Str(b), points = tonumber(L.Plain(e)) or 0 } -- id, name, description, icon, points
    else
      trees[tab] = { name = L.Str(a), points = tonumber(L.Plain(c)) or 0 } -- name, icon, points, file
    end
  end
  return trees
end

-- The talent trees of set `group` (default: the active one) in tab order, as
-- { { name, points }, ... }, or nil when the client can't tell.
function L.TalentTrees(group)
  group = group or L.TalentGroup()
  return TraitTrees(group) or LegacyTrees(group)
end

-- The tree with the most points in set `group`: tab index, name, points.
-- No points or a tie: nil, nil, the most points (and "tie" on a tie);
-- unreadable talents: nil, nil, nil, "unreadable".
function L.MainTalentTree(group)
  local trees = L.TalentTrees(group)
  if not trees then
    return nil, nil, nil, "unreadable"
  end
  local best, bestPts, tie = nil, 0, false
  for tab, tree in ipairs(trees) do
    if tree.points > bestPts then
      best, bestPts, tie = tab, tree.points, false
    elseif tree.points == bestPts and bestPts > 0 then
      tie = true
    end
  end
  if tie or not best then
    return nil, nil, bestPts, tie and "tie" or nil
  end
  return best, trees[best].name, bestPts
end
