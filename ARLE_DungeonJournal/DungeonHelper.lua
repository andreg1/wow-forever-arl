-- Dungeon Helper: a collapsible, tooltip-style window with three tabs (BiS
-- Finder, Quests, Clear Times), the events that drive them, the /arl
-- dungeon command, and the records pane on the module's options page.
-- Shared.lua has the module definition and the data; each tab has its file.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Skin = ARLE.Skin
local WIDTH = 250
local HEADER_H, TABS_H, TOOL_H = 22, 20, 20

local tabs = {}
for _, t in ipairs(H.tabs) do
  tabs[t.key] = t
end
H.auto = true -- follow the current dungeon

local frame, scroll

local function CurrentTab()
  return tabs[mod.db.tab] or H.tabs[1]
end

local function SetTab(key)
  if tabs[key] then
    mod.db.tab = key
    if scroll then
      scroll:SetVerticalScroll(0)
    end
    H.Render()
  end
end
H.SetTab = SetTab

-- The run time in the title bar, on every tab and when folded.
local function UpdateClock()
  if not frame then
    return
  end
  local text, done = tabs.times:Clock()
  if text and mod.db.timerInTitle then
    frame.clock:SetText(done and ("|cffffd100" .. text .. "|r") or text)
  else
    frame.clock:SetText("")
  end
end

local renderQueued = false
local function DoRender()
  renderQueued = false
  if not frame or not frame:IsShown() then
    return
  end
  local db = mod.db
  local tab = CurrentTab()
  frame.title:SetText(H.shown and ("ARL Dungeon Helper - " .. H.shown) or "ARL Dungeon Helper")
  frame.collapse:SetText(db.listCollapsed and "+" or "-")
  UpdateClock()

  local ar, ag, ab = Skin:Accent()
  for _, b in ipairs(frame.tabButtons) do
    local on = b.tab == tab
    b.text:SetTextColor(on and ar or 0.75, on and ag or 0.75, on and ab or 0.75)
    b.bg:SetColorTexture(on and ar or 1, on and ag or 1, on and ab or 1, on and 0.15 or 0.04)
    b.bar:SetShown(on)
    b.tab.bar:SetShown(on)
    b.tab.content:SetShown(on)
  end
  if frame.scrolled ~= tab then
    frame.scrolled = tab
    scroll:SetScrollChild(tab.content)
  end
  local y = tab:Render()
  tab.content:SetHeight(math.max(y, 1))
  tab.content:SetWidth(WIDTH - 30)

  -- Folded: just the title bar, like a collapsed tooltip.
  if db.listCollapsed then
    scroll:Hide()
    frame.tabStrip:Hide()
    frame.toolbars:Hide()
    frame:SetHeight(HEADER_H + 4)
  else
    scroll:Show()
    frame.tabStrip:Show()
    frame.toolbars:Show()
    local maxH = math.min(math.max(tonumber(db.maxHeight) or 420, 200), 800)
    frame:SetHeight(math.min(HEADER_H + TABS_H + TOOL_H + 10 + y, maxH))
  end
end

function H.Render()
  if renderQueued then
    return
  end
  renderQueued = true
  C_Timer.After(0, DoRender)
end

local function ShowDungeon(name, keepAuto)
  if not keepAuto then
    H.auto = name == nil
  end
  H.shown = name or H.CurrentDungeon()
  tabs.bis.RefreshMine()
  H.Request()
  H.Render()
end

