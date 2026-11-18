-- Quest Search: a search window over QuestieDB's quest database.
-- Based on QuestieDB_Search by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
--   Search text      quests whose name or objective text contains every word
--   Leads into zone  quests that start outside a zone and either end at an
--                    NPC/object standing in it, or whose text names it
--   faction filter   All / Alliance / Horde / your faction
--
-- Surfaces (ARLE.Bridge.QuestieDB / Questie): QuestDB / NpcDB / ObjectDB /
-- ItemDB Get(id, field) and GetAllIds(); LibQuestieDB.Enum.zoneIDs /
-- raceMaskById / factionRaceMasks; Questie's ZoneDB (subzones such as
-- Powderfuse Port count as their zone) and QuestieLink for shift-click links.
-- New in Forever's cutoff (ARLE.Lib.Quests.IsNew) stars new quests.
-- Nothing is hooked or written; scans run a slice per frame so a pass over
-- ~6000 quests doesn't freeze the client. The window is ARLE.UI.Window (the
-- current theme) and hides when combat starts.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local QDB, Q, Kit, Skin = ARLE.Bridge.QuestieDB, ARLE.Bridge.Questie, ARLE.UI.Kit, ARLE.Skin
local Quests = ARLE.Lib.Quests

local SLICE = 200 -- quests per frame while scanning
local ROWS = 20   -- visible result rows
local ROW_HEIGHT = 18
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"
local WHITE = "Interface\\Buttons\\WHITE8X8"

local F = {
  id = "QuestSearch",
  addon = ADDON,
  title = "Quest Search",
  group = "Questie",
  extends = "QuestieDB",
  command = "qs",
  commandAliases = { "search" },
  commandArgs = "[<words>|to <zone>]",
  commandHelp = "a quest search window over QuestieDB",
  mainHelp = "opens or closes the window; with words, searches quest names and objectives",
  commandUsage = {
    { "qs <words>", "opens it and searches quest names and objectives" },
    { "qs to <zone>", "quests that start outside a zone and lead into it" },  },
  description = "Search quests by words, or find the quests that lead into a zone.",
  options = {
    { key = "faction", type = "select", label = "Show quests for", default = "mine",
      values = {
        { value = "mine", label = "My faction" },
        { value = "All", label = "Both factions" },
        { value = "Alliance", label = "Alliance" },
        { value = "Horde", label = "Horde" },
      } },
    { type = "button", label = "Open Quest Search", nocmd = true, run = function(def) def:Open() end },
    ARLE.Options.Preset.ResetPosition(),
  },
}

local ui
local allRows = {}  -- { id = questId, why = string? } from the last search
local viewRows = {} -- allRows after the faction filter
local offset = 0
local scanToken = 0
local lastMode = "text"

local function QGet(id, key)
  return QDB.Quest(id, key)
end

-- "All", "Alliance" or "Horde".
local function Faction()
  local f = F.db.faction
  if f == "mine" or f == nil then
    local mine = UnitFactionGroup("player")
    return (mine == "Alliance" or mine == "Horde") and mine or "All"
  end
  return f
end

-------------------------------------------------------------------------------
-- Zones
-------------------------------------------------------------------------------

local areaNames = {}
local function AreaName(areaId)
  local name = areaNames[areaId]
  if name == nil then
    name = false
    if C_Map and C_Map.GetAreaInfo then
      local ok, n = pcall(C_Map.GetAreaInfo, areaId)
      if ok and type(n) == "string" and n ~= "" then
        name = n
      end
    end
    areaNames[areaId] = name
  end
  return name or nil
end

-- areaId and a display name for what was typed.
local function ResolveZone(input)
  local n = tonumber(input)
  if n then
    return n, AreaName(n) or tostring(n)
  end
  local enum = QDB.Enum()
  enum = enum and enum.zoneIDs
  local key = input:upper():gsub("^THE%s+", ""):gsub("'", ""):gsub("[^%w]+", "_")
  if type(enum) == "table" and type(enum[key]) == "number" then
    return enum[key], AreaName(enum[key]) or input
  end
  -- Names are case-sensitive in ZoneDB: try as typed, then Title Case.
  local titled = input:lower():gsub("(%a)([%w']*)", function(a, b)
    return a:upper() .. b
  end)
  for _, name in ipairs({ input, titled, "The " .. titled }) do
    local areaId = Q.AreaIdByName(name)
    if areaId then
      return areaId, name
    end
  end
  -- Last resort: an enum key that contains the term (lowest ID wins).
  if type(enum) == "table" then
    local best
    for k, v in pairs(enum) do
      if type(v) == "number" and k:find(key, 1, true) and (not best or v < best) then
        best = v
      end
    end
    if best then
      return best, AreaName(best) or input
    end
  end
