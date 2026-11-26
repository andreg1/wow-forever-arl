-- Dungeon Helper, Quests tab: the dungeon's quests (DungeonJournal's list,
-- for the player's faction and character) on the left, grouped by where the
-- player stands with each; the selected quest on the right: what it asks,
-- where it starts and ends, its rewards (items, gold), the quests that unlock it, the
-- quests that follow it, and the party's progress.
--
-- Chains:
--   Before: DungeonJournal's curated "required to unlock" lists
--     (QUEST_PREREQ_CHAINS: breadcrumbs left out on purpose; QUEST_GUIDE_CHAINS
--     marks lists that are how to do the quest rather than what unlocks it).
--     When it has none, QuestieDB's preQuestGroup (all needed) and
--     preQuestSingle (one of them is enough), walked back to the start.
--   After: QuestieDB's nextQuestInChain, walked forward.
-- QuestieDB is optional: without it, only DungeonJournal's chains show.
--
-- Party members with ARL share their state of each quest ("QS"), shown as
-- class-coloured squares like the loot's.
--
-- 0.15.0: the list also holds QuestieDB's quests whose work is in the
-- dungeon that DungeonJournal doesn't list (class quests above all): an
-- index of every QuestieDB quest, built once in slices, by the instance its
-- zone or (for tagged and class quests) its objectives' spawns are in. The
-- chain is a tree: every quest that unlocks it, the quests that unlock those
-- ("chains of chains", branches indented, "one of" groups), its lead-ins
-- (QuestieDB breadcrumbs), then the quests that follow.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Kit = ARLE.UI.Kit
local S = H.Script
local Members, Me, ColorName, TooltipSide = H.Members, H.Me, H.ColorName, H.TooltipSide
local QDB = ARLE.Bridge.QuestieDB
local LQ = ARLE.Lib.Quests

