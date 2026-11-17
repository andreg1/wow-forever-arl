-- Dungeon Helper, Bosses & Loot tab: the dungeon's bosses on the left, the
-- selected boss's drops on the right, and for each drop who in the party it
-- is BiS or an upgrade for.
--
-- Forever Leveling BiS can only score items for the player it runs for, so
-- every ARL member in the party scores the dungeon's drops with their own
-- copy and shares the gains (and their equipped item IDs) over ARL's addon
-- messages (party channel). Members without ARL get no marks: their gear
-- isn't guessed. "BiS" for a member = the biggest upgrade this dungeon has
-- for that slot; any other drop that gains them something is an "upgrade".
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Kit = ARLE.UI.Kit
local S = H.Script
local Bosses, FLB, Members, Me = H.Bosses, H.FLB, H.Members, H.Me
local ColorName, TooltipSide = H.ColorName, H.TooltipSide
local GetItemInfo, GetItemIcon = H.GetItemInfo, H.GetItemIcon

local BOSS_H, ITEM_H, BIG = 22, 18, 36
local OTHER = "@other" -- the Other loot entry
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local BAG = "Interface\\Icons\\INV_Misc_Bag_10"
local RARE_ICON = "atlas:nameplates-icon-elite-silver"

local tab = { key = "bis", label = "Bosses & Loot" }
H.tabs[#H.tabs + 1] = tab

-- Equip locations folded into the slot they compete for.
local SLOT_OF = {
  INVTYPE_ROBE = "INVTYPE_CHEST",
  INVTYPE_WEAPON = "MAINHAND",
  INVTYPE_2HWEAPON = "MAINHAND",
  INVTYPE_WEAPONMAINHAND = "MAINHAND",
  INVTYPE_WEAPONOFFHAND = "OFFHAND",
  INVTYPE_SHIELD = "OFFHAND",
  INVTYPE_HOLDABLE = "OFFHAND",
  INVTYPE_RANGED = "RANGED",
  INVTYPE_RANGEDRIGHT = "RANGED",
  INVTYPE_THROWN = "RANGED",
  INVTYPE_RELIC = "RANGED",
}
-- Inventory slots an equip location goes in (for "wears ...").
local INV_SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
  INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
  INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
  INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16, 17 },
  INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 },
  INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 }, INVTYPE_TABARD = { 19 },
}

local SPEC_LABEL = {
  beastmastery = "Beast Mastery", survivalmelee = "Survival (melee)", survival = "Survival (ranged)",
  feral = "Feral (cat)", bear = "Feral (bear)",
}
local function SpecLabel(spec)
  if not spec then
    return "?"
  end
  return SPEC_LABEL[spec] or (spec:sub(1, 1):upper() .. spec:sub(2))
end
tab.SpecLabel = SpecLabel

-------------------------------------------------------------------------------
-- Party data: party[name] = { class, spec, dungeon, gains = {id = gain}, worn = {slot = id} }
-------------------------------------------------------------------------------

local party = {}
tab.data = party

-- The player's own gains, straight from Forever Leveling BiS.
local function MyData(dungeon)
  local api = FLB()
  local data = { gains = {}, worn = {}, dungeon = dungeon, loading = false }
  if not api then
    return data
  end
  if api.GetSpec then
    local spec, _, classFile = api.GetSpec()
    data.spec, data.class = spec, classFile
  end
  for _, item in ipairs(H.GearItems(dungeon)) do
    local gain, loading = api.GetGain(item.id)
    if loading then
      data.loading = true
    elseif gain and gain > 0 then
      data.gains[item.id] = gain
    end
  end
  for slot = 1, 19 do
    data.worn[slot] = GetInventoryItemID("player", slot)
  end
  return data
end