end

-- Does this areaId belong to the target zone?
local function ZoneMatcher(targetArea)
  local targetMap = Q.UiMapForArea(targetArea)
  local cache = {}
  return function(areaId)
    if type(areaId) ~= "number" then
      return false
    end
    local hit = cache[areaId]
    if hit == nil then
      hit = areaId == targetArea or (targetMap ~= nil and Q.UiMapForArea(areaId) == targetMap)
      cache[areaId] = hit
    end
    return hit
  end
end

-------------------------------------------------------------------------------
-- Quest facts
-------------------------------------------------------------------------------

local GIVER_ENTITIES = { "NpcDB", "ObjectDB" }

-- fn(entity, id, isNpc) for each NPC/object in a startedBy / finishedBy table.
local function EachGiver(givers, fn)
  if type(givers) ~= "table" then
    return
  end
  for index = 1, 2 do
    for _, id in ipairs(type(givers[index]) == "table" and givers[index] or {}) do
      fn(GIVER_ENTITIES[index], id, index == 1)
    end
  end
end

local function GiverAreas(givers)
  local areas = {}
  EachGiver(givers, function(entity, id)
    local spawns = QDB.Get(entity, id, "spawns")
    if type(spawns) == "table" then
      for areaId in pairs(spawns) do
        areas[areaId] = true
      end
    end
  end)
  return areas
end

local function AnyIn(areas, inZone)
  for areaId in pairs(areas) do
    if inZone(areaId) then
      return true
    end
  end
  return false
end

-- "Name (Zone)" for the first NPC/object of a startedBy / finishedBy table.
local function GiverLabel(givers)
  local label
  EachGiver(givers, function(entity, id)
    if label then
      return
    end
    local name = QDB.Get(entity, id, "name")
    if type(name) ~= "string" then
      return
    end
    local spawns = QDB.Get(entity, id, "spawns")
    local zone
    if type(spawns) == "table" then
      for areaId in pairs(spawns) do
        zone = AreaName(areaId)
        if zone then
          break
        end
      end
    end
    label = zone and (name .. " (" .. zone .. ")") or name
  end)
  if not label and type(givers) == "table" and type(givers[3]) == "table" and givers[3][1] then
    local itemName = QDB.Item(givers[3][1], "name")
    label = "item: " .. (type(itemName) == "string" and itemName or ("#" .. givers[3][1]))
  end
  return label
end

