-- Quest Tracker: extras for EllesmereUI's Custom Quest Tracker (WoW Forever).
--
-- Zone focus: entering a zone folds every other zone category on the tracker
-- and unfolds the current zone's category and its quests; in a capital city
-- the class and profession categories unfold too. It writes the tracker's own
-- per-character fold state (EllesmereUI.CharData("questTracker").ctCollapsed,
-- keys "z:<quest log header>" and questIDs) and asks it to redraw, and only
-- when the zone changes, so folding by hand afterwards sticks.
--
-- Quest item buttons:
-- Draws an item icon at the right end of each quest title through EUI's
-- public row hook (EllesmereUI.RegisterQuestTrackerRow). EUI forbids secure
-- frames on its row slots, so the icons are plain buttons, and clicking goes
-- through our own SecureActionButtons (type "item") under UIParent, laid by
-- screen coordinates over every owned item's icon (based on
-- EllesmereUIQuestTracker_QuestItems): re-placed after each tracker redraw and
-- on a 0.25 s ticker out of combat, hidden when the row is scrolled out of the
-- tracker's ScrollFrame, and left in place in combat (so they work there).
-- They are never created, moved, shown, hidden or changed in combat.
--
-- Missing items: GetQuestLogSpecialItemInfo only reports an item while it is
-- in your bags, so every quest -> item pair seen is remembered (per
-- character, pruned when the quest leaves the log). A remembered item that is
-- no longer in your bags while the quest is still open is drawn red, and
-- announced once.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local SLOT_W = 24      -- width reserved right of each title (EUI caps at 64)
local SCAN_DELAY = 0.5 -- debounce for bag and quest log bursts
local LOGIN_GRACE = 3  -- seconds before the first missing-item check

local mod = {
  id = "EUIQuestItems",
  addon = ADDON,
  title = "Quest Tracker",
  group = "EllesmereUI",
  extends = "EllesmereUIQuestTracker",
  command = "qt",
  commandHelp = "EllesmereUI quest tracker extras",
  commands = {
    { name = "check", args = "<questID>", help = "which item buttons a quest gets, and why", always = true,
      run = function(self, rest) self:CheckQuest(tonumber(rest)) end },
  },
  description = "Quest item buttons, missing-item alerts and zone focus for EllesmereUI's quest tracker.",
  defaults = {
    zoneFocus = true,
    cityExtras = true,
    showButtons = true,
    showMissing = true,
    alertChat = true,
    alertScreen = true,
    alertSound = true,
    deferToEUI = true,
    iconSize = 18,
    questieItems = true,
    questieAbsent = true,
  },
  options = {
    { type = "header", label = "Zones" },
    {
      key = "zoneFocus",
      type = "boolean",
      label = "Expand only the current zone's quests",
      tooltip = "When you enter a zone, every other zone category folds and the current zone's category and its quests unfold. Fold or unfold by hand afterwards as you like; it only acts when the zone changes.",
    },
    {
      key = "cityExtras",
      type = "boolean",
      label = "In cities, also class and profession quests",
      tooltip = "In a capital city (Orgrimmar, Stormwind, ...) the categories for your class (e.g. Warlock), your professions and Crafting unfold as well.",
    },
    { type = "header", label = "Quest item buttons" },
    { key = "showButtons", type = "boolean", label = "Show quest item buttons" },
    { key = "iconSize", type = "number", label = "Button size (12-24)", min = 12, max = 24 },
    {
      key = "deferToEUI",
      type = "boolean",
      label = "Leave usable items to EUI's own buttons",
      tooltip = "When EllesmereUI's own Quest Item Buttons setting is on, only missing items are shown here, so you never get two buttons.",
    },
    {
      key = "questieItems",
      type = "boolean",
      requires = { "QuestieDB", "Questie" },
      label = "Also use QuestieDB's quest items",
      tooltip = "For quests the game gives no item button: the item the quest hands you, or one it needs, when "
        .. "it has a \"Use:\" effect (from QuestieDB, or Questie's database).",
    },
    {
      key = "questieAbsent",
      type = "boolean",
      requires = { "QuestieDB", "Questie" },
      label = "Show them greyed when not in bags",
      disabled = function(def) return not def.db.questieItems end,
    },
    { type = "header", label = "When a quest item is missing" },
    {
      key = "showMissing",
      type = "boolean",
      label = "Show a red button",
      tooltip = "Keep a red button on the quest while its item is not in your bags.",
    },
    { key = "alertChat", type = "boolean", label = "Chat message" },
    { key = "alertScreen", type = "boolean", label = "On-screen warning" },
    { key = "alertSound", type = "boolean", label = "Sound" },
  },
}

