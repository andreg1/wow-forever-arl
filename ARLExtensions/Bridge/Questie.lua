-- ARLE.Bridge.QuestieDB / ARLE.Bridge.Questie: the only code that reads
-- QuestieDB's data and Questie's modules. Every call is feature-checked and
-- pcall'd: when Questie changes shape, features see nil and say so in their
-- status instead of throwing errors.
--
-- QuestieDB: the QuestDB / NpcDB / ObjectDB / ItemDB globals of the QuestieDB
--   addon (src/api.lua): Get(id, field), GetAllIds(); LibQuestieDB.Enum.
-- Questie: modules through the global QuestieLoader:ImportModule(name).
local _, ns = ...
local ARLE = ns.ARLE
local Lib = ARLE.Lib

local DB = {}
ARLE.Bridge.QuestieDB = DB

local function Entity(name)
  local t = _G[name]
  if type(t) == "table" and type(t.Get) == "function" then
    return t
  end
end

function DB.Ready()
  local q = Entity("QuestDB")
  return q ~= nil and type(q.GetAllIds) == "function"
end

local function Get(entity, id, field)
  local t = Entity(entity)
  if not t or id == nil then
    return nil
  end
  local ok, value = pcall(t.Get, id, field)
  if ok then
    return value
  end
  return nil -- (one value always: tonumber(DB.Quest(...)) throws on none)
end
DB.Get = Get

function DB.Quest(id, field) return Get("QuestDB", id, field) end
function DB.Npc(id, field) return Get("NpcDB", id, field) end
function DB.Object(id, field) return Get("ObjectDB", id, field) end
function DB.Item(id, field) return Get("ItemDB", id, field) end

function DB.AllQuestIds()
  local q = Entity("QuestDB")
  if q and type(q.GetAllIds) == "function" then
    local ok, ids = pcall(q.GetAllIds)
    if ok and type(ids) == "table" then
      return ids
    end
  end
  return {}
end

function DB.HasNpcs()
  return Entity("NpcDB") ~= nil
end

function DB.Enum()
  local lib = _G.LibQuestieDB
  return type(lib) == "table" and type(lib.Enum) == "table" and lib.Enum or nil
end

-- Instance zones as QuestieDB lists them (support\<flavor>\Zones\dungeons.lua,
-- published as LibQuestieDB.Support.Get("ZoneDB").private.dungeons; Questie's
-- ZoneDB:GetDungeons() holds the same table): areaId -> instance name, each
-- alternative area ID (wings, quest zones) included. Battlegrounds, the tram,
-- the Faire's island and other non-instances are left out. Built once.
local NOT_INSTANCES = {
  [2257] = true, -- Deeprun Tram
  [2597] = true, -- Alterac Valley
  [3277] = true, -- Warsong Gulch
  [3358] = true, -- Arathi Basin
  [5733] = true, -- Molten Front
  [5861] = true, -- Darkmoon Faire Island
  [6298] = true, -- Brawl'gar Arena
  [6618] = true, -- Bizmo's Brawlpub
}
local instanceZones

local function DungeonTable()
  local lib = _G.LibQuestieDB
  local support = type(lib) == "table" and type(lib.Support) == "table" and lib.Support or nil
  if support and type(support.Get) == "function" then
    local ok, zoneDB = pcall(support.Get, "ZoneDB")
    local t = ok and type(zoneDB) == "table" and type(zoneDB.private) == "table" and zoneDB.private.dungeons
    if type(t) == "table" then
      return t
    end
  end
  local zoneDB = ARLE.Bridge.Questie.Module("ZoneDB")
  if zoneDB and type(zoneDB.GetDungeons) == "function" then
    local ok, t = pcall(zoneDB.GetDungeons, zoneDB)
    if ok and type(t) == "table" then
      return t
    end
  end
end

