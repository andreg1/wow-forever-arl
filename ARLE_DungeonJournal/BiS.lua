-- Dungeon Helper, BiS Finder tab: the dungeon's bosses and their drops,
-- marking which drops are BiS or upgrades for each party member.
--
-- Forever Leveling BiS can only score items for the player it runs for, so
-- every party member's own copy of this module scores the dungeon's drops and
-- shares the results (and their equipped item IDs) over addon messages.
-- "BiS" for a member = the biggest upgrade this dungeon has for that slot;
-- any other drop that gains them something is an "upgrade".
--
-- Members without the addon (pugs included) are inspected instead, and their
-- gains estimated from their gear, class, level and a spec picked for them in
-- the window (Estimate.lua). Exact numbers from a member's own addon always
-- replace an estimate.
local _, ns = ...
local ARLE = _G.ARLExtensions
local H = ns.H
if not ARLE or not H then
  return
end
local mod = H.mod
local Bosses, FLB, Members, Me = H.Bosses, H.FLB, H.Members, H.Me
local ClassColor, ColorName, TooltipSide = H.ClassColor, H.ColorName, H.TooltipSide
local GetItemInfo, GetItemIcon = H.GetItemInfo, H.GetItemIcon

local BOSS_H, ITEM_H = 18, 16

local tab = { key = "bis", label = "BiS Finder" }
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
-- a member "loading" forever: after this many refreshes it counts as done.
local MAX_TRIES = 15

-- Carries the refresh count of a record that was still loading.
local function CountTries(data, old, dungeon)
  if not data.loading then
    return
  end
  data.tries = ((old and old.dungeon == dungeon and old.tries) or 0) + 1
  if data.tries > MAX_TRIES then
    data.loading = false
    data.gaveUp = true
  end
end

local function RefreshMine()
  if H.shown and FLB() then
    local data = MyData(H.shown)
    CountTries(data, party[Me()], H.shown)
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

-------------------------------------------------------------------------------
-- Estimates for members without the addon: inspect, then Estimate.lua
-------------------------------------------------------------------------------

local Estimate = ns.Estimate
local INSPECT_TIMEOUT, INSPECT_GAP, INSPECT_DELAY, INSPECT_STALE = 4, 1.2, 3, 120
local inspected = {}  -- name -> { worn = { slot = link }, level, at }
local inspectQueue = {}
local inspecting      -- the inspect waiting for INSPECT_READY

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

local function Specs(class)
  local api = FLB()
  local list = api and api.GetSpecs and api.GetSpecs(class)
  return type(list) == "table" and list or {}
end
tab.Specs = Specs

-- The spec picked for a player in the window, else the class's first spec.
local function SpecFor(name, class)
  if type(mod.db.specs) ~= "table" then
    mod.db.specs = {}
  end
  local picked = mod.db.specs[name]
  for _, spec in ipairs(Specs(class)) do
    if spec == picked then
      return spec, true
    end
  end
  return Specs(class)[1], false
end

local function AllItems(dungeon)
  return H.GearItems(dungeon)
end

-- (Re)computes a member's estimate for the shown dungeon. Exact data wins.
local function EstimateMember(m)
  local info = inspected[m.name]
  local p = party[m.name]
  if not info or not H.shown or not FLB() or (p and not p.estimated) then
    return
  end
  local spec, picked = SpecFor(m.name, m.class)
  local member = { class = m.class, level = info.level, spec = spec, worn = info.worn }
  local gains, loading = Estimate.Gains(member, AllItems(H.shown), FLB())
  local worn = {}
  for slot, link in pairs(info.worn) do
    worn[slot] = tonumber(tostring(link):match("item:(%d+)"))
  end
  local data = {
    gains = gains, worn = worn, dungeon = H.shown, class = m.class, spec = spec,
    estimated = true, specPicked = picked, loading = loading,
  }
  CountTries(data, p, H.shown)
  party[m.name] = data
end

local function EstimateAll()
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" then
      EstimateMember(m)
    end
  end
end

local function NeedsInspect(m)
  if m.unit == "player" or not FLB() then
    return false
  end
  local p = party[m.name]
  if p and not p.estimated and p.dungeon == H.shown then
    return false -- exact numbers from their addon
  end
  local info = inspected[m.name]
  return not info or GetTime() - info.at > INSPECT_STALE
end

local function UserInspecting()
  return InspectFrame and InspectFrame:IsShown()
end

local InspectNext
local function FinishInspect()
  inspecting = nil
  C_Timer.After(INSPECT_GAP, function()
    InspectNext()
  end)
