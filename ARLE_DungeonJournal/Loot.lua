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

local BOSS_H, ITEM_H, BIG = 38, 34, 50
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

-- Whether the player's own gains for a dungeon still wait for item data.
function tab.Loading(dungeon)
  return MyData(dungeon).loading
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

H.Comm("BG", function(sender, payload)
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

H.Comm("BE", function(sender, payload)
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

-- Why a member has no numbers for the shown dungeon, in a few words (the
-- tooltip's right column, short enough not to widen it). From what their ARL
-- said about itself (Core/Comm.lua "AP", 0.10.0+), else the version their ARL
-- announced to the guild (older ones share only with the Dungeon Helper on).
local NEW_SHARING = "0.10.0"
local function NoNumbers(m)
  if m.unit == "player" then
    return FLB() and "loading..." or "needs Leveling BiS"
  end
  local info = ARLE:PartyInfo(m.name)
  if info then
    if not info.flb then
      return "needs Leveling BiS"
    elseif not info.fdj then
      return "needs DungeonJournal"
    elseif not info.share then
      return "sharing off"
    end
    return (H.askedAt and GetTime() - H.askedAt < 10) and "asking..." or "no answer, /reload"
  end
  local known = ARLE.KnownVersion and ARLE.KnownVersion(m.name)
  if known and ARLE.CompareVersions and ARLE.CompareVersions(known, NEW_SHARING) < 0 then
    return "old ARL v" .. known
  end
  return "no ARL"
end
tab.NoNumbers = NoNumbers

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
  H.Picked()
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
  local rank = GQRank(row.item)
  if rank then
    GameTooltip:AddDoubleLine("GearQuest", rank == 1 and "|cffffd100its best for you|r" or ("#" .. rank .. " for you"),
      0.3, 0.76, 1, 1, 1, 1)
  elseif H.GQ() then
    GameTooltip:AddDoubleLine("GearQuest", "not in its list for you", 0.3, 0.76, 1, 0.6, 0.6, 0.6)
  end
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
      GameTooltip:AddDoubleLine(ColorName(m), NoNumbers(m), 1, 1, 1, 0.5, 0.5, 0.5)
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
    else
      GameTooltip:AddDoubleLine(ColorName(m), NoNumbers(m), 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("ARL members with Leveling BiS share their numbers.", 0.8, 0.8, 0.8)
  if H.GQ() then
    GameTooltip:AddLine("|cff4dc3ffGQ #1|r: GearQuest's pick for you (#1 = its best for the slot)", 0.8, 0.8, 0.8)
  elseif not FLB() then
    GameTooltip:AddLine("No BiS numbers: install Forever Leveling BiS or GearQuest Forever.", 1, 0.5, 0.4, true)
  end
  GameTooltip:AddLine("|cffffd100Gold-edged class icon|r: BiS from this dungeon for that slot", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Plain class icon: an upgrade", 0.8, 0.8, 0.8)
  GameTooltip:AddLine(H.Inline(H.ICON.star) .. " and |cff66ff66+12.3|r on a drop: what it gains you", 0.8, 0.8, 0.8)
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
--   [face] Kirtonos the Herald         [c][c]
--          *2  +1  · 6 drops
-------------------------------------------------------------------------------

local listPool, sectionPool, listEmpty
local detail = {}
local STAR = H.Inline(H.ICON.star, 12)

-- What a boss's drops hold for the filter: visible items, BiS and upgrade
-- counts, and the members it has something for (strong: BiS for them).
-- GearQuest's rank of a drop for the player (1 = its best), or nil.
local function GQRank(item)
  return item.loc and H.GQRank(item.id, item.loc) or nil
end

local function Summary(items, marks, filter)
  local me = Me()
  local visible, bis, ups, who, order = {}, 0, 0, {}, {}
  local myBis, myUps, gq, gqBis, myAny = 0, 0, 0, 0, 0
  for _, item in ipairs(items) do
    local mk = marks[item.id] or {}
    local rank = GQRank(item)
    local mine = rank ~= nil
    local mineBis = rank == 1
    if rank then
      gq = gq + 1
      gqBis = gqBis + (rank == 1 and 1 or 0)
    end
    for _, m in ipairs(mk) do
      if m.bis then
        bis = bis + 1
      else
        ups = ups + 1
      end
      if m.member.name == me then
        mine = true
        mineBis = mineBis or m.bis
        if m.bis then
          myBis = myBis + 1
        else
          myUps = myUps + 1
        end
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
    if mineBis then
      myAny = myAny + 1
    end
    if filter == "all" or (filter == "party" and (#mk > 0 or rank)) or (filter == "mine" and mine) then
      visible[#visible + 1] = item
    end
  end
  return { visible = visible, bis = bis, ups = ups, who = order, myBis = myBis, myUps = myUps, gq = gq,
    gqBis = gqBis, myAny = myAny }
end

-- "*2  +1  · 6 drops": BiS (a star), upgrades (green), the drops.
local function CountText(sum, drops)
  local parts = {}
  if sum.bis > 0 then
    parts[#parts + 1] = STAR .. "|cffffd100" .. sum.bis .. "|r"
  end
  if sum.ups > 0 then
    parts[#parts + 1] = "|cff66ff66+" .. sum.ups .. "|r"
  end
  if sum.gq and sum.gq > 0 then
    parts[#parts + 1] = "|cff4dc3ffGQ " .. (sum.gqBis > 0 and (sum.gqBis .. "/") or "") .. sum.gq .. "|r"
  end
  if drops then
    parts[#parts + 1] = "|cff888888" .. drops .. (drops == 1 and " drop" or " drops") .. "|r"
  end
  return table.concat(parts, "  ")
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

local function GearCount(items)
  local n = 0
  for _, item in ipairs(items) do
    if item.loc then
      n = n + 1
    end
  end
  return n
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

-- Killed in the run in progress (Clear Times keeps it).
local function Killed(e)
  if e.boss == OTHER then
    return false
  end
  local times = H.byKey and H.byKey.times
  return times and times.IsKilled and times:IsKilled(H.shown, e.boss.group or e.boss.name) or false
end

local function Fighting(e)
  return tab.fighting ~= nil and e.boss ~= OTHER and (e.key == tab.fighting or e.boss.group == tab.fighting)
end

local function LinkItem(id)
  if IsModifiedClick and IsModifiedClick("CHATLINK") then
    local _, link = GetItemInfo(id)
    if link and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
    end
  end
end

function tab:Create(bar, list, detailFrame)
  self.filters = H.FilterButtons(bar, {
    { key = "all", label = "All", tip = "Every gear drop" },
    { key = "party", label = "Party", tip = "Drops that are BiS or an upgrade for an ARL member in the party" },
    { key = "mine", label = "Mine", tip = "Drops that are BiS or an upgrade for you" },
  }, Filter, function(key)
    mod.db.filter = key
  end)
  self.party = H.PartyStrip(bar)
  self.party:SetPoint("RIGHT", 0, 0)
  S(self.party, "OnEnter", PartyTooltip)
  S(self.party, "OnLeave", GameTooltip_Hide)

  self.listFrame = list
  listPool = H.Pool(function()
    local r = H.Row(list, BOSS_H, BOSS_H - 6)
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
  listEmpty = H.Empty(list)

  -- Details: a banner (portrait, name, tags) over the drops.
  detail.frame = detailFrame
  detail.banner = H.Banner(detailFrame, BIG)
  detail.items = H.Pool(function()
    local r = H.Row(detailFrame, ITEM_H, ITEM_H - 4)
    r.mine = r:CreateTexture(nil, "ARTWORK")
    r.mine:SetWidth(2)
    r.mine:SetPoint("TOPLEFT", 1, -2)
    r.mine:SetPoint("BOTTOMLEFT", 1, 2)
    r.mine:SetColorTexture(0.3, 1, 0.4, 0.9)
    S(r, "OnEnter", ItemTooltip)
    S(r, "OnLeave", GameTooltip_Hide)
    S(r, "OnClick", function(row)
      LinkItem(row.item.id)
    end)
    return r
  end)
  detail.note = H.Empty(detailFrame)
  detail.hint = Kit.Text(detailFrame, "GameFontDisableSmall")
end

-- What the list and the details both need, worked out once per render.
local view
local function View()
  local members = Members()
  local marks = (H.shown and FLB()) and Marks(H.shown, members) or {}
  local filter = Filter()
  local list, rares, other = {}, {}, nil
  if H.shown then
    list, rares, other = Entries(marks, filter)
  end
  local byKey = {}
  local myBis = 0
  for _, group in ipairs({ list, rares, other and { other } or {} }) do
    for _, e in ipairs(group) do
      byKey[e.key] = e
      myBis = myBis + e.sum.myAny
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
    byKey = byKey, sel = sel, myBis = myBis, shown = H.shown }
  return view
end

-- The tab's count: BiS drops for you in this dungeon.
function tab:Badge()
  local v = View()
  if v.myBis > 0 then
    return tostring(v.myBis), H.GOLD, H.ICON.star
  end
end

function tab:RenderList(width)
  self.filters.Paint()
  local v = View()
  H.PaintPartyStrip(self.party, v.members, function(m)
    local p = party[m.name]
    return p and p.dungeon == H.shown
  end)

  local y = 2
  local function Place(e)
    local r = listPool:Get()
    r.key, r.boss = e.key, e.boss
    r.who = WhoLines(e.sum)
    if e.boss == OTHER then
      H.SetIcon(r.pic, BAG)
      r.portraitOf = nil
    elseif r.portraitOf ~= e.boss then
      r.portraitOf = e.boss -- (SetPortrait is slow-ish: only when the row shows another boss)
      r.pic.tex:SetDesaturated(false)
      H.SetPortrait(r.pic.tex, e.boss)
    end
    local marks = {}
    for _, w in ipairs(e.sum.who) do
      marks[#marks + 1] = { class = w.class, strong = w.strong }
    end
    local killed, fight = Killed(e), Fighting(e)
    local sub = CountText(e.sum, #e.items)
    if fight then
      sub = "|cffff5040fighting|r  " .. sub
    end
    H.PaintRow(r, {
      name = e.boss == OTHER and "Other loot" or e.boss.name,
      sub = sub,
      marks = marks,
      selected = e.key == v.sel,
      dim = #e.sum.visible == 0,
      tint = fight and { 1, 0.2, 0.1, 0.12 } or nil,
    })
    local ar, ag, ab = ARLE.Skin:Accent()
    H.SetEdge(r.pic, ar, ag, ab, e.key == v.sel and 0.9 or 0.3)
    H.SetCorner(r.pic, (fight and H.ICON.skull) or (killed and H.ICON.ready) or nil)
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
    y = H.Place(h, y + 6, 20, 2)
    for _, e in ipairs(v.rares) do
      Place(e)
    end
  end
  if v.other then
    local h = sectionPool:Get()
    H.PaintSection(h, "Around the dungeon")
    y = H.Place(h, y + 6, 20, 2)
    Place(v.other)
  end
  listPool:Done()
  sectionPool:Done()

  if #v.list == 0 and #v.rares == 0 and not v.other then
    local text
    if not H.shown then
      text = "Not in a dungeon"
    else
      text = "No bosses listed here"
    end
    y = H.ShowEmpty(listEmpty, 8, width, text, SKULL)
  else
    listEmpty:Hide()
  end
  return y
end

-- "Head · Cloth", "Trinket", or what a non-gear drop is ("Tailoring").
local function SlotText(item)
  if not item.loc then
    local kind = item.kind
    if kind then
      kind = kind:match("^Recipe,%s*(.+)$") or kind:match("^([^,]+)")
    end
    return kind or ""
  end
  local slot = _G[item.loc]
  local _, _, subType, _, _, classID = H.GetItemInstant(item.id)
  local parts = {}
  if type(slot) == "string" and slot ~= "" then
    parts[#parts + 1] = slot
  end
  if type(subType) == "string" and subType ~= "" and subType ~= "Miscellaneous" and subType ~= slot
      and (classID == 2 or classID == 4) then
    parts[#parts + 1] = subType
  end
  return table.concat(parts, " · ")
end

-- Your own gain from an item: note (green "+12.4"), noteSub ("best in slot"), bis.
local function MyGain(marks)
  for _, mk in ipairs(marks) do
    if mk.member.name == Me() then
      return string.format("|cff66ff66+%.1f|r", mk.gain), mk.bis and "|cffffd100best in slot|r" or "upgrade", mk.bis
    end
  end
end

function tab:RenderDetail(width)
  local v = view or View()
  local e = v.sel and v.byKey[v.sel]
  local b = detail.banner
  if not e then
    b:Hide()
    detail.items:Done()
    detail.hint:Hide()
    if H.shown then
      return H.ShowEmpty(detail.note, 20, width, "Pick a boss", SKULL)
    end
    detail.note:Hide()
    return 1
  end

  -- Banner: portrait, name, and tags.
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", 0, 0)
  b:SetWidth(width)
  if e.boss == OTHER then
    H.SetIcon(b.pic, BAG)
  else
    b.pic.tex:SetDesaturated(false)
    H.SetPortrait(b.pic.tex, e.boss)
  end
  local ar, ag, ab = ARLE.Skin:Accent()
  H.SetEdge(b.pic, ar, ag, ab, 0.8)
  local tags = {}
  local fight, killed = Fighting(e), Killed(e)
  if fight then
    tags[#tags + 1] = { text = "Fighting", color = { 1, 0.35, 0.25 }, icon = H.ICON.skull }
  elseif killed then
    tags[#tags + 1] = { text = "Killed", color = H.GREEN, icon = H.ICON.ready,
      tip = { "Killed", "Down in this run (Clear Times)." } }
  end
  if e.boss ~= OTHER and e.boss.rare then
    tags[#tags + 1] = { text = "Rare", color = { 0.75, 0.8, 0.9 }, tip = { "Rare", "May not spawn in every run." } }
  elseif e.boss ~= OTHER and e.boss.optional then
    tags[#tags + 1] = { text = "Optional", color = { 0.75, 0.8, 0.9 },
      tip = { "Optional", "Summoned, or brought by a quest: a clear doesn't need it." } }
  end
  local gear = GearCount(e.items)
  tags[#tags + 1] = { text = gear .. (gear == 1 and " drop" or " drops"), color = H.GREY }
  if e.sum.bis > 0 then
    tags[#tags + 1] = { text = e.sum.bis .. " BiS", color = H.GOLD, icon = H.ICON.star,
      tip = { "Best in slot", "Drops that are the best this dungeon has for that slot, for someone in the party." } }
  end
  if e.sum.gq > 0 then
    tags[#tags + 1] = { text = "GQ " .. e.sum.gq, color = { 0.3, 0.76, 1 },
      tip = { "GearQuest", "Drops in GearQuest's top list for your character (" .. e.sum.gqBis .. " its best for "
        .. "the slot)." } }
  end
  if e.sum.ups > 0 then
    tags[#tags + 1] = { text = "+" .. e.sum.ups .. " upgrade" .. (e.sum.ups == 1 and "" or "s"), color = H.GREEN,
      tip = { "Upgrades", "Drops that gain someone in the party something, but aren't their best here." } }
  end
  H.PaintBanner(b, e.boss == OTHER and "Other loot" or e.boss.name, nil, tags)
  b.pic:SetAlpha(1)

  local y = H.BANNER_H + 6
  local me = Me()
  for _, item in ipairs(e.sum.visible) do
    local r = detail.items:Get()
    local mk = v.marks[item.id] or {}
    r.item, r.marks = item, mk
    H.SetItemPic(r.pic, item.id, item.quality)
    local marks, helpsMe = {}, false
    for _, m in ipairs(mk) do
      if m.member.name ~= me then
        marks[#marks + 1] = { class = m.member.class, strong = m.bis }
      end
      helpsMe = helpsMe or m.member.name == me
    end
    local note, noteSub, mineBis = MyGain(mk)
    local rank = GQRank(item)
    if rank then
      helpsMe = true
      if note then
        noteSub = (noteSub or "") .. "  |cff4dc3ffGQ #" .. rank .. "|r"
      else
        note = "|cff4dc3ffGQ #" .. rank .. "|r"
        noteSub = rank == 1 and "|cffffd100GearQuest's best|r" or "GearQuest pick"
      end
      mineBis = mineBis or rank == 1
    end
    local sub = SlotText(item)
    if item.sources and #item.sources > 0 then
      sub = (sub ~= "" and (sub .. "  ·  ") or "") .. item.sources[1] .. (#item.sources > 1 and " +" .. (#item.sources - 1) or "")
    end
    local qr, qg, qb = H.QualityColor(item.quality)
    H.PaintRow(r, {
      name = (GetItemInfo(item.id)) or item.name or ("item " .. item.id),
      sub = sub,
      note = note,
      noteSub = noteSub,
      marks = marks,
      color = { qr, qg, qb },
      tint = helpsMe and { 0.3, 1, 0.4, 0.05 } or nil,
    })
    H.SetCorner(r.pic, mineBis and H.ICON.star or nil)
    r.mine:SetShown(helpsMe)
    y = H.Place(r, y, ITEM_H, 2)
  end
  detail.items:Done()

  local hidden = #e.items - #e.sum.visible
  if #e.sum.visible == 0 then
    local text = #e.items == 0 and "No gear listed"
      or ("Nothing for " .. (v.filter == "mine" and "you" or "the party") .. " here")
    if hidden > 0 then
      text = text .. "\n|cff888888" .. hidden .. " more under All|r"
    end
    y = H.ShowEmpty(detail.note, y + 4, width, text, BAG)
    detail.hint:Hide()
  elseif hidden > 0 then
    detail.note:Hide()
    y = H.Para(detail.hint, y + 4, width, hidden .. " more under All")
  else
    detail.note:Hide()
    detail.hint:Hide()
  end
  return y + 4
end

-- For the dungeon picker: how many of a dungeon's drops are upgrades for
-- you (Forever Leveling BiS gain, or in GearQuest's list), and how many of
-- those are the best (GearQuest's #1, or FLB's biggest gain for the slot in
-- that dungeon). Worked out once per dungeon until gear or level changes.
local forMe = {}
function tab.ForMe(dungeon)
  local c = forMe[dungeon]
  if c and c.gen == H.gearGen then
    return c.ups, c.bis
  end
  local api = FLB()
  local best, gains = {}, {}
  local ups, bis = 0, 0
  local items = H.GearItems(dungeon)
  for _, item in ipairs(items) do
    local gain = 0
    if api and api.GetGain then
      local ok, g, loading = pcall(api.GetGain, item.id)
      gain = ok and not loading and tonumber(g) or 0
    end
    gains[item.id] = gain
    local slot = SLOT_OF[item.loc] or item.loc
    if gain > (best[slot] or 0) then
      best[slot] = gain
    end
  end
  for _, item in ipairs(items) do
    local rank = item.loc and H.GQRank(item.id, item.loc)
    local gain = gains[item.id]
    if gain > 0 or rank then
      ups = ups + 1
      local slot = SLOT_OF[item.loc] or item.loc
      if rank == 1 or (gain > 0 and gain >= (best[slot] or math.huge)) then
        bis = bis + 1
      end
    end
  end
  forMe[dungeon] = { gen = H.gearGen, ups = ups, bis = bis }
  return ups, bis
end

function tab:Status()
  local n = 0
  for name, p in pairs(party) do
    if name ~= Me() and p.dungeon == H.shown then
      n = n + 1
    end
  end
  local sources = {}
  if FLB() then
    sources[#sources + 1] = "Leveling BiS"
  end
  if H.GQ() then
    sources[#sources + 1] = "GearQuest"
  end
  return (#sources > 0 and ("BiS from " .. table.concat(sources, " + ")) or "no BiS addon (drops only)")
    .. ", party: " .. n .. " ARL member(s) sharing loot"
end
