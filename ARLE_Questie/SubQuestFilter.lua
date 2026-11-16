-- Sub-Quest Filter: hides Questie's sub-quests until you meet their level and
-- other requirements.
-- Based on Questie_SubQuestFilter by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- Problem: while a parent quest is in the log, Questie draws its child quests
-- (QuestieDB "childQuests" / "parentQuest") as available, skipping almost all
-- requirement checks (AvailableQuests' _DrawChildQuests checks only race,
-- completion, exclusiveTo and pre-quests; IsLevelRequirementsFulfilled
-- returns true for any quest whose parent is active).
-- Fix: a sub-quest is drawn only if its required level <= yours (and you're
-- not above its max level), and QuestieDB.IsDoable(questId) is true. Quests
-- an NPC actually offers you (gossip / quest detail) are always allowed this
-- session. Nothing is hidden permanently: every check runs again on each pass.
--
-- Questie modules (ARLE.Bridge.Questie), wrapped while the feature is on:
--   AvailableQuests.DrawAvailableQuest(quest): every starter icon and tooltip
--     goes through it, so blocking it hides both.
--   AvailableQuests.CalculateAndDrawAll(cb): an extra callback removes
--     sub-quests already drawn that are no longer ready (RemoveQuest).
--   QuestieDB.IsDoable / QueryQuestSingle / activeChildQuests,
--   QuestieLib.GetEffectiveQuestLevel, ActiveQuests.Get.
-- Taint: Questie's map icons are plain frames and are never touched; only Lua
-- calls are filtered.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Q = ARLE.Bridge.Questie

local F = {
  id = "SubQuestFilter",
  addon = ADDON,
  title = "Sub-Quest Filter",
  group = "Questie",
  extends = "Questie",
  command = "subq",
  commandHelp = "hides Questie sub-quests you can't pick up yet",
  description = "Hides Questie's sub-quests until you can actually pick them up.",
  options = {
    { type = "info", text = function(def) return def:Summary() end },
    { type = "button", label = "Redraw Questie's available quests", nocmd = true,
      run = function(def) def:Redraw() end },
  },
}

local AvailableQuests, QuestieDB, QuestieLib, ActiveQuests
local hooked = false
local blocked = {} -- [questId] = reason string (sub-quests currently hidden)
local offered = {} -- [questId] = true (an NPC offered it this session)

-------------------------------------------------------------------------------
-- Rules
-------------------------------------------------------------------------------

local function Query(questId, field)
  local ok, value = pcall(QuestieDB.QueryQuestSingle, questId, field)
  if ok then
    return value
  end
end

-- A sub-quest is one Questie treats as available because its parent is in
-- the log (from _DrawChildQuests or from the parent level bypass).
local function IsSubQuest(questId)
  if type(questId) ~= "number" then
    return false
  end
  if QuestieDB.activeChildQuests and QuestieDB.activeChildQuests[questId] then
    return true
  end
  local parent = Query(questId, "parentQuest")
  return parent and parent ~= 0 and ActiveQuests.Get(parent) ~= nil or false
end

-- nil if the quest is ready to pick up, else a short reason.
local function NotReadyReason(questId)
  local level = UnitLevel("player") or 1
  local ok, _, requiredLevel, requiredMaxLevel = pcall(QuestieLib.GetEffectiveQuestLevel, questId, level)
  if ok then
    if requiredLevel and requiredLevel > level then
      return "requires level " .. requiredLevel
    end
    if requiredMaxLevel and requiredMaxLevel ~= 0 and level > requiredMaxLevel then
      return "max level " .. requiredMaxLevel
    end
  end
  local okDoable, doable = pcall(QuestieDB.IsDoable, questId, false)
  if okDoable and doable == false then
    return "requirements not met"
  end
  return nil
end

-- true = let Questie draw it.
local function ShouldShow(questId)
  if not F._active or offered[questId] or not IsSubQuest(questId) then
    blocked[questId] = nil
    return true
  end
  local reason = NotReadyReason(questId)
  blocked[questId] = reason
  return reason == nil
end

-- Removes sub-quests that were drawn but are no longer ready.
local function Sweep()
  if not F._active then
    return
  end
  local drawn = AvailableQuests.__availableQuests
  if type(drawn) ~= "table" then
    return
  end
  local toRemove = {}
  for questId in pairs(drawn) do
    if not ShouldShow(questId) then
      toRemove[#toRemove + 1] = questId
    end
  end
  for i = 1, #toRemove do
    pcall(AvailableQuests.RemoveQuest, toRemove[i])
  end
end

-- Offered quests: the game says you can take them.
local function MarkOffered(questId)
  if type(questId) ~= "number" or questId <= 0 or offered[questId] then
    return
  end
  offered[questId] = true
  if blocked[questId] then
    blocked[questId] = nil
    local ok, quest = pcall(QuestieDB.GetQuest, questId)
    if ok and quest then
      pcall(AvailableQuests.DrawAvailableQuest, quest)
    end
  end
end

local function QuestLabel(questId)
  local name = QuestieDB and Query(questId, "name")
  return string.format("%s (%d)", name or "?", questId)
end

-- Questie's draw pass needs its startup done (QuestieDB.QuestPointers is set
-- during Questie's init, Questie.started at its end; its own daily-reset timer
-- checks QuestPointers the same way). Before that the pass errors in Questie's
-- thread; Questie's own first pass goes through our wrapper anyway.
local function QuestieReady()
  local questie = _G.Questie
  return type(questie) == "table" and questie.started == true
    and type(QuestieDB) == "table" and QuestieDB.QuestPointers ~= nil