function DB.InstanceZones()
  if instanceZones then
    return instanceZones
  end
  local t = DungeonTable()
  if not t then
    return nil -- (not cached: QuestieDB may still be loading)
  end
  instanceZones = {}
  for areaId, entry in pairs(t) do
    if type(areaId) == "number" and type(entry) == "table" and not NOT_INSTANCES[areaId] then
      local name = Lib.Str((Lib.Call(C_Map and C_Map.GetAreaInfo, areaId)))
        or (type(entry[1]) == "string" and entry[1]) or ("Zone " .. areaId)
      instanceZones[areaId] = name
      for _, alt in ipairs(type(entry[2]) == "table" and entry[2] or {}) do
        if type(alt) == "number" and not NOT_INSTANCES[alt] then
          instanceZones[alt] = name
        end
      end
    end
  end
  return instanceZones
end

local Q = {}
ARLE.Bridge.Questie = Q

function Q.Ready()
  local loader = _G.QuestieLoader
  return type(loader) == "table" and type(loader.ImportModule) == "function"
end

local cache = {}
function Q.Module(name)
  if cache[name] then
    return cache[name]
  end
  if not Q.Ready() then
    return nil
  end
  local ok, module = pcall(_G.QuestieLoader.ImportModule, _G.QuestieLoader, name)
  if ok and type(module) == "table" then
    cache[name] = module
    return module
  end
end

-- Questie's own QuestieDB module, as a fallback for the QuestieDB addon.
function Q.QueryQuest(id, field)
  local qdb = Q.Module("QuestieDB")
  if qdb and type(qdb.QueryQuestSingle) == "function" then
    local ok, value = pcall(qdb.QueryQuestSingle, id, field)
    if ok then
      return value
    end
  end
end

-- QuestieDB's value for a quest field, else Questie's.
function Q.QuestField(id, field)
  local v = DB.Quest(id, field)
  if v == nil then
    v = Q.QueryQuest(id, field)
  end
  return v
end

function Q.QuestLink(id)
  local link = Q.Module("QuestieLink")
  if link and type(link.GetQuestHyperLink) == "function" then
    local ok, text = pcall(link.GetQuestHyperLink, link, id)
    if ok and type(text) == "string" then
      return text
    end
  end
end

-- A quest's tag ID (81 dungeon, 85 heroic, 62/88/89 raid, 41 PvP, 1 elite):
-- Questie's QuestieDB.GetQuestTagInfo first (it holds corrections for quests
-- the game tags wrongly, such as Leaders of the Fang), else the game's own
-- C_QuestLog.GetQuestTagInfo / GetQuestTagInfo. nil when unknown.
function Q.QuestTag(id)
  local qdb = Q.Module("QuestieDB")
  if qdb and type(qdb.GetQuestTagInfo) == "function" then
    local tag = Lib.Call(qdb.GetQuestTagInfo, id)
    if type(tag) == "number" then
      return tag
    end
  end
  if C_QuestLog and C_QuestLog.GetQuestTagInfo then
    local info = Lib.Call(C_QuestLog.GetQuestTagInfo, id)
    if Lib.Readable(info) and type(info.tagID) == "number" then
      return info.tagID
    end
  end
  local tag = _G.GetQuestTagInfo and Lib.Call(_G.GetQuestTagInfo, id)
  return type(tag) == "number" and tag or nil
end

-- An area ID's world map (subzones resolve to their zone), via Questie's ZoneDB.
function Q.UiMapForArea(areaId)
  local zoneDB = Q.Module("ZoneDB")
  if zoneDB and type(zoneDB.GetUiMapIdByAreaId) == "function" then
    local ok, uiMap = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, areaId)
    if ok and type(uiMap) == "number" and uiMap > 0 then
      return uiMap
    end
  end
end

-- Questie's zone table answers (it's filled a moment after login): until
-- then every area lookup fails, which isn't "no map".
local zoneReady = false
function Q.ZoneReady()
  if not zoneReady then
    -- (12 = Elwynn Forest, 14 = Durotar: in every client's zone table)
    zoneReady = (Q.UiMapForArea(12) or Q.UiMapForArea(14)) ~= nil
  end
  return zoneReady
end

function Q.AreaIdByName(name)
  local zoneDB = Q.Module("ZoneDB")
  if zoneDB and type(zoneDB.GetAreaIdByName) == "function" then
    local ok, id = pcall(zoneDB.GetAreaIdByName, zoneDB, name)
    if ok and type(id) == "number" then
      return id
    end
  end
end