local function QuestText(questId)
  local parts = { QGet(questId, "name") or "" }
  local objectives = QGet(questId, "objectivesText")
  if type(objectives) == "table" then
    for _, line in ipairs(objectives) do
      parts[#parts + 1] = tostring(line)
    end
  end
  return table.concat(parts, "\n"):lower()
end

-- Faction: "A", "H" or "both".
local factionCache = {}

local function HasBit(value, bitValue)
  return math.floor(value / bitValue) % 2 == 1
end

local function RaceSide(races)
  local enum = QDB.Enum()
  if type(races) ~= "number" or races == 0 or not (enum and enum.raceMaskById and enum.factionRaceMasks) then
    return nil
  end
  -- Arithmetic bit tests: Forever's race bits 32/33 overflow the bit library.
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
  local a, h = Overlaps(enum.factionRaceMasks.Alliance), Overlaps(enum.factionRaceMasks.Horde)
  if a and not h then
    return "A"
  end
  if h and not a then
    return "H"
  end
  return "both"
end

local function NpcSide(givers)
  local npcs = type(givers) == "table" and type(givers[1]) == "table" and givers[1] or nil
  if not npcs then
    return nil
  end
  local a, h, known = false, false, false
  for _, npcId in ipairs(npcs) do
    local friendly = QDB.Npc(npcId, "friendlyToFaction")
    if type(friendly) == "string" and friendly ~= "" then
      known = true
      a = a or friendly:find("A", 1, true) ~= nil
      h = h or friendly:find("H", 1, true) ~= nil
    end
  end
  if not known then
    return nil
  end
  if a and not h then
    return "A"
  end
  if h and not a then
    return "H"
  end
  return "both"
end

local function QuestSide(questId)
  local side = factionCache[questId]
  if side then
    return side
  end
  side = RaceSide(QGet(questId, "requiredRaces")) or NpcSide(QGet(questId, "startedBy"))
    or NpcSide(QGet(questId, "finishedBy")) or "both"
  factionCache[questId] = side
  return side
end

local function PassesFilter(questId)
  local f = Faction()
  if f == "All" then
    return true
  end
  local side = QuestSide(questId)
  return side == "both" or (f == "Alliance" and side == "A") or (f == "Horde" and side == "H")
end

local function LevelColor(level)
  if type(level) == "number" and level > 0 and GetQuestDifficultyColor then
    local ok, c = pcall(GetQuestDifficultyColor, level)
    if ok and type(c) == "table" and c.r then
      return c.r, c.g, c.b
    end
  end
  return 1, 1, 1
end

-------------------------------------------------------------------------------
-- Results view
-------------------------------------------------------------------------------

local function SetStatus(message)
  if ui then
    ui.status:SetText(message or "")
  end
end

local function SortByLevel(a, b)
  local la, lb = QGet(a.id, "questLevel") or 0, QGet(b.id, "questLevel") or 0
  if la ~= lb then
    return la < lb
  end
  return a.id < b.id
end

local function RenderRows()
  if not ui then
    return
  end
  for i = 1, ROWS do
    local row = ui.rows[i]
    local data = viewRows[offset + i]
    if data then
      local id = data.id
      local level = QGet(id, "questLevel")
      local side = QuestSide(id)
      row.questId = id
      row.why = data.why
      row.level:SetText(type(level) == "number" and level > 0 and level or "?")
      row.level:SetTextColor(LevelColor(level))
      row.name:SetText((Quests.IsNew(id) and (STAR .. " ") or "") .. tostring(QGet(id, "name") or ("Quest " .. id)))
      row.side:SetText(side == "A" and "|cff4a9effAlliance|r" or side == "H" and "|cffff4040Horde|r"
        or "|cff999999Both|r")
      row.idText:SetText(id)
      row.start:SetText(GiverLabel(QGet(id, "startedBy")) or "|cff777777unknown|r")
      row:Show()
    else
      row.questId = nil
      row:Hide()
    end
  end
end

local function ApplyFilter()
  viewRows = {}
  for _, row in ipairs(allRows) do
    if PassesFilter(row.id) then
      viewRows[#viewRows + 1] = row
    end
  end
  if not ui then
    return
  end
  local maxOffset = math.max(0, #viewRows - ROWS)
  offset = math.min(offset, maxOffset)
  ui.scroll:SetMinMaxValues(0, maxOffset)
  ui.scroll:SetValue(offset)
  ui.scroll:SetShown(maxOffset > 0)
  local hidden = #allRows - #viewRows
  ui.count:SetText(string.format("%d result%s%s", #viewRows, #viewRows == 1 and "" or "s",
    hidden > 0 and string.format(" |cff999999(%d hidden by the faction filter)|r", hidden) or ""))
  RenderRows()
end

local function Publish(rows, message)
  table.sort(rows, SortByLevel)
  allRows, offset = rows, 0
  ApplyFilter()
  SetStatus(message)
end

-------------------------------------------------------------------------------
-- Searches (sliced over frames; a new search cancels the running one)
-------------------------------------------------------------------------------

local function Scan(test, onDone, label)
  if not QDB.Ready() then
    SetStatus("|cffff6060QuestieDB's QuestDB global was not found (QuestieDB update?).|r")
    return
  end
  scanToken = scanToken + 1
  local token = scanToken
  local ids = QDB.AllQuestIds()
  local rows, i = {}, 0
  local function Step()
    if token ~= scanToken or not F._active then
      return
    end
    local stop = math.min(#ids, i + SLICE)
    for j = i + 1, stop do
      local ok, keep, why = pcall(test, ids[j])
      if ok and keep then
        rows[#rows + 1] = { id = ids[j], why = why }
      end
    end
    i = stop
    if i < #ids then
      SetStatus(string.format("%s %d%%", label, math.floor(i * 100 / #ids)))
      C_Timer.After(0, Step)
    else
      onDone(rows)
    end
  end
  Step()
end

local function TextSearch(text)
  local words = {}
  for word in text:lower():gmatch("%S+") do
    words[#words + 1] = word
  end
  if #words == 0 then
    SetStatus("Type one or more words to search quest names and objectives.")
    return
  end
  Scan(function(id)
    local haystack = QuestText(id)
    for _, word in ipairs(words) do
      if not haystack:find(word, 1, true) then
        return false
      end
    end
    return true
  end, function(rows)
    Publish(rows, string.format("Quests whose name or objectives contain \"%s\".", text))
  end, "Searching...")
end

local function LeadsToSearch(input)
  if input == "" then
    SetStatus("Type a zone name (e.g. Riverglades) or area ID, then click Leads into zone.")
    return
  end
  local areaId, zoneName = ResolveZone(input)
  if not areaId then
    SetStatus("|cffff6060Unknown zone \"" .. input .. "\". Try the exact zone name or its area ID.|r")
    return
  end
  local inZone = ZoneMatcher(areaId)
  local needle = (zoneName or input):lower():gsub("^the%s+", "")
  Scan(function(id)
    if AnyIn(GiverAreas(QGet(id, "startedBy")), inZone) then
      return false
    end
    local endsInside = AnyIn(GiverAreas(QGet(id, "finishedBy")), inZone)
    local mentions = QuestText(id):find(needle, 1, true) ~= nil
    if endsInside and mentions then
      return true, "Ends in " .. zoneName .. " and names it"
    end
    if endsInside then
      return true, "Ends in " .. zoneName
    end
    if mentions then
      return true, "Objectives name " .. zoneName
    end
    return false
  end, function(rows)
    Publish(rows, string.format("Quests that start outside %s (area %d) and lead into it.", zoneName, areaId))
  end, "Scanning quests for " .. zoneName .. "...")
end

local function RunSearch(mode)
  if not ui then
    return
  end
  lastMode = mode or lastMode
  local text = ui.edit:GetText():match("^%s*(.-)%s*$")
  F.char.lastQuery = text
  ui.edit:ClearFocus()
  if lastMode == "zone" then
    LeadsToSearch(text)
  else
    TextSearch(text)
  end
end

-------------------------------------------------------------------------------
-- UI (ARLE.UI.Window: follows the theme)
-------------------------------------------------------------------------------

local COLUMNS = {
  { key = "level", title = "Lvl", x = 0, width = 30, justify = "CENTER" },
  { key = "name", title = "Quest", x = 34, width = 230, justify = "LEFT" },
  { key = "side", title = "Side", x = 268, width = 60, justify = "LEFT" },
  { key = "idText", title = "ID", x = 330, width = 50, justify = "LEFT" },
  { key = "start", title = "Starts at", x = 384, width = 250, justify = "LEFT" },
}

local function ShowRowTooltip(row)
  local id = row.questId
  if not id then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(tostring(QGet(id, "name") or ("Quest " .. id)), 1, 0.82, 0)
  local level, required = QGet(id, "questLevel"), QGet(id, "requiredLevel")
  local side = QuestSide(id)
  GameTooltip:AddLine(string.format("Level %s%s  -  Quest ID %d  -  %s", tostring(level or "?"),
    required and required > 0 and (" (requires " .. required .. ")") or "", id,
    side == "A" and "Alliance" or side == "H" and "Horde" or "Both factions"), 0.8, 0.8, 0.8)
  if Quests.IsNew(id) then
    GameTooltip:AddLine(STAR .. " New in WoW Forever", 1, 0.82, 0)
  end
  if row.why then
    GameTooltip:AddLine(row.why, 0.5, 1, 0.5)
  end
  local objectives = QGet(id, "objectivesText")
  if type(objectives) == "table" and objectives[1] then
    GameTooltip:AddLine(" ")
    for _, line in ipairs(objectives) do
      GameTooltip:AddLine(tostring(line), 1, 1, 1, true)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Starts:", GiverLabel(QGet(id, "startedBy")) or "unknown", 0.6, 0.6, 0.6, 1, 1, 1)
  GameTooltip:AddDoubleLine("Ends:", GiverLabel(QGet(id, "finishedBy")) or "unknown", 0.6, 0.6, 0.6, 1, 1, 1)
  GameTooltip:AddLine("Shift-click to link in chat", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local function OnRowClick(row)
  if row.questId and IsShiftKeyDown() then
    Quests.InsertLink(row.questId, QGet(row.questId, "name"), QGet(row.questId, "questLevel"))
  end
end

local function BuildUI()
  local f = ARLE.UI.Window:New({
    name = "ARLEQuestSearchFrame",
    title = "Quest Search",
    width = 680,
    height = 92 + ROWS * ROW_HEIGHT + 56,
    strata = "HIGH",
    store = F.char,
    key = "pos",
    point = { "CENTER", UIParent, "CENTER", 0, 60 },
    escClose = true,
  })
  local c = f.content
  ui = { frame = f, rows = {} }

  -- Search row
  ui.edit = Kit.EditBox(c, 260, "ARLEQuestSearchEditBox")
  ui.edit:SetPoint("TOPLEFT", 6, -4)
  ui.edit:SetText(F.char.lastQuery or "")
  F:Script(ui.edit, "OnEnterPressed", function()
    RunSearch()
  end)
  local textButton = Kit.Button(c, "Search text", 100)
  textButton:SetPoint("LEFT", ui.edit, "RIGHT", 8, 0)
  F:Script(textButton, "OnClick", function()
    RunSearch("text")
  end)
  local zoneButton = Kit.Button(c, "Leads into zone", 120)
  zoneButton:SetPoint("LEFT", textButton, "RIGHT", 4, 0)
  F:Script(zoneButton, "OnClick", function()
    RunSearch("zone")
  end)

  -- Faction filter
  local bar = CreateFrame("Frame", nil, c)
  bar:SetPoint("TOPLEFT", ui.edit, "BOTTOMLEFT", 0, -8)
  bar:SetSize(360, 18)
  local label = Kit.Text(bar, "GameFontHighlightSmall")
  label:SetPoint("LEFT", 0, 0)
  label:SetText("Show quests for:")
  local holder = CreateFrame("Frame", nil, bar)
  holder:SetPoint("LEFT", label, "RIGHT", 8, 0)
  holder:SetSize(240, 16)
  ui.factions = Kit.FilterButtons(holder, {
    { key = "mine", label = "Mine", width = 50, tip = "Your faction's quests and those for both." },
    { key = "All", label = "All", width = 44 },
    { key = "Alliance", label = "Alliance", width = 64 },
    { key = "Horde", label = "Horde", width = 56 },
  }, function()
    return F.db.faction or "mine"
  end, function(key)
    ARLE:SetOption(F.id, "faction", key)
  end)
  ui.count = Kit.Text(c, "GameFontHighlightSmall")
  ui.count:SetPoint("LEFT", bar, "RIGHT", 8, 0)

  -- Column headers
  local listTop = -58
  for _, col in ipairs(COLUMNS) do
    local h = Kit.Text(c, "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", 4 + col.x, listTop)
    h:SetWidth(col.width)
    h:SetJustifyH(col.justify)
    h:SetText(col.title)
    h:SetTextColor(Skin:Accent())
  end

  -- Result rows
  local list = CreateFrame("Frame", nil, c)
  list:SetPoint("TOPLEFT", 0, listTop - 14)
  list:SetPoint("RIGHT", c, "RIGHT", -18, 0)
  list:SetHeight(ROWS * ROW_HEIGHT)
  list:EnableMouseWheel(true)
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    if i % 2 == 0 then
      local stripe = row:CreateTexture(nil, "BACKGROUND")
      stripe:SetAllPoints()
      stripe:SetColorTexture(1, 1, 1, 0.04)
    end
    for _, col in ipairs(COLUMNS) do
      local fs = Kit.Text(row, "GameFontHighlightSmall")
      fs:SetPoint("LEFT", 4 + col.x, 0)
      fs:SetWidth(col.width)
      fs:SetJustifyH(col.justify)
      fs:SetWordWrap(false)
      row[col.key] = fs
    end
    F:Script(row, "OnEnter", ShowRowTooltip)
    F:Script(row, "OnLeave", GameTooltip_Hide)
    F:Script(row, "OnClick", OnRowClick)
    row:Hide()
    ui.rows[i] = row
  end

  -- Scroll bar: a slim track and thumb, like the theme's scroll bars.
  local scroll = CreateFrame("Slider", nil, c)
  scroll:SetOrientation("VERTICAL")
  scroll:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
  scroll:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 6, 0)
  scroll:SetWidth(8)
  local track = scroll:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(1, 1, 1, 0.06)
  scroll:SetThumbTexture(WHITE)
  local thumb = scroll.GetThumbTexture and scroll:GetThumbTexture()
  if thumb then
    thumb:SetVertexColor(1, 1, 1, 0.3)
    thumb:SetSize(8, 24)
  end
  scroll:SetMinMaxValues(0, 0)
  scroll:SetValueStep(1)
  if scroll.SetObeyStepOnDrag then
    scroll:SetObeyStepOnDrag(true)
  end
  F:Script(scroll, "OnValueChanged", function(_, value)
    local v = math.floor(value + 0.5)
    if v ~= offset then
      offset = v
      RenderRows()
    end
  end)
  F:Script(list, "OnMouseWheel", function(_, delta)
    local minV, maxV = scroll:GetMinMaxValues()
    scroll:SetValue(math.max(minV, math.min(maxV, offset - delta * 3)))
  end)
  ui.scroll = scroll

  ui.status = Kit.Text(c, "GameFontDisableSmall")
  ui.status:SetPoint("BOTTOMLEFT", 4, 2)
  ui.status:SetPoint("RIGHT", c, "RIGHT", -4, 0)
  ui.status:SetWordWrap(false)

  ui.factions.Paint()
  ApplyFilter()
  SetStatus("Search quest names and objectives, or type a zone and click Leads into zone. Hover a quest for details.")
end

function F:Open(query, mode)
  if InCombatLockdown() then
    self:Print("not available in combat.")
    return
  end
  if not ui then
    BuildUI()
  end
  ui.frame:Show()
  if query and query ~= "" then
    ui.edit:SetText(query)
    RunSearch(mode)
  end
end

function F:IsOpen()
  return ui ~= nil and ui.frame:IsShown()
end

function F:OnResetPosition()
  -- The window keeps its position in char.pos (the preset clears char.position).
  self.char.pos = nil
  if ui then
    ui.frame:RestorePosition()
  end
end

-- /arl qs [words | to <zone>]
function F:main(_, raw)
  raw = ARLE.Lib.Trim(raw)
  local command, rest = raw:match("^(%S+)%s*(.-)$")
  if command and command:lower() == "to" and rest ~= "" then
    self:Open(rest, "zone")
  elseif raw ~= "" then
    self:Open(raw, "text")
  elseif self:IsOpen() then
    ui.frame:Hide()
  else
    self:Open()
  end
end

-- The host checks on, off, help, set and settings (faction) before the main
-- action, so those words can't start "/arl qs <words>"; find takes any text.
F.commands = {
  { name = "find", args = "<words>", help = "searches quest names and objectives (any words, even on, off, set...)",
    run = function(self, _, raw)
      raw = ARLE.Lib.Trim(raw or "")
      if raw == "" then
        self:Open()
      else
        self:Open(raw, "text")
      end
    end },
}

-- QuestieDB_Search's data (QuestieDBSearchDB, per character) replaces ours:
-- its faction filter ("player" or the character's own faction mean "mine",
-- which follows the character), the window's centre offset (same anchor as ours)
-- and the last search text.
function F:Import()
  local old = _G.QuestieDBSearchDB
  if type(old) ~= "table" then
    return
  end
  local f = old.faction
  if f == "player" then
    self.db.faction = "mine"
  elseif f == "All" or f == "Alliance" or f == "Horde" then
    self.db.faction = (f == UnitFactionGroup("player")) and "mine" or f
  end
  local x, y = old.x, old.y
  if type(x) == "number" and type(y) == "number" and x == x and y == y then
    self.char.pos = { "CENTER", "CENTER", x, y }
  end
  if type(old.lastQuery) == "string" then
    self.char.lastQuery = old.lastQuery
  end
end

function F:OnEnable()
  self:On("PLAYER_REGEN_DISABLED", function()
    if ui and ui.frame:IsShown() then
      ui.frame:Hide()
    end
  end)
end

function F:OnDisable()
  scanToken = scanToken + 1
  if ui then
    ui.frame:Hide()
  end
end

function F:OnOptionChanged(key)
  if key == "faction" and ui then
    ui.factions.Paint()
    offset = 0
    ApplyFilter()
  end
end

ARLE:RegisterModule(F)