local ROW_H, STEP_H = 34, 26
local CHAIN_MAX, WALK_MAX = 25, 15
local TREE_MAX, INDENT, SLICE = 40, 14, 400
local FOLD_AT = 6 -- a longer chain folds its ends (OneMoreQuest's MAX_OPEN_CHAIN idea)

local tab = { key = "quests", label = "Quests" }
H.tabs[#H.tabs + 1] = tab

-- State codes, shared in messages too.
--   r ready to turn in, l in the quest log, a available (level OK, nothing
--   left before it), c level OK but earlier quests of its chain aren't done,
--   n not yet (level too low), d done
local SECTIONS = {
  { codes = { r = true, l = true }, label = "In your quest log" },
  { codes = { a = true }, label = "Available" },
  { codes = { c = true }, label = "Needs earlier quests" },
  { codes = { n = true }, label = "Level too low" },
  { codes = { d = true }, label = "Done" },
}

-------------------------------------------------------------------------------
-- Quests and states
-------------------------------------------------------------------------------

local IsDone = LQ.IsDone

local function InLog(id)
  return (LQ.InLog(id))
end

-- FDJ's helper, pcall'd: ok, result (ok false when it isn't there).
local function FDJCall(name, ...)
  local fdj = H.FDJ()
  local fn = fdj and fdj[name]
  if type(fn) ~= "function" then
    return false
  end
  local ok, res = pcall(fn, ...)
  return ok, res
end

local function IDs(v)
  if type(v) == "number" then
    return { v }
  end
  return type(v) == "table" and v or {}
end

local function PlayerClass()
  if not UnitClass then
    return nil
  end
  local ok, _, token = pcall(UnitClass, "player")
  token = ok and H.Plain(token)
  return type(token) == "string" and token ~= "" and token:upper() or nil
end

-- Whether the quest is for this character, by DungeonJournal's rules
-- (Journal.lua QuestMatchesFaction / QuestCountsForCharacter /
-- IsQuestUnavailable): another class's quest, a profession quest without the
-- profession, one not in the game now or not for this race, are left out.
-- Chain steps DungeonJournal keeps off its list (hideFromMainList) only show
-- while in the quest log: the rest are in the chains of the quests they lead to.
local function ForMe(q, id)
  if q.hideFromMainList and not InLog(id) then
    return false
  end
  local ok, counts = FDJCall("QuestCountsForCharacter", q)
  if ok then
    if not counts then
      return false
    end
  else
    local class = PlayerClass()
    if q.classOnly and class and tostring(q.classOnly):upper() ~= class then
      return false
    end
    if q.profession then
      local okP, has = FDJCall("PlayerHasProfession", q.profession)
      if okP and not has then
        return false
      end
    end
  end
  local okU, unavailable = FDJCall("IsQuestUnavailable", q)
  if okU then
    return not unavailable
  end
  local race = false
  if type(q.unavailableRaces) == "table" then
    local okR, r = FDJCall("IsQuestRaceUnavailable", q)
    race = okR and r or false
  end
  return not ((q.unavailable or race) and not IsDone(id))
end

-------------------------------------------------------------------------------
-- QuestieDB's quests for a dungeon (index built once, in slices)
-------------------------------------------------------------------------------

local index = { state = nil, byPlace = {}, count = 0, t05 = {}, t05set = {}, pvp = {} }
-- Battleground quests by the battleground's zone (QuestieDB zoneOrSort).
local PVP_ZONES = { [2597] = "AV", [3277] = "WSG", [3358] = "AB" }
-- Tier 0.5 (Dungeon Set 2): the quests these NPCs give (Deliana, Mokvar, Anthion
-- Harmon, Falrin Treeshaper, Bodley, and Forever's own Deliana and Mokvar).
local T05_STARTERS = { [16012] = true, [16013] = true, [16016] = true, [16032] = true, [16033] = true,
  [230317] = true, [230319] = true }
local DUNGEON_TAGS = { [81] = true, [85] = true, [62] = true, [88] = true, [89] = true }
local PLACE_ALIASES = { ["temple of atal'hakkar"] = "sunken temple", ["the temple of atal'hakkar"] = "sunken temple",
  ["deadmines"] = "the deadmines", ["stockade"] = "the stockade" }

-- A dungeon or instance name as both sides can match: lower case, no wing
-- (": Library", " - East"), no "Lower"/"Upper", "The" kept only by alias.
local function Place(name)
  if type(name) ~= "string" then
    return nil
  end
  local n = name:lower():gsub("\226\128\153", "'"):gsub("%s*:.*$", ""):gsub("%s+%-%s+.*$", "")
  n = n:gsub("^lower%s+", ""):gsub("^upper%s+", ""):gsub("^the%s+", "")
  return PLACE_ALIASES[n] or PLACE_ALIASES["the " .. n] or n
end

local function SpawnPlace(spawns, zones)
  if type(spawns) == "table" then
    for areaId in pairs(spawns) do
      if zones[areaId] then
        return zones[areaId]
      end
    end
  end
end

-- Where a quest's work is: its objectives' creatures, objects, item droppers.
local function ObjectivePlace(id, zones)
  local obj = QDB.Quest(id, "objectives")
  if type(obj) ~= "table" then
    return nil
  end
  for _, c in ipairs(type(obj[1]) == "table" and obj[1] or {}) do
    local found = type(c) == "table" and SpawnPlace(QDB.Npc(c[1], "spawns"), zones)
    if found then
      return found
    end
  end
  for _, o in ipairs(type(obj[2]) == "table" and obj[2] or {}) do
    local found = type(o) == "table" and SpawnPlace(QDB.Object(o[1], "spawns"), zones)
    if found then
      return found
    end
  end
  for _, it in ipairs(type(obj[3]) == "table" and obj[3] or {}) do
    local drops = type(it) == "table" and QDB.Item(it[1], "npcDrops")
    for i, npc in ipairs(type(drops) == "table" and drops or {}) do
      local found = i <= 5 and SpawnPlace(QDB.Npc(npc, "spawns"), zones)
      if found then
        return found
      end
    end
  end
end

local function IndexOne(id, zones)
  local by = QDB.Quest(id, "startedBy")
  for _, npc in ipairs(type(by) == "table" and type(by[1]) == "table" and by[1] or {}) do
    if T05_STARTERS[npc] then
      index.t05[#index.t05 + 1] = id
      index.t05set[id] = true
      break
    end
  end
  local zone = QDB.Quest(id, "zoneOrSort")
  local bg = type(zone) == "number" and PVP_ZONES[zone]
  if bg then
    index.pvp[bg] = index.pvp[bg] or {}
    table.insert(index.pvp[bg], id)
  end
  local place
  if type(zone) == "number" and zones[zone] then
    place = zones[zone]
  else
    local classes = tonumber(QDB.Quest(id, "requiredClasses")) or 0
    local tag = ARLE.Bridge.Questie and ARLE.Bridge.Questie.QuestTag and ARLE.Bridge.Questie.QuestTag(id)
    -- (class quests are filed under their class; tagged ones under a zone)
    if (classes > 0 and type(zone) == "number" and zone < 0) or DUNGEON_TAGS[tag or 0] then
      place = ObjectivePlace(id, zones)
    end
  end
  place = Place(place)
  if place then
    local list = index.byPlace[place] or {}
    index.byPlace[place] = list
    list[#list + 1] = id
  end
end

-- Sliced with mod:After (dropped if the feature goes off: the next enable
-- starts again from the top).
local function BuildIndex()
  if index.state == "building" or index.state == "ready" then
    return
  end
  local zones = QDB.Ready() and QDB.InstanceZones()
  if not zones then
    index.state = nil -- (QuestieDB still loading: tried again later)
    return
  end
  local ids = QDB.AllQuestIds()
  index.state, index.byPlace, index.count, index.t05, index.t05set, index.pvp = "building", {}, 0, {}, {}, {}
  local i = 0
  local function Step()
    local stop = math.min(#ids, i + SLICE)
    for j = i + 1, stop do
      pcall(IndexOne, ids[j], zones)
    end
    i = stop
    index.count = i
    if i < #ids then
      mod:After(0, Step)
    else
      index.state = "ready"
      mod:Debug("quest index: %d quests read", #ids)
      H.Render()
    end
  end
  Step()
end

local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7,
  MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11 }

local function HasBit(mask, bitIndex)
  return math.floor(mask / 2 ^ (bitIndex - 1)) % 2 == 1
end

local Quests -- (defined below; the objectives use it)

-- Every quest ID and name DungeonJournal lists, in any dungeon (built once).
local journalKnown
function tab.JournalKnown()
  if not journalKnown then
    journalKnown = {}
    local fdj = H.FDJ()
    for _, d in pairs(fdj and fdj.DB or {}) do
      for _, q in ipairs(type(d) == "table" and type(d.quests) == "table" and d.quests or {}) do
        if type(q) == "table" then
          if tonumber(q.id) then
            journalKnown[tonumber(q.id)] = true
          end
          if type(q.name) == "string" then
            journalKnown[q.name] = true
          end
        end
      end
    end
  end
  return journalKnown
end
local extraCache = {}
-- QuestieDB's quests for the dungeon that DungeonJournal's list doesn't have,
-- for this character's faction and class (no profession quests).
local function Extras(dungeon, known)
  if not mod.db.questExtras or not QDB.Ready() then
    return {}
  end
  if index.state ~= "ready" then
    BuildIndex()
    return {}
  end
  if extraCache[dungeon] then
    return extraCache[dungeon]
  end
  -- Quests DungeonJournal lists under any dungeon stay out: its lists are
  -- per wing, QuestieDB's zone is the whole instance (Blackrock Spire, Dire
  -- Maul, Scarlet Monastery), so the other wing's quests would come in here.
  for k in pairs(tab.JournalKnown()) do
    known[k] = true
  end
  local list = tab.QuestieQuests(index.byPlace[Place(dungeon)] or {}, known)
  extraCache[dungeon] = list
  return list
end

-- QuestieDB quests as list entries, for this character, one per name.
-- QuestieDB keeps many copies of some quests: the Tier 0.5 ones once per class
-- and again without a class (Forever's), 17 "Just Compensation" for one
-- faction. Of a name, the copy for your class wins, then one with a quest
-- giver, then the lowest ID. known: { [id] = true, [name] = true } to leave out.
function tab.QuestieQuests(ids, known)
  known = known or {}
  local class = PlayerClass()
  local myBit = class and CLASS_IDS[class]
  local best, order = {}, {}
  for _, id in ipairs(ids) do
    local classes = tonumber(QDB.Quest(id, "requiredClasses")) or 0
    local forClass = classes == 0 or (myBit and HasBit(classes, myBit))
    local skill = QDB.Quest(id, "requiredSkill")
    local name = ARLE.Lib.Str(QDB.Quest(id, "name"))
    if name and not known[id] and not known[name] and forClass and not (type(skill) == "table" and skill[1])
        and LQ.ForMySide(id) then
      local by = QDB.Quest(id, "startedBy")
      local rank = (classes > 0 and 0 or 2) + ((type(by) == "table" and next(by)) and 0 or 1)
      local cur = best[name]
      if not cur then
        order[#order + 1] = name
      end
      if not cur or rank < cur.rank or (rank == cur.rank and id < cur.id) then
        best[name] = { id = id, rank = rank, classes = classes }
      end
    end
  end
  local list = {}
  for _, name in ipairs(order) do
    local b = best[name]
    list[#list + 1] = { id = b.id, name = name, level = tonumber(QDB.Quest(b.id, "questLevel")),
      requires = tonumber(QDB.Quest(b.id, "requiredLevel")), source = "questie",
      classOnly = (b.classes > 0 and class) or nil }
  end
  return list
end

function tab:ClearCaches()
  wipe(extraCache)
end

Quests = function(dungeon)
  local fdj = H.FDJ()
  local d = fdj and dungeon and fdj.DB[dungeon]
  local faction = UnitFactionGroup and UnitFactionGroup("player")
  local list, known = {}, {}
  for _, q in ipairs(d and d.quests or {}) do
    local id = type(q) == "table" and tonumber(q.id)
    if id then
      known[id] = true
    end
    if type(q.name) == "string" then
      known[q.name] = true
    end
    if id and q.name
        and (not q.faction or q.faction == "Both" or q.faction == "Neutral" or not faction or q.faction == faction)
        and ForMe(q, id) then
      list[#list + 1] = q
    end
  end
  if dungeon then
    for _, q in ipairs(Extras(dungeon, known)) do
      list[#list + 1] = q
    end
  end
  return list
end
tab.Quests = Quests

-------------------------------------------------------------------------------
-- Objectives: what a quest is part of beyond the dungeon (a raid attunement,
-- Tier 0.5, your class, a profession). Their own sections in a dungeon's list,
-- and their own views from the Home page.
-------------------------------------------------------------------------------

local ATTUNE = { [4322] = "ONYXIA", [6502] = "ONYXIA", [4903] = "ONYXIA", [4974] = "ONYXIA", [6569] = "ONYXIA",
  [6602] = "ONYXIA", [7848] = "MOLTENCORE", [7761] = "BLACKWING" }
local ATTUNE_LABEL = { ONYXIA = "Onyxia attunement", MOLTENCORE = "Molten Core attunement",
  BLACKWING = "Blackwing Lair attunement" }
local ATTUNE_ICON = { ONYXIA = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
  MOLTENCORE = "Interface\\Icons\\Spell_Fire_Volcano", BLACKWING = "Interface\\Icons\\INV_Misc_Head_Dragon_Black" }
local PVP_LABEL = { AV = "Alterac Valley", WSG = "Warsong Gulch", AB = "Arathi Basin" }
local PVP_ICON = { AV = "Interface\\Icons\\INV_Jewelry_Necklace_21", WSG = "Interface\\Icons\\INV_Misc_Rune_07",
  AB = "Interface\\Icons\\INV_Jewelry_Amulet_07" }
local OBJ = {
  dungeon = { label = "Dungeon quests", icon = H.ICON.dungeon, order = 1 },
  class = { label = "Class quests", icon = "Interface\\Icons\\INV_Misc_Book_09", order = 2 },
  t05 = { label = "Tier 0.5 (Dungeon Set 2)", icon = "Interface\\Icons\\INV_Chest_Plate03", order = 4 },
  prof = { label = "Profession quests", icon = "Interface\\Icons\\Trade_BlackSmithing", order = 5 },
}

local function AttunementOf(q, id)
  local fdj = H.FDJ() or {}
  local a = q.attunement or (type(fdj.ATTUNEMENT_QUEST_IDS) == "table" and fdj.ATTUNEMENT_QUEST_IDS[id]) or ATTUNE[id]
  return a and tostring(a):upper() or nil
end

local t05Cache = {}
-- Tier 0.5: given by its NPCs, or one step from such a quest.
local function IsT05(id)
  if index.state ~= "ready" or not id then
    return false
  end
  if t05Cache[id] ~= nil then
    return t05Cache[id]
  end
  local yes = index.t05set[id] or false
  if not yes then
    local nxt = tonumber(QDB.Quest(id, "nextQuestInChain"))
    yes = (nxt and index.t05set[nxt]) or false
    for _, f in ipairs({ "preQuestGroup", "preQuestSingle" }) do
      for _, pre in ipairs(IDs(QDB.Quest(id, f))) do
        yes = yes or index.t05set[pre] or false
      end
    end
  end
  t05Cache[id] = yes and true or false
  return t05Cache[id]
end

-- key, label, icon of what a quest is part of ("dungeon" for plain ones).
local function ObjectiveOf(q)
  local id = tonumber(q.id)
  local a = AttunementOf(q, id)
  if a then
    local fdj = H.FDJ() or {}
    local icon = type(fdj.ATTUNEMENT_QUEST_ICONS) == "table" and fdj.ATTUNEMENT_QUEST_ICONS[a] or ATTUNE_ICON[a]
    return "attune:" .. a, ATTUNE_LABEL[a] or (a:sub(1, 1) .. a:sub(2):lower() .. " attunement"),
      icon or OBJ.class.icon, 3
  end
  if IsT05(id) then
    return "t05", OBJ.t05.label, OBJ.t05.icon, OBJ.t05.order
  end
  if q.classOnly then
    return "class", OBJ.class.label, OBJ.class.icon, OBJ.class.order
  end
  if q.profession then
    return "prof", OBJ.prof.label, OBJ.prof.icon, OBJ.prof.order
  end
  return "dungeon", OBJ.dungeon.label, OBJ.dungeon.icon, OBJ.dungeon.order
end
tab.ObjectiveOf = ObjectiveOf

-- Every quest of an objective, for this character (all dungeons, and for
-- Tier 0.5 and attunements the QuestieDB quests wherever they are).
local objCache = {}
local function ObjectiveQuests(key)
  if objCache[key] then
    return objCache[key]
  end
  local list, seen = {}, {}
  local function Add(q)
    local id = tonumber(q.id)
    if id and not seen[id] and not seen[q.name] then
      seen[id], seen[q.name] = true, true
      list[#list + 1] = q
    end
  end
  for _, d in ipairs(H.Dungeons()) do
    for _, q in ipairs(Quests(d)) do
      if ObjectiveOf(q) == key then
        Add(q)
      end
    end
  end
  if key:find("^pvp:") and index.state == "ready" then
    for _, q in ipairs(tab.QuestieQuests(index.pvp[key:match("^pvp:(.+)$")] or {}, seen)) do
      Add(q)
    end
  elseif key == "t05" and index.state == "ready" then
    for _, q in ipairs(tab.QuestieQuests(index.t05, seen)) do
      Add(q)
    end
  elseif key:find("^attune:") and QDB.Ready() then
    local want = key:match("^attune:(.+)$")
    local ids = {}
    for id, a in pairs(ATTUNE) do
      if a == want then
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    for _, q in ipairs(tab.QuestieQuests(ids, seen)) do
      Add(q)
    end
  end
  if index.state == "ready" then
    objCache[key] = list
  end
  return list
end
tab.ObjectiveQuests = ObjectiveQuests

local clearExtras = tab.ClearCaches
function tab:ClearCaches()
  clearExtras(self)
  wipe(objCache)
  wipe(t05Cache)
end

function tab.ObjectiveLabel(key)
  if key and key:find("^pvp:") then
    local b = key:match("^pvp:(.+)$")
    return PVP_LABEL[b] or b, PVP_ICON[b]
  end
  if key and key:find("^attune:") then
    local a = key:match("^attune:(.+)$")
    return ATTUNE_LABEL[a] or (a .. " attunement"), ATTUNE_ICON[a]
  end
  local o = OBJ[key or ""]
  return o and o.label or tostring(key), o and o.icon
end

-- Every quest DungeonJournal describes, by ID (any dungeon's list), built once.
local journalByID
local function JournalQuest(id)
  if not journalByID then
    journalByID = {}
    local fdj = H.FDJ()
    for _, d in pairs(fdj and fdj.DB or {}) do
      for _, q in ipairs(type(d) == "table" and d.quests or {}) do
        local qid = type(q) == "table" and tonumber(q.id)
        if qid and not journalByID[qid] then
          journalByID[qid] = q
        end
      end
    end
  end
  return journalByID[id]
end

local function Str(v)
  return type(v) == "string" and v ~= "" and v or nil
end

-- What is known of any quest (a chain step too): id, name, level, requires,
-- objective, pickup, turnin, startsInDungeon. DungeonJournal's entry, its
-- pre-quest details, then QuestieDB, then the game.
local infoCache = {}
local function Info(id, fallbackName)
  id = tonumber(id)
  if not id then
    return nil
  end
  local cached = infoCache[id]
  if cached then
    return cached
  end
  local fdj = H.FDJ() or {}
  local q = JournalQuest(id) or {}
  local det = type(fdj.QUEST_PREREQ_DETAILS) == "table" and fdj.QUEST_PREREQ_DETAILS[id] or {}
  local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
  local info = {
    id = id,
    name = Str(q.name) or Str(QDB.Quest(id, "name")) or Str(title) or Str(fallbackName) or ("Quest " .. id),
    level = tonumber(q.level) or tonumber(det.level) or tonumber(QDB.Quest(id, "questLevel")),
    requires = tonumber(q.requires) or tonumber(det.requires) or tonumber(QDB.Quest(id, "requiredLevel")),
    objective = Str(q.objective) or Str(det.objective),
    pickup = Str(q.pickup) or Str(det.pickup),
    turnin = Str(q.turnin) or Str(det.turnin),
    note = Str(q.note),
    startsInDungeon = (q.startsInDungeon or det.startsInDungeon) and true or false,
  }
  -- Who starts and ends it, from QuestieDB, when DungeonJournal doesn't say.
  local function Giver(field)
    local by = QDB.Quest(id, field)
    if type(by) ~= "table" then
      return nil
    end
    local npc = type(by[1]) == "table" and by[1][1]
    local obj = type(by[2]) == "table" and by[2][1]
    local nameOf = (npc and Str(QDB.Npc(npc, "name"))) or (obj and Str(QDB.Object(obj, "name")))
    if not nameOf then
      return nil
    end
    local spawns = npc and QDB.Npc(npc, "spawns") or (obj and QDB.Object(obj, "spawns"))
    local zoneName
    if type(spawns) == "table" then
      for areaId in pairs(spawns) do
        zoneName = Str((ARLE.Lib.Call(C_Map and C_Map.GetAreaInfo, areaId)))
        break
      end
    end
    return nameOf .. (zoneName and (", " .. zoneName) or "")
  end
  info.pickup = info.pickup or Giver("startedBy")
  info.turnin = info.turnin or Giver("finishedBy")
  info.classes = tonumber(QDB.Quest(id, "requiredClasses"))
  if not info.startsInDungeon and info.pickup then
    local ok, inside = FDJCall("StartsInsideDungeon", info.pickup)
    info.startsInDungeon = ok and inside and true or false
  end
  if not info.objective then
    local text = QDB.Quest(id, "objectivesText")
    if type(text) == "table" then
      local parts = {}
      for _, line in ipairs(text) do
        if Str(line) then
          parts[#parts + 1] = line
        end
      end
      info.objective = #parts > 0 and table.concat(parts, " ") or nil
    end
  end
  infoCache[id] = info
  return info
end

-- A reward text split into its gold (copper, from "1g 80s"-style tokens) and
-- everything else ("Undercity +150"), the way DungeonJournal reads it.
local function SplitReward(text)
  local money, kept = 0, {}
  -- (separators: "|", a new line, or a bullet; gsub first, a byte class
  -- would split other UTF-8 letters)
  local raw = (Str(text) or ""):gsub("\n", "|"):gsub("\226\128\162", "|"):gsub("\194\183", "|")
  for token in raw:gmatch("[^|]+") do
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if token ~= "" and not token:find("^[%d,%.]+%s*XP$") then
      if token:gsub("%d+%s*[gsc]", ""):gsub("%s+", "") == "" then
        for amount, unit in token:gmatch("(%d+)%s*([gsc])") do
          money = money + (tonumber(amount) or 0) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
        end
      else
        kept[#kept + 1] = token
      end
    end
  end
  return money, #kept > 0 and table.concat(kept, "  \194\183  ") or nil
end

-- The gold a quest gives, in copper (0 when unknown): DungeonJournal's reward
-- text, its own gold table for chain steps, else the game (quest in the log
-- or its data loaded). Only the fixed sources are cached.
local moneyCache = {}
local function Money(id)
  id = tonumber(id)
  if not id then
    return 0
  end
  if moneyCache[id] then
    return moneyCache[id]
  end
  local q = JournalQuest(id) or {}
  local money = SplitReward(Str(q.rewardSummary) or q.rewards)
  if money == 0 then
    local fdj = H.FDJ() or {}
    local fallback = type(fdj.PREREQ_REWARD_MONEY_FALLBACK) == "table" and fdj.PREREQ_REWARD_MONEY_FALLBACK[id]
    money = tonumber(fallback) or 0
  end
  if money > 0 then
    moneyCache[id] = money
    return money
  end
  if GetQuestLogRewardMoney then
    local ok, value = pcall(GetQuestLogRewardMoney, id)
    if ok and not ARLE.Lib.IsSecret(value) and type(value) == "number" and value > 0 then
      return value
    end
  end
  return 0
end

-- Copper with the game's coin icons (plain "1g 80s" if that isn't there).
local function CoinText(copper, size)
  if GetCoinTextureString then
    local ok, text = pcall(GetCoinTextureString, copper, size)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end
  return ARLE.Lib.FormatMoney(copper)
end

local function Objectives(id)
  local list = C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(id)
  return type(list) == "table" and list or {}
end

-- "3/8" summed over the quest's objectives (and 3, 8), or nil.
local function Progress(id)
  local have, need = 0, 0
  for _, o in ipairs(Objectives(id)) do
    if tonumber(o.numRequired) and o.numRequired > 0 then
      have = have + math.min(tonumber(o.numFulfilled) or 0, o.numRequired)
      need = need + o.numRequired
    end
  end
  if need > 0 then
    return have .. "/" .. need, have, need
  end
end


-- The quests before this one, oldest first: { {id, name, anyOf}, ... } and
-- where they came from ("journal", "guide" or "questie"), or nil. anyOf: one
-- of several alternatives (QuestieDB's preQuestSingle), the others named.
local chainCache = {}
local function Before(id)
  id = tonumber(id)
  if chainCache[id] ~= nil then
    return chainCache[id] or nil, chainCache[id] and chainCache[id].source
  end
  local fdj = H.FDJ() or {}
  local curated = type(fdj.QUEST_PREREQ_CHAINS) == "table" and fdj.QUEST_PREREQ_CHAINS[id]
  local steps
  if type(curated) == "table" and #curated > 0 then
    steps = { source = (type(fdj.QUEST_GUIDE_CHAINS) == "table" and fdj.QUEST_GUIDE_CHAINS[id]) and "guide"
      or "journal" }
    for _, step in ipairs(curated) do
      if type(step) == "table" and tonumber(step.id) and tonumber(step.id) ~= id then
        steps[#steps + 1] = { id = tonumber(step.id), name = step.name }
      end
    end
  elseif QDB.Ready() then
    -- Walk back: every quest of preQuestGroup, and one of preQuestSingle
    -- (one already done if there is, else the first), deepest first.
    steps = { source = "questie" }
    local seen = { [id] = true }
    local function Walk(qid, depth)
      if depth > WALK_MAX or #steps >= CHAIN_MAX then
        return
      end
      for _, pre in ipairs(IDs(QDB.Quest(qid, "preQuestGroup"))) do
        if not seen[pre] then
          seen[pre] = true
          Walk(pre, depth + 1)
          steps[#steps + 1] = { id = pre }
        end
      end
      local single = IDs(QDB.Quest(qid, "preQuestSingle"))
      if #single > 0 then
        local pick = single[1]
        for _, pre in ipairs(single) do
          if IsDone(pre) then
            pick = pre
            break
          end
        end
        if not seen[pick] then
          seen[pick] = true
          Walk(pick, depth + 1)
          local others = {}
          for _, pre in ipairs(single) do
            if pre ~= pick then
              others[#others + 1] = pre
            end
          end
          steps[#steps + 1] = { id = pick, anyOf = #others > 0 and others or nil }
        end
      end
    end
    Walk(id, 1)
  end
  if steps and #steps == 0 then
    steps = nil
  end
  chainCache[id] = steps or false
  return steps, steps and steps.source
end

-- The quests after this one (QuestieDB's nextQuestInChain), in order.
local afterCache = {}
local function After(id)
  id = tonumber(id)
  if afterCache[id] ~= nil then
    return afterCache[id] or nil
  end
  local steps = {}
  local seen = { [id] = true }
  local next = tonumber(QDB.Quest(id, "nextQuestInChain"))
  while next and next > 0 and not seen[next] and #steps < WALK_MAX do
    seen[next] = true
    steps[#steps + 1] = { id = next }
    next = tonumber(QDB.Quest(next, "nextQuestInChain"))
  end
  afterCache[id] = #steps > 0 and steps or false
  return afterCache[id] or nil
end

-- The whole tree of quests that unlock this one, as rows top to bottom
-- (oldest first): { id, depth, alt (one of a "one of" group), head (the
-- group's header: n alternatives), current }. A step with one prerequisite
-- keeps its depth (a plain chain stays flat); a step with several puts each
-- line one deeper. DungeonJournal's curated chain (not a guide) is the
-- trunk; QuestieDB fills in what each step needs in turn.
local treeCache = {}
local function Tree(id)
  id = tonumber(id)
  if treeCache[id] ~= nil then
    return treeCache[id] or nil
  end
  local rows, seen = {}, { [id] = true }
  local class = PlayerClass()
  local myBit = class and CLASS_IDS[class]
  -- A prerequisite this character could take: its faction, its class (the
  -- Tier 0.5 steps exist once per class), one per name.
  local names = { [Info(id).name] = true } -- one step per name in the whole tree
  local function Mine(pre)
    local classes = tonumber(QDB.Quest(pre, "requiredClasses")) or 0
    if classes > 0 and not (myBit and HasBit(classes, myBit)) then
      return false
    end
    if not LQ.ForMySide(pre) then
      return false
    end
    local name = Info(pre).name
    if type(name) == "string" then
      if names[name] then
        return false
      end
      names[name] = true
    end
    return true
  end
  local function Needs(qid)
    local group, single = {}, {}
    if QDB.Ready() then
      for _, pre in ipairs(IDs(QDB.Quest(qid, "preQuestGroup"))) do
        if not seen[pre] and Mine(pre) then
          group[#group + 1] = pre
        end
      end
      for _, pre in ipairs(IDs(QDB.Quest(qid, "preQuestSingle"))) do
        if not seen[pre] and Mine(pre) then
          single[#single + 1] = pre
        end
      end
    end
    return group, single
  end
  local Emit
  -- qid's prerequisites, then qid itself.
  Emit = function(qid, depth, alt, budget)
    if #rows >= TREE_MAX then
      return
    end
    seen[qid] = true
    if budget > 0 then
      local group, single = Needs(qid)
      local lines = #group + (#single > 0 and 1 or 0)
      local inner = lines > 1 and depth + 1 or depth
      for _, pre in ipairs(group) do
        if not seen[pre] then
          Emit(pre, inner, false, budget - 1)
        end
      end
      if #single == 1 then
        Emit(single[1], inner, false, budget - 1)
      elseif #single > 1 then
        -- One of several: the one done (else the first) with its own chain,
        -- the others as single rows under a header.
        local pick = single[1]
        for _, pre in ipairs(single) do
          if IsDone(pre) then
            pick = pre
          end
        end
        rows[#rows + 1] = { head = #single, depth = inner + 1 }
        Emit(pick, inner + 1, true, budget - 1)
        for _, pre in ipairs(single) do
          if pre ~= pick and not seen[pre] then
            seen[pre] = true
            rows[#rows + 1] = { id = pre, depth = inner + 1, alt = true }
          end
        end
      end
    end
    rows[#rows + 1] = { id = qid, depth = depth, alt = alt, current = qid == id }
  end
  local steps, source = Before(id)
  if steps and source ~= "guide" then
    -- (DungeonJournal's curated chain names every faction's and class's copy
    -- of a step: only this character's, once)
    local trunk = {}
    for _, step in ipairs(steps) do
      if not seen[step.id] and Mine(step.id) then
        trunk[#trunk + 1] = step.id
      end
      seen[step.id] = true
    end
    for _, sid in ipairs(trunk) do
      Emit(sid, 0, false, WALK_MAX)
    end
    rows[#rows + 1] = { id = id, depth = 0, current = true }
  else
    Emit(id, 0, false, WALK_MAX)
  end
  -- (a quest with nothing before it has no tree)
  if #rows <= 1 then
    rows = nil
  end
  treeCache[id] = rows or false
  return rows
end
tab.Tree = Tree

-- Optional quests that point to this one (QuestieDB breadcrumbs).
local function LeadIns(id)
  local list = {}
  for _, b in ipairs(IDs(QDB.Quest(id, "breadcrumbs"))) do
    if LQ.ForMySide(b) then
      list[#list + 1] = b
    end
  end
  return list
end

-- How many of the quests before this one aren't done (a guide chain is
-- how to do it, not what unlocks it: it never blocks). A "one of" group
-- counts once, and not at all when one of it is done.
local function Missing(id)
  local rows = Tree(id)
  if not rows then
    return 0
  end
  local n = 0
  for i, r in ipairs(rows) do
    if r.head then
      local done = false
      for j = i + 1, #rows do
        local o = rows[j]
        if o.depth < r.depth then
          break
        end
        if o.alt and o.depth == r.depth and o.id and IsDone(o.id) then
          done = true
        end
      end
      if not done then
        n = n + 1
      end
    elseif r.id and not r.current and not r.alt and not IsDone(r.id) then
      n = n + 1
    end
  end
  return n
end

-- The player's state for a quest: code, progress.
local function MyState(q)
  local id = tonumber(q.id)
  if IsDone(id) then
    return "d"
  end
  if InLog(id) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then
      return "r"
    end
    return "l", Progress(id)
  end
  if (UnitLevel("player") or 0) < (tonumber(q.requires) or 0) then
    return "n"
  end
  if Missing(id) > 0 then
    return "c"
  end
  return "a"
end
tab.MyState = MyState

-- party[name] = { dungeon, states = { [questID] = { code, progress } } }
local party = {}
tab.data = party

-------------------------------------------------------------------------------
-- Comms: "QS <dungeon>~<part>~<total>~id:code[:have/need],..."
-------------------------------------------------------------------------------

local lastSent = {}
function tab:Send(dungeon, channel, force)
  local list = {}
  for _, q in ipairs(Quests(dungeon)) do
    local code, progress = MyState(q)
    list[#list + 1] = q.id .. ":" .. code .. (progress and (":" .. progress) or "")
  end
  local key = table.concat(list, ",")
  if not force and lastSent[dungeon] == key then
    return
  end
  lastSent[dungeon] = key
  H.SendChunks("QS", dungeon, list, ",", channel)
end

H.Comm("QS", function(sender, payload)
  if not mod._active then
    return
  end
  local dungeon, part, list = payload:match("^(.-)~(%d+)~%d+~(.*)$")
  if not dungeon then
    return
  end
  local p = party[sender]
  if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
    p = { dungeon = dungeon, states = {} }
    party[sender] = p
  end
  for entry in list:gmatch("[^,]+") do
    local id, code, progress = entry:match("^(%d+):(%a)(.*)$")
    if id then
      p.states[tonumber(id)] = { code = code, progress = progress:match("^:(.+)$") }
    end
  end
  H.Render()
end)

function tab:OnQuestChange()
  wipe(chainCache) -- (a preQuestSingle pick follows what's done)
  if H.shown then
    H.QueueSend(H.shown, "quests")
  end
  H.Render()
end

function tab:Prune(keep)
  for name in pairs(party) do
    if not keep[name] then
      party[name] = nil
    end
  end
end

-------------------------------------------------------------------------------
-- View
--   list:    [!] Kirtonos the Herald                    [c][c]
--                Lv 60 · ready to turn in
--   details: a quest card: banner (mark, name, tags), a status strip, the
--            objective, where it starts and ends, rewards like the game's
--            quest frame, the chain as a track of steps, the party
-------------------------------------------------------------------------------

local selected = {} -- dungeon (or "obj:<objective>") -> quest ID

-- What the tab shows: a dungeon's quests, or an objective's (from Home).
local function ViewKey()
  return H.objective and ("obj:" .. H.objective) or H.shown
end

local function CurrentQuests()
  if H.objective then
    return ObjectiveQuests(H.objective)
  end
  return Quests(H.shown)
end

-- Opens a quest from elsewhere (Home): its dungeon or objective, selected.
function tab.Preselect(key, id)
  selected[key] = id
end
local listPool, sectionPool, listEmpty
local detail = {}

-- Per state: the picture, the strip's colour, its words.
local LOOK = {
  r = { icon = H.ICON.active, color = { 0.35, 1, 0.45 }, short = "|cff59ff73ready to turn in|r" },
  l = { icon = H.ICON.active, color = nil, short = "in your quest log" },
  a = { icon = H.ICON.available, color = { 1, 0.82, 0 }, short = "|cffffd100available|r" },
  c = { icon = H.ICON.lock, color = { 1, 0.45, 0.35 }, short = nil },
  n = { icon = H.ICON.available, color = { 0.6, 0.6, 0.6 }, short = nil, grey = true },
  d = { icon = H.ICON.ready, color = { 0.6, 0.6, 0.6 }, short = "|cff999999done|r" },
}
local SPEECH = "Interface\\GossipFrame\\GossipGossipIcon"
local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"

local function Filter()
  return mod.db.questFilter or "all"
end

local function DifficultyColor(level)
  if GetQuestDifficultyColor and tonumber(level) then
    local c = GetQuestDifficultyColor(tonumber(level))
    if type(c) == "table" and c.r then
      return c.r, c.g, c.b
    end
  end
  return 1, 0.82, 0
end

local function Hex(r, g, b)
  return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
end

local function PartyStates(id)
  local out = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      local p = party[m.name]
      if p and p.dungeon == H.shown then
        out[#out + 1] = { member = m, state = p.states[tonumber(id)] }
      end
    end
  end
  return out
end

local function Share(id)
  local fdj = H.FDJ()
  if fdj and fdj.ShareQuestByID then
    pcall(fdj.ShareQuestByID, tonumber(id))
    return
  end
  if C_QuestLog.SetSelectedQuest then
    pcall(C_QuestLog.SetSelectedQuest, id)
  elseif SelectQuestLogEntry then
    pcall(SelectQuestLogEntry, C_QuestLog.GetLogIndexForQuestID(id))
  end
  if QuestLogPushQuest then
    pcall(QuestLogPushQuest)
  end
end

local function Link(id, name, level)
  LQ.InsertLink(tonumber(id), name, tonumber(level))
end

local function PartyTooltip(owner)
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText("Party", 1, 1, 1)
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if m.unit == "player" or (p and p.dungeon == H.shown) then
      GameTooltip:AddDoubleLine(ColorName(m), "shares quests", 1, 1, 1, 0.45, 0.9, 0.5)
    else
      GameTooltip:AddDoubleLine(ColorName(m), H.Quiet(m), 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Class icons on a quest: ARL members in the party.", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Full: has it in the quest log", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cffffd100Gold edge|r: ready to turn in", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Faded: can pick it up", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

-- A chain step's hover: what is known of it.
local function StepTooltip(row)
  local info = Info(row.id, row.stepName)
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetText(info.name, DifficultyColor(info.level))
  local lv = {}
  if info.level then
    lv[#lv + 1] = "Level " .. info.level
  end
  if info.requires then
    lv[#lv + 1] = "needs " .. info.requires
  end
  if #lv > 0 then
    GameTooltip:AddLine(table.concat(lv, "  ·  "), 0.7, 0.7, 0.7)
  end
  if info.objective then
    GameTooltip:AddLine(info.objective, 1, 1, 1, true)
  end
  if info.pickup then
    GameTooltip:AddLine(H.Inline(H.ICON.available) .. " " .. info.pickup, 0.85, 0.85, 0.85, true)
  end
  if info.turnin then
    GameTooltip:AddLine(H.Inline(H.ICON.active) .. " " .. info.turnin, 0.85, 0.85, 0.85, true)
  end
  local money = Money(row.id)
  if money > 0 then
    GameTooltip:AddLine("Reward: " .. CoinText(money, 12), 1, 1, 1)
  end
  if row.anyOf then
    local names = {}
    for _, other in ipairs(row.anyOf) do
      names[#names + 1] = Info(other).name
    end
    GameTooltip:AddLine("Or instead: " .. table.concat(names, ", "), 0.6, 0.8, 1, true)
  end
  if row.source == "questie" then
    GameTooltip:AddLine("Chain from QuestieDB.", 0.5, 0.5, 0.5)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine((row.listed and "Click: open it.  " or "") .. "Shift-click: link it.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local chainOpen = false -- the long chain shown whole (OneMoreQuest's fold)

local function Select(id)
  local key = ViewKey()
  if key and selected[key] ~= id then
    selected[key] = id
    chainOpen = false
    H.DetailToTop()
  end
  H.Picked()
end

-- A line with a small picture on its left: where it starts, an objective...
local function IconLine(parent)
  local f = CreateFrame("Frame", nil, parent)
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(16, 16)
  f.icon:SetPoint("TOPLEFT", 8, 1)
  f.text = Kit.Text(f, "GameFontHighlight")
  f.text:SetPoint("TOPLEFT", 30, -1)
  f.text:SetWordWrap(true)
  return f
end

-- y = PlaceLine(f, y, width, icon, text, color)
local function PlaceLine(f, y, width, icon, text, color)
  f.icon:SetTexture(icon)
  f.text:SetWidth(math.max(width - 36, 40))
  f.text:SetText(text or "")
  local c = color or { 0.9, 0.9, 0.9 }
  f.text:SetTextColor(c[1], c[2], c[3])
  local h = math.max(f.text:GetStringHeight() or 14, 16) + 2
  f:SetHeight(h)
  return H.Place(f, y, h, 3)
end

-- A reward, the way the game's quest frame shows one: icon, name beside it.
local function RewardCell(parent)
  local c = CreateFrame("Button", nil, parent)
  c:SetHeight(36)
  c.bg = c:CreateTexture(nil, "BACKGROUND")
  c.bg:SetAllPoints()
  c.pic = H.Pic(c, 32)
  c.pic:SetPoint("LEFT", 2, 0)
  c.name = Kit.Text(c, "GameFontHighlightSmall")
  c.name:SetPoint("LEFT", c.pic, "RIGHT", 6, 0)
  c.name:SetPoint("RIGHT", -4, 0)
  c.name:SetWordWrap(true)
  if c.name.SetMaxLines then
    c.name:SetMaxLines(2)
  end
  c.hl = c:CreateTexture(nil, "HIGHLIGHT")
  c.hl:SetAllPoints()
  c.hl:SetColorTexture(1, 1, 1, 0.06)
  S(c, "OnEnter", function(self)
    GameTooltip:SetOwner(self, TooltipSide(self))
    GameTooltip:SetItemByID(self.itemID)
    if self.gain then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format("Forever Leveling BiS: |cff66ff66+%.1f|r for you", self.gain), 1, 1, 1)
    end
    GameTooltip:Show()
  end)
  S(c, "OnLeave", GameTooltip_Hide)
  S(c, "OnClick", function(self)
    if IsModifiedClick and IsModifiedClick("CHATLINK") then
      local _, link = H.GetItemInfo(self.itemID)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
    end
  end)
  return c
end

-- The status strip under the banner: a tinted band with a mark and a few words
-- (and the quest's progress).
local function Strip(parent)
  local s = CreateFrame("Frame", nil, parent)
  s:SetHeight(28)
  s.bg = s:CreateTexture(nil, "BACKGROUND")
  s.bg:SetAllPoints()
  s.edge = s:CreateTexture(nil, "ARTWORK")
  s.edge:SetWidth(3)
  s.edge:SetPoint("TOPLEFT")
  s.edge:SetPoint("BOTTOMLEFT")
  s.icon = s:CreateTexture(nil, "ARTWORK")
  s.icon:SetSize(18, 18)
  s.icon:SetPoint("LEFT", 10, 0)
  s.text = Kit.Text(s, "GameFontHighlight")
  s.text:SetPoint("LEFT", s.icon, "RIGHT", 6, 0)
  s.right = Kit.Text(s, "GameFontHighlight")
  s.right:SetPoint("RIGHT", -10, 0)
  s.right:SetJustifyH("RIGHT")
  s.bar = H.Bar(s)
  s.bar:SetHeight(3)
  s.bar:SetPoint("BOTTOMLEFT", 3, 0)
  s.bar:SetPoint("BOTTOMRIGHT", 0, 0)
  return s
end

function tab:Create(bar, list, detailFrame)
  self.filters = H.FilterButtons(bar, {
    { key = "all", label = "All", width = 32, tip = "Every quest of this dungeon for your character" },
    { key = "todo", label = "To do", width = 42, tip = "Quests you haven't done yet" },
    { key = "party", label = "Party", width = 42, tip = "Quests someone in the party (you too) has in their quest log" },
    { key = "class", label = "Class", width = 42, tip = "Your class's quests for this dungeon" },
  }, Filter, function(key)
    mod.db.questFilter = key
  end)
  self.party = H.PartyStrip(bar)
  self.party:SetPoint("RIGHT", 0, 0)
  S(self.party, "OnEnter", PartyTooltip)
  S(self.party, "OnLeave", GameTooltip_Hide)

  listPool = H.Pool(function()
    local r = H.Row(list, ROW_H, 22)
    S(r, "OnClick", function(row, button)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        Link(row.id, row.quest.name, row.quest.level)
      elseif button == "RightButton" and (row.code == "l" or row.code == "r") then
        Share(row.id)
      else
        Select(row.id)
      end
    end)
    H.Tip(r, function(row)
      return row.quest.name
    end, function(row)
      return ((row.code == "l" or row.code == "r") and "Right-click: share it with the party.\n" or "")
        .. "Shift-click: link it."
    end)
    return r
  end)
  sectionPool = H.Pool(function()
    return H.Section(list)
  end)
  listEmpty = H.Empty(list)

  -- The card.
  detail.frame = detailFrame
  detail.banner = H.Banner(detailFrame, 44)
  detail.share = H.SmallButton(detail.banner, "Share", 48)
  detail.share:SetPoint("TOPRIGHT", -6, -6)
  S(detail.share, "OnClick", function()
    Share(detail.id)
  end)
  H.Tip(detail.share, "Share", "Offers the quest to the party (it must be in your quest log).")
  detail.link = H.SmallButton(detail.banner, "Link", 40)
  detail.link:SetPoint("RIGHT", detail.share, "LEFT", -3, 0)
  S(detail.link, "OnClick", function()
    local info = Info(detail.id)
    if info then
      Link(info.id, info.name, info.level)
    end
  end)
  H.Tip(detail.link, "Link", "Puts the quest's link in the chat box.")
  detail.strip = Strip(detailFrame)
  detail.paras = H.Pool(function()
    return Kit.Text(detailFrame, "GameFontHighlight")
  end)
  detail.lines = H.Pool(function()
    return IconLine(detailFrame)
  end)
  detail.sections = H.Pool(function()
    return H.Section(detailFrame)
  end)
  detail.cells = H.Pool(function()
    return RewardCell(detailFrame)
  end)
  detail.steps = H.Pool(function()
    local r = H.Row(detailFrame, STEP_H, 18)
    r.up = r:CreateTexture(nil, "BORDER")
    r.up:SetWidth(2)
    r.up:SetPoint("TOP", r, "TOPLEFT", 15, 0)
    r.up:SetPoint("BOTTOM", r.pic, "TOP", 0, 0)
    r.down = r:CreateTexture(nil, "BORDER")
    r.down:SetWidth(2)
    r.down:SetPoint("TOP", r.pic, "BOTTOM", 0, 0)
    r.down:SetPoint("BOTTOM", r, "BOTTOMLEFT", 15, 0)
    S(r, "OnEnter", StepTooltip)
    S(r, "OnLeave", GameTooltip_Hide)
    S(r, "OnClick", function(row)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        local info = Info(row.id, row.stepName)
        Link(info.id, info.name, info.level)
      elseif row.listed then
        Select(row.id)
      end
    end)
    return r
  end)
  detail.members = H.Pool(function()
    return H.Row(detailFrame, 28, 22)
  end)
  detail.folds = H.Pool(function()
    local f = CreateFrame("Button", nil, detailFrame)
    f.text = Kit.Text(f, "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", 4, 0)
    f.text:SetPoint("RIGHT", -4, 0)
    f.text:SetWordWrap(false)
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    S(f, "OnClick", function()
      chainOpen = not chainOpen
      H.Render()
    end)
    return f
  end)
end

-- One quest's entry for the list and the details.
local function Entry(q)
  local code, progress, have, need = MyState(q)
  return { q = q, id = tonumber(q.id), code = code, progress = progress, have = have, need = need,
    states = PartyStates(q.id), missing = code == "c" and Missing(q.id) or 0 }
end

local function Marks(states)
  local marks = {}
  for _, ps in ipairs(states) do
    local s = ps.state and ps.state.code
    if s == "l" or s == "r" or s == "a" then
      marks[#marks + 1] = { class = ps.member.class, strong = s == "r", weak = s == "a" }
    end
  end
  return marks
end

-- The quest's state in a few words, for the list's second line.
local function StateWords(e)
  if e.code == "c" then
    return H.Inline(H.ICON.lock, 11) .. " |cffff7359" .. e.missing .. " earlier quest" .. (e.missing == 1 and "" or "s")
      .. " first|r"
  elseif e.code == "n" then
    return "|cff999999unlocks at " .. (tonumber(e.q.requires) or "?") .. "|r"
  elseif e.code == "l" then
    return e.progress or LOOK.l.short
  end
  return LOOK[e.code].short
end

local function SetStateIcon(pic, code)
  H.SetIcon(pic, LOOK[code].icon, false)
  if LOOK[code].grey then
    pic.tex:SetDesaturated(true)
  end
end

-- A list's quests with chains kept together: each quest whose earlier step
-- (its nearest one in its tree) is also listed goes right under that one,
-- one step deeper. { { e, depth }, ... }; the roots keep the list's order.
local CHAIN_INDENT = 12
local function ChainOrder(list)
  local byId, parent, kids = {}, {}, {}
  for _, e in ipairs(list) do
    byId[e.id] = e
  end
  for _, e in ipairs(list) do
    local rows = Tree(e.id)
    if rows then
      for i = #rows, 1, -1 do
        local r = rows[i]
        if r.id and not r.current and byId[r.id] and r.id ~= e.id then
          parent[e.id] = r.id
          break
        end
      end
    end
  end
  for _, e in ipairs(list) do
    local p = parent[e.id]
    if p then
      kids[p] = kids[p] or {}
      table.insert(kids[p], e)
    end
  end
  local out, placed = {}, {}
  local function Put(e, depth)
    if placed[e.id] or depth > 8 then
      return
    end
    placed[e.id] = true
    out[#out + 1] = { e = e, depth = depth }
    for _, k in ipairs(kids[e.id] or {}) do
      Put(k, depth + 1)
    end
  end
  for _, e in ipairs(list) do
    if not parent[e.id] then
      Put(e, 0)
    end
  end
  for _, e in ipairs(list) do -- (a loop in the data: whatever is left, flat)
    Put(e, 0)
  end
  return out
end

tab.ChainOrder = ChainOrder

local view
function tab:RenderList(width)
  self.filters.Paint()
  local filter = Filter()
  local members = Members()
  H.PaintPartyStrip(self.party, members, function(m)
    local p = party[m.name]
    return m.unit == "player" or (p and p.dungeon == H.shown)
  end)

  local quests = CurrentQuests()
  local key = ViewKey()
  local groups, byGroup, byID, first = {}, {}, {}, nil
  local RANK = { r = 1, l = 2, a = 3, c = 4, n = 5, d = 6 }
  for _, q in ipairs(quests) do
    local e = Entry(q)
    local anyLog = e.code == "l" or e.code == "r"
    for _, ps in ipairs(e.states) do
      local st = ps.state and ps.state.code
      anyLog = anyLog or st == "l" or st == "r"
    end
    local keep = filter == "all" or (filter == "todo" and e.code ~= "d") or (filter == "party" and anyLog)
      or (filter == "class" and q.classOnly ~= nil)
    if e.code == "d" and not mod.db.questShowDone then
      keep = false
    end
    if keep then
      -- A dungeon's list: one section per objective (plain dungeon quests
      -- first). An objective's list: one per state.
      local gk, label, icon, order
      if H.objective then
        for si, sec in ipairs(SECTIONS) do
          if sec.codes[e.code] then
            gk, label, order = "s" .. si, sec.label, si
          end
        end
      else
        gk, label, icon, order = ObjectiveOf(q)
      end
      if not byGroup[gk] then
        byGroup[gk] = { key = gk, label = label, icon = icon, order = order or 9, list = {}, todo = 0 }
        groups[#groups + 1] = byGroup[gk]
      end
      local g = byGroup[gk]
      g.list[#g.list + 1] = e
      if e.code ~= "d" then
        g.todo = g.todo + 1
      end
      byID[e.id] = e
    end
  end
  table.sort(groups, function(x, y)
    if x.order ~= y.order then
      return x.order < y.order
    end
    return x.label < y.label
  end)

  local ar, ag, ab = ARLE.Skin:Accent()
  local y = 2
  for _, g in ipairs(groups) do
    table.sort(g.list, function(a2, b2)
      if a2.code ~= b2.code then
        return (RANK[a2.code] or 9) < (RANK[b2.code] or 9)
      end
      -- In chain order: fewer quests left before it comes first.
      local ma, mb = a2.missing or 0, b2.missing or 0
      if ma ~= mb then
        return ma < mb
      end
      local la, lb = tonumber(a2.q.level) or 0, tonumber(b2.q.level) or 0
      if la ~= lb then
        return la < lb
      end
      return a2.q.name < b2.q.name
    end)
    local h = sectionPool:Get()
    local note = H.objective and ("|cff888888" .. #g.list .. "|r")
      or (g.todo > 0 and ("|cffffd100" .. g.todo .. "|r|cff888888/" .. #g.list .. "|r") or ("|cff888888" .. #g.list .. "|r"))
    H.PaintSection(h, g.label, note, g.icon)
    y = H.Place(h, y + (y > 2 and 6 or 0), 20, 2)
    for _, item in ipairs(ChainOrder(g.list)) do
      local e, depth = item.e, math.min(item.depth, 2) -- (a long chain stays readable)
      first = first or e.id
      local r = listPool:Get()
      r.id, r.quest, r.code = e.id, e.q, e.code
      SetStateIcon(r.pic, e.code)
      H.SetEdge(r.pic, ar, ag, ab, 0.2)
      local lr, lg, lb = DifficultyColor(e.q.level)
      local lv = e.q.level and (Hex(lr, lg, lb) .. "Lv " .. e.q.level .. "|r  ") or ""
      H.PaintRow(r, {
        name = e.q.name,
        sub = (e.code == "l" and e.need) and e.progress or (lv .. (StateWords(e) or "")),
        color = e.code == "d" and { 0.55, 0.55, 0.55 } or { lr, lg, lb },
        marks = Marks(e.states),
        progress = (e.code == "l" and e.need) and { e.have, e.need } or nil,
        selected = e.id == (selected[key or ""] or nil),
        tint = e.code == "r" and { 0.35, 1, 0.45, 0.07 } or nil,
        dim = e.code == "n",
      })
      r.pic:SetAlpha((e.code == "n" or e.code == "d") and 0.6 or 1)
      if e.q.classOnly then
        r.pic.corner:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[tostring(e.q.classOnly):upper()]
        if c then
          r.pic.corner:SetTexCoord(c[1], c[2], c[3], c[4])
          r.pic.corner:Show()
        else
          r.pic.corner:Hide()
        end
      else
        r.pic.corner:SetTexCoord(0, 1, 0, 1)
        r.pic.corner:Hide()
      end
      local y0 = y
      y = H.Place(r, y, ROW_H)
      -- A step of a chain sits under the quest before it: indented, with a
      -- corner line from that quest.
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", depth * CHAIN_INDENT, -y0)
      r:SetPoint("RIGHT")
      if not r.link then
        r.link = r:CreateTexture(nil, "BORDER")
        r.link:SetWidth(2)
        r.stub = r:CreateTexture(nil, "BORDER")
        r.stub:SetHeight(2)
      end
      if depth > 0 then
        r.link:ClearAllPoints()
        r.link:SetPoint("TOPLEFT", r, "TOPLEFT", -CHAIN_INDENT + 6, 3)
        r.link:SetPoint("BOTTOMLEFT", r, "LEFT", -CHAIN_INDENT + 6, 0)
        r.stub:ClearAllPoints()
        r.stub:SetPoint("LEFT", r, "LEFT", -CHAIN_INDENT + 6, 0)
        r.stub:SetPoint("RIGHT", r, "LEFT", -1, 0)
        local done = e.code == "d"
        local c = done and { 0.4, 1, 0.45, 0.5 } or { ar, ag, ab, 0.55 }
        r.link:SetColorTexture(c[1], c[2], c[3], c[4])
        r.stub:SetColorTexture(c[1], c[2], c[3], c[4])
        r.link:Show()
        r.stub:Show()
      else
        r.link:Hide()
        r.stub:Hide()
      end
    end
  end
  listPool:Done()
  sectionPool:Done()

  -- The selection: kept while it's listed, else the first quest.
  if key and not byID[selected[key]] then
    selected[key] = first
    -- (the rows just drawn showed no selection: the next render does)
    if first then
      H.Render()
    end
  end
  view = { byID = byID }

  if y <= 2 then
    local text
    if not key then
      text = "Not in a dungeon"
    elseif #quests == 0 then
      text = index.state == "building" and ("Reading QuestieDB...\n|cff888888" .. index.count .. " quests|r")
        or "No quests here\nfor your character"
    else
      text = "No quests match\n|cff888888try All|r"
    end
    y = H.ShowEmpty(listEmpty, 8, width, text, H.ICON.available)
  else
    listEmpty:Hide()
  end
  return y
end

-- The tab's count: quests ready to turn in (green), else in your log.
function tab:Badge()
  local ready, inLog = 0, 0
  for _, q in ipairs(CurrentQuests()) do
    local code = MyState(q)
    ready = ready + (code == "r" and 1 or 0)
    inLog = inLog + ((code == "l" or code == "r") and 1 or 0)
  end
  if ready > 0 then
    return tostring(ready), H.GREEN, H.ICON.active
  elseif inLog > 0 then
    return tostring(inLog), { 1, 0.82, 0 }
  end
end

-- A chain step's state for the player: code, note.
local function StepState(id, nextUp)
  if IsDone(id) then
    return "d", ""
  end
  if InLog(id) then
    if C_QuestLog.IsComplete and C_QuestLog.IsComplete(id) then
      return "r", "|cff59ff73ready|r"
    end
    return "l", Progress(id) or "|cffffd100in log|r"
  end
  if nextUp then
    return "a", "|cffffd100next|r"
  end
  return "n", ""
end

-- The strip: what the player's state means, in a few words.
local function StripText(e, info)
  local code = e.code
  if code == "r" then
    return "Ready to turn in", nil
  elseif code == "l" then
    return "In progress", e.progress
  elseif code == "a" then
    return "Available", nil
  elseif code == "c" then
    return "Locked: finish " .. e.missing .. " earlier quest" .. (e.missing == 1 and "" or "s") .. " first", nil
  elseif code == "n" then
    return "Unlocks at level " .. (tonumber(info.requires) or tonumber(e.q.requires) or "?"),
      "you are " .. (UnitLevel("player") or "?")
  end
  return "Completed", nil
end

function tab:RenderDetail(width)
  local e = view and ViewKey() and view.byID[selected[ViewKey()]]
  -- Pools are finished at the end: Done hides what this render didn't use.
  -- (Done at the start only hid what the render before last left over, so a
  -- shorter quest kept the previous one's extra lines on screen.)
  local function Finish(y)
    detail.paras:Done()
    detail.lines:Done()
    detail.sections:Done()
    detail.steps:Done()
    detail.cells:Done()
    detail.members:Done()
    detail.folds:Done()
    return y
  end
  if not e then
    detail.banner:Hide()
    detail.strip:Hide()
    return Finish(1)
  end
  local q, id = e.q, e.id
  detail.id = id
  local info = Info(id)
  local ar, ag, ab = ARLE.Skin:Accent()

  -- Banner: the quest's mark, its name, and its facts as tags.
  local b = detail.banner
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", 0, 0)
  b:SetWidth(width)
  SetStateIcon(b.pic, e.code)
  H.SetEdge(b.pic, ar, ag, ab, 0.7)
  detail.share:SetEnabled(e.code == "l" or e.code == "r")
  local lr, lg, lb = DifficultyColor(q.level)
  local tags = {}
  if q.level then
    tags[#tags + 1] = { text = "Lv " .. q.level, color = { lr, lg, lb },
      tip = { "Quest level " .. q.level, "Its colour says how hard it is for you." } }
  end
  if q.requires then
    local low = (UnitLevel("player") or 0) < (tonumber(q.requires) or 0)
    tags[#tags + 1] = { text = "Req " .. q.requires, color = low and { 1, 0.4, 0.35 } or H.GREY,
      tip = { "Needs level " .. q.requires, low and "You can't pick it up yet." or nil } }
  end
  if info.startsInDungeon then
    tags[#tags + 1] = { text = "Inside", icon = H.ICON.dungeon, color = { 0.55, 0.8, 1 },
      tip = { "Starts inside the dungeon", "Picked up from something or someone in the dungeon." } }
  end
  if q.faction and q.faction ~= "Both" and q.faction ~= "Neutral" then
    tags[#tags + 1] = { text = q.faction, color = q.faction == "Horde" and { 1, 0.4, 0.35 } or { 0.45, 0.65, 1 } }
  end
  if q.classOnly then
    local cr, cg, cb = H.ClassColor(tostring(q.classOnly):upper())
    tags[#tags + 1] = { text = tostring(q.classOnly):sub(1, 1):upper() .. tostring(q.classOnly):sub(2):lower(),
      color = { cr, cg, cb } }
  end
  H.PaintBanner(b, q.name, { lr, lg, lb }, tags, 100)
  local y = H.BANNER_H + 6

  -- Status strip.
  local s = detail.strip
  local look = LOOK[e.code]
  local sc = look.color or { ar, ag, ab }
  local text, right = StripText(e, info)
  s.bg:SetColorTexture(sc[1], sc[2], sc[3], 0.12)
  s.edge:SetColorTexture(sc[1], sc[2], sc[3], 0.9)
  s.icon:SetTexture(look.icon)
  s.icon:SetDesaturated(look.grey and true or false)
  s.text:SetText(text)
  s.text:SetTextColor(sc[1], sc[2], sc[3])
  s.right:SetText(right or "")
  s:ClearAllPoints()
  s:SetPoint("TOPLEFT", 6, -y)
  s:SetWidth(width - 12)
  s:Show()
  if e.code == "l" and e.need then
    s.bar.width = width - 15
    s.bar:Show()
    H.SetBar(s.bar, e.have, e.need, sc[1], sc[2], sc[3])
  else
    s.bar:Hide()
  end
  y = y + 28 + 4

  local function Section(label, note, icon)
    local h = detail.sections:Get()
    H.PaintSection(h, label, note, icon)
    y = H.Place(h, y + 6, 20, 3)
  end
  local function Para(text2, color)
    if not text2 then
      return
    end
    local fs = detail.paras:Get()
    local c = color or { 0.92, 0.92, 0.92 }
    fs:SetTextColor(c[1], c[2], c[3])
    y = H.Para(fs, y, width, text2, 4, 8)
  end
  local function Line(icon, text2, color)
    if not text2 then
      return
    end
    y = PlaceLine(detail.lines:Get(), y, width, icon, text2, color)
  end

  -- Objective, and in the quest log, each part of it.
  local objectives = (e.code == "l" or e.code == "r") and Objectives(id) or {}
  if info.objective or #objectives > 0 then
    Section("Objective")
    Para(info.objective)
    for _, o in ipairs(objectives) do
      if o.text and o.text ~= "" then
        Line(o.finished and H.ICON.ready or H.ICON.waiting, o.text, o.finished and { 0.45, 1, 0.5 } or nil)
      end
    end
  end

  -- Where it starts and ends.
  if info.pickup or info.turnin or info.note then
    Section("Where")
    Line(H.ICON.available, info.pickup)
    Line(H.ICON.active, info.turnin)
    Line(SPEECH, info.note, { 0.6, 0.8, 1 })
  end

  -- Rewards, two to a line like the game's quest frame.
  local items = type(q.rewardItems) == "table" and q.rewardItems or {}
  local money = Money(id)
  local _, otherRewards = SplitReward(Str(q.rewardSummary) or q.rewards)
  if #items > 0 or money > 0 or otherRewards then
    Section("Rewards", q.rewardChoice and "|cffffd100choose one|r" or nil)
    local flb = H.FLB()
    local colW = math.floor((width - 16) / 2)
    local col = 0
    for _, item in ipairs(items) do
      local itemID = type(item) == "table" and tonumber(item[1])
      if itemID then
        local c = detail.cells:Get()
        c.itemID = itemID
        local quality = tonumber(item[3]) or 1
        H.SetItemPic(c.pic, itemID, quality)
        c.gain = nil
        if flb and flb.GetGain then
          local ok, gain = pcall(flb.GetGain, itemID)
          if ok and type(gain) == "number" and gain > 0 then
            c.gain = gain
          end
        end
        c.pic.label:SetText(c.gain and string.format("|cff66ff66+%.0f|r", c.gain) or "")
        c.name:SetText((H.GetItemInfo(itemID)) or item[2] or ("item " .. itemID))
        c.name:SetTextColor(H.QualityColor(quality))
        c.bg:SetColorTexture(1, 1, 1, c.gain and 0.06 or 0.03)
        if c.gain then
          c.bg:SetColorTexture(0.3, 1, 0.4, 0.08)
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", 6 + col * (colW + 4), -y)
        c:SetWidth(colW)
        c:Show()
        col = col + 1
        if col == 2 then
          col = 0
          y = y + 38
        end
      end
    end
    if col > 0 then
      y = y + 38
    end
    if money > 0 then
      Line(COIN, CoinText(money, 14))
    end
    if #items == 0 and otherRewards then
      Para(otherRewards)
    end
  end

  -- The chain as a tree: every quest that unlocks this one (branches
  -- indented, "one of" groups), this one, then what follows; lead-ins apart.
  -- A fold of the chain: a clickable line that opens (or closes) the whole of it.
  local function FoldLine(yy, text)
    local f = detail.folds:Get()
    f.text:SetText(text)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", 6, -yy)
    f:SetPoint("RIGHT")
    f:SetHeight(18)
    f:Show()
    return yy + 20
  end
  local function Step(stepId, depth, opts)
    local r = detail.steps:Get()
    local sInfo = Info(stepId)
    r.id, r.stepName, r.anyOf, r.source = stepId, nil, nil, opts.source
    r.listed = not opts.current and view.byID[stepId] ~= nil
    local code, note
    if opts.current then
      code, note = e.code, "|cffffffffthis quest|r"
    else
      code, note = StepState(stepId, opts.nextUp)
    end
    SetStateIcon(r.pic, code)
    H.SetEdge(r.pic, ar, ag, ab, opts.current and 0.9 or 0.15)
    local slr, slg, slb = DifficultyColor(sInfo.level)
    local name = (sInfo.level and ("|cff888888" .. sInfo.level .. "|r  ") or "") .. sInfo.name
      .. (sInfo.startsInDungeon and (" " .. H.Inline(H.ICON.dungeon, 12)) or "")
      .. (opts.alt and " |cff888888(or)|r" or "")
      .. (opts.asks and ("  |cff888888" .. opts.asks .. "|r") or "")
    H.PaintRow(r, {
      name = name,
      note = note,
      color = code == "d" and { 0.55, 0.55, 0.55 } or { slr, slg, slb },
      tint = opts.current and { ar, ag, ab, 0.14 } or nil,
      dim = code == "n",
    })
    r.pic:SetAlpha(code == "n" and 0.55 or 1)
    local doneC, todoC = { 0.4, 1, 0.45, 0.6 }, { 1, 1, 1, 0.15 }
    local upC = opts.prevDone and doneC or todoC
    local downC = code == "d" and doneC or todoC
    r.up:SetColorTexture(upC[1], upC[2], upC[3], upC[4])
    r.down:SetColorTexture(downC[1], downC[2], downC[3], downC[4])
    r.up:SetShown(opts.first ~= true)
    r.down:SetShown(opts.last ~= true)
    H.Place(r, y, STEP_H, 0)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", depth * INDENT, -y)
    r:SetPoint("RIGHT")
    y = y + STEP_H
    return code == "d"
  end
  local rows = Tree(id)
  local _, source = Before(id)
  local after = After(id)
  local leads = LeadIns(id)
  if source == "guide" then
    local steps = Before(id)
    Section("How to do it", "|cff888888" .. #steps .. " steps|r")
    local prev = false
    for i, st in ipairs(steps) do
      prev = Step(st.id, 0, { source = "guide", first = i == 1, last = i == #steps, prevDone = prev })
    end
  end
  if rows or after then
    -- OneMoreQuest's way with a long chain: the quests done before fold
    -- into one line ("6 done before"), this quest and what's left stay, the
    -- far end folds into "n more"; a click on either shows the whole chain.
    local list = rows or { { id = id, depth = 0, current = true } }
    local all = {}
    for _, r in ipairs(list) do
      all[#all + 1] = r
    end
    for _, st in ipairs(after or {}) do
      all[#all + 1] = { id = st.id, depth = 0, after = true }
    end
    local at, total = 0, 0
    local names = {}
    for _, r in ipairs(all) do
      if r.id then
        total = total + 1
        if r.current then
          at = total
        end
        local nm = Info(r.id).name
        names[nm] = (names[nm] or 0) + 1
      end
    end
    local left = Missing(id)
    Section("Quest chain", (left > 0 and (H.Inline(H.ICON.lock, 11) .. " |cffff7359" .. left .. " to go|r  ") or "")
      .. "|cff888888step " .. at .. " of " .. total .. "|r")
    local folded = total > FOLD_AT and not chainOpen
    local doneBefore, moreAfter = 0, 0
    local show = {}
    for i, r in ipairs(all) do
      local hide = false
      if folded and r.id and not r.current then
        if not r.after and IsDone(r.id) then
          hide, doneBefore = true, doneBefore + 1
        elseif r.after then
          -- keep the first one after this quest
          local prevAfter = i > 1 and all[i - 1].after
          if prevAfter then
            hide, moreAfter = true, moreAfter + 1
          end
        end
      end
      if folded and r.head and i < #all and all[i + 1].id and IsDone(all[i + 1].id) then
        hide = true
      end
      if not hide then
        show[#show + 1] = r
      end
    end
    if folded and doneBefore > 0 then
      y = FoldLine(y, H.Inline(H.ICON.ready, 12) .. "  |cff999999" .. doneBefore .. " quest"
        .. (doneBefore == 1 and "" or "s") .. " done before|r  |cff66bbff(show)|r")
    end
    -- Steps of the same name are told apart by what each asks.
    local function Asks(qid)
      local text = QDB.Quest(qid, "objectivesText")
      local first = type(text) == "table" and Str(text[1])
      first = first and first:match("^([^%.!]+)") or nil
      if first and #first > 48 then
        first = first:sub(1, 46) .. "..."
      end
      return first
    end
    local nextShown, prev = false, false
    for i, r in ipairs(show) do
      if r.head then
        local h = detail.lines:Get()
        local y0 = y
        y = PlaceLine(h, y, width - r.depth * INDENT, H.ICON.waiting, "|cff99ccffone of these " .. r.head .. ":|r")
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", r.depth * INDENT, -y0)
        h:SetPoint("RIGHT")
      else
        local done = IsDone(r.id)
        local nm = Info(r.id).name
        prev = Step(r.id, r.depth, { current = r.current, alt = r.alt, source = rows and "tree" or nil,
          nextUp = not done and not nextShown and not r.current, first = i == 1 and doneBefore == 0,
          last = i == #show and moreAfter == 0, prevDone = prev,
          asks = (names[nm] or 0) > 1 and Asks(r.id) or nil })
        nextShown = nextShown or (not done and not r.current)
      end
    end
    if folded and moreAfter > 0 then
      y = FoldLine(y, H.Inline(H.ICON.waiting, 12) .. "  |cff999999" .. moreAfter .. " more quest"
        .. (moreAfter == 1 and "" or "s") .. " after|r  |cff66bbff(show)|r")
    elseif chainOpen and total > FOLD_AT then
      y = FoldLine(y, "|cff66bbffshow less|r")
    end
  end
  if #leads > 0 then
    Section("Lead-ins", "|cff888888optional, point you here|r")
    for _, lid in ipairs(leads) do
      Step(lid, 0, { first = true, last = true })
    end
  end

  -- The party: each member's state, their class icon as the picture.
  local others = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      others[#others + 1] = m
    end
  end
  if #others > 0 then
    Section("Party")
    for _, m in ipairs(others) do
      local found
      for _, ps in ipairs(e.states) do
        if ps.member.name == m.name then
          found = ps
        end
      end
      local st = found and found.state
      local r = detail.members:Get()
      H.SetClassIcon(r.pic.tex, m.class)
      H.SetEdge(r.pic, 0, 0, 0, 1)
      local words, corner
      if not found then
        words = "|cff888888" .. H.Quiet(m) .. "|r"
      elseif not st then
        words = "|cff888888?|r"
      else
        local look2 = LOOK[st.code]
        words = (st.code == "l" and (st.progress or LOOK.l.short)) or (look2 and look2.short)
          or (st.code == "c" and "|cffff7359needs earlier quests|r") or (st.code == "n" and "|cff999999level too low|r")
          or st.code
        corner = look2 and look2.icon
      end
      local cr, cg, cb = H.ClassColor(m.class)
      H.PaintRow(r, { name = m.name, note = words, color = { cr, cg, cb }, dim = not found })
      H.SetCorner(r.pic, corner)
      y = H.Place(r, y, 28, 1)
    end
  end
  return Finish(y + 6)
end

-- For Home: the objectives this character has quests in, with progress.
-- { key, label, icon, done, total, next = { q, code } }, attunements first.
function tab.Objectives()
  local keys, seen = {}, {}
  local function Want(k)
    if not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
  end
  Want("attune:ONYXIA")
  Want("attune:MOLTENCORE")
  Want("attune:BLACKWING")
  Want("t05")
  Want("class")
  Want("pvp:AV")
  Want("pvp:WSG")
  Want("pvp:AB")
  local out = {}
  for _, k in ipairs(keys) do
    local list = ObjectiveQuests(k)
    if #list > 0 then
      local done, nextQ, nextCode = 0, nil, nil
      local RANK = { r = 1, l = 2, a = 3, c = 4, n = 5 }
      for _, q in ipairs(list) do
        local code = MyState(q)
        if code == "d" then
          done = done + 1
        elseif not nextCode or (RANK[code] or 9) < (RANK[nextCode] or 9) then
          nextQ, nextCode = q, code
        end
      end
      local label, icon = tab.ObjectiveLabel(k)
      local category = (k:find("^attune:") and "Raid Attunements") or (k:find("^pvp:") and "PvP")
        or "Important Quests"
      out[#out + 1] = { key = k, label = label, icon = icon, done = done, total = #list, next = nextQ,
        nextCode = nextCode, category = category }
    end
  end
  return out, index.state
end

-- For Home: your quests in a log, for any dungeon: { dungeon, q, code, progress }.
function tab.LogQuests()
  local out = {}
  for _, d in ipairs(H.Dungeons()) do
    for _, q in ipairs(Quests(d)) do
      local code, progress = MyState(q)
      if code == "l" or code == "r" then
        out[#out + 1] = { dungeon = d, q = q, code = code, progress = progress }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.code ~= b.code then
      return a.code == "r"
    end
    return a.dungeon < b.dungeon
  end)
  return out
end

-- For the dungeon picker: quests in your log there, ready to turn in, and
-- available to pick up.
function tab.CountFor(dungeon)
  local inLog, ready, avail = 0, 0, 0
  for _, q in ipairs(Quests(dungeon)) do
    local code = MyState(q)
    if code == "r" then
      ready = ready + 1
      inLog = inLog + 1
    elseif code == "l" then
      inLog = inLog + 1
    elseif code == "a" then
      avail = avail + 1
    end
  end
  return inLog, ready, avail
end

function tab:Status()
  local open = 0
  for _, q in ipairs(Quests(H.shown)) do
    local code = MyState(q)
    if code == "l" or code == "r" then
      open = open + 1
    end
  end
  return open .. " quest(s) in your log"
end