local function DungeonMenu(owner)
  local names = H.Dungeons()
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, function(_, root)
      root:CreateRadio("Current dungeon (automatic)", function()
        return H.auto
      end, function()
        ShowDungeon(nil)
      end)
      root:CreateDivider()
      for _, name in ipairs(names) do
        root:CreateRadio(name, function()
          return not H.auto and H.shown == name
        end, function()
          ShowDungeon(name)
        end)
      end
    end)
  else
    -- Older clients: step through the list.
    local idx = 0
    for i, name in ipairs(names) do
      if name == H.shown then
        idx = i
      end
    end
    ShowDungeon(names[idx % #names + 1])
  end
end

local function CreateWindow()
  local kit = ARLE.UIKit
  frame = Skin:CreateTooltipWindow("ARLEDungeonHelperFrame", UIParent)
  frame:SetSize(WIDTH, 200)
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, rel, x, y = self:GetPoint()
    mod.db.pos = { point, rel, x, y }
  end)
  local pos = mod.db.pos
  if type(pos) == "table" and pos[1] then
    frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 60)
  end

  -- Title bar: [-] ARL Dungeon Helper - Dungeon .... 12:34 [v][x]
  frame.collapse = H.SmallButton(frame, "-", 18)
  frame.collapse:SetPoint("TOPLEFT", 4, -3)
  frame.collapse:SetScript("OnClick", function()
    mod.db.listCollapsed = not mod.db.listCollapsed or nil
    H.Render()
  end)
  frame.close = H.SmallButton(frame, "x", 18)
  frame.close:SetPoint("TOPRIGHT", -4, -3)
  frame.close:SetScript("OnClick", function()
    frame:Hide()
  end)
  frame.pick = H.SmallButton(frame, "v", 18)
  frame.pick:SetPoint("RIGHT", frame.close, "LEFT", -2, 0)
  frame.pick:SetScript("OnClick", DungeonMenu)
  frame.pick:SetScript("OnEnter", function(self)
    H.SimpleTooltip(self, "Pick a dungeon")
  end)
  frame.pick:SetScript("OnLeave", GameTooltip_Hide)
  frame.clock = kit.Text(frame, "GameFontHighlightSmall")
  frame.clock:SetPoint("RIGHT", frame.pick, "LEFT", -4, 0)
  frame.clock:SetJustifyH("RIGHT")
  frame.title = kit.Text(frame, "GameFontNormalSmall")
  frame.title:SetPoint("LEFT", frame.collapse, "RIGHT", 4, 0)
  frame.title:SetPoint("RIGHT", frame.clock, "LEFT", -4, 0)
  frame.title:SetWordWrap(false)

  -- Tab strip: [BiS Finder][Quests][Clear Times]
  local strip = CreateFrame("Frame", nil, frame)
  strip:SetPoint("TOPLEFT", 4, -HEADER_H)
  strip:SetPoint("TOPRIGHT", -4, -HEADER_H)
  strip:SetHeight(TABS_H - 2)
  frame.tabStrip = strip
  frame.tabButtons = {}
  local tabW = (WIDTH - 8 - (#H.tabs - 1) * 2) / #H.tabs
  for i, tab in ipairs(H.tabs) do
    local b = CreateFrame("Button", nil, strip)
    b:SetSize(tabW, TABS_H - 2)
    b:SetPoint("LEFT", (i - 1) * (tabW + 2), 0)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetHeight(2)
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetPoint("BOTTOMRIGHT")
    b.bar:SetColorTexture(Skin:Accent())
    b.text = kit.Text(b, "GameFontNormalSmall")
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(tab.label)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.tab = tab
    b:SetScript("OnClick", function(self)
      SetTab(self.tab.key)
    end)
    frame.tabButtons[i] = b
  end

  -- One toolbar and one scroll child per tab; only the selected tab's show.
  local toolbars = CreateFrame("Frame", nil, frame)
  toolbars:SetPoint("TOPLEFT", 4, -(HEADER_H + TABS_H))
  toolbars:SetPoint("TOPRIGHT", -4, -(HEADER_H + TABS_H))
  toolbars:SetHeight(TOOL_H)
  frame.toolbars = toolbars

  scroll = CreateFrame("ScrollFrame", "ARLEDungeonHelperScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -(HEADER_H + TABS_H + TOOL_H + 4))
  scroll:SetPoint("BOTTOMRIGHT", -24, 4)
  Skin:ScrollBar(scroll)

  for _, tab in ipairs(H.tabs) do
    tab.bar = CreateFrame("Frame", nil, toolbars)
    tab.bar:SetAllPoints()
    tab.content = CreateFrame("Frame", nil, scroll)
    tab.content:SetSize(WIDTH - 30, 1)
    tab:Create(tab.content, tab.bar)
    tab.bar:Hide()
    tab.content:Hide()
  end

  -- Keep the clock (and the Clear Times tab) running.
  local elapsed = 0
  frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed < 0.5 then
      return
    end
    elapsed = 0
    UpdateClock()
    if CurrentTab() == tabs.times and not mod.db.listCollapsed then
      tabs.times:Tick()
    end
  end)
  frame:SetScript("OnShow", H.Render)
  frame:Hide()
end

local function Open(tabKey)
  if not frame then
    CreateWindow()
  end
  if tabKey then
    SetTab(tabKey)
  end
  frame:Show()
  -- Item data that came while it was closed: estimates catch up now.
  if tabs.bis:WantsItemInfo(true) then
    tabs.bis:OnItemInfo(true)
  end
  H.Render()
end

local function Toggle(tabKey)
  if frame and frame:IsShown() and (not tabKey or tabKey == mod.db.tab) then
    frame:Hide()
  else
    if not H.shown then
      ShowDungeon(nil)
    end
    Open(tabKey)
  end
end

-------------------------------------------------------------------------------
-- Boss fights
-------------------------------------------------------------------------------

-- Opens the BiS Finder on a boss, unfolding only that boss.
local function FocusBoss(dungeon, bossName)
  if dungeon and dungeon ~= H.shown and H.auto then
    H.shown = dungeon
    tabs.bis.RefreshMine()
  end
  if dungeon ~= H.shown then
    return
  end
  tabs.bis:Focus(bossName)
  mod.db.listCollapsed = nil
  mod.db.tab = "bis"
  if not frame then
    CreateWindow()
  end
  frame:Show()
  H.Render()
  if scroll then
    scroll:SetVerticalScroll(0)
  end
end
mod.FocusBoss = FocusBoss

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local autoOpened = false
local recentKills = {} -- "dungeon\0boss" -> GetTime() of the kill handled (several events per kill)
local KILL_DEDUPE = 30
local lastCurrent = false -- the dungeon the zone logic last ran for (false: never)
local rosterKey -- the group's member names when the group was last asked
local Plain = H.Plain

local function ZoneChanged()
  local current = H.CurrentDungeon()
  lastCurrent = current
  tabs.times:OnZone(current)
  if H.auto then
    H.shown = current
    tabs.bis.RefreshMine()
    H.Request()
  end
  if current and mod.db.autoOpen and not (frame and frame:IsShown()) then
    autoOpened = true
    Open()
  elseif not current and autoOpened and frame then
    autoOpened = false
    frame:Hide()
  end
  H.Render()
end

local function PruneParty()
  local keep = {}
  for _, m in ipairs(H.Members()) do
    keep[m.name] = true
  end
  for _, tab in ipairs(H.tabs) do
    if tab.Prune then
      tab:Prune(keep)
    end
  end
end

local QUEST_EVENTS = {
  QUEST_LOG_UPDATE = true, QUEST_ACCEPTED = true, QUEST_TURNED_IN = true, QUEST_REMOVED = true,
  PLAYER_LEVEL_UP = true,
}

local function InInstance()
  return IsInInstance and Plain(IsInInstance()) and true or false
end

-- One boss kill, however many events tell it (ENCOUNTER_END, BOSS_KILL,
-- PARTY_KILL, UNIT_DIED): handled once. True when it was (now or before)
-- and the window jumped to it.
local function Killed(dungeon, boss)
  if not dungeon or not boss then
    return false
  end
  local key, now = dungeon .. "\0" .. boss, GetTime()
  if recentKills[key] and now - recentKills[key] < KILL_DEDUPE then
    return mod.db.openOnKill and true or false
  end
  recentKills[key] = now
  tabs.times:OnKill(dungeon, boss)
  if mod.db.openOnKill then
    FocusBoss(dungeon, boss)
    return true
  end
  return false
end

-- The instance copy and the NPC of a creature GUID (kills, the target).
local function SeenGUID(guid)
  local npc, zone, map = H.ParseGUID(guid)
  if zone and InInstance() then
    tabs.times:OnInstanceGUID(zone, map)
  end
  return npc
end

-- A death told by GUID (PARTY_KILL, UNIT_DIED): bosses with no encounter
-- (all of Scholomance, most rares) are known by their NPC ID. Forever hides
-- the GUIDs of some deaths (secret values): those are skipped.
local function GUIDDied(guid)
  if not InInstance() then
    return
  end
  local npc = SeenGUID(guid)
  if npc then
    local dungeon, boss = H.BossForNPC(npc)
    if boss then
      Killed(dungeon, boss)
    end
  end
end

local function OnEvent(_, event, ...)
  if event == "ENCOUNTER_START" then
    -- Encounter details can be "secret" values on newer clients; a failed
    -- lookup just leaves everything as it was.
    local encounterID, encounterName = ...
    local ok, dungeon, boss = pcall(H.BossFor, Plain(encounterID), Plain(encounterName))
    if ok and boss then
      tabs.times:OnPull(dungeon, boss)
      if mod.db.openOnPull then
        FocusBoss(dungeon, boss)
      end
    end
  elseif event == "ENCOUNTER_END" or event == "BOSS_KILL" then
    -- ENCOUNTER_END: id, name, difficulty, size, success; BOSS_KILL: id, name.
    local encounterID, encounterName, _, _, success = ...
    encounterID, encounterName, success = Plain(encounterID), Plain(encounterName), Plain(success)
    local killed = event == "BOSS_KILL" or success == 1 or success == true
    local focused = false
    if killed and InInstance() then
      local ok, dungeon, boss, also = pcall(H.BossFor, encounterID, encounterName)
      if ok and boss then
        focused = Killed(dungeon, boss)
        -- The encounter's other bosses (Gyth with Rend).
        for _, extra in ipairs(also or {}) do
          local name = H.ResolveBoss(dungeon, extra)
          if name then
            tabs.times:OnKill(dungeon, name) -- (no jump: the window stays on the main boss)
          end
        end
      end
    end
    if event == "ENCOUNTER_END" and not focused then
      tabs.bis.focus = nil
      H.Render()
    end
  elseif event == "PARTY_KILL" then
    local _, targetGUID = ...
    GUIDDied(targetGUID)
  elseif event == "UNIT_DIED" then
    GUIDDied((...))
  elseif event == "PLAYER_TARGET_CHANGED" then
    -- (mobs only, the way DungeonJournal's run log reads the instance copy)
    if InInstance() and UnitGUID and UnitCanAttack and Plain(UnitCanAttack("player", "target")) then
      SeenGUID(UnitGUID("target"))
    end
  elseif event == "CHAT_MSG_SYSTEM" then
    if not InInstance() then
      tabs.times:OnSystemMessage((...))
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    tabs.times:OnCombat()
  elseif QUEST_EVENTS[event] then
    tabs.quests:OnQuestChange()
  elseif event == "GROUP_ROSTER_UPDATE" then
    -- Comes in bursts (and for every change of a member's state): once
    -- the group settles, and only when its members changed.
    mod:Debounce("roster", 2, function()
      local names = {}
      for _, m in ipairs(H.Members()) do
        names[#names + 1] = m.name or "?"
      end
      table.sort(names)
      local key = table.concat(names, ",")
      if key ~= rosterKey then
        rosterKey = key
        PruneParty()
        H.Request()
        H.Render()
      end
    end)
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    tabs.bis.RefreshMine()
    H.QueueSend(H.shown, "bis")
    H.Render()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    -- Many come at once; only while something is still waiting for them
    -- (the player's own gains, or estimates the window shows).
    if tabs.bis:WantsItemInfo(frame ~= nil and frame:IsShown()) then
      mod:Debounce("iteminfo", 1, function()
        tabs.bis:OnItemInfo(frame ~= nil and frame:IsShown())
        H.Render()
      end)
    end
  elseif event == "INSPECT_READY" then
    tabs.bis:OnInspectReady(...)
  elseif event == "PLAYER_REGEN_ENABLED" then
    tabs.bis.QueueInspects() -- catch up on inspects skipped in combat
  elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
    -- Moving between rooms: only a new wing (Lower to Upper Spire, Dire
    -- Maul, Stratholme) runs the zone logic.
    if H.CurrentDungeon() ~= lastCurrent then
      ZoneChanged()
    end
  else
    ZoneChanged()
  end
end

local TAB_WORDS = {
  bis = "bis", loot = "bis",
  quests = "quests", quest = "quests", q = "quests",
  times = "times", time = "times", timer = "times", timers = "times",
}

-- "/arl dh [tab|reset|spec ...]" is the feature's main command (Shared.lua
-- declares command = "dh"); these are the shortcuts per tab, on while the
-- feature is on.
local function Command(rest)
  rest = rest or ""
  local who, spec = rest:match("^spec%s+(%S+)%s+(%S+)")
  if who then
    tabs.bis:SpecCommand(who, spec)
    return
  end
  if rest:match("^spec") then
    ARLE:Print("Use: /arl bis spec <name> <spec>  (a party member's spec, for estimated scores)")
    return
  end
  local word = (rest:match("^(%S+)") or ""):lower()
  if word == "reset" then
    tabs.times:Reset()
    ARLE:Print("Clear Times: run reset.")
    return
  end
  if word ~= "" and not TAB_WORDS[word] then
    ARLE:Print("Unknown tab \"" .. word .. "\". /arl help dh lists what the command takes.")
    return
  end
  Toggle(TAB_WORDS[word])
end

function mod:main(rest)
  Command(rest)
end

local SHORTCUTS = {
  {
    name = "bis", args = "[spec <name> <spec>]",
    help = "opens or closes it on the BiS Finder",
    usage = {
      { "bis", "opens or closes the window on the BiS Finder" },
      { "bis spec <name> <spec>", "sets the spec scored for an estimated party member" },
    },
    fn = function(rest)
      Command((rest or ""):match("^spec") and rest or "bis")
    end,
  },
  {
    name = "quests", aliases = { "quest" },
    help = "opens or closes it on Quests",
    fn = function()
      Command("quests")
    end,
  },
  {
    name = "timers", aliases = { "timer", "times" }, args = "[reset]",
    help = "opens or closes it on Clear Times; reset restarts the run",
    usage = {
      { "timers", "opens or closes the window on Clear Times" },
      { "timers reset", "restarts the run timer" },
    },
    fn = function(rest)
      Command((rest or ""):match("^reset") and "reset" or "times")
    end,
  },
}

-- DungeonJournal's internals this feature reads are not a public API: one
-- chat warning naming what an update took away (the rest keeps working).
local toldMissing = false
local function CheckFDJ(fdj)
  if toldMissing then
    return
  end
  local missing = {}
  for _, k in ipairs({ "SHARED_BY_BOSS", "RUNLOG_ENCOUNTERS", "STATIC_DISPLAY_IDS" }) do
    if type(fdj[k]) ~= "table" then
      missing[#missing + 1] = k
    end
  end
  for _, k in ipairs({ "CurrentDungeon", "SetBakedPortrait", "ShareQuestByID" }) do
    if type(fdj[k]) ~= "function" then
      missing[#missing + 1] = k
    end
  end
  if type(_G.ForeverDungeonJournalDB) ~= "table" then
    missing[#missing + 1] = "ForeverDungeonJournalDB"
  end
  if #missing > 0 then
    toldMissing = true
    mod:Print("DungeonJournal has changed: " .. table.concat(missing, ", ") .. " missing. The parts that use "
      .. "them (shared loot, boss kills by encounter, current dungeon, portraits, quest sharing) may not work.")
  end
end

local flbHooked = false
function mod:OnEnable()
  local fdj = H.FDJ()
  if not fdj then
    error("DungeonJournal (ForeverDungeonJournal) is not loaded; it provides the bosses, loot and quests", 0)
  end
  CheckFDJ(fdj)
  -- Up to 0.1.0 the run in progress was account-wide (another character
  -- could carry it on); it is per character now, and the old one is dropped.
  self.db.run = nil
  lastCurrent, rosterKey = false, nil
  wipe(recentKills)
  -- 0.2.0 had an "only upgrades" switch; it is the Party filter now.
  if self.db.onlyUpgrades ~= nil then
    if self.db.onlyUpgrades then
      self.db.filter = "party"
    end
    self.db.onlyUpgrades = nil
  end
  if not flbHooked and H.FLB() and H.FLB().OnChanged then
    flbHooked = true
    H.FLB().OnChanged(function()
      if mod._active and H.shown then
        tabs.bis.RefreshMine()
        H.QueueSend(H.shown, "bis")
        H.Render()
      end
    end)
  end
  -- self:On pcalls each registration (an event this client lacks is
  -- skipped) and drops them all when the feature is turned off.
  for _, e in ipairs({
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "PARTY_KILL", "UNIT_DIED", "PLAYER_TARGET_CHANGED",
    "CHAT_MSG_SYSTEM",
    "GROUP_ROSTER_UPDATE", "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED",
    "INSPECT_READY", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP",
  }) do
    self:On(e, OnEvent)
  end
  for _, c in ipairs(SHORTCUTS) do
    self:Command(c)
  end
  ZoneChanged()
end

function mod:OnDisable()
  -- (the events registered with self:On are dropped by the host)
  if frame then
    frame:Hide()
  end
  for _, tab in ipairs(H.tabs) do
    if tab.data then
      wipe(tab.data)
    end
  end
end

function mod:OnOptionChanged(key)
  if key == "showShared" or key == "showOther" then
    H.ClearBossCache()
    tabs.bis.RefreshMine()
    H.QueueSend(H.shown, "bis", true)
  end
  H.Render()
end

function mod:GetStatus()
  local parts = { "Active", H.shown or "not in a dungeon" }
  if H.shown then
    parts[#parts + 1] = tabs.bis:Status()
    parts[#parts + 1] = tabs.quests:Status()
  end
  parts[#parts + 1] = tabs.times:Status()
  return table.concat(parts, "  ·  ")
end

-------------------------------------------------------------------------------
-- Options page: the player's records, a button to open the window, and one
-- to clear the records.
-------------------------------------------------------------------------------

local PANE_ROW = 18

StaticPopupDialogs.ARLE_DUNGEON_CLEAR_RECORDS = {
  text = "Clear every Clear Times record of this character?\nThis can't be undone.",
  button1 = "Clear",
  button2 = "Cancel",
  OnAccept = function()
    tabs.times:ClearRecords()
    ARLE:Print("Clear Times: records cleared.")
    if ARLE.RefreshUI then
      ARLE:RefreshUI()
    end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

function mod:CreatePane(pane)
  local kit = ARLE.UIKit
  pane.title = kit.Text(pane, "GameFontNormal")
  pane.title:SetPoint("TOPLEFT", 0, 0)
  pane.title:SetText("Your records (this character)")
  pane.summary = kit.Text(pane, "GameFontDisableSmall")
  pane.summary:SetPoint("TOPLEFT", pane.title, "BOTTOMLEFT", 0, -4)
  pane.summary:SetPoint("RIGHT", 0, 0)

  pane.open = kit.Button(pane, "Open the window", 130)
  pane.open:SetPoint("BOTTOMLEFT", 0, 0)
  pane.open:SetScript("OnClick", function()
    if not mod._active then
      mod:Print("the feature is off: turn it on first.")
      return
    end
    if not H.shown then
      ShowDungeon(nil)
    end
    Open()
  end)
  pane.clear = kit.Button(pane, "Clear my records", 130)
  pane.clear:SetPoint("LEFT", pane.open, "RIGHT", 8, 0)
  pane.clear:SetScript("OnClick", function()
    StaticPopup_Show("ARLE_DUNGEON_CLEAR_RECORDS")
  end)

  pane.list = CreateFrame("ScrollFrame", "ARLEDungeonRecordsList", pane, "UIPanelScrollFrameTemplate")
  pane.list:SetPoint("TOPLEFT", pane.summary, "BOTTOMLEFT", 0, -8)
  pane.list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -24, 30)
  Skin:ScrollBar(pane.list)
  pane.child = CreateFrame("Frame", nil, pane.list)
  pane.child:SetSize(300, 1)
  pane.list:SetScrollChild(pane.child)
  pane.rows = {}
end

function mod:RefreshPane(pane)
  local kit = ARLE.UIKit
  local records = tabs.times:AllRecords() or {}
  local names = {}
  for dungeon, rec in pairs(records) do
    if type(rec) == "table" then
      names[#names + 1] = dungeon
    end
  end
  table.sort(names)
  local clears = 0
  for _, name in ipairs(names) do
    clears = clears + (records[name].clears or 0)
  end
  pane.summary:SetText(#names == 0 and "No records yet: they are made as you kill bosses in dungeons."
    or (#names .. " dungeon(s)  ·  " .. clears .. " clear(s). Hover a split in the window for boss records."))

  local width = math.max(pane.list:GetWidth(), 200)
  pane.child:SetWidth(width)
  for i, name in ipairs(names) do
    local rec = records[name]
    local row = pane.rows[i]
    if not row then
      row = CreateFrame("Frame", nil, pane.child)
      row:SetHeight(PANE_ROW)
      row.name = kit.Text(row, "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", 2, 0)
      row.best = kit.Text(row, "GameFontHighlightSmall")
      row.best:SetPoint("RIGHT", -2, 0)
      row.best:SetJustifyH("RIGHT")
      row.name:SetPoint("RIGHT", row.best, "LEFT", -8, 0)
      row.name:SetWordWrap(false)
      pane.rows[i] = row
    end
    local bosses = 0
    for _ in pairs(rec.bosses or {}) do
      bosses = bosses + 1
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * PANE_ROW)
    row:SetPoint("RIGHT")
    row.name:SetText(name)
    row.best:SetText((rec.total and ("best " .. H.FormatTime(rec.total)) or "|cff888888no clear|r")
      .. "  |cff888888" .. (rec.clears or 0) .. " clear(s), " .. bosses .. " boss record(s)|r")
    row:Show()
  end
  for i = #names + 1, #pane.rows do
    pane.rows[i]:Hide()
  end
  pane.child:SetHeight(math.max(#names * PANE_ROW, 1))
  pane.clear:SetEnabled(#names > 0)
end

mod.Toggle = Toggle
mod.Bosses = H.Bosses
mod.ShowDungeon = ShowDungeon
mod.SetTab = SetTab
mod.tabs = tabs
mod.H = H
ARLE:RegisterModule(mod)
