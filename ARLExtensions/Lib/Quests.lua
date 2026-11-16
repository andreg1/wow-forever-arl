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