-------------------------------------------------------------------------------
-- Item helpers
-------------------------------------------------------------------------------

local GetItemCount = (C_Item and C_Item.GetItemCount) or _G.GetItemCount
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemCooldown = (C_Container and C_Container.GetItemCooldown) or _G.GetItemCooldown

local function Count(itemID, includeBank)
  return GetItemCount(itemID, includeBank) or 0
end

local function ItemLink(itemID)
  local _, link = GetItemInfo(itemID)
  if not link and C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  return link or ("item " .. itemID)
end

local function ItemName(itemID)
  local name = GetItemInfo(itemID)
  return name or "quest item"
end

local function SpecialItemAt(logIndex)
  local link, tex, charges, showDone = GetQuestLogSpecialItemInfo(logIndex)
  local itemID = link and tonumber(link:match("item:(%d+)"))
  if itemID then
    return itemID, tex, charges, showDone
  end
end

local function SpecialItem(questID)
  local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
  if logIndex then
    return SpecialItemAt(logIndex)
  end
end

-- itemID, texture, charges, showWhenComplete: live from the log, else learned.
local function QuestItem(questID)
  local itemID, tex, charges, showDone = SpecialItem(questID)
  if itemID then
    mod.char.known[questID] = itemID
    return itemID, tex, charges, showDone
  end
  itemID = mod.char.known[questID]
  if itemID then
    return itemID, GetItemIcon(itemID), nil, false
  end
end

-- QuestieDB's items for a quest: the item it hands you (sourceItemId) and the
-- ones it needs (requiredSourceItems), kept when they have a "Use:" effect.
-- Cached once every item's data has loaded; until then the items still
-- loading are in `waiting`, and ITEM_DATA_LOAD_RESULT redraws the tracker.
local dbItems = {}
local waiting = {} -- itemID -> its data was requested
local NONE = {}
local function Usable(itemID)
  if ARLE.Lib.Items.HasUseSpell(itemID) then
    return true
  end
  local cached = C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(itemID)
  if cached == false then
    if not waiting[itemID] then
      waiting[itemID] = true
      if C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
      end
    end
    return nil
  end
  return false
end

