-- ARLE.Lib.Quests: quest helpers shared by the Questie features, Quest
-- Search and the Dungeon Helper's Quests tab.
local _, ns = ...
local ARLE = ns.ARLE
local Q = {}
ARLE.Lib.Quests = Q

-- Every original Classic quest has an ID below 10000; WoW Forever's own
-- quests are numbered above it (most in the 90000s).
Q.CLASSIC_MAX = 10000

-- The cutoff the New in Forever feature uses (its setting), else 10000.
function Q.NewCutoff()
  local def = ARLE.modules.NewInForever
  local min = def and def.db and tonumber(def.db.minId)
  return min or Q.CLASSIC_MAX
end

function Q.IsNew(questID)
  questID = tonumber(questID)
  return questID ~= nil and questID >= Q.NewCutoff()
end

Q.STAR = "|TInterface\\COMMON\\FavoritesIcon:12:12:0:0|t"

-- A chat link for a quest. Questie's link when it has one, else the game's
-- own quest hyperlink.
function Q.Link(questID, title, level)
  local questie = ARLE.Bridge.Questie
  if questie and questie.QuestLink then
    local link = questie.QuestLink(questID)
    if link then
      return link
    end
  end
  return string.format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", questID, level or -1, title or ("Quest " .. questID))
end

-- Puts a quest link in the chat box being typed in, if there is one.
function Q.InsertLink(questID, title, level)
  local link = Q.Link(questID, title, level)
  if ChatEdit_InsertLink and ChatEdit_InsertLink(link) then
    return true
  end
  if ChatFrame_OpenChat then
    ChatFrame_OpenChat(link)
    return true
  end
end

-- Which side a quest is for: "A", "H" or "both", from QuestieDB's
-- requiredRaces, else the factions of its givers, else its turn-in NPCs.
-- (Quest Search's faction filter and Dungeon Lead-ins.)
local sideCache = {}

-- Arithmetic bit test: Forever's race bits 32/33 overflow the bit library.
local function HasBit(value, bitValue)
  return math.floor(value / bitValue) % 2 == 1
end

local function Either(a, h)
  if a and not h then
    return "A"
  end
  if h and not a then
    return "H"
  end
  return "both"
end

local function RaceSide(races)
  local enum = ARLE.Bridge.QuestieDB.Enum()
  if type(races) ~= "number" or races == 0 or not (enum and enum.raceMaskById and enum.factionRaceMasks) then
    return nil
  end
  local function Overlaps(mask)
    if type(mask) ~= "number" then
      return false
    end
    for _, bitValue in pairs(enum.raceMaskById) do
      if HasBit(races, bitValue) and HasBit(mask, bitValue) then
        return true
      end
    end
    return false
  end
  return Either(Overlaps(enum.factionRaceMasks.Alliance), Overlaps(enum.factionRaceMasks.Horde))
end

local function NpcSide(givers)
  local npcs = type(givers) == "table" and type(givers[1]) == "table" and givers[1] or nil
  if not npcs then
    return nil
  end
  local a, h, known = false, false, false
  for _, npcId in ipairs(npcs) do
    local friendly = ARLE.Bridge.QuestieDB.Npc(npcId, "friendlyToFaction")
    if type(friendly) == "string" and friendly ~= "" then
      known = true
      a = a or friendly:find("A", 1, true) ~= nil
      h = h or friendly:find("H", 1, true) ~= nil
    end
  end
  return known and Either(a, h) or nil
end

function Q.Side(questID)
  local side = sideCache[questID]
  if side then
    return side
  end
  local DB = ARLE.Bridge.QuestieDB
  side = RaceSide(DB.Quest(questID, "requiredRaces")) or NpcSide(DB.Quest(questID, "startedBy"))
    or NpcSide(DB.Quest(questID, "finishedBy")) or "both"
  sideCache[questID] = side
  return side
end

-- Can the player's faction take this quest?
function Q.ForMySide(questID)
  local side = Q.Side(questID)
  if side == "both" then
    return true
  end
  local faction = UnitFactionGroup("player")
  return (faction == "Alliance" and side == "A") or (faction == "Horde" and side == "H")
end

-- Is this quest in the log, and its log index.
function Q.InLog(questID)
  if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
    local index = C_QuestLog.GetLogIndexForQuestID(questID)
    return index ~= nil and index > 0, index
  end
  return false
end

function Q.IsDone(questID)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
  end
  if IsQuestFlaggedCompleted then
    return IsQuestFlaggedCompleted(questID) and true or false
  end
  return false
end