-- Item data that never arrives (an item the server doesn't know) would keep
-- the player "loading" forever: after this many refreshes it counts as done.
local MAX_TRIES = 15

local function RefreshMine()
  if H.shown and FLB() then
    local data = MyData(H.shown)
    local old = party[Me()]
    if data.loading then
      data.tries = ((old and old.dungeon == H.shown and old.tries) or 0) + 1
      if data.tries > MAX_TRIES then
        data.loading, data.gaveUp = false, true
      end
    end
    party[Me()] = data
  end
end
tab.RefreshMine = RefreshMine

-- "<dungeon>~<class>~<spec>~<part>~<total>~id:gain,id:gain", then the
-- equipped items. What was sent last time isn't sent again unless forced.
local lastSent = {}
function tab:Send(dungeon, channel, force)
  if not FLB() then
    return
  end
  local data = MyData(dungeon)
  local list = {}
  for id, gain in pairs(data.gains) do
    list[#list + 1] = id .. ":" .. string.format("%.1f", gain)
  end
  table.sort(list)
  local head = dungeon .. "~" .. (data.class or "") .. "~" .. (data.spec or "")
  local worn = {}
  for slot = 1, 19 do
    if data.worn[slot] then
      worn[#worn + 1] = slot .. ":" .. data.worn[slot]
    end
  end
  local key = head .. "|" .. table.concat(list, ",") .. "|" .. table.concat(worn, ",")
  if not force and lastSent[dungeon] == key then
    return
  end
  lastSent[dungeon] = key
  H.SendChunks("BG", head, list, ",", channel)
  ARLE:Send("BE", table.concat(worn, ","), channel)
end

-- Whether item data that arrives could change the player's own gains (they
-- are sent to the party, so always wanted).
function tab:WantsItemInfo()
  local mine = party[Me()]
  return mine ~= nil and mine.loading and mine.dungeon == H.shown
end

function tab:OnItemInfo()
  local mine = party[Me()]
  if mine and mine.loading and mine.dungeon == H.shown then
    RefreshMine()
    if party[Me()] and not party[Me()].loading then
      H.QueueSend(H.shown, "bis") -- the full numbers, now that they are known
    end
  end
end

function tab:Prune(keep)
  for name in pairs(party) do
    if not keep[name] then
      party[name] = nil
    end
  end
end

ARLE:RegisterComm("BG", function(sender, payload)
  if not mod._active then
    return
  end
  local dungeon, class, spec, part, total, list = payload:match("^(.-)~(.-)~(.-)~(%d+)~(%d+)~(.*)$")
  if not dungeon then
    return
  end
  local p = party[sender]
  if not p or p.dungeon ~= dungeon or tonumber(part) == 1 then
    p = { gains = {}, worn = p and p.worn or {}, dungeon = dungeon }
    party[sender] = p
  end
  p.class, p.spec = class ~= "" and class or nil, spec ~= "" and spec or nil
  for id, gain in list:gmatch("(%d+):([%d%.%-]+)") do
    p.gains[tonumber(id)] = tonumber(gain)
  end
  p.complete = tonumber(part) == tonumber(total)
  H.Render()
end)

ARLE:RegisterComm("BE", function(sender, payload)
  if not mod._active then
    return
  end
  local p = party[sender] or { gains = {} }
  party[sender] = p
  p.worn = {}
  for slot, id in payload:gmatch("(%d+):(%d+)") do
    p.worn[tonumber(slot)] = tonumber(id)
  end
  H.Render()
end)

-- BiS/upgrade marks per item: marks[itemID] = { {member, gain, bis}, ... },
-- biggest gain first.
local function Marks(dungeon, members)
  local best = {} -- member -> slot -> best gain
  local marks = {}
  local items = H.GearItems(dungeon)
  for _, m in ipairs(members) do
    local p = party[m.name]
    if p and p.dungeon == dungeon then
      best[m.name] = {}
      for _, item in ipairs(items) do
        local g = p.gains[item.id]
        local slot = SLOT_OF[item.loc] or item.loc
        if g and g > 0 and g > (best[m.name][slot] or 0) then
          best[m.name][slot] = g
        end
      end
    end
  end
  for _, item in ipairs(items) do
    local list = {}
    for _, m in ipairs(members) do
      local p = party[m.name]
      local g = p and p.dungeon == dungeon and p.gains[item.id]
      if g and g > 0 then
        local slot = SLOT_OF[item.loc] or item.loc
        list[#list + 1] = { member = m, gain = g, bis = g >= (best[m.name][slot] or math.huge) }
      end
    end
    table.sort(list, function(a, b)
      return a.gain > b.gain
    end)
    marks[item.id] = list
  end
  return marks
end

-------------------------------------------------------------------------------
-- Selection
-------------------------------------------------------------------------------

local selected = {} -- dungeon -> boss name (or OTHER)

local function Filter()
  return mod.db.filter or "all"
end

-- bossName may be a fight (the Ring of Law): its first boss is selected.
-- pulling: the fight is on (its row gets a marker until it ends).
function tab:Focus(bossName, pulling)
  for _, boss in ipairs(H.shown and Bosses(H.shown) or {}) do
    if boss.name == bossName or boss.group == bossName then
      selected[H.shown] = boss.name
      break
    end
  end
  self.fighting = pulling and bossName or nil
end

local function Select(name)
  if H.shown and selected[H.shown] ~= name then
    selected[H.shown] = name
    H.DetailToTop()
  end
  H.Render()
end

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------

local function ItemTooltip(row)
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetItemByID(row.item.id)
  if row.item.sources then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Drops from: " .. table.concat(row.item.sources, ", "), 0.6, 0.8, 1, true)
  end
  if not row.item.loc then
    GameTooltip:Show()
    return
  end
  GameTooltip:AddLine(" ")
  local slots = INV_SLOTS[row.item.loc] or {}
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if p and p.dungeon == H.shown then
      local mark
      for _, mk in ipairs(row.marks) do
        if mk.member.name == m.name then
          mark = mk
        end
      end
      if mark then
        GameTooltip:AddDoubleLine(ColorName(m) .. (mark.bis and "  |cffffd100BiS|r" or "  upgrade"),
          string.format("+%.1f", mark.gain), 1, 1, 1, 0.4, 1, 0.4)
      else
        GameTooltip:AddDoubleLine(ColorName(m), "no gain", 1, 1, 1, 0.6, 0.6, 0.6)
      end
      local wears = {}
      for _, slot in ipairs(slots) do
        local id = p.worn and p.worn[slot]
        if id then
          wears[#wears + 1] = (GetItemInfo(id)) or ("item " .. id)
        end
      end
      GameTooltip:AddLine("    " .. (#wears > 0 and ("wears " .. table.concat(wears, " / ")) or "nothing in that slot"),
        0.65, 0.65, 0.65)
    else
      GameTooltip:AddDoubleLine(ColorName(m), "no ARL (no numbers)", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Shift-click: link it in chat.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function PartyTooltip(owner)
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText("Party", 1, 1, 1)
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if p and p.dungeon == H.shown then
      GameTooltip:AddDoubleLine(ColorName(m), SpecLabel(p.spec) .. (p.loading and " (loading)" or ""),
        1, 1, 1, 0.45, 0.9, 0.5)
    elseif m.unit == "player" then
      GameTooltip:AddDoubleLine(ColorName(m), FLB() and "loading..." or "needs Forever Leveling BiS",
        1, 1, 1, 0.6, 0.6, 0.6)
    else
      GameTooltip:AddDoubleLine(ColorName(m), "no ARL", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("ARL members score the drops with their own Forever Leveling BiS and share the numbers. "
    .. "Others get no marks.", 0.8, 0.8, 0.8, true)
  GameTooltip:AddLine("|cffffd100Gold-edged square|r: BiS from this dungeon for that slot", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Plain square: an upgrade", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function BossTooltip(row)
  local boss = row.boss
  if boss == OTHER then
    H.SimpleTooltip(row, "Other loot", "Drops from the dungeon's mobs, chests and other spawns, and every recipe "
      .. "found in the dungeon (from bosses too). Gear here counts for BiS and upgrades like the bosses' gear.")
    return
  end
  GameTooltip:SetOwner(row, TooltipSide(row))
  GameTooltip:SetText(boss.name, 1, 1, 1)
  if boss.rare then
    GameTooltip:AddLine("Rare: may not spawn in every run.", 0.75, 0.75, 0.75)
  elseif boss.optional then
    GameTooltip:AddLine("Optional: summoned, or brought by a quest.", 0.75, 0.75, 0.75)
  end
  GameTooltip:AddLine(#boss.items .. " gear drop(s).", 0.8, 0.8, 0.8)
  for _, line in ipairs(row.who or {}) do
    GameTooltip:AddLine(line, 1, 1, 1)
  end
  GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- The list: bosses, the rares, Other loot
-------------------------------------------------------------------------------

local listPool, sectionPool, listEmpty
local detail = {}

-- What a boss's drops hold for the filter: visible items, BiS and upgrade
-- counts, and the members it has something for (strong: BiS for them).
local function Summary(items, marks, filter)
  local me = Me()
  local visible, bis, ups, who, order = {}, 0, 0, {}, {}
  for _, item in ipairs(items) do
    local mk = marks[item.id] or {}
    local mine = false
    for _, m in ipairs(mk) do
      if m.bis then
        bis = bis + 1
      else
        ups = ups + 1
      end
      if m.member.name == me then
        mine = true
      end
      local w = who[m.member.name]
      if not w then
        w = { class = m.member.class, name = m.member.name, member = m.member, bis = 0, ups = 0 }
        who[m.member.name] = w
        order[#order + 1] = w
      end
      if m.bis then
        w.bis, w.strong = w.bis + 1, true
      else
        w.ups = w.ups + 1
      end
    end
    if filter == "all" or (filter == "party" and #mk > 0) or (filter == "mine" and mine) then
      visible[#visible + 1] = item
    end
  end
  return { visible = visible, bis = bis, ups = ups, who = order }
end

local function CountText(sum)
  local parts = {}
  if sum.bis > 0 then
    parts[#parts + 1] = "|cffffd100" .. sum.bis .. " BiS|r"
  end
  if sum.ups > 0 then
    parts[#parts + 1] = "|cffaaaaaa" .. sum.ups .. " up|r"
  end
  return table.concat(parts, " ")
end

local function WhoLines(sum)
  local lines = {}
  for _, w in ipairs(sum.who) do
    local parts = {}
    if w.bis > 0 then
      parts[#parts + 1] = "|cffffd100" .. w.bis .. " BiS|r"
    end
    if w.ups > 0 then
      parts[#parts + 1] = w.ups .. " upgrade(s)"
    end
    lines[#lines + 1] = ColorName(w.member) .. ": " .. table.concat(parts, ", ")
  end
  return lines
end

-- The entries of the list, in order, with their summaries.
local function Entries(marks, filter)
  local list, rares = {}, {}
  for _, boss in ipairs(Bosses(H.shown)) do
    local e = { key = boss.name, boss = boss, items = boss.items, sum = Summary(boss.items, marks, filter) }
    if boss.optional then
      rares[#rares + 1] = e
    else
      list[#list + 1] = e
    end
  end
  local other
  if mod.db.showOther then
    local items = H.OtherLoot(H.shown)
    if #items > 0 then
      other = { key = OTHER, boss = OTHER, items = items, sum = Summary(items, marks, filter) }
    end
  end
  return list, rares, other
end

function tab:Create(bar, list, detailFrame)
  self.filters = H.FilterButtons(bar, {
    { key = "all", label = "All", tip = "Every gear drop" },
    { key = "party", label = "Party", tip = "Drops that are BiS or an upgrade for an ARL member in the party" },
    { key = "mine", label = "Mine", tip = "Drops that are BiS or an upgrade for you" },
  }, Filter, function(key)
    mod.db.filter = key
  end)
  self.partyButton = CreateFrame("Button", nil, bar)
  self.partyButton:SetPoint("LEFT", self.filters.last, "RIGHT", 8, 0)
  self.partyButton:SetSize(160, 18)
  self.partyButton.text = Kit.Text(self.partyButton, "GameFontHighlightSmall")
  self.partyButton.text:SetPoint("LEFT")
  S(self.partyButton, "OnEnter", PartyTooltip)
  S(self.partyButton, "OnLeave", GameTooltip_Hide)

  self.listFrame = list
  listPool = H.Pool(function()
    local r = H.Row(list, BOSS_H, 18)
    S(r, "OnClick", function(row)
      Select(row.key)
    end)
    S(r, "OnEnter", BossTooltip)
    S(r, "OnLeave", GameTooltip_Hide)
    return r
  end)
  sectionPool = H.Pool(function()
    return H.Section(list)
  end)
  listEmpty = Kit.Text(list, "GameFontDisableSmall")

  -- Details: a big portrait and the boss's name over its drops.
  detail.frame = detailFrame
  detail.portrait = detailFrame:CreateTexture(nil, "ARTWORK")
  detail.portrait:SetSize(BIG, BIG)
  detail.portrait:SetPoint("TOPLEFT", 4, -4)
  detail.title = Kit.Text(detailFrame, "GameFontNormal")
  detail.title:SetPoint("TOPLEFT", detail.portrait, "TOPRIGHT", 8, -2)
  detail.title:SetPoint("RIGHT", -4, 0)
  detail.title:SetWordWrap(false)
  detail.sub = Kit.Text(detailFrame, "GameFontDisableSmall")
  detail.sub:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -3)
  detail.sub:SetPoint("RIGHT", -4, 0)
  detail.sub:SetWordWrap(false)
  detail.items = H.Pool(function()
    local r = H.Row(detailFrame, ITEM_H, ITEM_H - 2)
    r.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.mine = r:CreateTexture(nil, "ARTWORK")
    r.mine:SetWidth(2)
    r.mine:SetPoint("TOPLEFT", 1, -1)
    r.mine:SetPoint("BOTTOMLEFT", 1, 1)
    r.mine:SetColorTexture(0.3, 1, 0.4, 0.9)
    S(r, "OnEnter", ItemTooltip)
    S(r, "OnLeave", GameTooltip_Hide)
    S(r, "OnClick", function(row)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then
        local _, link = GetItemInfo(row.item.id)
        if link and ChatEdit_InsertLink then
          ChatEdit_InsertLink(link)
        end
      end
    end)
    return r
  end)
  detail.note = Kit.Text(detailFrame, "GameFontDisableSmall")
  detail.legend = Kit.Text(detailFrame, "GameFontDisableSmall")
end

-- What the list and the details both need, worked out once per render.
local view
local function View()
  local members = Members()
  local marks = (H.shown and FLB()) and Marks(H.shown, members) or {}
  local filter = Filter()
  local list, rares, other = {}, {}, nil
  if H.shown and FLB() then
    list, rares, other = Entries(marks, filter)
  end
  local byKey = {}
  for _, group in ipairs({ list, rares, other and { other } or {} }) do
    for _, e in ipairs(group) do
      byKey[e.key] = e
    end
  end
  local sel = H.shown and selected[H.shown]
  if not byKey[sel] then
    -- The first boss with something to show for the filter, else the first.
    sel = nil
    for _, group in ipairs({ list, rares }) do
      for _, e in ipairs(group) do
        if not sel and #e.sum.visible > 0 then
          sel = e.key
        end
      end
    end
    sel = sel or (list[1] and list[1].key) or (other and other.key)
    if H.shown then
      selected[H.shown] = sel
    end
  end
  view = { members = members, marks = marks, filter = filter, list = list, rares = rares, other = other,
    byKey = byKey, sel = sel }
  return view
end

function tab:RenderList(width)
  self.filters.Paint()
  local v = View()
  local sharing = 0
  for _, m in ipairs(v.members) do
    local p = party[m.name]
    if p and p.dungeon == H.shown then
      sharing = sharing + 1
    end
  end
  self.partyButton.text:SetText("Party: " .. sharing .. "/" .. #v.members .. " with ARL")

  local y = 0
  local function Place(e)
    local r = listPool:Get()
    r.key, r.boss = e.key, e.boss
    r.who = WhoLines(e.sum)
    if e.boss == OTHER then
      r.pic:SetTexture(BAG)
      r.pic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      r.portraitOf = nil
    elseif r.portraitOf ~= e.boss then
      r.portraitOf = e.boss -- (SetPortrait is slow-ish: only when the row shows another boss)
      H.SetPortrait(r.pic, e.boss)
    end
    local marks = {}
    for _, w in ipairs(e.sum.who) do
      marks[#marks + 1] = { class = w.class, strong = w.strong }
    end
    local empty = #e.sum.visible == 0
    local fight = tab.fighting ~= nil and (e.key == tab.fighting or (e.boss ~= OTHER and e.boss.group == tab.fighting))
    local name = (e.boss == OTHER and "Other loot" or e.boss.name)
    if fight then
      name = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12|t " .. name
    end
    H.PaintRow(r, name, CountText(e.sum), marks, e.key == v.sel)
    r.name:SetTextColor(empty and 0.5 or 1, empty and 0.5 or 1, empty and 0.5 or 1)
    r.pic:SetAlpha(empty and 0.5 or 1)
    y = H.Place(r, y, BOSS_H)
  end
  for _, e in ipairs(v.list) do
    Place(e)
  end
  if #v.rares > 0 then
    local h = sectionPool:Get()
    local allRare = true
    for _, e in ipairs(v.rares) do
      allRare = allRare and e.boss.rare
    end
    H.PaintSection(h, allRare and "Rares" or "Rares & optional", nil, RARE_ICON)
    y = H.Place(h, y + 4, 18)
    for _, e in ipairs(v.rares) do
      Place(e)
    end
  end
  if v.other then
    local h = sectionPool:Get()
    H.PaintSection(h, "Elsewhere in the dungeon")
    y = H.Place(h, y + 4, 18)
    Place(v.other)
  end
  listPool:Done()
  sectionPool:Done()

  local empty = #v.list == 0 and #v.rares == 0 and not v.other
  listEmpty:SetShown(empty)
  if empty then
    local text
    if not FLB() then
      text = "Bosses & Loot needs Forever Leveling BiS v1.3 or newer."
    elseif not H.shown then
      text = "Not in a dungeon. Pick one with the v button."
    else
      text = "DungeonJournal lists no bosses here."
    end
    y = H.Para(listEmpty, 6, width, text)
  end
  return y
end

local function MyNote(item, marks)
  if not item.loc then
    -- Non-gear (recipes...) says what it is instead: "Tailoring", "Reagent".
    local kind = item.kind
    if kind then
      kind = kind:match("^Recipe,%s*(.+)$") or kind:match("^([^,]+)")
    end
    return kind and ("|cff888888" .. kind .. "|r") or ""
  end
  for _, mk in ipairs(marks) do
    if mk.member.name == Me() then
      return (mk.bis and "|cffffd100BiS|r " or "") .. string.format("|cff66ff66+%.1f|r", mk.gain)
    end
  end
  return ""
end

function tab:RenderDetail(width)
  local v = view or View()
  local e = v.sel and v.byKey[v.sel]
  if not e then
    detail.portrait:Hide()
    detail.title:Hide()
    detail.sub:Hide()
    detail.items:Done()
    detail.legend:Hide()
    local y = H.Para(detail.note, 6, width, H.shown and FLB() and "Pick a boss on the left." or "")
    return y
  end
  detail.portrait:Show()
  detail.title:Show()
  detail.sub:Show()
  if e.boss == OTHER then
    detail.portrait:SetTexture(BAG)
    detail.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    detail.title:SetText("Other loot")
  else
    H.SetPortrait(detail.portrait, e.boss)
    detail.title:SetText(e.boss.name)
  end
  local ar, ag, ab = ARLE.Skin:Accent()
  detail.title:SetTextColor(ar, ag, ab)
  local sub = {}
  if e.boss ~= OTHER and e.boss.rare then
    sub[#sub + 1] = "Rare: may not spawn"
  elseif e.boss ~= OTHER and e.boss.optional then
    sub[#sub + 1] = "Optional: summoned or brought by a quest"
  end
  local gear = 0
  for _, item in ipairs(e.items) do
    if item.loc then
      gear = gear + 1
    end
  end
  sub[#sub + 1] = gear .. " gear drop(s)"
  local counts = CountText(e.sum)
  if counts ~= "" then
    sub[#sub + 1] = counts
  end
  detail.sub:SetText(table.concat(sub, "  ·  "))

  local y = BIG + 10
  local me = Me()
  for _, item in ipairs(e.sum.visible) do
    local r = detail.items:Get()
    local mk = v.marks[item.id] or {}
    r.item, r.marks = item, mk
    r.pic:SetTexture(GetItemIcon(item.id) or 134400)
    local marks, helpsMe = {}, false
    for _, m in ipairs(mk) do
      marks[#marks + 1] = { class = m.member.class, strong = m.bis }
      helpsMe = helpsMe or m.member.name == me
    end
    H.PaintRow(r, (GetItemInfo(item.id)) or item.name or ("item " .. item.id), MyNote(item, mk), marks, false)
    r.name:SetTextColor(H.QualityColor(item.quality))
    r.mine:SetShown(helpsMe)
    y = H.Place(r, y, ITEM_H, 0)
  end
  detail.items:Done()
  local hidden = #e.items - #e.sum.visible
  if hidden > 0 or #e.sum.visible == 0 then
    local text = #e.sum.visible == 0 and (#e.items == 0 and "No gear listed for this boss."
      or "Nothing here for " .. (v.filter == "mine" and "you" or "the party") .. ".")
      or (hidden .. " more hidden by the filter.")
    if hidden > 0 and #e.sum.visible == 0 then
      text = text .. " " .. hidden .. " drop(s) hidden by the filter: try All."
    end
    y = H.Para(detail.note, y + 4, width, text)
  else
    detail.note:Hide()
  end
  y = H.Para(detail.legend, y + 6, width, "Squares: ARL members in the party. |cffffd100Gold edge|r: BiS from "
    .. "this dungeon for that slot; plain: an upgrade. Green bar and number: what it gains you. Hover an item "
    .. "for everyone's numbers.")
  return y
end

function tab:Status()
  local n = 0
  for name, p in pairs(party) do
    if name ~= Me() and p.dungeon == H.shown then
      n = n + 1
    end
  end
  if not FLB() then
    return "Bosses & Loot off (needs Forever Leveling BiS)"
  end
  return "party: " .. n .. " ARL member(s) sharing loot"
end