end

-- true if a redraw was started.
function F:Redraw()
  if hooked and QuestieReady() then
    return (pcall(AvailableQuests.CalculateAndDrawAll))
  end
  return false
end

function F:Summary()
  local n = 0
  for _ in pairs(blocked) do
    n = n + 1
  end
  if not hooked then
    return "Not active yet (turn it on; needs Questie)."
  end
  return n .. " sub-quest" .. (n == 1 and "" or "s") .. " hidden right now. /arl subq list says why."
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  AvailableQuests = Q.Module("AvailableQuests")
  QuestieDB = Q.Module("QuestieDB")
  QuestieLib = Q.Module("QuestieLib")
  ActiveQuests = Q.Module("ActiveQuests")
  if type(AvailableQuests) ~= "table" or type(AvailableQuests.DrawAvailableQuest) ~= "function"
      or type(AvailableQuests.CalculateAndDrawAll) ~= "function" or type(AvailableQuests.RemoveQuest) ~= "function"
      or type(QuestieDB) ~= "table" or type(QuestieDB.IsDoable) ~= "function"
      or type(QuestieDB.QueryQuestSingle) ~= "function"
      or type(QuestieLib) ~= "table" or type(QuestieLib.GetEffectiveQuestLevel) ~= "function"
      or type(ActiveQuests) ~= "table" or type(ActiveQuests.Get) ~= "function" then
    error("a Questie function this needs was not found (Questie update?); sub-quests aren't filtered", 0)
  end
  self:Wrap(AvailableQuests, "DrawAvailableQuest", function(orig, quest, ...)
    local ok, show = pcall(ShouldShow, type(quest) == "table" and quest.Id)
    if ok and not show then
      return
    end
    return orig(quest, ...)
  end)
  self:Wrap(AvailableQuests, "CalculateAndDrawAll", function(orig, callback, ...)
    local function after()
      local ok, err = pcall(Sweep)
      if not ok then
        geterrorhandler()(err)
      end
      if callback then
        callback()
      end
    end
    return orig(after, ...)
  end)
  hooked = true
  self:On("GOSSIP_SHOW", function()
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
      local ok, list = pcall(C_GossipInfo.GetAvailableQuests)
      if ok and type(list) == "table" then
        for _, info in pairs(list) do
          MarkOffered(info.questID)
        end
      end
    end
  end)
  self:On("QUEST_DETAIL", function()
    if GetQuestID then
      MarkOffered(GetQuestID())
    end
  end)
  self:Redraw()
end

function F:OnDisable()
  wipe(blocked)
  -- The wrappers pass everything through now: redraw so hidden quests come back.
  self:Redraw()
end

function F:GetStatus()
  return "Active · " .. self:Summary()
end

F.commands = {
  { name = "list", help = "sub-quests hidden right now, and why", run = function(self)
    local n = 0
    for questId, reason in pairs(blocked) do
      n = n + 1
      print("   " .. QuestLabel(questId) .. ": " .. reason)
    end
    if n == 0 then
      self:Print("no sub-quests hidden right now.")
    end
  end },
  { name = "check", args = "<questID>", help = "why a quest is shown or hidden", run = function(self, rest)
    local id = tonumber(rest)
    if not id then
      self:Print("usage: /arl subq check <questID>")
      return
    end
    if not IsSubQuest(id) then
      self:Print(QuestLabel(id) .. " is not a sub-quest of a quest in your log; Questie's normal rules apply.")
    elseif offered[id] then
      self:Print(QuestLabel(id) .. " was offered by an NPC, so it is shown.")
    else
      local reason = NotReadyReason(id)
      self:Print(QuestLabel(id) .. ": " .. (reason and ("hidden, " .. reason) or "ready, shown"))
    end
  end },
  { name = "refresh", help = "redraws Questie's available quests", run = function(self)
    if self:Redraw() then
      self:Print("redrawing Questie's available quests.")
    else
      self:Print("Questie hasn't finished starting yet; its own first pass is filtered.")
    end
  end },
}

-- Questie_SubQuestFilter (QuestieSubQuestFilterDB) only kept its on/off
-- switch, and db.enabled here is the host's feature switch (the player's
-- own choice in /arl), so there is nothing to import.

ARLE:RegisterModule(F)