end

-- One inspect at a time, out of combat, never over the player's own inspect.
function InspectNext()
  if inspecting or not mod._active or not NotifyInspect then
    return
  end
  while inspectQueue[1] do
    local m = table.remove(inspectQueue, 1)
    if not InCombatLockdown() and not UserInspecting() and UnitExists(m.unit)
        and (not CanInspect or CanInspect(m.unit)) and NeedsInspect(m) then
      local token = { name = m.name, unit = m.unit, class = m.class, guid = UnitGUID(m.unit) }
      inspecting = token
      NotifyInspect(m.unit)
      C_Timer.After(INSPECT_TIMEOUT, function()
        if inspecting == token then
          if not UserInspecting() and ClearInspectPlayer then
            ClearInspectPlayer()
          end
          FinishInspect()
        end
      end)
      return
    end
  end
end

function tab:OnInspectReady(guid)
  local i = inspecting
  if not i or guid ~= i.guid then
    return
  end
  local worn = {}
  for slot = 1, 19 do
    worn[slot] = GetInventoryItemLink(i.unit, slot)
  end
  inspected[i.name] = { worn = worn, level = UnitLevel(i.unit), at = GetTime() }
  if not UserInspecting() and ClearInspectPlayer then
    ClearInspectPlayer()
  end
  EstimateMember(i)
  FinishInspect()
  H.Render()
end

