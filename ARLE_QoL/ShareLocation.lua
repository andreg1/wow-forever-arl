-- Share Location: guildmates who use OpenMap see you as a dot where you
-- stand on their map, live, whether or not you use OpenMap yourself.
--
-- OpenMap (MIT, "OpenMap contributors") shows guild members who share their
-- place as a class-coloured dot (OpenMap/Map/Friends.lua). It accepts any
-- guild addon message on its prefix "OpenMapLoc":
--   "L1\t<uiMapID>\t<x>\t<y>\t<CLASS>\t<level>"  (x, y 0..1 on that zone's map)
--   "L0"                                          (stopped sharing)
-- and drops a dot it hasn't heard from in 150 s. This feature speaks that
-- format only; no OpenMap code is used. Like OpenMap: every 10 s while you
-- move, every 60 s while you stand still, never from inside a dungeon, raid
-- or battleground (an "L0" goes out instead, once), guild only.
--
-- With OpenMap loaded and its own "Share where you are" on, OpenMap already
-- sends the same messages: this stands aside (and sends no "L0", which would
-- take OpenMap's dot away). Party members get the most out of it too:
-- OpenMap places a group member the game keeps secret from this message.
--
-- The map: a micro map (cave, building) or an orphan isn't on OpenMap's
-- stitched world, so the place is given on the zone it lies in.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local PREFIX = "OpenMapLoc"
local TICK = 2           -- seconds between looks at where you are
local SEND_EVERY = 10    -- seconds between places sent while you move
local STILL_EVERY = 60   -- ... and while you stand still
local MOVED = 0.002      -- (a move this small on a zone's map isn't one)
local ZONE_TYPE = 3      -- Enum.UIMapType.Zone; Dungeon, Micro, Orphan are above it

local F = {
  id = "ShareLocation",
  addon = ADDON,
  title = "Share Location",
  group = "QualityOfLife",
  command = "share",
  commandHelp = "shows you live on your guildmates' OpenMap",
  description = "Guildmates who use OpenMap see you as a dot where you stand on their map, live. Guild only, "
    .. "never from inside a dungeon, raid or battleground. You don't need OpenMap yourself.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
  },
}

local last = { at = -math.huge }   -- the place last sent: map, x, y, at
local sharing = false              -- an L1 went out since the last L0 (they're told when it stops)
local why = "starting"             -- why nothing is sent right now, for the status line

local function Secret(v)
  return issecretvalue ~= nil and issecretvalue(v)
end

-- OpenMap's own sharing, when it's loaded and turned on
local function OpenMapShares()
  local om = _G.OpenMap
  local mod = type(om) == "table" and type(om.GetModule) == "function" and om:GetModule("worldmap")
  return type(mod) == "table" and type(mod.db) == "table" and mod.db.friendsShare == true and mod.enabled and true
    or false
end

local function MapInfo(id)
  local ok, info = pcall(C_Map.GetMapInfo, id)
  if ok and type(info) == "table" and not Secret(info) then
    return info
  end
end

local function PositionOn(mapID)
  local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
  if not ok or type(pos) ~= "table" or Secret(pos) then
    return
  end
  local x, y
  if pos.GetXY then
    x, y = pos:GetXY()
  else
    x, y = pos.x, pos.y
  end
  if Secret(x) or Secret(y) or type(x) ~= "number" or type(y) ~= "number" then
    return
  end
  if (x <= 0 and y <= 0) or x > 1 or y > 1 or x < 0 or y < 0 then
    return
  end
  return x, y
end

-- uiMapID, x, y of where you are on a zone (or city) map, or nil and why not
local function Here()
  local inInstance = IsInInstance()
  if Secret(inInstance) or inInstance then
    return nil, "in an instance"
  end
  local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or Secret(map) or type(map) ~= "number" then
    return nil, "the game doesn't say where you are"
  end
  -- up from a cave or building to the zone it lies in (OpenMap only places zones and cities)
  for _ = 1, 4 do
    local info = MapInfo(map)
    if not info then
      return nil, "the game doesn't say where you are"
    end
    if (info.mapType or 0) <= ZONE_TYPE then
      break
    end
    if not info.parentMapID or info.parentMapID == 0 then
      return nil, "not on the world map here"
    end
    map = info.parentMapID
  end
  local x, y = PositionOn(map)
  if not x then
    return nil, "the game doesn't say where you are"
  end
  return map, x, y
end

local function Send(text)
  if not (IsInGuild() and C_ChatInfo and C_ChatInfo.SendAddonMessage) then
    return false
  end
  local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "GUILD")
  -- (modern clients answer with a result code: 0 is sent)
  return ok and (result == nil or result == true or result == 0 or (Enum.SendAddonMessageResult
    and result == Enum.SendAddonMessageResult.Success))
end

function F:Stop(reason)
  why = reason
  if sharing then
    sharing = false
    last.at = -math.huge
    Send("L0")
    self:Debug("stopped (%s): L0 sent", reason)
  end
end

function F:Tick(force)
  if not IsInGuild() then
    why = "not in a guild"
    return
  end
  if OpenMapShares() then
    -- (OpenMap's own L1 replaces ours: no L0, it would remove OpenMap's dot)
    sharing, why, last.at = false, "OpenMap's own sharing is on", -math.huge
    return
  end
  local map, x, y = Here()
  if not map then
    self:Stop(x)
    return
  end
  local moved = map ~= last.map or math.abs(x - last.x) > MOVED or math.abs(y - last.y) > MOVED
  if not force and GetTime() - last.at < (moved and SEND_EVERY or STILL_EVERY) then
    return
  end
  local _, class = UnitClass("player")
  if Secret(class) or type(class) ~= "string" then
    class = ""
  end
  local level = UnitLevel("player")
  level = (not Secret(level) and tonumber(level)) or 0
  local text = ("L1\t%d\t%.4f\t%.4f\t%s\t%d"):format(map, x, y, class, level)
  if Send(text) then
    last.map, last.x, last.y, last.at = map, x, y, GetTime()
    sharing, why = true, nil
    self:Debug("sent %s", text:gsub("\t", " "))
  else
    why = "the game refused the message"
    self:Debug("send refused: %s", text:gsub("\t", " "))
  end
end

function F:OnEnable()
  why = "starting"
  self:Ticker(TICK, function(def) def:Tick() end)
  -- (a loading screen: at once, so a dot leaves when you enter a dungeon and comes back when you leave)
  self:On("PLAYER_ENTERING_WORLD", function(def) def:After(1, function(d) d:Tick(true) end) end)
  self:After(3, function(def) def:Tick(true) end)
end

function F:OnDisable()
  self:Stop("off")
end

function F:GetStatus()
  if why == nil and sharing then
    local info = last.map and MapInfo(last.map)
    local ago = math.floor(GetTime() - last.at)
    return ("Sharing with the guild · %s %.1f, %.1f · sent %d s ago"):format(info and info.name or "?",
      last.x * 100, last.y * 100, ago)
  end
  return "Not sharing right now: " .. tostring(why)
end

ARLE:RegisterModule(F)
