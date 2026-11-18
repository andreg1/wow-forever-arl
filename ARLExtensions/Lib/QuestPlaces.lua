-- ARLE.Lib.QuestPlaces: where a quest still has something for you to do, from
-- QuestieDB, as world maps (uiMapIDs at zone level), and which zone maps the
-- player is in. Used by Quest Tracker ("quests whose objectives are here")
-- and Rare Objectives (a quest mob's maps).
--
--   P.PlayerZoneMaps()        { [uiMap] = true } for the player's zone(s)
--   P.NpcMaps(npcId)          { [uiMap] = true } or nil (unknown)
--   P.ObjectMaps(objectId)    the same for an object
--   P.QuestMaps(questID)      maps of the quest's unfinished objectives, or of
--                             its turn-in once complete; nil when unknown
--   P.IsHere(questID)         one of those maps is the player's zone
--   P.Why(questID)            { "objective name", ... } in the player's zone
--   P.Reset()                 forget the player's maps (they also follow the
--                             player's current map on every call)
--
-- QuestieDB's quest fields (src/meta/questMeta.lua): objectives = six groups
-- (creature {id, text}, object {id, text}, item {id, text}, reputation,
-- kill credit {{ids}, rootId, text}, spell); finishedBy = {npcIds, objectIds};
-- triggerEnd = {text, {[areaId] = coords}}. Spawns are keyed by areaId and
-- become world maps through Questie's ZoneDB (ARLE.Bridge.Questie).
local _, ns = ...
local ARLE = ns.ARLE
local P = {}
ARLE.Lib.QuestPlaces = P

local DB = ARLE.Bridge.QuestieDB
local Q = ARLE.Bridge.Questie

-- Zone-level maps only: a continent contains every zone, so two zones on one
-- continent must not match through it.
local ZONE_TYPE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3

function P.WalkToZone(m, fn)
  local guard = 0
  if issecretvalue and issecretvalue(m) then
    return
  end
  while type(m) == "number" and m > 0 and guard < 10 do
    local info = C_Map.GetMapInfo(m)
    if type(info) ~= "table" or (issecretvalue and issecretvalue(info))
      or (info.mapType and info.mapType < ZONE_TYPE) then
      return
    end
    if fn(m) then
      return true
    end
    m = info.parentMapID
    guard = guard + 1
  end
end

-- Rebuilt whenever the player's best map differs from last time, asked on
-- every call: an event-driven reset could come after EllesmereUI's tracker
-- had already rebuilt for the new zone with the old answer.
local playerMaps, playerBest
function P.PlayerZoneMaps()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  if issecretvalue and issecretvalue(m) then
    m = nil
  end
  if not playerMaps or m ~= playerBest then
    playerMaps, playerBest = {}, m
    P.WalkToZone(m, function(map)
      playerMaps[map] = true
    end)
  end
  return playerMaps
end

function P.Reset()
  playerMaps, playerBest = nil, nil
end

local function AddAreas(maps, byZone)
  local any = false
  if type(byZone) == "table" then
    for areaId in pairs(byZone) do
      local uiMap = type(areaId) == "number" and Q.UiMapForArea(areaId)
      if uiMap then
        maps[uiMap] = true
        any = true
      end
    end
  end
  return any
end

local entityMaps = { npc = {}, object = {} } -- id -> maps | false
local function EntityMaps(kind, id)
  if type(id) ~= "number" then
    return nil
  end
  local cache = entityMaps[kind]
  local v = cache[id]
  if v == nil then
    if not Q.ZoneReady() then
      return nil -- (not cached: asked again once Questie's zones are loaded)
    end
    local maps, any = {}, false
    local get = kind == "npc" and DB.Npc or DB.Object
    for _, field in ipairs({ "spawns", "waypoints" }) do
      any = AddAreas(maps, get(id, field)) or any
    end
    v = any and maps or false
    cache[id] = v
  end
  return v or nil
end

function P.NpcMaps(npcId)
  return EntityMaps("npc", npcId)
end

function P.ObjectMaps(objectId)
  return EntityMaps("object", objectId)
end

local function Merge(into, maps)
  if maps then
    for m in pairs(maps) do
      into[m] = true
    end
    return true
  end
  return false
end

-- The log objective whose text names `name`: finished (true/false), or nil
-- when none names it (then it counts as still to do).
local function Finished(logObjectives, name)
  if type(name) ~= "string" or name == "" or type(logObjectives) ~= "table" then
    return nil
  end
  local needle = name:lower()
  for _, o in ipairs(logObjectives) do
    if type(o) == "table" and type(o.text) == "string" and o.text:lower():find(needle, 1, true) then
      return o.finished == true
    end
  end
end

local function ItemName(itemId)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemId)
  return name or DB.Item(itemId, "name")
end

-- One cache entry per quest, kept while its progress (complete + each
-- objective's finished flag) is the same.
local questCache = {} -- questID -> { sig, maps | false, why }

local function Signature(questID, logObjectives)
  local parts = { C_QuestLog.IsComplete(questID) and "c" or "o" }
  for i, o in ipairs(type(logObjectives) == "table" and logObjectives or {}) do
    parts[i + 1] = (type(o) == "table" and o.finished) and "1" or "0"
  end
  return table.concat(parts)
end

-- Returns the union of maps (or false), and the parts: { label, maps } per
-- place, so Why can name only the ones in the player's zone.
local function Compute(questID, logObjectives)
  local maps, parts, any = {}, {}, false
  local byLabel = {}
  local function add(m, label)
    if Merge(maps, m) then
      any = true
      local part = byLabel[label]
      if not part then
        part = { label = label, maps = {} }
        byLabel[label] = part
        parts[#parts + 1] = part
      end
      Merge(part.maps, m)
    end
  end
  if C_QuestLog.IsComplete(questID) then
    local by = DB.Quest(questID, "finishedBy")
    if type(by) == "table" then
      for _, id in ipairs(type(by[1]) == "table" and by[1] or {}) do
        add(P.NpcMaps(id), "turn in to " .. tostring(DB.Npc(id, "name") or id))
      end
      for _, id in ipairs(type(by[2]) == "table" and by[2] or {}) do
        add(P.ObjectMaps(id), "turn in at " .. tostring(DB.Object(id, "name") or id))
      end
    end
    return any and maps or false, parts
  end
  local obj = DB.Quest(questID, "objectives")
  if type(obj) == "table" then
    -- Creatures.
    for _, o in ipairs(type(obj[1]) == "table" and obj[1] or {}) do
      local id = type(o) == "table" and o[1]
      local name = (type(o) == "table" and o[2]) or DB.Npc(id, "name")
      if Finished(logObjectives, name) ~= true then
        add(P.NpcMaps(id), tostring(name or id))
      end
    end
    -- Objects.
    for _, o in ipairs(type(obj[2]) == "table" and obj[2] or {}) do
      local id = type(o) == "table" and o[1]
      local name = (type(o) == "table" and o[2]) or DB.Object(id, "name")
      if Finished(logObjectives, name) ~= true then
        add(P.ObjectMaps(id), tostring(name or id))
      end
    end
    -- Items: where they drop (mobs and objects).
    for _, o in ipairs(type(obj[3]) == "table" and obj[3] or {}) do
      local id = type(o) == "table" and o[1]
      if type(id) == "number" then
        local name = (type(o) == "table" and o[2]) or ItemName(id)
        if Finished(logObjectives, name) ~= true then
          local label = tostring(name or ("item " .. id))
          for _, npc in ipairs(type(DB.Item(id, "npcDrops")) == "table" and DB.Item(id, "npcDrops") or {}) do
            add(P.NpcMaps(npc), label)
          end
          for _, ob in ipairs(type(DB.Item(id, "objectDrops")) == "table" and DB.Item(id, "objectDrops") or {}) do
            add(P.ObjectMaps(ob), label)
          end
        end
      end
    end
    -- Kill credit: any of the listed NPCs counts.
    for _, o in ipairs(type(obj[5]) == "table" and obj[5] or {}) do
      if type(o) == "table" then
        local name = o[3] or DB.Npc(o[2], "name")
        if Finished(logObjectives, name) ~= true then
          for _, id in ipairs(type(o[1]) == "table" and o[1] or {}) do
            add(P.NpcMaps(id), tostring(name or id))
          end
        end
      end
    end
  end
  -- Exploration: { text, { [areaId] = coords } }.
  local trigger = DB.Quest(questID, "triggerEnd")
  if type(trigger) == "table" and Finished(logObjectives, trigger[1]) ~= true then
    local m = {}
    if AddAreas(m, trigger[2]) then
      add(m, tostring(trigger[1] or "explore"))
    end
  end
  return any and maps or false, parts
end

local function Entry(questID)
  if type(questID) ~= "number" or not DB.Ready() or not Q.ZoneReady() then
    return nil
  end
  local logObjectives = C_QuestLog.GetQuestObjectives(questID)
  local sig = Signature(questID, logObjectives)
  local e = questCache[questID]
  if not e or e.sig ~= sig then
    local ok, maps, parts = pcall(Compute, questID, logObjectives)
    e = { sig = sig, maps = ok and maps or false, parts = ok and parts or {} }
    questCache[questID] = e
  end
  return e
end

function P.QuestMaps(questID)
  local e = Entry(questID)
  return e and e.maps or nil
end

function P.IsHere(questID)
  local maps = P.QuestMaps(questID)
  if not maps then
    return false
  end
  for m in pairs(P.PlayerZoneMaps()) do
    if maps[m] then
      return true
    end
  end
  return false
end

-- The objectives (or the turn-in) that are in the player's zone.
function P.Why(questID)
  local e = Entry(questID)
  local out = {}
  local here = P.PlayerZoneMaps()
  for _, part in ipairs(e and e.parts or {}) do
    for m in pairs(part.maps) do
      if here[m] then
        out[#out + 1] = part.label
        break
      end
    end
  end
  return out
end
