-- Dungeon Helper: the window, the events that drive the tabs, the /arl dh
-- command, and the records pane on the module's options page.
--
-- The window is a tooltip-style box (ARL's skin):
--
--   [-] ARL Dungeon Helper ............................. [v][x]
--   +- banner: the dungeon's art (DungeonJournal's) ----------------+
--   | [icon] Scholomance                                   12:34    |
--   |        Level 58-60 · Western Plaguelands            3/7 bosses |
--   +---------------------------------------------------------------+
--   [skull Bosses & Loot *2][! Quests 1][watch Clear Times]
--   toolbar of the tab (filters, party, reset...)
--   +- list ----------------+- details of the selected entry --------+
--   | [face] Kirtonos       | [ face ] Kirtonos the Herald           |
--   |        *2  +1     [c] |          [6 drops] [*2 BiS]            |
--   +-----------------------+----------------------------------------+
--
-- Each tab (Loot.lua, Quests.lua, Times.lua) draws its own list and details
-- (tab:Create(bar, list, detail), tab:RenderList(w), tab:RenderDetail(w),
-- both returning their height; tab:Badge() the count on its tab). The
-- window folds to its title bar, and follows the current dungeon unless one
-- is picked with the v button. Everything here is our own frames: nothing is
-- secure, so it all works in combat. Scripts go through mod:Script
-- (H.Script), so their errors are caught.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Skin, Kit = ARLE.Skin, ARLE.UI.Kit
local S = H.Script

local WIDTH, LIST_W = 660, 260
local HEADER_H, BANNER_H, TABS_H, TOOL_H = 22, 54, 26, 26
local TOP = HEADER_H + BANNER_H + TABS_H + TOOL_H + 8
local MIN_H = 300
local LIST_CHILD_W = LIST_W - 24 -- the list's scroll bar sits in the gap
local DETAIL_X = LIST_W + 6
local DETAIL_CHILD_W = WIDTH - DETAIL_X - 28

local TAB_ICONS = {
  bis = H.ICON.bossSkull,
  quests = H.ICON.available,
  times = H.ICON.watch,
}

local tabs = {}
for _, t in ipairs(H.tabs) do
  tabs[t.key] = t
end
H.byKey = tabs
H.auto = true -- follow the current dungeon

local frame, listScroll, detailScroll, placeFrame
local comeBack = false -- hidden for a fight (Hide in combat): shown again when it ends

local function CurrentTab()
  return tabs[mod.db.tab] or H.tabs[1]
end

local function SetTab(key)
  if tabs[key] then
    mod.db.tab = key
    if listScroll then
      listScroll:SetVerticalScroll(0)
      detailScroll:SetVerticalScroll(0)
    end
    H.Render()
  end
end
H.SetTab = SetTab

-- A tab's details start at the top again when its selection changes.
function H.DetailToTop()
  if detailScroll then
    detailScroll:SetVerticalScroll(0)
  end
end

-- The run time: big in the banner, in the title bar when folded.
local function UpdateClock()
  if not frame then
    return
  end
  local text, done = tabs.times:Clock()
  local shown = text and mod.db.timerInTitle
  local folded = mod.db.listCollapsed
  frame.clock:SetText((shown and folded) and (done and ("|cffffd100" .. text .. "|r") or text) or "")
  local b = frame.banner
  if shown and not folded then
    b.clock:SetText(text)
    if done then
      b.clock:SetTextColor(1, 0.82, 0)
    else
      b.clock:SetTextColor(1, 1, 1)
    end
    b.progress:SetText(tabs.times:Progress() or "")
  else
    b.clock:SetText("")
    b.progress:SetText("")
  end
end

-- DungeonJournal's card art for a dungeon, and its texture coordinates.
local function DungeonArt(dungeon)
  local fdj = H.FDJ() or {}
  local art = dungeon and type(fdj.DUNGEON_HOME_ART) == "table" and fdj.DUNGEON_HOME_ART[dungeon]
  local tc = dungeon and type(fdj.DUNGEON_HOME_TEXCOORD) == "table" and fdj.DUNGEON_HOME_TEXCOORD[dungeon]
  return art, type(tc) == "table" and tc or nil
