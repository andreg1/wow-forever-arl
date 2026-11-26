-- Dungeon Helper: the window, when it shows, the events that drive the tabs,
-- the /arl dh command, and the records pane on the module's options page.
--
-- Two layouts (db.layout), both ARL's tooltip-style box:
--   compact (default)              full
--   [ic] Scholomance 12:34 [*][<>][v][x]   [-] Dungeon Helper ........ [*][<>][v][x]
--   [Quests 2][Loot *1][Times]             banner: art, name, level, clock
--   toolbar (filters, party)               [Quests][Bosses & Loot][Clear Times]
--   list (300 px wide)    -> details       toolbar
--                            open beside   list | details
--                            it on a pick
-- Each tab (Loot.lua, Quests.lua, Times.lua) draws its own list and details
-- (tab:Create(bar, list, detail), tab:RenderList(w), tab:RenderDetail(w),
-- both returning their height; tab:Badge() the count on its tab). Nothing is
-- secure, so it all works in combat. Scripts go through mod:Script (H.Script).
--
-- With no dungeon (outside, nothing picked) the list is a dungeon picker:
-- every dungeon with what the open tab is about there (your quests, your
-- upgrades, your best time and the guild's record), suggested ones first
-- (quests in your log, your level); a click shows that dungeon.
--
-- When it shows (0.15.0; it used to pop up at random):
--   * it opens by itself once per visit to a dungeon (autoOpen), and closes
--     by itself on leaving only if it opened by itself;
--   * the player's x keeps it closed until they leave (stayClosed): no pull
--     or kill reopens it;
--   * DungeonJournal's current dungeon is nil in some rooms of Dire Maul,
--     Stratholme and the Scarlet Monastery: inside the same instance the last
--     known dungeon stays (H.CurrentDungeon is wrapped below), so a room
--     change no longer counts as leaving and coming back;
--   * kills of rares and optional bosses never open it; a boss kill does as
--     set (onKill), a pull only with openOnPull;
--   * in combat it hides (back after), fades, or stays (combat).
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Skin, Kit = ARLE.Skin, ARLE.UI.Kit
local S = H.Script

local FULL_W, FULL_LIST_W = 660, 260
local COMPACT_W, SIDE_W = 300, 360
local HEADER_H, BANNER_H, TABS_H, TOOL_H = 24, 54, 24, 26
local MIN_H = 180
local FADED = 0.3

local TAB_ICONS = {
  bis = H.ICON.bossSkull,
  quests = H.ICON.available,
  times = H.ICON.watch,
}
local SHORT = { bis = "Loot", quests = "Quests", times = "Times" }

local tabs = {}
for _, t in ipairs(H.tabs) do
  tabs[t.key] = t
end
H.byKey = tabs
H.auto = true -- follow the current dungeon

local frame, side, listScroll, detailScroll, placeFrame

-- visit: the instance we're in ({ key, dungeon }); by: "auto" or "player"
-- (who opened it); dismissed: the player closed it this visit; combatHidden:
-- hidden for the fight; pending: an automatic opening waiting for the fight
-- to end (its tab).
local vis = { visit = nil, by = nil, dismissed = false, combatHidden = false, pending = nil }

local Plain = H.Plain

local function InInstance()
  return IsInInstance and Plain(IsInInstance()) and true or false
end

local function InstanceKey()
  if not InInstance() then
    return nil
  end
  local name, _, _, _, _, _, _, id = GetInstanceInfo()
  id, name = Plain(id), Plain(name)
  return tostring(id or name or "?")
end

-- DungeonJournal's dungeon, or the last one it named in this same instance.
local RawCurrent = H.CurrentDungeon
function H.CurrentDungeon()
  local d = RawCurrent()
  if d then
    if vis.visit then
      vis.visit.dungeon = d
    end
    return d
  end
  return vis.visit and vis.visit.dungeon or nil
end

local function Compact()
  return mod.db.layout ~= "full"
end

local function Scale()
  return math.max(0.5, (tonumber(mod.db.scale) or 100) / 100)
end

local function CurrentTab()
  return tabs[mod.db.tab] or H.tabs[1]
end

local function SetTab(key)
  if tabs[key] then
    if tabs[key].OnShown and mod.db.tab ~= key then
      tabs[key]:OnShown()
    end
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

-- The player picked an entry: in the compact layout its details open beside.
function H.Picked()
  H.sideOpen = true
  H.Render()
end

-- The run time: in the header (compact, or folded), in the banner (full).
local function UpdateClock()
  if not frame then
    return
  end
  local text, done = tabs.times:Clock()
  local shown = text and mod.db.timerInTitle
  local inHeader = Compact() or mod.db.listCollapsed
  frame.clock:SetText((shown and inHeader) and (done and ("|cffffd100" .. text .. "|r") or text) or "")
  local b = frame.banner
  if shown and not inHeader then
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

local function DungeonInfo()
  local fdj = H.FDJ()
  return H.shown and fdj and fdj.DB[H.shown] or nil
end

local function PaintBanner()
  local b = frame.banner
  local d = DungeonInfo()
  local art, tc = DungeonArt(H.shown)
  if art then
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

-- The header: the dungeon (compact) or the window's name (full).
local function PaintHeader()
  local d = DungeonInfo()
  local compact = Compact()
  frame.dicon:SetShown(compact)
  if compact then
    H.SetIcon(frame.dicon, d and type(d.icon) == "string" and d.icon or H.ICON.dungeon,
      d and d.icon and true or false)
    local name = H.shown or "Dungeon Helper"
    local lv = d and d.level and ("  |cff888888" .. tostring(d.level) .. "|r") or ""
    frame.title:SetText((H.auto or not H.shown) and (name .. lv) or ("|cffffd100" .. name .. "|r" .. lv))
  else
    local folded = mod.db.listCollapsed
    frame.title:SetText(folded and H.shown and ("Dungeon Helper - " .. H.shown) or "Dungeon Helper")
  end
  frame.collapse:SetText(mod.db.listCollapsed and "+" or "-")
  frame.pick:SetText(H.auto and "v" or "|cffffd100v|r")
  frame.layout:SetText(compact and ">" or "<")
end

local function PaintTabs(current)
  local ar, ag, ab = Skin:Accent()
  local compact = Compact()
  for _, b in ipairs(frame.tabButtons) do
    local on = b.tab == current
    b.text:SetText(compact and SHORT[b.tab.key] or b.tab.label)
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

-- Where everything goes, for the layout and the fold.
local function Layout()
  local compact, folded = Compact(), mod.db.listCollapsed
  local s = Scale()
  if frame:GetScale() ~= s then
    frame:SetScale(s)
    side:SetScale(s)
    placeFrame()
  end
  local width = compact and COMPACT_W or FULL_W
  frame:SetWidth(width)
  local bannerH = compact and 0 or BANNER_H
  frame.banner:SetShown(not compact and not folded)
  local stripY = HEADER_H + bannerH + 1
  frame.tabStrip:ClearAllPoints()
  frame.tabStrip:SetPoint("TOPLEFT", 4, -stripY)
  frame.tabStrip:SetPoint("TOPRIGHT", -4, -stripY)
  local tabW = (width - 8 - (#H.tabs - 1) * 3) / #H.tabs
  for i, b in ipairs(frame.tabButtons) do
    b:SetWidth(tabW)
    b:ClearAllPoints()
    b:SetPoint("LEFT", (i - 1) * (tabW + 3), 0)
  end
  frame.toolbars:ClearAllPoints()
  frame.toolbars:SetPoint("TOPLEFT", 6, -(stripY + TABS_H + 1))
  frame.toolbars:SetPoint("TOPRIGHT", -6, -(stripY + TABS_H + 1))
  local top = stripY + TABS_H + TOOL_H + 6
  frame.top = top

  listScroll:ClearAllPoints()
  detailScroll:ClearAllPoints()
  if compact then
    frame.listW = width - 32
    listScroll:SetPoint("TOPLEFT", 4, -top)
    listScroll:SetPoint("BOTTOMRIGHT", -26, 6)
    if detailScroll:GetParent() ~= side then
      detailScroll:SetParent(side)
    end
    detailScroll:SetPoint("TOPLEFT", 6, -(HEADER_H + 2))
    detailScroll:SetPoint("BOTTOMRIGHT", -26, 6)
    frame.detailW = SIDE_W - 36
    frame.listBack:Hide()
    frame.divider:Hide()
  else
    frame.listW = FULL_LIST_W - 24
    local detailX = FULL_LIST_W + 6
    listScroll:SetPoint("TOPLEFT", 4, -top)
    listScroll:SetPoint("BOTTOMLEFT", 4, 6)
    listScroll:SetWidth(frame.listW)
    if detailScroll:GetParent() ~= frame then
      detailScroll:SetParent(frame)
    end
    detailScroll:SetPoint("TOPLEFT", detailX, -top)
    detailScroll:SetPoint("BOTTOMRIGHT", -24, 6)
    frame.detailW = FULL_W - detailX - 28
    frame.listBack:ClearAllPoints()
    frame.listBack:SetPoint("TOPLEFT", 4, -top + 2)
    frame.listBack:SetPoint("BOTTOMLEFT", 4, 4)
    frame.listBack:SetWidth(FULL_LIST_W - 4)
    frame.divider:ClearAllPoints()
    frame.divider:SetPoint("TOPLEFT", detailX - 3, -top + 2)
    frame.divider:SetPoint("BOTTOMLEFT", detailX - 3, 4)
    frame.listBack:SetShown(not folded)
    frame.divider:SetShown(not folded)
  end
  for _, tab in ipairs(H.tabs) do
    if tab.party then
      H.LayoutPartyStrip(tab.party, compact)
    end
  end
  for _, f in ipairs({ listScroll, frame.tabStrip, frame.toolbars }) do
    f:SetShown(not folded)
  end
  detailScroll:SetShown(not folded)
end

-- The details beside the compact list: right of it, or left when there's no
-- room on the right.
local function PlaceSide()
  side:ClearAllPoints()
  local right = (frame:GetRight() or 0) * frame:GetEffectiveScale()
  local screen = UIParent:GetWidth() * UIParent:GetEffectiveScale()
  if right + SIDE_W * side:GetEffectiveScale() > screen then
    side:SetPoint("TOPRIGHT", frame, "TOPLEFT", -2, 0)
  else
    side:SetPoint("TOPLEFT", frame, "TOPRIGHT", 2, 0)
  end
end

-------------------------------------------------------------------------------
-- The dungeon picker (no dungeon shown)
-------------------------------------------------------------------------------

local pick = {}
local PICK_ROW = 34
local ShowDungeon

-- "58-60" -> 58, 60 (a single "60" -> 60, 60).
local function LevelRange(text)
  local lo, hi = tostring(text or ""):match("(%d+)%s*%-%s*(%d+)")
  lo, hi = tonumber(lo), tonumber(hi)
  if not lo then
    lo = tonumber(tostring(text or ""):match("(%d+)"))
    hi = lo
  end
  return lo, hi
end

-- What a dungeon holds for the tab, as the row's note and a sort weight.
local function PickNote(key, name)
  if key == "quests" then
    local inLog, ready, avail = tabs.quests.CountFor(name)
    local parts = {}
    if ready > 0 then
      parts[#parts + 1] = "|cff66ff66" .. ready .. " ready|r"
    end
    if inLog - ready > 0 then
      parts[#parts + 1] = "|cffffd100" .. (inLog - ready) .. " in log|r"
    end
    if avail > 0 then
      parts[#parts + 1] = H.Inline(H.ICON.available, 11) .. avail
    end
    return table.concat(parts, "  "), inLog > 0, inLog * 10 + avail
  elseif key == "bis" then
    local ups, bis = tabs.bis.ForMe(name)
    if ups == 0 then
      return "", false, 0
    end
    return (bis > 0 and (H.Inline(H.ICON.star, 11) .. "|cffffd100" .. bis .. "|r  ") or "")
      .. "|cff66ff66+" .. ups .. "|r", false, bis * 10 + ups
  else
    local mine, guild, who, isMe = tabs.times.BestFor(name)
    local parts = {}
    if mine then
      parts[#parts + 1] = H.FormatTime(mine)
    end
    if guild and not isMe then
      parts[#parts + 1] = "|cff888888guild " .. H.FormatTime(guild) .. " " .. tostring(who) .. "|r"
    elseif guild and isMe then
      parts[#parts + 1] = "|cffffd100guild record|r"
    end
    return table.concat(parts, "  "), false, mine and 1 or 0
  end
end

local function CreatePicker(listParent, barParent)
  pick.list = CreateFrame("Frame", nil, listParent)
  pick.list:SetSize(COMPACT_W - 32, 1)
  pick.list:Hide()
  pick.bar = CreateFrame("Frame", nil, barParent)
  pick.bar:SetAllPoints()
  pick.bar:Hide()
  pick.filters = H.FilterButtons(pick.bar, {
    { key = "suggested", label = "For me", width = 54, tip = "Dungeons with quests in your log, and those for your "
      .. "level" },
    { key = "all", label = "All", width = 36, tip = "Every dungeon DungeonJournal knows" },
  }, function()
    return mod.db.pickFilter or "suggested"
  end, function(key)
    mod.db.pickFilter = key
  end)
  pick.hint = Kit.Text(pick.bar, "GameFontDisableSmall")
  pick.hint:SetPoint("RIGHT", 0, 0)
  pick.hint:SetJustifyH("RIGHT")
  pick.rows = H.Pool(function()
    local r = H.Row(pick.list, PICK_ROW, PICK_ROW - 8)
    S(r, "OnClick", function(row)
      ShowDungeon(row.dungeon)
    end)
    H.Tip(r, function(row)
      return row.dungeon
    end, function(row)
      return (row.tip or "") .. "\nClick: show this dungeon. The v button goes back to this list."
    end)
    return r
  end)
  pick.sections = H.Pool(function()
    return H.Section(pick.list)
  end)
  pick.empty = H.Empty(pick.list)
end

local function RenderPicker(width, key)
  pick.filters.Paint()
  local level = UnitLevel and Plain(UnitLevel("player")) or 1
  local fdj = H.FDJ()
  local mineList, levelList, rest = {}, {}, {}
  for _, name in ipairs(H.Dungeons()) do
    local d = fdj and fdj.DB[name] or {}
    local lo, hi = LevelRange(d.level)
    local note, hasLog, weight = PickNote(key, name)
    local e = { name = name, d = d, lo = lo or 0, hi = hi or 0, note = note, weight = weight }
    if hasLog then
      mineList[#mineList + 1] = e
    elseif lo and level >= lo - 3 and level <= (hi or lo) + 2 then
      levelList[#levelList + 1] = e
    else
      rest[#rest + 1] = e
    end
  end
  local function ByLevel(a, b)
    if a.lo ~= b.lo then
      return a.lo < b.lo
    end
    return a.name < b.name
  end
  table.sort(mineList, ByLevel)
  table.sort(levelList, ByLevel)
  table.sort(rest, ByLevel)
  local groups = { { "Your quests are here", mineList }, { "For your level (" .. level .. ")", levelList } }
  if (mod.db.pickFilter or "suggested") == "all" or (#mineList == 0 and #levelList == 0) then
    groups[#groups + 1] = { "Other dungeons", rest }
  end
  local ar, ag, ab = Skin:Accent()
  local y = 2
  local shown = 0
  for _, g in ipairs(groups) do
    if #g[2] > 0 then
      local h = pick.sections:Get()
      H.PaintSection(h, g[1], "|cff888888" .. #g[2] .. "|r")
      y = H.Place(h, y + (y > 2 and 6 or 0), 20, 2)
      for _, e in ipairs(g[2]) do
        local r = pick.rows:Get()
        r.dungeon = e.name
        H.SetIcon(r.pic, type(e.d.icon) == "string" and e.d.icon or H.ICON.dungeon, e.d.icon and true or false)
        H.SetEdge(r.pic, ar, ag, ab, 0.3)
        local cr, cg, cb = 0.9, 0.9, 0.9
        if e.lo > 0 then
          if level < e.lo - 3 then
            cr, cg, cb = 1, 0.35, 0.3 -- too high for you
          elseif level > e.hi + 4 then
            cr, cg, cb = 0.55, 0.55, 0.55 -- grey
          elseif level >= e.lo then
            cr, cg, cb = 0.4, 1, 0.45
          else
            cr, cg, cb = 1, 0.82, 0
          end
        end
        local lv = e.d.level and ("Lv " .. tostring(e.d.level)) or ""
        local where = type(e.d.location) == "string" and e.d.location or ""
        r.tip = (lv ~= "" and (lv .. (where ~= "" and (" · " .. where) or "")) or where)
        H.PaintRow(r, {
          name = e.name,
          sub = "|cff999999" .. lv .. "|r",
          note = e.note ~= "" and e.note or nil,
          color = { cr, cg, cb },
          dim = level > e.hi + 4,
        })
        y = H.Place(r, y, PICK_ROW)
        shown = shown + 1
      end
    end
  end
  pick.rows:Done()
  pick.sections:Done()
  pick.hint:SetText(key == "quests" and "quests for you" or key == "bis" and "upgrades for you" or "best times")
  if shown == 0 then
    y = H.ShowEmpty(pick.empty, 8, width, fdj and "No dungeons known" or "DungeonJournal isn't loaded",
      H.ICON.dungeon)
  else
    pick.empty:Hide()
  end
  return y
end

local renderQueued = false
local function DoRender()
  renderQueued = false
  if not frame or not frame:IsShown() then
    if side then
      side:Hide()
    end
    return
  end
  local db = mod.db
  local tab = CurrentTab()
  local folded = db.listCollapsed
  Layout()
  PaintHeader()
  if not Compact() then
    PaintBanner()
  end
  UpdateClock()

  local ar, ag, ab = Skin:Accent()
  frame.divider:SetColorTexture(ar, ag, ab, 0.25)

  -- No dungeon: the picker, the tab as what to show for each.
  local picking = not H.shown
  pick.bar:SetShown(picking and not folded)
  if picking then
    for _, t in ipairs(H.tabs) do
      t.bar:Hide()
      t.list:Hide()
      t.detail:Hide()
    end
    if frame.scrolled ~= pick then
      frame.scrolled = pick
      listScroll:SetScrollChild(pick.list)
    end
    local w = Compact() and frame.listW or (FULL_W - 32)
    listScroll:ClearAllPoints()
    listScroll:SetPoint("TOPLEFT", 4, -frame.top)
    listScroll:SetPoint("BOTTOMRIGHT", -26, 6)
    detailScroll:Hide()
    frame.divider:Hide()
    frame.listBack:Hide()
    pick.list:SetWidth(w)
    pick.list:Show()
    local ly = RenderPicker(w, tab.key)
    pick.list:SetHeight(math.max(ly, 1))
    PaintTabs(tab)
    for _, t in ipairs(H.tabs) do
      t.bar:Hide()
      t.list:Hide()
      t.detail:Hide()
    end
    local maxH = math.min(math.max(tonumber(db.maxHeight) or 460, MIN_H), 900)
    frame:SetHeight(folded and (HEADER_H + 4) or math.max(math.min(frame.top + 8 + ly, maxH), MIN_H))
    side:Hide()
    return
  end
  pick.list:Hide()
  if frame.scrolled ~= tab then
    frame.scrolled = tab
    listScroll:SetScrollChild(tab.list)
    detailScroll:SetScrollChild(tab.detail)
  end
  tab.list:SetWidth(frame.listW)
  tab.detail:SetWidth(frame.detailW)
  local ly = tab:RenderList(frame.listW) or 1
  local dy = tab:RenderDetail(frame.detailW) or 1
  tab.list:SetHeight(math.max(ly, 1))
  tab.detail:SetHeight(math.max(dy, 1))
  PaintTabs(tab) -- (after the render: the badges count what it worked out)

  local maxH = math.min(math.max(tonumber(db.maxHeight) or 460, MIN_H), 900)
  if folded then
    frame:SetHeight(HEADER_H + 4)
  elseif Compact() then
    frame:SetHeight(math.max(math.min(frame.top + 8 + ly, maxH), MIN_H))
  else
    frame:SetHeight(math.max(math.min(frame.top + 8 + math.max(ly, dy), maxH), MIN_H + 120))
  end
  local wantSide = Compact() and not folded and H.sideOpen and dy > 2
  if wantSide then
    side:SetHeight(math.max(frame:GetHeight(), math.min(HEADER_H + 10 + dy, maxH)))
    side.title:SetText(SHORT[tab.key] and tab.label or "")
    PlaceSide()
    side:Show()
  else
    side:Hide()
  end
end

function H.Render()
  if renderQueued then
    return
  end
  renderQueued = true
  mod:After(0, function()
    DoRender()
  end)
end

ShowDungeon = function(name, keepAuto)
  if not keepAuto then
    H.auto = name == nil
  end
  local was = H.shown
  H.shown = name or H.CurrentDungeon()
  if H.shown ~= was then
    H.sideOpen = false
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
      root:CreateRadio("Current dungeon (outside: the dungeon list)", function()
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
    local idx = 0
    for i, name in ipairs(names) do
      if name == H.shown then
        idx = i
      end
    end
    ShowDungeon(names[idx % #names + 1])
  end
end

local function Pane(name, parent)
  local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
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

local Close

-- A small icon button for the header (the cog).
local function IconButton(parent, path, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetAllPoints()
  b.tex:SetTexture(path)
  b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.2)
  return b
end

local function CreateWindow()
  frame = Skin:CreateTooltipWindow("ARLEDungeonHelperFrame", UIParent)
  frame:SetSize(COMPACT_W, MIN_H)
  frame:SetFrameStrata("MEDIUM")
  mod.db.pos = nil
  placeFrame = Kit.Movable(frame, mod, { x = 360, y = 80, onMoved = function()
    if side and side:IsShown() then
      PlaceSide()
    end
  end })

  -- Header: [-][icon] name ... clock [cog][<>][v][x]
  frame.collapse = H.SmallButton(frame, "-", 18)
  frame.collapse:SetPoint("TOPLEFT", 4, -4)
  S(frame.collapse, "OnClick", function()
    mod.db.listCollapsed = not mod.db.listCollapsed or nil
    H.Render()
  end)
  H.Tip(frame.collapse, "Fold", "Folds the window to this line (the clock stays).")
  frame.close = H.SmallButton(frame, "x", 18)
  frame.close:SetPoint("TOPRIGHT", -4, -4)
  S(frame.close, "OnClick", function()
    Close("player")
  end)
  H.Tip(frame.close, "Close", function()
    return mod.db.stayClosed and InInstance() and "It stays closed until you leave this dungeon (/arl dh opens it)."
      or "/arl dh opens it again."
  end)
  frame.pick = H.SmallButton(frame, "v", 18)
  frame.pick:SetPoint("RIGHT", frame.close, "LEFT", -2, 0)
  S(frame.pick, "OnClick", DungeonMenu)
  H.Tip(frame.pick, "Pick a dungeon", function()
    return H.auto and "Following the dungeon you are in (outside one: the dungeon list)." or "Showing a dungeon "
      .. "you picked. Pick \"Current dungeon\" to follow where you are again (outside: back to the list)."
  end)
  frame.layout = H.SmallButton(frame, ">", 18)
  frame.layout:SetPoint("RIGHT", frame.pick, "LEFT", -2, 0)
  S(frame.layout, "OnClick", function()
    ARLE:SetOption(mod.id, "layout", Compact() and "full" or "compact")
  end)
  H.Tip(frame.layout, function()
    return Compact() and "Full size" or "Compact"
  end, function()
    return Compact() and "List and details side by side, with the dungeon's banner."
      or "One narrow list; details open beside it when you pick something."
  end)
  frame.cog = IconButton(frame, H.ICON.cog, 16)
  frame.cog:SetPoint("RIGHT", frame.layout, "LEFT", -3, 0)
  S(frame.cog, "OnClick", function()
    ARLE:Open(mod.id)
  end)
  H.Tip(frame.cog, "Settings", "When it opens and hides (dungeons, groups, combat, boss kills), its size, and "
    .. "each tab's options.")
  frame.clock = Kit.Text(frame, "GameFontHighlightSmall")
  frame.clock:SetPoint("RIGHT", frame.cog, "LEFT", -6, 0)
  frame.clock:SetJustifyH("RIGHT")
  frame.dicon = H.Pic(frame, 18)
  frame.dicon:SetPoint("LEFT", frame.collapse, "RIGHT", 4, 0)
  frame.title = Kit.Text(frame, "GameFontNormal")
  frame.title:SetPoint("LEFT", frame.dicon, "RIGHT", 5, 0)
  frame.title:SetPoint("RIGHT", frame.clock, "LEFT", -4, 0)
  frame.title:SetWordWrap(false)

  CreateBanner()

  -- Tab strip: [icon Label badge] x3 (laid out by Layout)
  local strip = CreateFrame("Frame", nil, frame)
  strip:SetHeight(TABS_H - 2)
  frame.tabStrip = strip
  frame.tabButtons = {}
  for i, tab in ipairs(H.tabs) do
    local b = CreateFrame("Button", nil, strip)
    b:SetHeight(TABS_H - 2)
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
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("RIGHT", b.text, "LEFT", -4, 0)
    b.icon:SetTexture(TAB_ICONS[tab.key] or H.ICON.scroll)
    b.badge = H.Badge(b)
    b.badge:SetPoint("LEFT", b.text, "RIGHT", 5, 0)
    b.badge:Hide()
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.06)
    b.tab = tab
    S(b, "OnClick", function(self)
      SetTab(self.tab.key)
    end)
    H.Tip(b, tab.label, (mod.pages and (function()
      for _, p in ipairs(mod.pages) do
        if p.key == tab.key then
          return p.notes
        end
      end
    end)()) or nil)
    frame.tabButtons[i] = b
  end

  local toolbars = CreateFrame("Frame", nil, frame)
  toolbars:SetHeight(TOOL_H - 2)
  frame.toolbars = toolbars

  frame.listBack = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
  frame.listBack:SetColorTexture(0, 0, 0, 0.22)

  -- The details' own box, for the compact layout.
  side = Skin:CreateTooltipWindow("ARLEDungeonHelperSide", UIParent)
  side:SetSize(SIDE_W, 300)
  side:SetFrameStrata("MEDIUM")
  side:EnableMouse(true)
  side.close = H.SmallButton(side, "x", 18)
  side.close:SetPoint("TOPRIGHT", -4, -4)
  S(side.close, "OnClick", function()
    H.sideOpen = false
    H.Render()
  end)
  side.title = Kit.Text(side, "GameFontNormalSmall")
  side.title:SetPoint("TOPLEFT", 8, -8)
  side.title:SetPoint("RIGHT", side.close, "LEFT", -4, 0)
  side:Hide()

  listScroll = Pane("ARLEDungeonHelperList", frame)
  detailScroll = Pane("ARLEDungeonHelperDetail", frame)
  frame.divider = frame:CreateTexture(nil, "ARTWORK")
  frame.divider:SetWidth(1)

  for _, tab in ipairs(H.tabs) do
    tab.bar = CreateFrame("Frame", nil, toolbars)
    tab.bar:SetAllPoints()
    tab.list = CreateFrame("Frame", nil, listScroll)
    tab.list:SetSize(COMPACT_W - 32, 1)
    tab.detail = CreateFrame("Frame", nil, detailScroll)
    tab.detail:SetSize(SIDE_W - 36, 1)
    tab:Create(tab.bar, tab.list, tab.detail)
    tab.bar:Hide()
    tab.list:Hide()
    tab.detail:Hide()
  end

  CreatePicker(listScroll, toolbars)

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
  S(frame, "OnHide", function()
    side:Hide()
  end)
  frame:Hide()
  Layout()
end

-------------------------------------------------------------------------------
-- Showing and hiding
-------------------------------------------------------------------------------

local function InCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end

local function ApplyCombat()
  if not frame then
    return
  end
  local fade = mod.db.combat == "fade" and InCombat()
  frame:SetAlpha(fade and FADED or 1)
  side:SetAlpha(fade and FADED or 1)
end

local function Show(tabKey)
  if not frame then
    CreateWindow()
  end
  if tabKey and tabKey ~= "last" then
    SetTab(tabKey)
  end
  frame:Show()
  ApplyCombat()
  if tabs.bis:WantsItemInfo() then
    tabs.bis:OnItemInfo()
  end
  H.Render()
end

-- The player asked for it (command, cog's page button, a binding).
local function Open(tabKey)
  vis.by, vis.dismissed, vis.pending = "player", false, nil
  if not H.shown then
    ShowDungeon(nil)
  end
  Show(tabKey)
end

-- The feature wants it shown (a visit, a kill, a pull). False when it stays
-- closed: dismissed this visit, or waiting for the fight to end.
local function AutoOpen(tabKey, why)
  if vis.dismissed and mod.db.stayClosed then
    mod:Debug("%s: stays closed (you closed it this visit)", why)
    return false
  end
  if mod.db.combat == "hide" and InCombat() then
    vis.pending = tabKey or vis.pending or "last"
    mod:Debug("%s: opens after the fight", why)
    return false
  end
  if not (frame and frame:IsShown()) then
    vis.by = "auto"
    mod:Debug("%s: opened", why)
  end
  Show(tabKey)
  return true
end

-- why: "player" (the x) or "left" (the visit ended).
Close = function(why)
  if why == "player" then
    vis.dismissed = vis.visit ~= nil or vis.group == true
  end
  vis.by, vis.pending, vis.combatHidden = nil, nil, false
  if frame then
    frame:Hide()
  end
  mod:Debug("closed (%s)", why)
end

local function Toggle(tabKey)
  if frame and frame:IsShown() and (not tabKey or tabKey == mod.db.tab) then
    Close("player")
  else
    Open(tabKey)
  end
end

-------------------------------------------------------------------------------
-- Boss fights
-------------------------------------------------------------------------------

local function IsOptional(dungeon, name)
  for _, boss in ipairs(H.Bosses(dungeon)) do
    if boss.name == name or boss.group == name then
      return boss.optional
    end
  end
  return true -- (not a listed boss)
end

-- Bosses & Loot on a boss. auto: may open the window (as set); otherwise it
-- only switches when it's shown.
local function FocusBoss(dungeon, bossName, pulling, open)
  if dungeon and dungeon ~= H.shown and H.auto then
    ShowDungeon(dungeon, true)
  end
  if dungeon ~= H.shown then
    return
  end
  tabs.bis:Focus(bossName, pulling)
  local shown = frame and frame:IsShown()
  if not shown and not open then
    return
  end
  if shown then
    mod.db.listCollapsed = nil
    H.sideOpen = true
    Show("bis")
  elseif AutoOpen("bis", pulling and "pull" or "kill") then
    mod.db.listCollapsed = nil
    H.sideOpen = true
  end
  H.DetailToTop()
  H.Render()
end
mod.FocusBoss = FocusBoss

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local recentKills = {}
local KILL_DEDUPE = 30
local rosterKey
local lastDungeon

-- The visit: entering an instance starts one (and may open the window),
-- leaving ends it (and closes what opened by itself). Group outside
-- dungeons: the same with showInGroup.
local function ZoneChanged()
  local key = InstanceKey()
  local newVisit = false
  if key then
    if not vis.visit or vis.visit.key ~= key then
      vis.visit = { key = key, dungeon = RawCurrent() }
      vis.dismissed, vis.group = false, nil
      H.auto = true -- (a dungeon picked from the list outside gives way to the one you entered)
      newVisit = true
    end
  elseif vis.visit then
    vis.visit = nil
    vis.dismissed = false
    if vis.by == "auto" then
      Close("left")
    end
  end
  local current = H.CurrentDungeon()
  if current ~= lastDungeon or newVisit then
    lastDungeon = current
    tabs.times:OnZone(current)
  end
  if H.auto then
    ShowDungeon(nil)
  end
  if newVisit and current and mod.db.autoOpen then
    AutoOpen(mod.db.openTab or "quests", "entered " .. current)
  end
  -- Grouped in the open world.
  if not key then
    local grouped = IsInGroup and IsInGroup() and true or false
    if grouped and mod.db.showInGroup and H.shown and not vis.group then
      vis.group = true
      AutoOpen(mod.db.openTab or "quests", "in a group")
    elseif not grouped and vis.group then
      vis.group, vis.dismissed = nil, false
      if vis.by == "auto" then
        Close("left")
      end
    end
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

-- One boss kill, however many events tell it: handled once.
local function Killed(dungeon, boss)
  if not dungeon or not boss then
    return false
  end
  local key, now = dungeon .. "\0" .. boss, GetTime()
  if recentKills[key] and now - recentKills[key] < KILL_DEDUPE then
    return true
  end
  recentKills[key] = now
  tabs.times:OnKill(dungeon, boss)
  local how = mod.db.onKill or "open"
  if how == "never" or IsOptional(dungeon, boss) then
    mod:Debug("%s died: %s", boss, how == "never" and "set to do nothing" or "rare or optional, no jump")
    return false
  end
  FocusBoss(dungeon, boss, false, how == "open")
  return true
end

local function SeenGUID(guid)
  local npc, zone, map = H.ParseGUID(guid)
  if zone and InInstance() then
    tabs.times:OnInstanceGUID(zone, map)
  end
  return npc
end

local kidDeaths = {}

local function GUIDDied(guid)
  if not InInstance() then
    return
  end
  local npc = SeenGUID(guid)
  if npc then
    local dungeon, boss = H.BossForNPC(npc)
    if boss then
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
    local encounterID, encounterName = ...
    local ok, dungeon, boss = pcall(H.BossFor, Plain(encounterID), Plain(encounterName))
    if ok and boss then
      tabs.times:OnPull(dungeon, boss)
      if mod.db.openOnPull then
        FocusBoss(dungeon, boss, true, true)
      else
        tabs.bis:Focus(boss, true)
        H.Render()
      end
    end
  elseif event == "ENCOUNTER_END" or event == "BOSS_KILL" then
    local encounterID, encounterName, _, _, success = ...
    encounterID, encounterName, success = Plain(encounterID), Plain(encounterName), Plain(success)
    local killed = event == "BOSS_KILL" or success == 1 or success == true
    if killed and InInstance() then
      local ok, dungeon, boss, also = pcall(H.BossFor, encounterID, encounterName)
      if ok and boss then
        Killed(dungeon, boss)
        for _, extra in ipairs(also or {}) do
          local name = H.ResolveBoss(dungeon, extra)
          if name then
            tabs.times:OnKill(dungeon, name)
          end
        end
      end
    end
    if event == "ENCOUNTER_END" then
      tabs.bis.fighting = nil
      H.Render()
    end
  elseif event == "PARTY_KILL" then
    local _, targetGUID = ...
    GUIDDied(targetGUID)
  elseif event == "UNIT_DIED" then
    GUIDDied((...))
  elseif event == "PLAYER_TARGET_CHANGED" then
    if InInstance() and UnitGUID and UnitCanAttack and Plain(UnitCanAttack("player", "target")) then
      SeenGUID(UnitGUID("target"))
    end
  elseif event == "CHAT_MSG_SYSTEM" then
    if not InInstance() then
      tabs.times:OnSystemMessage((...))
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    tabs.times:OnCombat()
    if mod.db.combat == "hide" and frame and frame:IsShown() then
      vis.combatHidden = true
      frame:Hide()
    end
    ApplyCombat()
  elseif event == "PLAYER_REGEN_ENABLED" then
    ApplyCombat()
    if vis.combatHidden then
      vis.combatHidden = false
      if frame and not (vis.dismissed and mod.db.stayClosed) then
        frame:Show()
        H.Render()
      end
    end
    if vis.pending then
      local tab = vis.pending
      vis.pending = nil
      if AutoOpen(tab, "after the fight") and tab == "bis" then
        H.sideOpen = true -- (a kill during the fight: its loot, beside the list)
        H.Render()
      end
    end
  elseif QUEST_EVENTS[event] then
    mod:Debounce("quests", 0.5, function()
      tabs.quests:OnQuestChange()
    end)
    if event == "PLAYER_LEVEL_UP" then
      H.ClearGQ()
    end
  elseif event == "GROUP_ROSTER_UPDATE" then
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
        if not InInstance() then
          ZoneChanged()
        end
        H.Render()
      end
    end)
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    mod:Debounce("gear", 1, function()
      H.ClearGQ()
      tabs.bis.RefreshMine()
      H.QueueSend(H.shown, "bis")
      H.Render()
    end)
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if tabs.bis:WantsItemInfo() then
      mod:Debounce("iteminfo", 1, function()
        tabs.bis:OnItemInfo()
        H.Render()
      end)
    end
  elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
    -- Rooms: only a different wing (or a first name for this instance)
    -- runs the zone logic.
    local raw = RawCurrent()
    if raw and raw ~= lastDungeon then
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

local function Command(rest)
  local word = ((rest or ""):match("^(%S+)") or ""):lower()
  if word == "reset" then
    tabs.times:Reset()
    mod:Print("Clear Times: run reset.")
    return
  end
  if word == "compact" or word == "full" then
    ARLE:SetOption(mod.id, "layout", word)
    Open()
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

-- Settings from before 0.15.0.
local function Migrate(db)
  if db.hideInCombat ~= nil then
    db.combat = db.hideInCombat and "hide" or "keep"
    db.hideInCombat = nil
  end
  if db.openOnKill ~= nil then
    db.onKill = db.openOnKill and "open" or "shown"
    db.openOnKill = nil
  end
  if not db.compactSeen then
    -- The big window was what hogged the screen: everyone starts compact once.
    db.compactSeen = true
    db.layout = "compact"
    if (tonumber(db.maxHeight) or 0) > 600 or db.maxHeight == 540 then
      db.maxHeight = 460
    end
  end
  db.run, db.specs, db.roomy = nil, nil, nil
  if db.onlyUpgrades ~= nil then
    if db.onlyUpgrades then
      db.filter = "party"
    end
    db.onlyUpgrades = nil
  end
end

local flbHooked = false
function mod:OnEnable()
  renderQueued = false
  H.ResetSends()
  H.RegisterComms()
  local fdj = H.FDJ()
  if not fdj then
    error("DungeonJournal (ForeverDungeonJournal) is not loaded; it provides the bosses, loot and quests", 0)
  end
  CheckFDJ(fdj)
  Migrate(self.db)
  vis.visit, vis.by, vis.dismissed, vis.combatHidden, vis.pending, vis.group = nil, nil, false, false, nil, nil
  rosterKey, lastDungeon = nil, nil
  wipe(recentKills)
  H.ClearGQ()
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
  ARLE:QueuePresence()
end

function mod:OnDisable()
  ARLE:QueuePresence()
  vis.by, vis.pending, vis.combatHidden = nil, nil, false
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
  if key == "combat" then
    if self.db.combat ~= "hide" and vis.combatHidden and frame then
      vis.combatHidden = false
      frame:Show()
    end
    ApplyCombat()
  elseif key == "showShared" or key == "showOther" then
    H.ClearBossCache()
    tabs.bis.RefreshMine()
    H.QueueSend(H.shown, "bis", true)
  elseif key == "useGearQuest" then
    H.ClearGQ()
  elseif key == "guildBoard" and self.db.guildBoard then
    tabs.times:ShareAll()
  elseif key == "questExtras" and tabs.quests.ClearCaches then
    tabs.quests:ClearCaches()
  elseif key == "showInGroup" then
    ZoneChanged()
  end
  H.Render()
end

function mod:GetStatus()
  local parts = { "Active", H.shown or "not in a dungeon" }
  local shown = frame and frame:IsShown()
  if vis.dismissed and mod.db.stayClosed then
    parts[#parts + 1] = "closed for this visit"
  elseif vis.pending then
    parts[#parts + 1] = "opens after the fight"
  elseif shown then
    parts[#parts + 1] = (Compact() and "compact" or "full") .. ", " .. (vis.by == "auto" and "opened by itself"
      or "opened by you")
  end
  if H.shown then
    parts[#parts + 1] = tabs.bis:Status()
    parts[#parts + 1] = tabs.quests:Status()
  end
  parts[#parts + 1] = tabs.times:Status()
  return table.concat(parts, "  ·  ")
end

function mod:ReportDetails()
  return {
    string.format("visit %s (dungeon %s), opened by %s, dismissed %s, pending %s, combat hidden %s",
      tostring(vis.visit and vis.visit.key), tostring(vis.visit and vis.visit.dungeon), tostring(vis.by),
      tostring(vis.dismissed), tostring(vis.pending), tostring(vis.combatHidden)),
    string.format("shown %s, layout %s, tab %s, raw current %s, auto %s", tostring(H.shown),
      tostring(self.db.layout), tostring(self.db.tab), tostring(RawCurrent()), tostring(H.auto)),
    string.format("settings: autoOpen %s, openTab %s, showInGroup %s, combat %s, stayClosed %s, onKill %s, "
      .. "openOnPull %s", tostring(self.db.autoOpen), tostring(self.db.openTab), tostring(self.db.showInGroup),
      tostring(self.db.combat), tostring(self.db.stayClosed), tostring(self.db.onKill),
      tostring(self.db.openOnPull)),
  }
end

-- (the options page's records pane follows; it opens the window with Open)
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
