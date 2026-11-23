-- Dungeon Lead-ins: a dungeon mark on OneMoreQuest's quest list and quest
-- page for every quest whose chain leads to a dungeon (or raid) quest.
--
-- OneMoreQuest has no public API (its namespace is private) and no license
-- that lets its code into MIT ARL, so none of its code is used and nothing of
-- it is called: this reads its named frames only and lays frames of its own
-- over them.
--   TrailheadLog          the quest window beside the map
--   TrailheadLogList      the list (a ScrollFrame; TrailheadLogListLegacy
--                         when the slim scroll bar can't be made); its scroll child holds a
--                         pool of plain Buttons, each with `.data` = the
--                         quest ID for a quest row (the widest button of a
--                         quest is its row; narrower ones are its track /
--                         share / voice buttons)
--   the page header       a child of TrailheadLog with `.questId`, `.title`
--                         (FontString) and `.titleButton`
-- OneMoreQuest redraws on its own schedule (no hookable function), so the
-- marks follow it on a 0.2 s ticker while the window is visible. Our marks
-- are child frames of our own, anchored to its row buttons, so they scroll
-- with them; no field is written to its frames. A row's tooltip gets its line
-- through F:HookScript on the row buttons' OnEnter.
--
-- "Leads to a dungeon quest" is our own walk over QuestieDB: from a quest,
-- forward through nextQuestInChain and every quest naming it in
-- preQuestSingle / preQuestGroup (an index built once, sliced over frames),
-- up to MAX_STEPS, skipping quests for the other faction, until a quest the
-- character hasn't done that is for an instance: its zoneOrSort is an
-- instance zone (ARLE.Bridge.QuestieDB.InstanceZones), or its tag says dungeon
-- or raid (ARLE.Bridge.Questie.QuestTag; Leaders of the Fang is filed under
-- the Barrens and only its tag tells). Quests that are themselves in a dungeon aren't
-- marked.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib
local QDB = ARLE.Bridge.QuestieDB
local Quests = ARLE.Lib.Quests

local SLICE = 250        -- quests indexed per frame
local MAX_STEPS = 10     -- chain steps walked forward
local POLL = 0.2         -- seconds between syncs while the window is visible
local ROW_BADGE = 24     -- px, the icon on a list row (over its quest mark's corner)
local ROW_X, ROW_Y = 10, -6
local STRIPE_WIDTH = 3   -- px, the orange stripe down a marked row's left edge
local STRIPE_COLOR = { 1, 0.5, 0.1, 0.9 }
local PAGE_BADGE = 30    -- px, the mark after the page title
local LIST_NAMES = { "TrailheadLogList", "TrailheadLogListLegacy" }

local F = {
  id = "DungeonLeadIns",
  addon = ADDON,
  title = "Dungeon Lead-ins",
  group = "OneMoreQuest",
  extends = "OneMoreQuest",
  command = "leads",
  commandHelp = "dungeon marks on OneMoreQuest's quests that lead to a dungeon quest",
  description = "Marks the quests in OneMoreQuest's quest log that lead to a dungeon quest, in the list and on the quest's page; hover for where it leads.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "list", type = "boolean", label = "Mark the quest list", default = true },
    { key = "page", type = "boolean", label = "Mark the quest page", default = true },
    { key = "tooltip", type = "boolean", label = "Say where it leads in the list's tooltip", default = true },
  },
}

local ICON_ATLAS = "Dungeon"
local ICON_FILE = "Interface\\Minimap\\Dungeon"

-------------------------------------------------------------------------------
-- The chain walk
-------------------------------------------------------------------------------

local succ          -- questId -> { questIds that follow it }
local indexState    -- nil, "building", "ready", "failed"
local indexCount = 0
local leadCache = {} -- questId -> lead table or false

local function AddNext(from, to)
  if type(from) ~= "number" or type(to) ~= "number" or from <= 0 or to <= 0 or from == to then
    return
  end
  local list = succ[from]
  if not list then
    list = {}
    succ[from] = list
  end
  list[#list + 1] = to
end

local function IndexQuest(id)
  AddNext(id, QDB.Quest(id, "nextQuestInChain"))
  for _, field in ipairs({ "preQuestSingle", "preQuestGroup" }) do
    local pre = QDB.Quest(id, field)
    if type(pre) == "table" then
      for _, p in ipairs(pre) do
        AddNext(math.abs(tonumber(p) or 0), id)
      end
    end
  end
end

-- Sliced over frames with F:After: dropped if the feature goes off, so
-- OnEnable starts it again from the top.
local function BuildIndex()
  if not QDB.Ready() then
    indexState = "failed"
    F:Debug("index: QuestieDB's QuestDB isn't there")
    return
  end
  local ids = QDB.AllQuestIds()
  succ, indexState, indexCount, leadCache = {}, "building", 0, {}
  local i = 0
  local function Step()
    local stop = math.min(#ids, i + SLICE)
    for j = i + 1, stop do
      pcall(IndexQuest, ids[j])
    end
    i = stop
    indexCount = i
    if i < #ids then
      F:After(0, Step)
    else
      indexState = "ready"
      F:Debug("index: %d quests read", #ids)
    end
  end
  Step()
end

local DUNGEON_TAGS = { [81] = "dungeon", [85] = "dungeon", [62] = "raid", [88] = "raid", [89] = "raid" }

-- The first instance zone among a spawns table's zones ({ [areaId] = ... }).
local function SpawnInstance(spawns, zones)
  if type(spawns) == "table" then
    for areaId in pairs(spawns) do
      if zones[areaId] then
        return zones[areaId]
      end
    end
  end
end

-- Where a tagged quest's work is: its objectives' creatures, objects and the
-- droppers of its items (QuestieDB objectives = { creatures, objects, items }).
local function ObjectiveInstance(questId, zones)
  local obj = QDB.Quest(questId, "objectives")
  if type(obj) ~= "table" then
    return nil
  end
  for _, c in ipairs(type(obj[1]) == "table" and obj[1] or {}) do
    local found = type(c) == "table" and SpawnInstance(QDB.Npc(c[1], "spawns"), zones)
    if found then
      return found
    end
  end
  for _, o in ipairs(type(obj[2]) == "table" and obj[2] or {}) do
    local found = type(o) == "table" and SpawnInstance(QDB.Object(o[1], "spawns"), zones)
    if found then
      return found
    end
  end
  for _, it in ipairs(type(obj[3]) == "table" and obj[3] or {}) do
    local drops = type(it) == "table" and QDB.Item(it[1], "npcDrops")
    for i, npcId in ipairs(type(drops) == "table" and drops or {}) do
      local found = i <= 5 and SpawnInstance(QDB.Npc(npcId, "spawns"), zones)
      if found then
        return found
      end
    end
  end
end

-- The instance a quest is for, or nil: its zone (zoneOrSort) is an instance,
-- or its tag says dungeon / raid (Questie's tags with its corrections, else the
-- game's: Leaders of the Fang is filed under the Barrens but tagged Dungeon).
-- A tagged quest is named after where its objectives are, else "a dungeon".
local function InstanceOf(questId)
  local zones = QDB.InstanceZones() or {}
  local zone = QDB.Quest(questId, "zoneOrSort")
  if type(zone) == "number" and zones[zone] then
    return zones[zone]
  end
  local kind = DUNGEON_TAGS[ARLE.Bridge.Questie.QuestTag(questId) or 0]
  if kind then
    return ObjectiveInstance(questId, zones) or ("a " .. kind)
  end
end

local function QuestName(questId)
  return Lib.Str(QDB.Quest(questId, "name")) or ("Quest " .. questId)
end

-- { questId, name, dungeon, steps } for the nearest dungeon quest this quest
-- leads to, or nil.
local function Lead(questId)
  if indexState ~= "ready" or type(questId) ~= "number" then
    return nil
  end
  local cached = leadCache[questId]
  if cached ~= nil then
    return cached or nil
  end
  local found
  if not InstanceOf(questId) then
    local seen, queue, head = { [questId] = true }, { { questId, 0 } }, 1
    local from = {} -- questId -> the quest the walk reached it from
    while head <= #queue and not found do
      local id, depth = queue[head][1], queue[head][2]
      head = head + 1
      for _, nextId in ipairs(succ[id] or {}) do
        if not seen[nextId] and Quests.ForMySide(nextId) then
          seen[nextId] = true
          from[nextId] = id
          local dungeon = InstanceOf(nextId)
          if dungeon and not Quests.IsDone(nextId) then
            local path, step = {}, nextId
            while step do
              table.insert(path, 1, step)
              step = from[step]
            end
            found = { questId = nextId, name = QuestName(nextId), dungeon = dungeon, steps = depth + 1, path = path }
            break
          end
          if depth + 1 < MAX_STEPS then
            queue[#queue + 1] = { nextId, depth + 1 }
          end
        end
      end
    end
  end
  leadCache[questId] = found or false
  return found
end

local function LeadText(lead)
  return ("Leads to %s: %s%s"):format(lead.dungeon, lead.name,
    lead.steps > 1 and (" (%d steps on)"):format(lead.steps) or "")
end

-------------------------------------------------------------------------------
-- Marks
-------------------------------------------------------------------------------

local function SetIcon(tex)
  if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ICON_ATLAS) then
    tex:SetAtlas(ICON_ATLAS)
  else
    tex:SetTexture(ICON_FILE)
  end
end

local rowBadges = {}                                -- our pool, list marks
local rowsHooked = setmetatable({}, { __mode = "k" }) -- OMQ row buttons given our OnEnter
local pageBadge
local pageQuest -- the quest the page mark is for
local shownRows = 0
local listFound, headerFound -- whether the last sync found OMQ's list and page header

-- A row's mark: a frame over the row's left part holding an orange stripe
-- down the row's left edge and the dungeon icon on the quest mark's corner.
local function RowBadge(i, parent)
  local b = rowBadges[i]
  if not b then
    b = CreateFrame("Frame", nil, parent)
    b:SetWidth(ROW_X + ROW_BADGE + 2)
    b:EnableMouse(false) -- the row's own button keeps its clicks and tooltip
    local stripe = b:CreateTexture(nil, "OVERLAY")
    stripe:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -1)
    stripe:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 1)
    stripe:SetWidth(STRIPE_WIDTH)
    stripe:SetColorTexture(STRIPE_COLOR[1], STRIPE_COLOR[2], STRIPE_COLOR[3], STRIPE_COLOR[4])
    local tex = b:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetSize(ROW_BADGE, ROW_BADGE)
    tex:SetPoint("TOPLEFT", b, "TOPLEFT", ROW_X, ROW_Y)
    SetIcon(tex)
    rowBadges[i] = b
  elseif b:GetParent() ~= parent then
    b:SetParent(parent)
  end
  return b
end

local function HideRows(from)
  for i = from, #rowBadges do
    rowBadges[i]:Hide()
  end
end

local function OnRowEnter(button)
  if not F.db.tooltip then
    return
  end
  local lead = Lead(rawget(button, "data"))
  if lead and GameTooltip:IsOwned(button) and GameTooltip:IsShown() then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|T" .. ICON_FILE .. ":0|t " .. LeadText(lead), 1, 0.82, 0, true)
    GameTooltip:Show()
  end
end

-- OMQ makes the list as TrailheadLogList, and when the game's slim scroll bar
-- can't be made it hides that and uses TrailheadLogListLegacy instead.
local function ListFrame()
  for _, name in ipairs(LIST_NAMES) do
    local scroll = _G[name]
    if scroll and scroll.GetScrollChild and scroll:IsVisible() then
      return scroll
    end
  end
end

local function SyncList()
  local scroll = F.db.list and ListFrame()
  listFound = scroll ~= nil or not F.db.list
  local content = scroll and scroll:GetScrollChild()
  if not content then
    HideRows(1)
    shownRows = 0
    return
  end
  -- The widest shown button of each quest is its row.
  local rows = {}
  for _, child in ipairs({ content:GetChildren() }) do
    local id = child:IsShown() and child:IsObjectType("Button") and rawget(child, "data")
    if type(id) == "number" then
      local width = child:GetWidth() or 0
      if not rows[id] or width > rows[id].width then
        rows[id] = { button = child, width = width }
      end
    end
  end
  local n = 0
  for id, row in pairs(rows) do
    if Lead(id) then
      n = n + 1
      local b = RowBadge(n, content)
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", row.button, "TOPLEFT", 0, 0)
      b:SetPoint("BOTTOMLEFT", row.button, "BOTTOMLEFT", 0, 0)
      b:SetFrameLevel((row.button:GetFrameLevel() or 1) + 5)
      b:Show()
    end
    if not rowsHooked[row.button] then
      rowsHooked[row.button] = true
      F:HookScript(row.button, "OnEnter", OnRowEnter)
    end
  end
  HideRows(n + 1)
  shownRows = n
end

local function FindPageHeader(window)
  for _, child in ipairs({ window:GetChildren() }) do
    if rawget(child, "titleButton") and type(rawget(child, "title")) == "table" then
      return child
    end
  end
end

local function ShowPageTooltip(self)
  local lead = Lead(pageQuest)
  if lead then
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Dungeon lead-in", 1, 0.82, 0)
    GameTooltip:AddLine(LeadText(lead), 1, 1, 1, true)
    GameTooltip:Show()
  end
end

local function SyncPage(window)
  local header = F.db.page and FindPageHeader(window)
  headerFound = header ~= nil or not F.db.page
  local questId = header and header:IsVisible() and rawget(header, "questId")
  local lead = Lead(questId)
  if not lead then
    if pageBadge then
      pageBadge:Hide()
    end
    pageQuest = nil
    return
  end
  if not pageBadge then
    pageBadge = CreateFrame("Frame", nil, header)
    pageBadge:SetSize(PAGE_BADGE, PAGE_BADGE)
    local tex = pageBadge:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(pageBadge)
    SetIcon(tex)
    pageBadge:EnableMouse(true)
    F:Script(pageBadge, "OnEnter", ShowPageTooltip)
    F:Script(pageBadge, "OnLeave", function() GameTooltip:Hide() end)
  elseif pageBadge:GetParent() ~= header then
    pageBadge:SetParent(header)
  end
  local title = rawget(header, "title")
  local width = math.min(Lib.Plain(title:GetStringWidth()) or 0, Lib.Plain(title:GetWidth()) or 0)
  pageBadge:ClearAllPoints()
  pageBadge:SetPoint("LEFT", title, "TOPLEFT", width + 4, -PAGE_BADGE / 2 + 1)
  pageBadge:SetFrameLevel((header:GetFrameLevel() or 1) + 10)
  pageBadge:Show()
  pageQuest = questId
end

local function HideAll()
  HideRows(1)
  shownRows = 0
  if pageBadge then
    pageBadge:Hide()
  end
  pageQuest = nil
end

local function Sync()
  local window = _G.TrailheadLog
  if not (window and window:IsVisible()) or indexState ~= "ready" then
    HideAll()
    return
  end
  SyncList()
  SyncPage(window)
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  indexState, leadCache = nil, {}
  self:After(1, BuildIndex) -- (out of the login rush)
  self:Ticker(POLL, Sync)
  self:On("QUEST_TURNED_IN", function()
    leadCache = {}
  end)
end

function F:OnDisable()
  HideAll()
end

function F:OnOptionChanged()
  Sync()
end

F.commands = {
  { name = "check", args = "<questID>", help = "where does this quest lead?", run = function(self, rest)
    local id = tonumber(rest)
    if not id then
      self:Print("usage: /arl leads check <questID>")
      return
    end
    if indexState ~= "ready" then
      self:Print("still reading QuestieDB's quest chains, try again in a moment.")
      return
    end
    local here = InstanceOf(id)
    local lead = Lead(id)
    if here then
      self:Print(("%s (%d) is itself a quest for %s, so it isn't marked."):format(QuestName(id), id, here))
    elseif lead then
      self:Print(("%s (%d): %s, quest %d."):format(QuestName(id), id, LeadText(lead), lead.questId))
      for i, step in ipairs(lead.path) do
        print(("   %d. %s (%d)"):format(i, QuestName(step), step))
      end
    else
      self:Print(("%s (%d) leads to no dungeon quest you can still do (within %d steps)."):format(QuestName(id), id, MAX_STEPS))
    end
  end },
}

function F:GetStatus()
  if indexState == "failed" then
    return "Active · QuestieDB's quest data wasn't found"
  end
  if indexState ~= "ready" then
    return ("Active · reading quest chains (%d quests so far)"):format(indexCount)
  end
  local window = _G.TrailheadLog
  if not window then
    return "Active · waiting for OneMoreQuest's quest window"
  end
  if not window:IsVisible() then
    return "Active · marks show when OneMoreQuest's quest window is open"
  end
  local missing = {}
  if listFound == false then
    missing[#missing + 1] = "its quest list"
  end
  if headerFound == false then
    missing[#missing + 1] = "its quest page title"
  end
  return ("Active · %d quest%s marked in the list%s%s"):format(shownRows, shownRows == 1 and "" or "s",
    pageQuest and ", and the page" or "",
    #missing > 0 and (" · can't find OneMoreQuest's " .. table.concat(missing, " or ") .. " (OneMoreQuest update?)") or "")
end

ARLE:RegisterModule(F)
