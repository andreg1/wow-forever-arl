-- New in Forever: a star on Questie's map icons, and in Questie's map tooltip,
-- for quests that are new in WoW Forever (not part of original Classic).
-- Based on Questie_NewInForever by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- How "new" is decided: every original Classic quest has an ID below 10000.
-- QuestieDB's Forever data adds ~1630 quests above that: ~1400 in the 90000s
-- (Forever's own zones and stories) and ~230 from 60000-89999. minId sets the
-- cutoff (90000 = only Forever's own block). ARLE.Lib.Quests.IsNew uses the
-- same cutoff, so Quest Search and the Dungeon Helper star the same quests.
--
-- Questie modules (ARLE.Bridge.Questie), wrapped while the feature is on:
--   QuestieMap:DrawWorldIcon(data, ...): data.Id is the quest ID, data.Type
--     "available" / "complete" / objective types; returns the world map icon
--     and the minimap icon.
--   QuestieFramePool:GetFrame(): Questie recycles icon frames, so any badge is
--     hidden as soon as a frame is handed out again.
--   MapIconTooltip.ShowOnTooltip(icon, Tooltip, ...): collects the hovered
--     cluster's quests into Tooltip.npcAndObjectOrder / Tooltip.questOrder and
--     renders via Tooltip:_Rebuild(); new quests' titles get the star, and a
--     legend line is added (kept when Questie rebuilds on Shift).
-- Taint: Questie's icons are plain Buttons. The badge is a child frame of our
-- own on the icon; no fields are written to Questie's frames.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Q, QDB = ARLE.Bridge.Questie, ARLE.Bridge.QuestieDB

local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local STAR_INLINE = "|T" .. STAR .. ":0|t"

local F = {
  id = "NewInForever",
  addon = ADDON,
  title = "New in Forever",
  group = "Questie",
  extends = "Questie",
  command = "new",
  commandHelp = "stars on Questie's icons for quests new in WoW Forever",
  description = "Stars on Questie's map icons for quests that are new in WoW Forever.",
  options = {
    { type = "header", label = "Where" },
    { key = "turnins", type = "boolean", label = "Turn-in icons too", default = true },
    { key = "objectives", type = "boolean", label = "Objective icons too", default = false },
    { key = "minimap", type = "boolean", label = "Minimap icons too", default = false },
    { key = "tooltip", type = "boolean", label = "Mark new quests in Questie's map tooltip", default = true },
    { type = "header", label = "Which quests" },
    { key = "minId", type = "select", label = "Count as new", default = 10000, cmd = "min",
      values = {
        { value = 10000, label = "Everything after Classic (ID 10000+)" },
        { value = 60000, label = "Later additions too (60000+)" },
        { value = 90000, label = "Only Forever's own quests (90000+)" },
      } },
  },
}

local marked = setmetatable({}, { __mode = "k" }) -- tooltip entry tables already prefixed
local badges = setmetatable({}, { __mode = "k" }) -- icon frame -> badge holder
local drawn = setmetatable({}, { __mode = "k" })  -- icon frame -> true (seen in DrawWorldIcon)

local function IsNewQuest(questId)
  return type(questId) == "number" and questId >= (tonumber(F.db.minId) or 10000)
end

local function WantsIcon(frame)
  local data = frame.data
  if type(data) ~= "table" or not IsNewQuest(data.Id) then
    return false
  end
  if frame.miniMapIcon and not F.db.minimap then
    return false
  end
  local t = data.Type
  if t == "available" then
    return true
  end
  if t == "complete" then
    return F.db.turnins
  end
  if t == "manual" or t == nil then
    return false
  end
  return F.db.objectives
end

-------------------------------------------------------------------------------
-- Badge
-------------------------------------------------------------------------------

local function RaiseBadge(holder)
  -- Above neighbouring icons stacked on the same spot.
  local parent = holder:GetParent()
  if parent then
    holder:SetFrameLevel(parent:GetFrameLevel() + 5)
  end
end

local function GetBadge(frame)
  local holder = badges[frame]
  if holder then
    return holder
  end
  holder = CreateFrame("Frame", nil, frame)
  holder:EnableMouse(false)
  -- Top-right quadrant of the icon, overhanging a little; scales with the icon.
  holder:SetPoint("BOTTOMLEFT", frame, "CENTER", 1, 1)
  holder:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 3, 3)
  local tex = holder:CreateTexture(nil, "OVERLAY")
  tex:SetAllPoints(holder)
  tex:SetTexture(STAR)
  holder:SetScript("OnShow", RaiseBadge)
  holder:Hide()
  badges[frame] = holder
  return holder
end

local function HideBadge(frame)
  local holder = badges[frame]
  if holder then
    holder:Hide()
  end
end

local function Apply(frame)
  if not frame then
    return
  end
  if F._active and WantsIcon(frame) then
    local holder = GetBadge(frame)
    holder:Show()
    RaiseBadge(holder)
  else
    HideBadge(frame)
  end
end

local function RefreshAll()
  for frame in pairs(drawn) do
    if frame.data then
      Apply(frame)
    else
      HideBadge(frame)
    end
  end
end

-------------------------------------------------------------------------------
-- Tooltip
-------------------------------------------------------------------------------

local function QuestName(questId)
  local name = QDB.Quest(questId, "name")
  return type(name) == "string" and name or ("Quest " .. tostring(questId))
end

-- Prefixes new quests among the givers / turn-ins; returns whether any were
-- marked, and the names of new quests shown only through objective icons.
local function MarkTooltipData(Tooltip)
  local anyMarked = false
  for _, quests in pairs(type(Tooltip.npcAndObjectOrder) == "table" and Tooltip.npcAndObjectOrder or {}) do
    for _, entry in pairs(quests) do
      if type(entry) == "table" and IsNewQuest(entry.questId) and type(entry.title) == "string" then
        if not marked[entry] then
          marked[entry] = true
          entry.title = STAR_INLINE .. " " .. entry.title
        end
        anyMarked = true
      end
    end
  end
  local objectiveNames = {}
  for questId in pairs(type(Tooltip.questOrder) == "table" and Tooltip.questOrder or {}) do
    if IsNewQuest(questId) then
      objectiveNames[#objectiveNames + 1] = QuestName(questId)
    end
  end
  table.sort(objectiveNames)
  return anyMarked, objectiveNames
end

local function AddLegend(Tooltip, anyMarked, objectiveNames)
  if anyMarked and #objectiveNames == 0 then
    Tooltip:AddLine(STAR_INLINE .. " New in WoW Forever", 1, 0.82, 0)
  elseif #objectiveNames > 0 then
    Tooltip:AddLine(STAR_INLINE .. " New in WoW Forever: " .. table.concat(objectiveNames, ", "), 1, 0.82, 0, true)
  end
end

local function AfterShowOnTooltip(Tooltip, rebuildBefore)
  if not F.db.tooltip or type(Tooltip) ~= "table" then
    return
  end
  local rebuild = Tooltip._Rebuild
  -- Questie returns early (icon faded, hovered too fast) without a new _Rebuild.
  if type(rebuild) ~= "function" or rebuild == rebuildBefore then
    return
  end
  local anyMarked, objectiveNames = MarkTooltipData(Tooltip)
  if not anyMarked and #objectiveNames == 0 then
    return
  end
  -- Questie's Shift handler calls Tooltip:_Rebuild() again; keep the legend there too.
  Tooltip._Rebuild = function(self, ...)
    rebuild(self, ...)
    AddLegend(self, anyMarked, objectiveNames)
  end
  if Tooltip:IsShown() then
    Tooltip:ClearLines()
    Tooltip:_Rebuild()
    Tooltip:Show()
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  local QuestieMap, Pool = Q.Module("QuestieMap"), Q.Module("QuestieFramePool")
  if not (QuestieMap and Pool and type(QuestieMap.DrawWorldIcon) == "function"
      and type(Pool.GetFrame) == "function") then
    error("Questie's QuestieMap:DrawWorldIcon or QuestieFramePool:GetFrame was not found (Questie update?)", 0)
  end
  self:Wrap(Pool, "GetFrame", function(orig, ...)
    local frame = orig(...)
    if frame then
      HideBadge(frame)
    end
    return frame
  end)
  self:Wrap(QuestieMap, "DrawWorldIcon", function(orig, ...)
    local iconMap, iconMinimap = orig(...)
    for _, icon in ipairs({ iconMap or false, iconMinimap or false }) do
      if icon then
        drawn[icon] = true
        local ok, err = pcall(Apply, icon)
        if not ok then
          ARLE.Debug:Record(F, err)
        end
      end
    end
    return iconMap, iconMinimap
  end)
  local MapIconTooltip = Q.Module("MapIconTooltip")
  if not self:Wrap(MapIconTooltip, "ShowOnTooltip", function(orig, icon, Tooltip, ...)
    local rebuildBefore = type(Tooltip) == "table" and Tooltip._Rebuild or nil
    orig(icon, Tooltip, ...)
    local ok, err = pcall(AfterShowOnTooltip, Tooltip, rebuildBefore)
    if not ok then
      ARLE.Debug:Record(F, err)
    end
  end) then
    self:Print("Questie's MapIconTooltip.ShowOnTooltip was not found (Questie update?); tooltips won't be marked.")
  end
  RefreshAll()
end

function F:OnDisable()
  RefreshAll()
end

function F:OnOptionChanged()
  RefreshAll()
end

-- Questie_NewInForever's settings (QuestieNewInForeverDB, account-wide)
-- replace ours. Its cutoff could be any ID; only the three listed here map.
function F:Import()
  local old = _G.QuestieNewInForeverDB
  if type(old) ~= "table" then
    return
  end
  -- (old.enabled is not copied: db.enabled is the host's feature switch.)
  for _, key in ipairs({ "turnins", "objectives", "minimap", "tooltip" }) do
    if type(old[key]) == "boolean" then
      self.db[key] = old[key]
    end
  end
  if old.minId == 10000 or old.minId == 60000 or old.minId == 90000 then
    self.db.minId = old.minId
  end
end

F.commands = {
  { name = "check", args = "<questID>", help = "is this quest new?", always = true, run = function(self, rest)
    local id = tonumber(rest)
    if not id then
      self:Print("usage: /arl new check <questID>")
      return
    end
    self:Print(string.format("quest %d (%s) is %s.", id, QuestName(id), IsNewQuest(id) and "|cff40ff40new|r"
      or "original Classic"))
  end },
}

ARLE:RegisterModule(F)