-- Every usable QuestieDB item of the quest (a list; don't modify it).
local function DatabaseItems(questID)
  if mod.db.questieItems == false then
    return NONE
  end
  local list = dbItems[questID]
  if not list then
    local Q = ARLE.Bridge.Questie
    local complete, seen = true, {}
    list = {}
    local function Consider(itemID)
      itemID = tonumber(itemID)
      if not itemID or itemID <= 0 or seen[itemID] then
        return
      end
      seen[itemID] = true
      local usable = Usable(itemID)
      if usable then
        list[#list + 1] = itemID
      elseif usable == nil then
        complete = false
      end
    end
    Consider(Q.QuestField(questID, "sourceItemId"))
    local required = Q.QuestField(questID, "requiredSourceItems")
    if type(required) == "table" then
      for _, itemID in ipairs(required) do
        Consider(itemID)
      end
    end
    if complete then
      dbItems[questID] = list
    end
  end
  return list
end

-- The one to show: the first one in your bags, else the first.
local function DatabaseItem(questID)
  local list = DatabaseItems(questID)
  for _, itemID in ipairs(list) do
    if Count(itemID) > 0 then
      return itemID
    end
  end
  return list[1]
end

function mod:CheckQuest(questID)
  if not questID then
    self:Print("usage: /arl qt check <questID>")
    return
  end
  questID = math.floor(questID)
  dbItems[questID] = nil -- look it up again
  local live = SpecialItem(questID)
  local known = type(self.char.known) == "table" and self.char.known
  local learned = known and known[questID]
  local names = {}
  for _, itemID in ipairs(DatabaseItems(questID)) do
    names[#names + 1] = ItemLink(itemID) .. " (" .. Count(itemID) .. " in bags)"
  end
  local fromDB = names[1] and table.concat(names, ", ")
    or (ARLE.Bridge.QuestieDB.Ready() and ("none" .. (next(waiting) and " (item data still loading, try again)" or ""))
      or "not installed")
  self:Print("quest " .. questID .. ": game item " .. (live and ItemLink(live) or "none")
    .. ", remembered " .. (learned and ItemLink(learned) or "none")
    .. ", QuestieDB " .. fromDB)
end

local function EUIButtonsOn()
  local eqt = _G.EllesmereUIQuestTracker
  if eqt and eqt.Cfg then
    local ok, value = pcall(eqt.Cfg, "customItemButtons")
    return ok and value == true
  end
  return false
end

local function RefreshRows()
  if EllesmereUI and EllesmereUI.RefreshQuestTrackerRows then
    EllesmereUI.RefreshQuestTrackerRows()
  end
end

-------------------------------------------------------------------------------
-- Tooltip and the secure use buttons
-------------------------------------------------------------------------------

local visuals = setmetatable({}, { __mode = "k" }) -- EUI slot -> our icon button
local shown = {}   -- icon buttons currently showing

local function TooltipAnchor(owner)
  local x = owner:GetCenter()
  if x and x * owner:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2 then
    return "ANCHOR_LEFT"
  end
  return "ANCHOR_RIGHT"
end

-- b: an icon button, or a use button's data (questID, itemID, items).
-- clickable: the owner is a use button.
local function ShowTooltip(owner, b, clickable)
  if not (b and b.itemID) then
    return
  end
  GameTooltip:SetOwner(owner, TooltipAnchor(owner))
  local logIndex = b.questID and C_QuestLog.GetLogIndexForQuestID(b.questID)
  if not b.missing and logIndex and SpecialItemAt(logIndex) == b.itemID then
    GameTooltip:SetQuestLogSpecialItem(logIndex)
  else
    GameTooltip:SetItemByID(b.itemID)
  end
  local items = b.items
  if items and items[2] then
    for i = 2, #items do
      local id = items[i]
      local name = GetItemInfo(id)
      if not name and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
      end
      GameTooltip:AddLine("Also uses: |T" .. (GetItemIcon(id) or 134400) .. ":0|t " .. (name or ("item " .. id))
        .. (Count(id) > 0 and "" or " |cff999999(not in bags)|r"), 1, 1, 1, true)
    end
  end
  if b.absent then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Not in your bags yet: the quest uses it (QuestieDB).", 0.7, 0.7, 0.7, true)
  elseif b.missing then
    GameTooltip:AddLine(" ")
    if Count(b.itemID, true) > 0 then
      GameTooltip:AddLine("Not in your bags. It is in your bank.", 1, 0.55, 0.3, true)
    else
      GameTooltip:AddLine(
        "Not in your bags. You may need to get it again, or abandon and re-accept the quest.",
        1,
        0.3,
        0.3,
        true
      )
    end
    GameTooltip:AddLine("Right-click: stop warning about this quest", 0.6, 0.6, 0.6)
  elseif clickable then
    GameTooltip:AddLine("Click to use it.", 0.05, 0.82, 0.62)
  elseif InCombatLockdown() then
    GameTooltip:AddLine("Appeared in combat: it can be clicked once combat ends.", 1, 0.55, 0.3, true)
  end
  GameTooltip:Show()
end

-- Using an item needs a secure button, and EUI's rows must never carry one
-- (PLUGINS_API.md), so: a pool of our own SecureActionButtons under UIParent,
-- placed by screen coordinates over each owned item's icon, never anchored
-- to the tracker. They are placed out of combat only (after every redraw and
-- on a short ticker, which follows scrolling and dragging) and stay put in
-- combat, so a button placed before the pull still works during it.
local useButtons = {} -- pool, in use order
local useData = setmetatable({}, { __mode = "k" }) -- use button -> { questID, itemID, items }
local syncQueued = false

local function GetUseButton(i)
  local u = useButtons[i]
  if u then
    return u
  end
  u = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
  u:SetAttribute("type", "item")
  u:SetAttribute("useOnKeyDown", false)
  u:RegisterForClicks("AnyUp")
  u:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  u:SetScript("OnEnter", function(self)
    ShowTooltip(self, useData[self], true)
  end)
  u:SetScript("OnLeave", GameTooltip_Hide)
  u:Hide()
  useButtons[i] = u
  return u
end

-- The scroll frame clipping the tracker rows, if any (a row scrolled out of
-- view must not leave a clickable button on the screen).
local function ClipFrame(frame)
  local p = frame:GetParent()
  while p do
    if p.IsObjectType and p:IsObjectType("ScrollFrame") then
      return p
    end
    p = p:GetParent()
  end
end

local function SyncUseButtons()
  syncQueued = false
  if InCombatLockdown() then
    return
  end
  local n = 0
  if mod._active then
    for _, b in pairs(visuals) do
      local itemID = b.itemID
      local ok = itemID and not b.missing and not b.absent and b:IsVisible() and Count(itemID) > 0
      local left, bottom, w, h
      if ok then
        left, bottom, w, h = b:GetLeft(), b:GetBottom(), b:GetWidth(), b:GetHeight()
        ok = left and bottom and w and h and w > 0 and h > 0
      end
      if ok then
        local clip = ClipFrame(b)
        if clip then
          local top, cbottom = clip:GetTop(), clip:GetBottom()
          if top and cbottom and (bottom + h > top + 0.5 or bottom < cbottom - 0.5) then
            ok = false
          end
        end
      end
      if ok then
        n = n + 1
        local u = GetUseButton(n)
        local s = b:GetEffectiveScale() / u:GetEffectiveScale()
        u:ClearAllPoints()
        u:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * s, bottom * s)
        u:SetSize(w * s, h * s)
        u:SetFrameStrata(b:GetFrameStrata())
        u:SetFrameLevel(b:GetFrameLevel() + 5)
        local item = "item:" .. itemID
        if u:GetAttribute("item") ~= item then
          u:SetAttribute("item", item)
        end
        local d = useData[u] or {}
        d.questID, d.itemID, d.items = b.questID, itemID, b.items
        useData[u] = d
        u:Show()
        -- The use button takes hover and clicks; the icon only while uncovered.
        b:EnableMouse(false)
      else
        b:EnableMouse(true)
      end
    end
  end
  for i = n + 1, #useButtons do
    local u = useButtons[i]
    if u:IsShown() then
      if GameTooltip:IsOwned(u) then
        GameTooltip:Hide()
      end
      u:Hide()
    end
  end
end

local function QueueSync()
  if syncQueued then
    return
  end
  syncQueued = true
  C_Timer.After(0, SyncUseButtons)
end

-- Out of combat only (OnDisable runs it through ARLE.Secure in combat).
local function ClearUseButtons()
  for _, u in ipairs(useButtons) do
    if GameTooltip:IsOwned(u) then
      GameTooltip:Hide()
    end
    u:Hide()
    u:SetAttribute("item", nil)
    useData[u] = nil
  end
end

-------------------------------------------------------------------------------
-- Row icons
-------------------------------------------------------------------------------

local Forget -- defined with the scanner

local function UpdateCooldown(b)
  local start, duration, enable = GetItemCooldown(b.itemID)
  if CooldownFrame_Set then
    CooldownFrame_Set(b.cd, start or 0, duration or 0, enable)
  elseif start and duration and duration > 0 then
    b.cd:SetCooldown(start, duration)
  end
end

local function Visual(slot)
  local b = CreateFrame("Button", nil, slot)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 1, -1)
  b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cd:SetAllPoints(b.icon)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  b.count:SetPoint("BOTTOMRIGHT", 0, 0)
  b.alert = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  b.alert:SetPoint("CENTER", 0, 0)
  b.alert:SetText("!")
  b.alert:SetTextColor(1, 0.25, 0.2)
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  b:SetScript("OnEnter", function(self)
    ShowTooltip(self, self, false)
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  -- Only reached where no use button covers the icon: a red (missing) or
  -- grey (not in bags) one, or an icon that appeared in combat.
  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.missing then
      Forget(self.questID)
    elseif not self.missing and not self.absent and InCombatLockdown() then
      UIErrorsFrame:AddMessage("This quest item button appeared in combat: it can be used once combat ends.", 1, 0.3,
        0.3)
    end
  end)
  b:SetScript("OnShow", function(self)
    shown[self] = true
  end)
  b:SetScript("OnHide", function(self)
    shown[self] = nil
  end)
  visuals[slot] = b
  return b
end

-- EUI calls this for every quest title row on every tracker redraw.
local function OnRow(slot, questID, title)
  local b = visuals[slot]
  QueueSync() -- the use buttons follow every redraw
  if not mod._active or type(questID) ~= "number" then
    if b then
      b:Hide()
    end
    return
  end
  local db = mod.db
  local itemID, tex, charges, showDone = QuestItem(questID)
  local fromDB = false
  if not itemID then
    itemID = DatabaseItem(questID)
    fromDB = itemID ~= nil
  end
  local complete = C_QuestLog.IsComplete(questID) == true
  local count = itemID and Count(itemID) or 0
  -- A database item you don't have yet isn't "missing" (no red, no alert):
  -- it's shown greyed, or not at all.
  local absent = fromDB and count == 0
  local missing = itemID ~= nil and count == 0 and not fromDB
  local show = false
  if itemID and not mod.char.ignored[questID] then
    if absent then
      show = db.showButtons and db.questieAbsent and not complete
    elseif missing then
      show = db.showMissing and not complete
    else
      show = db.showButtons and (not complete or showDone) and not (db.deferToEUI and EUIButtonsOn())
    end
  end
  if not show then
    if b then
      b:Hide()
    end
    return
  end

  b = b or Visual(slot)
  -- The quest's other usable QuestieDB items ("Also uses" in the tooltip).
  local items = { itemID }
  if not complete then
    for _, id in ipairs(DatabaseItems(questID)) do
      if id ~= itemID and (db.questieAbsent or Count(id) > 0) then
        items[#items + 1] = id
      end
    end
  end
  b.items = items
  local size = math.min(math.max(tonumber(db.iconSize) or 18, 12), SLOT_W)
  local fontSize
  if title and title.GetFont then
    fontSize = select(2, title:GetFont())
  end
  b:SetSize(size, size)
  b:ClearAllPoints()
  -- Centred on the title's first line, however many lines it wraps to.
  b:SetPoint("TOPRIGHT", slot, "TOPRIGHT", 0, ((fontSize or size) - size) / 2)
  b.questID, b.itemID, b.missing, b.absent = questID, itemID, missing, absent
  b.icon:SetTexture(tex or GetItemIcon(itemID) or 134400)
  b.icon:SetDesaturated(missing or absent)
  b.icon:SetAlpha((missing or absent) and 0.55 or 1)
  if missing then
    b.bg:SetColorTexture(0.85, 0.12, 0.1, 1)
  else
    b.bg:SetColorTexture(0, 0, 0, 1)
  end
  b.alert:SetShown(missing)
  local stack = (charges and charges > 1 and charges) or (count > 1 and count) or nil
  b.count:SetText(stack or "")
  UpdateCooldown(b)
  b:Show()
  shown[b] = true
end

-------------------------------------------------------------------------------
-- Scanner: learns quest items, notices lost ones, alerts once per loss
-------------------------------------------------------------------------------

local had = {}      -- questID -> item was in bags at the last scan
local progress = {} -- questID -> objectives fulfilled at the last scan
local alerted = {}  -- questID -> warned about this loss already
local signature     -- last scan's state, to redraw only on change
local logReady = false
local scanQueued = false
local bagsChanged = false -- a BAG_UPDATE_DELAYED since the last scan
local events = CreateFrame("Frame")

local function Fulfilled(questID)
  local total = 0
  local objectives = C_QuestLog.GetQuestObjectives(questID)
  if objectives then
    for _, o in ipairs(objectives) do
      total = total + (o.numFulfilled or (o.finished and 1 or 0))
    end
  end
  return total
end

local function Announce(lost)
  local db = mod.db
  if db.alertChat then
    for _, entry in ipairs(lost) do
      local questID, itemID = entry[1], entry[2]
      local title = C_QuestLog.GetTitleForQuestID(questID) or ("quest " .. questID)
      local where = Count(itemID, true) > 0 and " It is in your bank." or ""
      ARLE:Print(ItemLink(itemID) .. " for |cffffd100" .. title .. "|r is not in your bags." .. where)
    end
  end
  if db.alertScreen and RaidNotice_AddMessage and RaidWarningFrame then
    local text = #lost == 1 and ("Missing quest item: " .. ItemName(lost[1][2]))
      or (#lost .. " quest items missing from your bags")
    RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.2 })
  end
  if db.alertSound and SOUNDKIT then
    PlaySound(SOUNDKIT.RAID_WARNING or 8959, "Master")
  end
end

local function Scan()
  scanQueued = false
  if not mod._active then
    return
  end
  local db = mod.db
  local known, ignored = mod.char.known, mod.char.ignored
  local bags = bagsChanged
  bagsChanged = false

  local inLog = {}
  local entries = C_QuestLog.GetNumQuestLogEntries()
  for i = 1, entries do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then
      inLog[info.questID] = true
      local itemID = SpecialItemAt(i)
      if itemID then
        known[info.questID] = itemID
      end
    end
  end

  local lost, parts = {}, {}
  for questID, itemID in pairs(known) do
    if logReady and not inLog[questID] then
      -- Turned in or abandoned.
      known[questID], ignored[questID] = nil, nil
      had[questID], progress[questID], alerted[questID] = nil, nil, nil
    elseif inLog[questID] then
      local have = Count(itemID) > 0
      local done = Fulfilled(questID)
      if have then
        alerted[questID] = nil
      elseif logReady and not ignored[questID] and C_QuestLog.IsComplete(questID) ~= true then
        if had[questID] and progress[questID] and done > progress[questID] then
          -- Used up by the objective it was for, not lost.
          ignored[questID] = itemID
        elseif not alerted[questID] then
          alerted[questID] = true
          lost[#lost + 1] = { questID, itemID }
        end
      end
      had[questID], progress[questID] = have, done
      parts[#parts + 1] = questID .. (have and "+" or "-") .. (ignored[questID] and "i" or "")
    end
  end

  if #lost > 0 then
    Announce(lost)
  end
  table.sort(parts)
  local sig = table.concat(parts, ",")
  if sig ~= signature then
    signature = sig
    RefreshRows()
    ARLE:Changed()
  elseif bags and (next(shown) ~= nil or (db.questieItems ~= false and not db.questieAbsent)) then
    -- The signature only covers remembered quest items: QuestieDB items
    -- (owned or greyed, or a looted one that now gets an icon) and stack
    -- counts need a redraw of their own.
    RefreshRows()
  end
end

local function Queue()
  if scanQueued then
    return
  end
  scanQueued = true
  C_Timer.After(SCAN_DELAY, Scan)
end

function Forget(questID)
  mod.char.ignored[questID] = mod.char.known[questID] or true
  signature = nil
  Queue()
end

events:SetScript("OnEvent", function(_, event, arg1)
  if event == "BAG_UPDATE_COOLDOWN" then
    for b in pairs(shown) do
      UpdateCooldown(b)
    end
    return
  end
  if event == "UNIT_QUEST_LOG_CHANGED" and arg1 ~= "player" then
    return
  end
  if event == "BAG_UPDATE_DELAYED" then
    bagsChanged = true
  end
  Queue()
end)

-------------------------------------------------------------------------------
-- Zone focus
-------------------------------------------------------------------------------

-- Capital cities by map ID (the same on every client language).
local CAPITALS = {
  [1453] = true, -- Stormwind City
  [1454] = true, -- Orgrimmar
  [1455] = true, -- Ironforge
  [1456] = true, -- Thunder Bluff
  [1457] = true, -- Darnassus
  [1458] = true, -- Undercity
}

local function InCapital()
  local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  -- Walk up from a sub-zone map (the Cleft of Shadow is inside Orgrimmar).
  for _ = 1, 4 do
    if not mapID then
      return false
    end
    if CAPITALS[mapID] then
      return true
    end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    mapID = info and info.parentMapID
  end
  return false
end

-- Quest log categories for the player's class and professions.
local function ClassAndProfessionHeaders(set)
  local className = UnitClass("player")
  if className then
    set[className] = true
  end
  set["Crafting"] = true -- WoW Forever's own category for crafting quests
  if GetProfessions and GetProfessionInfo then
    for _, index in pairs({ GetProfessions() }) do
      local name = index and GetProfessionInfo(index)
      if name then
        set[name] = true
      end
    end
  elseif GetNumSkillLines and GetSkillLineInfo then
    -- Older clients: the skill list's professions sections.
    local inProfessions = false
    for i = 1, GetNumSkillLines() do
      local name, isHeader = GetSkillLineInfo(i)
      if isHeader then
        inProfessions = (name == TRADE_SKILLS or name == SECONDARY_SKILLS
          or name == "Professions" or name == "Secondary Skills")
      elseif inProfessions and name then
        set[name] = true
      end
    end
  end
end

-- questID -> quest log category, from EUI's own snapshot when it has one.
local function QuestCategories()
  local eqt = _G.EllesmereUIQuestTracker
  if eqt and eqt.QuestLogSnapshot then
    local ok, _, byQuest = pcall(eqt.QuestLogSnapshot)
    if ok and type(byQuest) == "table" then
      return byQuest
    end
  end
  local byQuest, header = {}, nil
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and info.isHeader then
      header = info.title
    elseif info and info.questID then
      byQuest[info.questID] = header
    end
  end
  return byQuest
end

-- Folds every zone category but the wanted ones and unfolds those (and their
-- quests). Leaves the tracker alone when none of the wanted categories has a
-- quest, so walking through a zone without quests folds nothing.
local function FocusZone()
  local db = mod.db
  if not mod._active or not db.zoneFocus or not _G.EUI_CustomQuestTracker then
    return
  end
  local charData = EllesmereUI and EllesmereUI.CharData and EllesmereUI.CharData("questTracker", true)
  if type(charData) ~= "table" then
    return
  end
  if type(charData.ctCollapsed) ~= "table" then
    charData.ctCollapsed = {}
  end
  local collapsed = charData.ctCollapsed

  local wanted = {}
  local zone = GetRealZoneText and GetRealZoneText()
  if zone and zone ~= "" then
    wanted[zone] = true
  end
  if IsInInstance and IsInInstance() then
    local instance = GetInstanceInfo()
    if instance then
      wanted[instance] = true
    end
  end
  if db.cityExtras and InCapital() then
    ClassAndProfessionHeaders(wanted)
  end

  local byQuest = QuestCategories()
  local present, hit = {}, false
  for _, header in pairs(byQuest) do
    present[header] = true
    if wanted[header] then
      hit = true
    end
  end
  if not hit then
    return
  end
  for header in pairs(present) do
    collapsed["z:" .. header] = not wanted[header] or nil
  end
  for questID, header in pairs(byQuest) do
    if wanted[header] then
      collapsed[questID] = nil
    end
  end
  RefreshRows()
end
mod.FocusZone = FocusZone

local zoneEvents = CreateFrame("Frame")
zoneEvents:SetScript("OnEvent", function()
  -- The zone text and the quest log settle a moment after a loading screen.
  C_Timer.After(1, FocusZone)
end)

-------------------------------------------------------------------------------
-- Module lifecycle
-------------------------------------------------------------------------------

local registered = false
local EVENTS = {
  "BAG_UPDATE_DELAYED",
  "BAG_UPDATE_COOLDOWN",
  "QUEST_LOG_UPDATE",
  "QUEST_ACCEPTED",
  "QUEST_REMOVED",
  "UNIT_QUEST_LOG_CHANGED",
}

function mod:OnEnable()
  local db, char = self.db, self.char
  -- Remembered and ignored quest items are per character (they are pruned
  -- against this character's quest log). Older versions kept them account
  -- wide: those go once to the first character that enables this, whose
  -- quest log check then drops whatever isn't its own.
  for _, key in ipairs({ "known", "ignored" }) do
    if type(char[key]) ~= "table" then
      char[key] = type(db[key]) == "table" and db[key] or {}
    end
    db[key] = nil
  end
  if not registered and EllesmereUI and EllesmereUI.RegisterQuestTrackerRow then
    registered = EllesmereUI.RegisterQuestTrackerRow(ADDON, OnRow, SLOT_W)
  end
  for _, event in ipairs(EVENTS) do
    events:RegisterEvent(event)
  end
  -- Lists built while an item's data was loading weren't cached: redraw.
  self:On("ITEM_DATA_LOAD_RESULT", function(_, _, itemID)
    if itemID and waiting[itemID] then
      waiting[itemID] = nil
      self:Debounce("itemData", 0.2, RefreshRows)
    end
  end)
  self:On("PLAYER_REGEN_ENABLED", QueueSync)
  -- Follows scrolling and dragging of the tracker (no redraw happens then);
  -- SyncUseButtons does nothing in combat.
  self:Ticker(0.25, function()
    if next(shown) ~= nil or (useButtons[1] and useButtons[1]:IsShown()) then
      SyncUseButtons()
    end
  end)
  -- Bags and the quest log settle a moment after login: no pruning or
  -- warnings until then.
  C_Timer.After(LOGIN_GRACE, function()
    logReady = true
    Queue()
  end)
  signature = nil
  Queue()
  zoneEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  zoneEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
  C_Timer.After(LOGIN_GRACE, FocusZone)
end

function mod:OnDisable()
  events:UnregisterAllEvents()
  zoneEvents:UnregisterAllEvents()
  -- Secure buttons can't hide in combat: then once it ends (OutOfCombat
  -- would be dropped now that the feature is off), unless it's back on.
  ARLE.Secure:Run(function()
    if not mod._active then
      ClearUseButtons()
    end
  end)
  for b in pairs(shown) do
    b:Hide()
  end
  wipe(alerted)
  signature = nil
  RefreshRows()
end

-- The standalone EllesmereUIQuestTracker_QuestItems' settings (account wide
-- EUIQuestItemsDB: enabled, showMissing = the greyed icon when not in bags).
function mod:Import()
  local old = _G.EUIQuestItemsDB
  if type(old) ~= "table" then
    return
  end
  if type(old.enabled) == "boolean" then
    self.db.showButtons = old.enabled
  end
  if type(old.showMissing) == "boolean" then
    self.db.questieAbsent = old.showMissing
    self.db.showMissing = old.showMissing
  end
end

function mod:OnOptionChanged(key, value)
  signature = nil
  RefreshRows()
  -- Turning zone focus (or the city extras) on applies it right away.
  if (key == "zoneFocus" or key == "cityExtras") and value then
    FocusZone()
  end
end

function mod:GetStatus()
  local total, missing = 0, 0
  local known = type(self.char.known) == "table" and self.char.known or {}
  local ignored = type(self.char.ignored) == "table" and self.char.ignored or {}
  for questID in pairs(known) do
    total = total + 1
    if had[questID] == false and not ignored[questID] and C_QuestLog.IsComplete(questID) ~= true then
      missing = missing + 1
    end
  end
  local status = "Active  ·  " .. total .. " quest item" .. (total == 1 and "" or "s")
  if missing > 0 then
    status = status .. ", |cffff5544" .. missing .. " missing|r"
  end
  -- EUI only builds this frame while its Custom Quest Tracker is in use; with
  -- the Blizzard-style tracker the row hook never runs.
  if not registered or not _G.EUI_CustomQuestTracker then
    status = status .. "  ·  |cffffb84dno buttons: EUI's Custom Quest Tracker is off|r"
  end
  return status
end

ARLE:RegisterModule(mod)