end

local function PaintBanner()
  local b = frame.banner
  local fdj = H.FDJ()
  local d = H.shown and fdj and fdj.DB[H.shown]
  local art, tc = DungeonArt(H.shown)
  if art then
    -- A strip across the middle of the card art.
    local l, r, t, bt = 0, 1, 0, 1
    if tc then
      l, r, t, bt = tc[1] or 0, tc[2] or 1, tc[3] or 0, tc[4] or 1
    end
    local mid, span = t + (bt - t) * 0.42, (bt - t) * 0.24
    b.art:SetTexture(art)
    b.art:SetTexCoord(l, r, mid - span / 2, mid + span / 2)
    b.art:Show()
  else
    b.art:Hide()
  end
  local ar, ag, ab = Skin:Accent()
  b.tint:SetColorTexture(ar, ag, ab, art and 0.06 or 0.12)
  b.line:SetColorTexture(ar, ag, ab, 0.5)
  H.SetIcon(b.icon, d and type(d.icon) == "string" and d.icon or H.ICON.dungeon, d and d.icon and true or false)
  H.SetEdge(b.icon, ar, ag, ab, 0.7)
  b.name:SetText(H.shown or "No dungeon")
  local sub = {}
  if not H.shown then
    sub[1] = "Enter a dungeon, or pick one with the v button"
  else
    if d and d.level then
      sub[#sub + 1] = "Level " .. tostring(d.level)
    end
    if d and type(d.location) == "string" then
      sub[#sub + 1] = d.location
    end
    if not H.auto then
      sub[#sub + 1] = "|cffffd100picked|r"
    end
  end
  b.sub:SetText(table.concat(sub, "  ·  "))
end

local function PaintTabs(current)
  local ar, ag, ab = Skin:Accent()
  for _, b in ipairs(frame.tabButtons) do
    local on = b.tab == current
    b.text:SetTextColor(on and 1 or 0.7, on and 1 or 0.7, on and 1 or 0.7)
    b.bg:SetColorTexture(on and ar or 1, on and ag or 1, on and ab or 1, on and 0.18 or 0.04)
    b.bar:SetColorTexture(ar, ag, ab, 1)
    b.bar:SetShown(on)
    b.icon:SetDesaturated(not on)
    b.icon:SetAlpha(on and 1 or 0.7)
    local text, color, icon = nil, nil, nil
    if b.tab.Badge then
      text, color, icon = b.tab:Badge()
    end
    if text then
      H.PaintBadge(b.badge, { text = text, color = color, icon = icon })
      b.text:SetPoint("CENTER", -((b.badge:GetWidth() or 0) + 4) / 2 + 9, 0)
    else
      b.badge:Hide()
      b.text:SetPoint("CENTER", 9, 0)
    end
    b.tab.bar:SetShown(on)
    b.tab.list:SetShown(on)
    b.tab.detail:SetShown(on)
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
  local folded = db.listCollapsed
  frame.title:SetText(folded and H.shown and ("ARL Dungeon Helper - " .. H.shown) or "ARL Dungeon Helper")
  frame.collapse:SetText(folded and "+" or "-")
  frame.pick:SetText(H.auto and "v" or "|cffffd100v|r")
  PaintBanner()
  UpdateClock()

  local ar, ag, ab = Skin:Accent()
  frame.divider:SetColorTexture(ar, ag, ab, 0.25)
  if frame.scrolled ~= tab then
    frame.scrolled = tab
    listScroll:SetScrollChild(tab.list)
    detailScroll:SetScrollChild(tab.detail)
  end
  tab.list:SetWidth(LIST_CHILD_W)
  tab.detail:SetWidth(DETAIL_CHILD_W)
  local ly = tab:RenderList(LIST_CHILD_W) or 1
  local dy = tab:RenderDetail(DETAIL_CHILD_W) or 1
  tab.list:SetHeight(math.max(ly, 1))
  tab.detail:SetHeight(math.max(dy, 1))
  PaintTabs(tab) -- (after the render: the badges count what it worked out)

  -- Folded: just the title bar, like a collapsed tooltip.
  for _, f in ipairs({ listScroll, detailScroll, frame.tabStrip, frame.toolbars, frame.divider, frame.banner,
    frame.listBack }) do
    f:SetShown(not folded)
  end
  if not folded then
    local maxH = math.min(math.max(tonumber(db.maxHeight) or 540, MIN_H), 900)
    frame:SetHeight(math.max(math.min(TOP + 8 + math.max(ly, dy), maxH), MIN_H))
  else
    frame:SetHeight(HEADER_H + 4)
  end
end

function H.Render()
  if renderQueued then
    return
  end
  renderQueued = true
  C_Timer.After(0, function()
    ARLE.Debug.Call(mod, DoRender)
  end)
end

local function ShowDungeon(name, keepAuto)
  if not keepAuto then
    H.auto = name == nil
  end
  local was = H.shown
  H.shown = name or H.CurrentDungeon()
  if H.shown ~= was then
    for _, tab in ipairs(H.tabs) do
      if tab.OnDungeon then
        tab:OnDungeon(H.shown)
      end
    end
  end
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

local function Pane(name)
  local scroll = CreateFrame("ScrollFrame", name, frame, "UIPanelScrollFrameTemplate")
  Skin:ScrollBar(scroll)
  return scroll
end

local function CreateBanner()
  local b = CreateFrame("Frame", nil, frame)
  b:SetPoint("TOPLEFT", 1, -HEADER_H)
  b:SetPoint("TOPRIGHT", -1, -HEADER_H)
  b:SetHeight(BANNER_H)
  if b.SetClipsChildren then
    b:SetClipsChildren(true)
  end
  b.art = b:CreateTexture(nil, "BACKGROUND", nil, 1)
  b.art:SetAllPoints()
  b.art:SetAlpha(0.6)
  -- Darker on the left (the name) and the right (the clock).
  b.shade = b:CreateTexture(nil, "BACKGROUND", nil, 2)
  b.shade:SetAllPoints()
  b.shade:SetColorTexture(0, 0, 0, 0.45)
  if b.shade.SetGradient and CreateColor then
    pcall(b.shade.SetGradient, b.shade, "HORIZONTAL", CreateColor(0, 0, 0, 0.75), CreateColor(0, 0, 0, 0.2))
  end
  b.tint = b:CreateTexture(nil, "BACKGROUND", nil, 3)
  b.tint:SetAllPoints()
  b.line = b:CreateTexture(nil, "ARTWORK")
  b.line:SetHeight(1)
  b.line:SetPoint("BOTTOMLEFT")
  b.line:SetPoint("BOTTOMRIGHT")
  b.icon = H.Pic(b, 38)
  b.icon:SetPoint("LEFT", 10, 0)
  b.name = Kit.Text(b, "GameFontNormalLarge")
  b.name:SetPoint("BOTTOMLEFT", b.icon, "RIGHT", 10, 1)
  b.name:SetTextColor(1, 0.95, 0.85)
  b.name:SetShadowOffset(1, -1)
  b.sub = Kit.Text(b, "GameFontHighlightSmall")
  b.sub:SetPoint("TOPLEFT", b.icon, "RIGHT", 10, -3)
  b.sub:SetTextColor(0.85, 0.85, 0.85)
  b.clock = Kit.Text(b, "GameFontNormalHuge")
  b.clock:SetPoint("RIGHT", -14, 6)
  b.clock:SetJustifyH("RIGHT")
  b.clock:SetShadowOffset(1, -1)
  b.progress = Kit.Text(b, "GameFontHighlightSmall")
  b.progress:SetPoint("TOPRIGHT", b.clock, "BOTTOMRIGHT", 0, -2)
  b.progress:SetJustifyH("RIGHT")
  b.name:SetPoint("RIGHT", b.clock, "LEFT", -10, 0)
  b.sub:SetPoint("RIGHT", b.clock, "LEFT", -10, 0)
  b.name:SetWordWrap(false)
  b.sub:SetWordWrap(false)
  frame.banner = b
end

local function CreateWindow()
  frame = Skin:CreateTooltipWindow("ARLEDungeonHelperFrame", UIParent)
  frame:SetSize(WIDTH, MIN_H)
  frame:SetFrameStrata("MEDIUM")
  -- Kept where it's dragged (char.position: the Reset position preset
  -- clears it). Up to 0.7.0 it was db.pos, an anchor: dropped.
  mod.db.pos = nil
  placeFrame = Kit.Movable(frame, mod, { x = 330, y = 60 })

  -- Title bar: [-] ARL Dungeon Helper .... (12:34 when folded) [v][x]
  frame.collapse = H.SmallButton(frame, "-", 18)
  frame.collapse:SetPoint("TOPLEFT", 4, -3)
  S(frame.collapse, "OnClick", function()
    mod.db.listCollapsed = not mod.db.listCollapsed or nil
    H.Render()
  end)
  frame.close = H.SmallButton(frame, "x", 18)
  frame.close:SetPoint("TOPRIGHT", -4, -3)
  S(frame.close, "OnClick", function()
    comeBack = false
    frame:Hide()
  end)
  frame.pick = H.SmallButton(frame, "v", 18)
  frame.pick:SetPoint("RIGHT", frame.close, "LEFT", -2, 0)
  S(frame.pick, "OnClick", DungeonMenu)
  H.Tip(frame.pick, "Pick a dungeon", function()
    return H.auto and "Following the dungeon you are in." or "Showing a dungeon you picked. Pick \"Current "
      .. "dungeon\" to follow where you are again."
  end)
  frame.clock = Kit.Text(frame, "GameFontHighlightSmall")
  frame.clock:SetPoint("RIGHT", frame.pick, "LEFT", -6, 0)
  frame.clock:SetJustifyH("RIGHT")
  frame.title = Kit.Text(frame, "GameFontNormalSmall")
  frame.title:SetPoint("LEFT", frame.collapse, "RIGHT", 4, 0)
  frame.title:SetPoint("RIGHT", frame.clock, "LEFT", -4, 0)
  frame.title:SetWordWrap(false)

  CreateBanner()

  -- Tab strip: [icon Bosses & Loot n][icon Quests n][icon Clear Times]
  local strip = CreateFrame("Frame", nil, frame)
  strip:SetPoint("TOPLEFT", 4, -(HEADER_H + BANNER_H + 3))
  strip:SetPoint("TOPRIGHT", -4, -(HEADER_H + BANNER_H + 3))
  strip:SetHeight(TABS_H - 2)
  frame.tabStrip = strip
  frame.tabButtons = {}
  local tabW = (WIDTH - 8 - (#H.tabs - 1) * 3) / #H.tabs
  for i, tab in ipairs(H.tabs) do
    local b = CreateFrame("Button", nil, strip)
    b:SetSize(tabW, TABS_H - 2)
    b:SetPoint("LEFT", (i - 1) * (tabW + 3), 0)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetHeight(2)
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetPoint("BOTTOMRIGHT")
    b.text = Kit.Text(b, "GameFontNormal")
    b.text:SetPoint("CENTER", 9, 0)
    b.text:SetText(tab.label)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("RIGHT", b.text, "LEFT", -5, 0)
    b.icon:SetTexture(TAB_ICONS[tab.key] or H.ICON.scroll)
    b.badge = H.Badge(b)
    b.badge:SetPoint("LEFT", b.text, "RIGHT", 6, 0)
    b.badge:Hide()
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.tab = tab
    S(b, "OnClick", function(self)
      SetTab(self.tab.key)
    end)
    frame.tabButtons[i] = b
  end

  -- One toolbar per tab; two scroll panes whose children switch with the tab.
  local toolbars = CreateFrame("Frame", nil, frame)
  toolbars:SetPoint("TOPLEFT", 6, -(HEADER_H + BANNER_H + TABS_H + 4))
  toolbars:SetPoint("TOPRIGHT", -6, -(HEADER_H + BANNER_H + TABS_H + 4))
  toolbars:SetHeight(TOOL_H - 2)
  frame.toolbars = toolbars

  -- The list sits on a darker backing, like a journal's index.
  frame.listBack = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  frame.listBack:SetPoint("TOPLEFT", 4, -TOP + 2)
  frame.listBack:SetPoint("BOTTOMLEFT", 4, 4)
  frame.listBack:SetWidth(LIST_W - 4)
  frame.listBack:SetColorTexture(0, 0, 0, 0.22)

  listScroll = Pane("ARLEDungeonHelperList")
  listScroll:SetPoint("TOPLEFT", 4, -TOP)
  listScroll:SetPoint("BOTTOMLEFT", 4, 6)
  listScroll:SetWidth(LIST_CHILD_W)
  detailScroll = Pane("ARLEDungeonHelperDetail")
  detailScroll:SetPoint("TOPLEFT", DETAIL_X, -TOP)
  detailScroll:SetPoint("BOTTOMRIGHT", -24, 6)
  frame.divider = frame:CreateTexture(nil, "ARTWORK")
  frame.divider:SetWidth(1)
  frame.divider:SetPoint("TOPLEFT", DETAIL_X - 3, -TOP + 2)
  frame.divider:SetPoint("BOTTOMLEFT", DETAIL_X - 3, 4)

  for _, tab in ipairs(H.tabs) do
    tab.bar = CreateFrame("Frame", nil, toolbars)
    tab.bar:SetAllPoints()
    tab.list = CreateFrame("Frame", nil, listScroll)
    tab.list:SetSize(LIST_CHILD_W, 1)
    tab.detail = CreateFrame("Frame", nil, detailScroll)
    tab.detail:SetSize(DETAIL_CHILD_W, 1)
    tab:Create(tab.bar, tab.list, tab.detail)
    tab.bar:Hide()
    tab.list:Hide()
    tab.detail:Hide()
  end

  -- Keep the clock (and the Clear Times tab) running.
  local elapsed = 0
  S(frame, "OnUpdate", function(_, dt)
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
  S(frame, "OnShow", H.Render)
  frame:Hide()
end

-- Hide in combat: the window goes when a fight starts and comes back when
-- it ends; automatic openings during a fight wait for its end (comeBack).
-- Our own frame, nothing secure: hiding it in combat is allowed.

local function HiddenForCombat()
  return mod.db.hideInCombat and InCombatLockdown() and true or false
end

-- auto: opened by the feature itself (dungeon entered, pull, kill), not by
-- the player: waits for the end of the fight when it's hidden in combat.
local function Open(tabKey, auto)
  if not frame then
    CreateWindow()
  end
  if tabKey then
    SetTab(tabKey)
  end
  if auto and HiddenForCombat() then
    comeBack = true
    mod:Debug("opening after combat (hidden in combat)")
    return
  end
  frame:Show()
  -- Item data that came while it was closed: gains catch up now.
  if tabs.bis:WantsItemInfo() then
    tabs.bis:OnItemInfo()
  end
  H.Render()
end

local function Toggle(tabKey)
  if frame and frame:IsShown() and (not tabKey or tabKey == mod.db.tab) then
    comeBack = false
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

-- Opens Bosses & Loot with a boss selected (a fight starts: pulling, or it
-- died).
local function FocusBoss(dungeon, bossName, pulling)
  if dungeon and dungeon ~= H.shown and H.auto then
    ShowDungeon(dungeon, true)
  end
  if dungeon ~= H.shown then
    return
  end
  if not H.FLB() then
    -- (Bosses & Loot needs Forever Leveling BiS: no jump to an empty tab)
    mod:Debug("%s: no jump to Bosses & Loot, Forever Leveling BiS isn't loaded", tostring(bossName))
    return
  end
  tabs.bis:Focus(bossName, pulling)
  mod.db.listCollapsed = nil
  mod.db.tab = "bis"
  Open(nil, true)
  H.DetailToTop()
  H.Render()
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
    ShowDungeon(nil)
  end
  if current and mod.db.autoOpen and not (frame and frame:IsShown()) then
    autoOpened = true
    Open(nil, true)
  elseif not current and autoOpened and frame then
    autoOpened, comeBack = false, false
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
local kidDeaths = {} -- "dungeon|group" -> { [guid] = true }: a group's guardians down so far

local function GUIDDied(guid)
  if not InInstance() then
    return
  end
  local npc = SeenGUID(guid)
  if npc then
    local dungeon, boss = H.BossForNPC(npc)
    if boss then
      -- A group of guardians (the Altar) is killed with its last guardian.
      local need = H.Bosses(dungeon).kids[boss]
      if need and need > 1 and type(guid) == "string" then
        local key = dungeon .. "|" .. boss
        local down = kidDeaths[key] or {}
        kidDeaths[key] = down
        down[guid] = true
        local n = 0
        for _ in pairs(down) do
          n = n + 1
        end
        if n < need then
          mod:Debug("%s: %d of %d down", boss, n, need)
          return
        end
        kidDeaths[key] = nil
      end
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
        FocusBoss(dungeon, boss, true)
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
      tabs.bis.fighting = nil
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
    if mod.db.hideInCombat and frame and frame:IsShown() then
      comeBack = true
      frame:Hide()
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if comeBack then
      comeBack = false
      if frame and mod.db.hideInCombat then
        frame:Show()
        H.Render()
      end
    end
  elseif QUEST_EVENTS[event] then
    mod:Debounce("quests", 0.5, function()
      tabs.quests:OnQuestChange()
    end)
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
    mod:Debounce("gear", 1, function()
      tabs.bis.RefreshMine()
      H.QueueSend(H.shown, "bis")
      H.Render()
    end)
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    -- Many come at once; only while the player's own gains wait for them.
    if tabs.bis:WantsItemInfo() then
      mod:Debounce("iteminfo", 1, function()
        tabs.bis:OnItemInfo()
        H.Render()
      end)
    end
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
  bis = "bis", loot = "bis", bosses = "bis", boss = "bis",
  quests = "quests", quest = "quests", q = "quests",
  times = "times", time = "times", timer = "times", timers = "times",
}

-- "/arl dh [tab|reset]" is the feature's main command (Shared.lua declares
-- command = "dh"); these are the shortcuts per tab, on while it's on.
local function Command(rest)
  local word = ((rest or ""):match("^(%S+)") or ""):lower()
  if word == "reset" then
    tabs.times:Reset()
    mod:Print("Clear Times: run reset.")
    return
  end
  if word ~= "" and not TAB_WORDS[word] then
    mod:Print("Unknown tab \"" .. word .. "\". /arl help dh lists what the command takes.")
    return
  end
  Toggle(TAB_WORDS[word])
end

function mod:main(rest)
  Command(rest)
end

local SHORTCUTS = {
  {
    -- (not "loot": that's Quick Loot's command)
    name = "bis", aliases = { "bosses" },
    help = "opens or closes it on Bosses & Loot",
    fn = function()
      Command("loot")
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
  for _, k in ipairs({ "SHARED_BY_BOSS", "RUNLOG_ENCOUNTERS", "STATIC_DISPLAY_IDS", "QUEST_PREREQ_CHAINS" }) do
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
      .. "them (shared loot, boss kills by encounter, current dungeon, portraits, quest chains, quest sharing) "
      .. "may not work.")
  end
end

local flbHooked = false
function mod:OnEnable()
  H.RegisterComms()
  local fdj = H.FDJ()
  if not fdj then
    error("DungeonJournal (ForeverDungeonJournal) is not loaded; it provides the bosses, loot and quests", 0)
  end
  CheckFDJ(fdj)
  -- Up to 0.1.0 the run in progress was account-wide (another character
  -- could carry it on); it is per character now, and the old one is dropped.
  self.db.run = nil
  -- Up to 0.7.0: party members without ARL were inspected and scored with a
  -- picked spec; only ARL members' own numbers count now.
  self.db.specs = nil
  -- 0.9.0 made the window roomier: the old default height (420) grows with it.
  if not self.db.roomy then
    if self.db.maxHeight == 420 then
      self.db.maxHeight = 540
    end
    self.db.roomy = true
  end
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
        ARLE.Debug.Call(mod, function()
          tabs.bis.RefreshMine()
          H.QueueSend(H.shown, "bis")
          H.Render()
        end)
      end
    end)
  end
  -- self:On pcalls each registration (an event this client lacks is
  -- skipped) and drops them all when the feature is turned off.
  for _, e in ipairs({
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL", "PARTY_KILL", "UNIT_DIED", "PLAYER_TARGET_CHANGED",
    "CHAT_MSG_SYSTEM", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "GROUP_ROSTER_UPDATE", "PLAYER_EQUIPMENT_CHANGED", "GET_ITEM_INFO_RECEIVED",
    "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP",
  }) do
    self:On(e, OnEvent)
  end
  for _, c in ipairs(SHORTCUTS) do
    self:Command(c)
  end
  for _, tab in ipairs(H.tabs) do
    if tab.OnEnable then
      tab:OnEnable()
    end
  end
  ZoneChanged()
end

function mod:OnDisable()
  -- (the events registered with self:On are dropped by the host)
  comeBack = false
  if frame then
    frame:Hide()
  end
  for _, tab in ipairs(H.tabs) do
    if tab.data then
      wipe(tab.data)
    end
  end
end

function mod:OnResetPosition()
  if placeFrame then
    placeFrame()
  end
end

function mod:OnOptionChanged(key)
  if key == "hideInCombat" and not self.db.hideInCombat and comeBack and frame then
    comeBack = false -- switched off mid-fight: back now
    frame:Show()
  end
  if key == "showShared" or key == "showOther" then
    H.ClearBossCache()
    tabs.bis.RefreshMine()
    H.QueueSend(H.shown, "bis", true)
  elseif key == "guildBoard" and self.db.guildBoard then
    tabs.times:ShareAll()
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
-- to clear the records (click twice: no game popups).
-------------------------------------------------------------------------------

local PANE_ROW = 18

function mod:CreatePane(pane)
  pane.title = Kit.Text(pane, "GameFontNormal")
  pane.title:SetPoint("TOPLEFT", 0, 0)
  pane.title:SetText("Your records (this character)")
  pane.summary = Kit.Text(pane, "GameFontDisableSmall")
  pane.summary:SetPoint("TOPLEFT", pane.title, "BOTTOMLEFT", 0, -4)
  pane.summary:SetPoint("RIGHT", 0, 0)

  pane.open = Kit.Button(pane, "Open the window", 130)
  pane.open:SetPoint("BOTTOMLEFT", 0, 0)
  S(pane.open, "OnClick", function()
    if not mod._active then
      mod:Print("the feature is off: turn it on first.")
      return
    end
    Open("times")
  end)
  pane.clear = Kit.Button(pane, "Clear my records", 130)
  pane.clear:SetPoint("LEFT", pane.open, "RIGHT", 8, 0)
  S(pane.clear, "OnClick", function(self)
    if self.armed and GetTime() - self.armed < 4 then
      self.armed = nil
      self:SetText("Clear my records")
      tabs.times:ClearRecords()
      mod:Print("Clear Times: records cleared.")
      if ARLE.RefreshUI then
        ARLE:RefreshUI()
      end
      return
    end
    self.armed = GetTime()
    self:SetText("|cffff6060Click to confirm|r")
    mod:After(4, function()
      if self.armed and GetTime() - self.armed >= 3.9 then
        self.armed = nil
        self:SetText("Clear my records")
      end
    end)
  end)
  H.Tip(pane.clear, "Clear my records", "Throws away every Clear Times record of this character. Click twice to "
    .. "confirm; it can't be undone.")

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
    or (#names .. " dungeon(s)  ·  " .. clears .. " clear(s). The window's Clear Times tab has the splits and "
      .. "the guild leaderboard."))

  local width = math.max(pane.list:GetWidth(), 200)
  pane.child:SetWidth(width)
  for i, name in ipairs(names) do
    local rec = records[name]
    local row = pane.rows[i]
    if not row then
      row = CreateFrame("Frame", nil, pane.child)
      row:SetHeight(PANE_ROW)
      row.name = Kit.Text(row, "GameFontHighlightSmall")
      row.name:SetPoint("LEFT", 2, 0)
      row.best = Kit.Text(row, "GameFontHighlightSmall")
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
