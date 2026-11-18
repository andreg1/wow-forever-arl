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