local function QueueInspects()
  wipe(inspectQueue)
  for _, m in ipairs(Members()) do
    if NeedsInspect(m) then
      inspectQueue[#inspectQueue + 1] = m
    end
  end
  InspectNext()
end
tab.QueueInspects = QueueInspects

-- After asking the group, give members with the addon a moment to answer
-- before inspecting the rest.
local inspectTimer = false
local function QueueInspectsSoon()
  if inspectTimer then
    return
  end
  inspectTimer = true
  C_Timer.After(INSPECT_DELAY, function()
    inspectTimer = false
    if mod._active then
      EstimateAll()
      QueueInspects()
    end
  end)
end

function tab:OnRequest()
  EstimateAll() -- members already inspected, for the newly shown dungeon
  QueueInspectsSoon()
end

-- Whether item data that arrives could change anything: the player's own
-- gains (always: they are sent to the party), estimates only while the
-- window shows them.
function tab:WantsItemInfo(windowShown)
  local mine = party[Me()]
  if mine and mine.loading and mine.dungeon == H.shown then
    return true
  end
  if windowShown then
    for _, p in pairs(party) do
      if p.estimated and p.loading then
        return true
      end
    end
  end
  return false
end

-- Item stats the player's own gains or an estimate were waiting for may
-- have arrived.
function tab:OnItemInfo(windowShown)
  local mine = party[Me()]
  if mine and mine.loading and mine.dungeon == H.shown then
    RefreshMine()
    if party[Me()] and not party[Me()].loading then
      H.QueueSend(H.shown, "bis") -- the full numbers, now that they are known
    end
  end
  if windowShown then
    for _, p in pairs(party) do
      if p.estimated and p.loading then
        EstimateAll()
        return
      end
    end
  end
end

local function SetSpec(name, spec)
  if type(mod.db.specs) ~= "table" then
    mod.db.specs = {}
  end
  mod.db.specs[name] = spec
  for _, m in ipairs(Members()) do
    if m.name == name then
      EstimateMember(m)
    end
  end
  H.Render()
end

-- /arl bis spec <name> <spec>
function tab:SpecCommand(who, spec)
  for _, m in ipairs(Members()) do
    if m.name:lower() == who:lower() then
      for _, key in ipairs(Specs(m.class)) do
        if key == spec then
          SetSpec(m.name, key)
          ARLE:Print(m.name .. " is scored as " .. SpecLabel(key) .. ".")
          return
        end
      end
      ARLE:Print("Specs for " .. m.name .. ": " .. table.concat(Specs(m.class), ", "))
      return
    end
  end
  ARLE:Print("No party member called " .. who .. ".")
end

function tab:Prune(keep)
  for name in pairs(party) do
    if not keep[name] then
      party[name] = nil
    end
  end
  for name in pairs(inspected) do
    if not keep[name] then
      inspected[name] = nil
    end
  end
end

function tab:Reset()
  wipe(party)
  wipe(lastSent)
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

-- BiS/upgrade marks per item: marks[itemID] = { {member, gain, bis}, ... }
local function Marks(dungeon, members)
  local best = {} -- member -> slot -> best gain
  local marks = {}
  for _, m in ipairs(members) do
    local p = party[m.name]
    if p and p.dungeon == dungeon then
      best[m.name] = {}
      for _, item in ipairs(H.GearItems(dungeon)) do
        local g = p.gains[item.id]
        local slot = SLOT_OF[item.loc] or item.loc
        if g and g > 0 and g > (best[m.name][slot] or 0) then
          best[m.name][slot] = g
        end
      end
    end
  end
  for _, item in ipairs(H.GearItems(dungeon)) do
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
-- View: boss headers and one-line item rows. Each item row is icon + name +
-- one small square per member it helps: class coloured, with a gold edge for
-- BiS, faded for an upgrade. Hover a row for the numbers.
-------------------------------------------------------------------------------

local child, emptyText
local headers, rows = {}, {}
local FILTERS = {
  { key = "all", label = "All", tip = "Every gear drop" },
  { key = "party", label = "Party", tip = "Drops that are BiS or an upgrade for someone in the party" },
  { key = "mine", label = "Mine", tip = "Drops that are BiS or an upgrade for you" },
}

local function Filter()
  return mod.db.filter or "all"
end

local function Collapsed()
  local db = mod.db
  if type(db.collapsed) ~= "table" then
    db.collapsed = {}
  end
  db.collapsed[H.shown or ""] = db.collapsed[H.shown or ""] or {}
  return db.collapsed[H.shown or ""]
end

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
  for _, m in ipairs(row.members) do
    local p = party[m.name]
    if p and p.dungeon == H.shown then
      local mark
      for _, mk in ipairs(row.marks) do
        if mk.member.name == m.name then
          mark = mk
        end
      end
      local est = p.estimated and ("  |cffff9933est. " .. SpecLabel(p.spec) .. "|r") or ""
      if mark then
        GameTooltip:AddDoubleLine(ColorName(m) .. (mark.bis and "  |cffffd100BiS|r" or "  upgrade") .. est,
          string.format(p.estimated and "~+%.1f" or "+%.1f", mark.gain), 1, 1, 1, 0.4, 1, 0.4)
      else
        GameTooltip:AddDoubleLine(ColorName(m) .. est, "no gain", 1, 1, 1, 0.6, 0.6, 0.6)
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
      GameTooltip:AddDoubleLine(ColorName(m), (inspecting and inspecting.name == m.name) and "inspecting..."
        or "no data (out of inspect range?)", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:Show()
end

local function PartyTooltip(owner)
  GameTooltip:SetOwner(owner, TooltipSide(owner))
  GameTooltip:SetText("Party", 1, 1, 1)
  for _, m in ipairs(Members()) do
    local p = party[m.name]
    if p and p.dungeon == H.shown and p.estimated then
      GameTooltip:AddDoubleLine(ColorName(m), "estimated: " .. SpecLabel(p.spec) .. (p.specPicked and "" or " (guess)"),
        1, 1, 1, 1, 0.6, 0.2)
    elseif p and p.dungeon == H.shown then
      GameTooltip:AddDoubleLine(ColorName(m), SpecLabel(p.spec) .. " (exact)", 1, 1, 1, 0.45, 0.9, 0.5)
    else
      GameTooltip:AddDoubleLine(ColorName(m), (inspecting and inspecting.name == m.name) and "inspecting..."
        or "no data yet (inspect range)", 1, 1, 1, 0.5, 0.5, 0.5)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Exact: scored by their own addon. Estimated: from inspecting their gear.", 0.8, 0.8, 0.8, true)
  GameTooltip:AddLine("|cffffd100Click|r to set the spec of estimated members.", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cffffd100Gold-edged square|r: BiS from this dungeon for that slot", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Faded square: an upgrade", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Green bar: helps you", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Click a boss to fold it, right-click to show only that boss.", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end

-- The Other loot section's key in the folded-sections table.
local OTHER = "@other"

-- bossName may be a fight (the Ring of Law): each of its bosses unfolds.
local function Solo(bossName)
  local collapsed = Collapsed()
  for _, boss in ipairs(H.shown and Bosses(H.shown) or {}) do
    collapsed[boss.name] = not (boss.name == bossName or (boss.group ~= nil and boss.group == bossName)) or nil
  end
  collapsed[OTHER] = bossName ~= OTHER or nil
end

-- Unfolds only the boss being fought or killed, whatever the player had
-- folded. Non-secure frames, so this works in combat.
function tab:Focus(bossName)
  Solo(bossName)
  self.focus = bossName
end

local function Header(i)
  local h = headers[i]
  if h then
    return h
  end
  h = CreateFrame("Button", nil, child)
  h:SetHeight(BOSS_H)
  h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  h.bg = h:CreateTexture(nil, "BACKGROUND")
  h.bg:SetAllPoints()
  h.toggle = ARLE.UIKit.Text(h, "GameFontNormalSmall")
  h.toggle:SetPoint("LEFT", 4, 0)
  h.toggle:SetWidth(10)
  h.count = ARLE.UIKit.Text(h, "GameFontHighlightSmall")
  h.count:SetPoint("RIGHT", -4, 0)
  h.count:SetJustifyH("RIGHT")
  -- Rare mobs get the game's silver "rare" dragon before their name.
  h.rare = h:CreateTexture(nil, "ARTWORK")
  h.rare:SetSize(14, 14)
  h.rare:SetPoint("LEFT", h.toggle, "RIGHT", 1, 0)
  if not (h.rare.SetAtlas and pcall(h.rare.SetAtlas, h.rare, "nameplates-icon-elite-silver")) then
    h.rare:SetTexture("Interface\\Tooltips\\EliteNameplateIcon")
    h.rare:SetDesaturated(true)
  end
  h.label = ARLE.UIKit.Text(h, "GameFontNormalSmall")
  h.label:SetPoint("RIGHT", h.count, "LEFT", -4, 0)
  h.label:SetWordWrap(false)
  h:SetScript("OnEnter", function(self)
    if self.boss == OTHER then
      H.SimpleTooltip(self, "Other loot", "Drops from the dungeon's mobs, chests and other spawns, and every recipe "
        .. "found in the dungeon (from bosses too). Hover an item to see what drops it. Gear here counts for BiS "
        .. "and upgrades like the bosses' gear.")
    elseif self.isRare then
      H.SimpleTooltip(self, self.boss, "Rare: may not spawn in every run.")
    end
  end)
  h:SetScript("OnLeave", GameTooltip_Hide)
  h:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      Solo(self.boss)
    else
      local collapsed = Collapsed()
      collapsed[self.boss] = not collapsed[self.boss] or nil
    end
    H.Render()
  end)
  headers[i] = h
  return h
end

local MARK = 8
local MAX_MARKS = 5

local function Row(i)
  local r = rows[i]
  if r then
    return r
  end
  r = CreateFrame("Button", nil, child)
  r:SetHeight(ITEM_H)
  r.mine = r:CreateTexture(nil, "ARTWORK")
  r.mine:SetWidth(2)
  r.mine:SetPoint("TOPLEFT", 1, -1)
  r.mine:SetPoint("BOTTOMLEFT", 1, 1)
  r.mine:SetColorTexture(0.3, 1, 0.4, 0.9)
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(ITEM_H - 2, ITEM_H - 2)
  r.icon:SetPoint("LEFT", 6, 0)
  r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  r.name = ARLE.UIKit.Text(r, "GameFontHighlightSmall")
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
  r.name:SetWordWrap(false)
  r.note = ARLE.UIKit.Text(r, "GameFontDisableSmall")
  r.note:SetPoint("RIGHT", -4, 0)
  r.note:SetJustifyH("RIGHT")
  r.squares = {}
  for k = 1, MAX_MARKS do
    local edge = r:CreateTexture(nil, "ARTWORK")
    edge:SetSize(MARK + 2, MARK + 2)
    edge:SetPoint("RIGHT", -(4 + (k - 1) * (MARK + 4)), 0)
    edge:SetColorTexture(1, 0.82, 0, 1)
    local fill = r:CreateTexture(nil, "OVERLAY")
    fill:SetSize(MARK, MARK)
    fill:SetPoint("CENTER", edge, "CENTER")
    r.squares[k] = { edge = edge, fill = fill }
  end
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.07)
  r:SetScript("OnEnter", ItemTooltip)
  r:SetScript("OnLeave", GameTooltip_Hide)
  r:SetScript("OnClick", function(self)
    if IsModifiedClick and IsModifiedClick("CHATLINK") then
      local _, link = GetItemInfo(self.item.id)
      if link then
        ChatEdit_InsertLink(link)
      end
    end
  end)
  rows[i] = r
  return r
end

local function PaintRow(r, item, marks, members)
  r.item, r.marks, r.members = item, marks, members
  r.icon:SetTexture(GetItemIcon(item.id) or 134400)
  r.name:SetText((GetItemInfo(item.id)) or item.name or ("item " .. item.id))
  r.name:SetTextColor(H.QualityColor(item.quality))
  local me, n = Me(), math.min(#marks, MAX_MARKS)
  local helpsMe = false
  for k = 1, MAX_MARKS do
    local sq, mk = r.squares[k], marks[k]
    if mk and k <= n then
      local cr, cg, cb = ClassColor(mk.member.class)
      sq.fill:SetColorTexture(cr, cg, cb, 1)
      sq.fill:SetAlpha(mk.bis and 1 or 0.45)
      sq.fill:Show()
      sq.edge:SetShown(mk.bis)
    else
      sq.fill:Hide()
      sq.edge:Hide()
    end
    if mk and mk.member.name == me then
      helpsMe = true
    end
  end
  r.mine:SetShown(helpsMe)
  -- Non-gear (recipes...) says what it is instead: "Tailoring", "Reagent".
  local kind = not item.loc and item.kind
  if kind then
    kind = kind:match("^Recipe,%s*(.+)$") or kind:match("^([^,]+)")
  end
  r.note:SetText(kind or "")
  r.note:SetShown(kind ~= nil)
  r.name:ClearAllPoints()
  r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
  if kind then
    r.name:SetPoint("RIGHT", r.note, "LEFT", -4, 0)
  else
    r.name:SetPoint("RIGHT", r, "RIGHT", -(6 + n * (MARK + 4)), 0)
  end
end

-- Party label click: a spec for each member whose numbers are estimated.
local function SpecMenu(owner)
  local list = {}
  for _, m in ipairs(Members()) do
    if m.unit ~= "player" and (inspected[m.name] or (party[m.name] and party[m.name].estimated)) then
      list[#list + 1] = m
    end
  end
  if #list == 0 then
    ARLE:Print("Nobody's numbers are estimated: everyone in the party with data sends exact ones.")
    return
  end
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, function(_, root)
      root:CreateTitle("Spec of estimated members")
      for _, m in ipairs(list) do
        local current = SpecFor(m.name, m.class)
        local sub = root:CreateButton(ColorName(m) .. "  |cff999999" .. SpecLabel(current) .. "|r")
        for _, spec in ipairs(Specs(m.class)) do
          sub:CreateRadio(SpecLabel(spec), function()
            return SpecFor(m.name, m.class) == spec
          end, function()
            SetSpec(m.name, spec)
          end)
        end
      end
    end)
  else
    ARLE:Print("Set a spec with: /arl bis spec <name> <spec>")
  end
end

-- Toolbar: [All][Party][Mine]  Party 2/3        [+][-]
function tab:Create(content, bar)
  child = content
  local kit = ARLE.UIKit
  self.filters = H.FilterButtons(bar, FILTERS, Filter, function(key)
    mod.db.filter = key
  end)
  local foldAll = H.SmallButton(bar, "-", 16)
  foldAll:SetPoint("RIGHT", 0, 0)
  foldAll:SetScript("OnClick", function()
    local collapsed = Collapsed()
    for _, boss in ipairs(H.shown and Bosses(H.shown) or {}) do
      collapsed[boss.name] = true
    end
    collapsed[OTHER] = true
    H.Render()
  end)
  local openAll = H.SmallButton(bar, "+", 16)
  openAll:SetPoint("RIGHT", foldAll, "LEFT", -2, 0)
  openAll:SetScript("OnClick", function()
    wipe(Collapsed())
    H.Render()
  end)
  for _, b in ipairs({ openAll, foldAll }) do
    b:SetScript("OnEnter", function(self)
      H.SimpleTooltip(self, self == openAll and "Unfold every boss" or "Fold every boss")
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
  end
  self.partyButton = CreateFrame("Button", nil, bar)
  self.partyButton:SetPoint("LEFT", self.filters.last, "RIGHT", 6, 0)
  self.partyButton:SetPoint("RIGHT", openAll, "LEFT", -4, 0)
  self.partyButton:SetHeight(20)
  self.partyButton.text = kit.Text(self.partyButton, "GameFontHighlightSmall")
  self.partyButton.text:SetPoint("LEFT")
  self.partyButton:SetScript("OnEnter", PartyTooltip)
  self.partyButton:SetScript("OnClick", SpecMenu)
  self.partyButton:SetScript("OnLeave", GameTooltip_Hide)

  emptyText = kit.Text(child, "GameFontDisableSmall")
  emptyText:SetPoint("TOPLEFT", 6, -8)
  emptyText:SetPoint("RIGHT", -6, 0)
end

-- Draws the list; returns its height.
function tab:Render()
  local ar, ag, ab = ARLE.Skin:Accent()
  local filter = Filter()
  self.filters.Paint()

  local members = Members()
  local sharing = 0
  for _, m in ipairs(members) do
    local p = party[m.name]
    if p and p.dungeon == H.shown then
      sharing = sharing + 1
    end
  end
  self.partyButton.text:SetText("Party " .. sharing .. "/" .. #members)

  local y, nh, nr = 0, 0, 0
  local bosses = (H.shown and FLB()) and Bosses(H.shown) or {}
  local marks = (H.shown and FLB()) and Marks(H.shown, members) or {}
  local collapsed = Collapsed()
  local me = Me()
  -- The bosses, then Other loot as one more section.
  local sections = {}
  for _, boss in ipairs(bosses) do
    sections[#sections + 1] = boss
  end
  if mod.db.showOther and #bosses > 0 then
    local other = H.OtherLoot(H.shown)
    if #other > 0 then
      sections[#sections + 1] = { name = OTHER, label = "Other loot", items = other, other = true }
    end
  end
  for _, boss in ipairs(sections) do
    local visible = {}
    local bis, ups = 0, 0
    for _, item in ipairs(boss.items) do
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
      end
      if filter == "all" or (filter == "party" and #mk > 0) or (filter == "mine" and mine) then
        visible[#visible + 1] = item
      end
    end
    if #visible > 0 then
      if boss.other then
        y = y + 4
      end
      nh = nh + 1
      local h = Header(nh)
      h.boss, h.isRare = boss.name, boss.rare
      h.rare:SetShown(boss.rare == true)
      h.label:ClearAllPoints()
      h.label:SetPoint("LEFT", boss.rare and h.rare or h.toggle, "RIGHT", 2, 0)
      h.label:SetPoint("RIGHT", h.count, "LEFT", -4, 0)
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", 0, -y)
      h:SetPoint("RIGHT")
      local focused = self.focus ~= nil and (boss.name == self.focus or boss.group == self.focus)
      h.bg:SetColorTexture(ar, ag, ab, focused and 0.3 or 0.1)
      h.toggle:SetText(collapsed[boss.name] and "+" or "-")
      h.label:SetText(boss.label or boss.name)
      h.label:SetTextColor(ar, ag, ab)
      local parts = {}
      if bis > 0 then
        parts[#parts + 1] = "|cffffd100" .. bis .. " BiS|r"
      end
      if ups > 0 then
        parts[#parts + 1] = "|cffaaaaaa" .. ups .. " up|r"
      end
      if collapsed[boss.name] then
        parts[#parts + 1] = "|cff888888(" .. #visible .. ")|r"
      end
      h.count:SetText(table.concat(parts, " "))
      h:Show()
      y = y + BOSS_H + 1
      if not collapsed[boss.name] then
        for _, item in ipairs(visible) do
          nr = nr + 1
          local r = Row(nr)
          r:ClearAllPoints()
          r:SetPoint("TOPLEFT", 0, -y)
          r:SetPoint("RIGHT")
          PaintRow(r, item, marks[item.id] or {}, members)
          r:Show()
          y = y + ITEM_H
        end
      end
      y = y + 2
    end
  end
  for i = nh + 1, #headers do
    headers[i]:Hide()
  end
  for i = nr + 1, #rows do
    rows[i]:Hide()
  end
  emptyText:SetShown(nh == 0)
  if nh == 0 then
    if not FLB() then
      emptyText:SetText("The BiS Finder needs Forever Leveling BiS v1.3 or newer.")
    elseif not H.shown then
      emptyText:SetText("Not in a dungeon. Pick one with the v button.")
    elseif filter ~= "all" then
      emptyText:SetText("Nothing here for " .. (filter == "mine" and "you" or "the party") .. ". Try All.")
    else
      emptyText:SetText("No gear drops listed for this dungeon.")
    end
    y = 40
  end
  return y
end

function tab:Status()
  local exact, est = 0, 0
  for name, p in pairs(party) do
    if name ~= Me() and p.dungeon == H.shown then
      if p.estimated then
        est = est + 1
      else
        exact = exact + 1
      end
    end
  end
  if not FLB() then
    return "BiS Finder off (needs Forever Leveling BiS)"
  end
  return "party: " .. exact .. " exact, " .. est .. " estimated"
end
