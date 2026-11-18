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
