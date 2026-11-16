-- Darkmoon Tickets: ranks every Darkmoon Faire Prize Ticket turn-in by how
-- much it costs per ticket at the auction house, from Auctionator's last scan:
--   cost per ticket = AH unit price * items per turn-in / tickets.
-- Based on Auctionator_DarkmoonTickets by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- Auctionator.API.v1 through ARLE.Bridge.Auctionator (every call pcall'd: the
-- v1 API raises errors on bad state, e.g. a search with the AH closed):
-- GetAuctionPriceByItemLink / ...ByItemID, GetAuctionAgeByItemID,
-- RegisterForDBUpdate (refresh after a scan), MultiSearchExact ("Search all").
--
-- Ticket data: the built-in table comes from community guides. When you turn
-- a quest in, the real counts are read from the quest window (required item
-- count on QUEST_PROGRESS, the Prize Ticket reward count on QUEST_COMPLETE)
-- and kept account-wide (shared.learned), overriding the built-in numbers.
-- Reputation: tiers 1-4 stop being offered at a Darkmoon Faire reputation value
-- (approximate); those rows are greyed and sorted after the rest.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local AH, Kit, Skin, Items = ARLE.Bridge.Auctionator, ARLE.UI.Kit, ARLE.Skin, ARLE.Lib.Items

local TICKET_ID = 19182
local FACTION_ID = 909 -- Darkmoon Faire

-- Tier offered while DMF reputation value (absolute, Neutral = 0) is below this.
local TIER_CAP = { [1] = 401, [2] = 1100, [3] = 1625, [4] = 2500 }

local TURNINS = {
  { id = 3240, name = "Coarse Weightstone", qty = 10, tickets = 1, tier = 1, src = "Blacksmithing" },
  { id = 4363, name = "Copper Modulator", qty = 3, tickets = 1, tier = 1, src = "Engineering" },
  { id = 2309, name = "Embossed Leather Boots", qty = 3, tickets = 1, tier = 1, src = "Leatherworking" },
  { id = 5134, name = "Small Furry Paw", qty = 5, tickets = 1, tier = 1, src = "Beast drop" },
  { id = 3486, name = "Heavy Grinding Stone", qty = 7, tickets = 4, tier = 2, src = "Blacksmithing" },
  { id = 4375, name = "Whirring Bronze Gizmo", qty = 7, tickets = 4, tier = 2, src = "Engineering" },
  { id = 2314, name = "Toughened Leather Armor", qty = 3, tickets = 4, tier = 2, src = "Leatherworking" },
  { id = 11407, name = "Torn Bear Pelt", qty = 5, tickets = 4, tier = 2, src = "Beast drop" },
  { id = 3835, name = "Green Iron Bracers", qty = 3, tickets = 8, tier = 3, src = "Blacksmithing" },
  { id = 9313, name = "Green Firework", qty = 36, tickets = 8, tier = 3, src = "Engineering" },
  { id = 5739, name = "Barbaric Harness", qty = 3, tickets = 8, tier = 3, src = "Leatherworking" },
  { id = 4582, name = "Soft Bushy Tail", qty = 5, tickets = 8, tier = 3, src = "Beast drop" },
  { id = 7945, name = "Big Black Mace", qty = 3, tickets = 12, tier = 4, src = "Blacksmithing" },
  { id = 11590, name = "Mechanical Repair Kit", qty = 6, tickets = 12, tier = 4, src = "Engineering" },
  { id = 8185, name = "Turtle Scale Leggings", qty = 1, tickets = 12, tier = 4, src = "Leatherworking" },
  { id = 5117, name = "Vibrant Plume", qty = 5, tickets = 12, tier = 4, src = "Beast drop" },
  { id = 12644, name = "Dense Grinding Stone", qty = 8, tickets = 20, tier = 5, src = "Blacksmithing" },
  { id = 15994, name = "Thorium Widget", qty = 6, tickets = 20, tier = 5, src = "Engineering" },
  { id = 15564, name = "Rugged Armor Kit", qty = 8, tickets = 20, tier = 5, src = "Leatherworking" },
  { id = 11404, name = "Evil Bat Eye", qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
  { id = 19933, name = "Glowing Scorpid Blood", qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
}

local byID = {}
for _, t in ipairs(TURNINS) do
  byID[t.id] = t
end

local F = {
  id = "DarkmoonTickets",
  addon = ADDON,
  title = "Darkmoon Tickets",
  group = "Auctionator",
  extends = "Auctionator",
  command = "dmf",
  commandArgs = "[best [n]|learned|forget]",
  commandHelp = "Darkmoon Faire turn-ins ranked by gold per Prize Ticket",
  mainHelp = "opens or closes the window",
  description = "Darkmoon Faire turn-ins ranked by gold per Prize Ticket, from Auctionator's prices.",
  options = {
    { key = "hideCapped", type = "boolean", label = "Hide tiers past my reputation", default = false,
      cmd = "hidecapped" },
    { key = "includeBank", type = "boolean", label = "Count bank items", default = true, cmd = "bank" },
    ARLE.Options.Preset.Tooltip({ label = "Tooltip line on turn-in items" }),
    { type = "button", label = "Open Darkmoon Tickets", nocmd = true, run = function(def) def:Toggle(true) end },
    { type = "button", label = "Forget learned ticket counts", confirm = "Click again to forget them", nocmd = true,
      desc = "back to the built-in numbers", run = function(def) def:Forget() end },
  },
}

local frame, rows = nil, {}

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

-- Learned counts are facts about the quests, the same for every character:
-- they live in F.shared (account wide), while settings are per character.
-- A copy left in this character's settings (from when settings were account
-- wide) is merged in once.
local function Learned()
  local shared = F.shared
  shared.learned = type(shared.learned) == "table" and shared.learned or {}
  if type(F.db.learned) == "table" then
    for id, l in pairs(F.db.learned) do
      if shared.learned[id] == nil then
        shared.learned[id] = l
      end
    end
    F.db.learned = nil
  end
  return shared.learned
end

local function TurnIn(t)
  local l = Learned()[t.id]
  if l and l.qty and l.tickets and l.tickets > 0 then
    return l.qty, l.tickets, true
  end
  return t.qty, t.tickets, false
end

local function ItemInfo(id)
  local name, link, _, _, _, _, _, _, _, icon = Items.GetInfo(id)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
  if not icon and Items.GetInfoInstant then
    icon = select(5, Items.GetInfoInstant(id))
  end
  return name, link, icon
end

local function Reputation()
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, FACTION_ID)
    if ok and d and d.currentStanding then
      return d.currentStanding, d.reaction
    end
  end
  if GetFactionInfoByID then
    local ok, _, _, standingID, _, _, value = pcall(GetFactionInfoByID, FACTION_ID)
    if ok and value then
      return value, standingID
    end
  end
  return nil
end

local function IsCapped(tier, rep)
  local cap = TIER_CAP[tier]
  return cap ~= nil and rep ~= nil and rep >= cap
end

local function Money(copper)
  if not copper then
    return "|cff808080--|r"
  end
  copper = math.floor(copper + 0.5)
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, copper)
    if ok and s then
      return s
    end
  end
  return ARLE.Lib.FormatMoney(copper)
end

-- The ranked list. Each entry: t, name, link, icon, qty, tickets, learned,
-- unit, perTicket, perTurnIn, age, have, capped.
local function BuildList()
  local rep = Reputation()
  local list = {}
  for _, t in ipairs(TURNINS) do
    local name, link, icon = ItemInfo(t.id)
    local qty, tickets, learned = TurnIn(t)
    local unit = AH.Price(t.id, link)
    local e = {
      t = t,
      name = name or t.name,
      link = link,
      icon = icon,
      qty = qty,
      tickets = tickets,
      learned = learned,
      unit = unit,
      age = AH.Age(t.id),
      have = Items.Count(t.id, F.db.includeBank ~= false),
      capped = IsCapped(t.tier, rep),
    }
    if unit then
      e.perTurnIn = unit * qty
      e.perTicket = e.perTurnIn / tickets
    end
    if not (e.capped and F.db.hideCapped) then
      list[#list + 1] = e
    end
  end
  table.sort(list, function(a, b)
    if a.capped ~= b.capped then
      return not a.capped
    end
    if (a.perTicket ~= nil) ~= (b.perTicket ~= nil) then
      return a.perTicket ~= nil
    end
    if a.perTicket and b.perTicket and a.perTicket ~= b.perTicket then
      return a.perTicket < b.perTicket
    end
    return a.t.id < b.t.id
  end)
  return list, rep
end

-------------------------------------------------------------------------------
-- Window (ARLE.UI.Window: follows the theme)
-------------------------------------------------------------------------------

local ROW_H, NUM_ROWS, WIDTH = 20, #TURNINS, 700
local COLS = { -- x offset, width, justify
  rank = { 2, 20, "RIGHT" },
  item = { 28, 200, "LEFT" },
  turnin = { 232, 70, "CENTER" },
  unit = { 304, 100, "RIGHT" },
  ticket = { 408, 110, "RIGHT" },
  seen = { 522, 50, "CENTER" },
  have = { 574, 50, "CENTER" },
  tier = { 626, 56, "CENTER" },
}

local function MakeText(parent, col, font)
  local c = COLS[col]
  local fs = Kit.Text(parent, font or "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", c[1], 0)
  fs:SetWidth(c[2])
  fs:SetJustifyH(c[3])
  fs:SetWordWrap(false)
  return fs
end

local Refresh

local function SearchAll()
  local names = {}
  for _, t in ipairs(TURNINS) do
    names[#names + 1] = ItemInfo(t.id) or t.name
  end
  local ok, err = AH.SearchExact(names)
  if not ok then
    F:Print("open the auction house first. (" .. tostring(err or ""):gsub("^.-: ", "") .. ")")
  end
end

local function CreateWindow()
  local f = ARLE.UI.Window:New({
    name = "ARLEDarkmoonTicketsFrame",
    title = "Darkmoon Faire: cost per Prize Ticket (Auctionator's last scan)",
    width = WIDTH,
    height = 70 + ROW_H * (NUM_ROWS + 1) + 40,
    strata = "HIGH",
    store = F.char,
    key = "pos",
    escClose = true,
  })
  local c = f.content
  f.summary = Kit.Text(c, "GameFontNormal")
  f.summary:SetPoint("TOPLEFT", 4, -4)
  f.summary:SetPoint("RIGHT", -4, 0)

  local header = CreateFrame("Frame", nil, c)
  header:SetPoint("TOPLEFT", 0, -26)
  header:SetSize(WIDTH - 12, ROW_H)
  local labels = { rank = "#", item = "Item", turnin = "Items > Tix", unit = "AH unit", ticket = "Per ticket",
    seen = "Seen", have = "Have", tier = "Tier" }
  for col, text in pairs(labels) do
    local fs = MakeText(header, col, "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetTextColor(Skin:Accent())
  end

  for i = 1, NUM_ROWS do
    local r = CreateFrame("Button", nil, c)
    r:SetSize(WIDTH - 12, ROW_H)
    r:SetPoint("TOPLEFT", 0, -26 - ROW_H * i)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.08)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("LEFT", COLS.item[1], 0)
    r.rank, r.turnin, r.unit = MakeText(r, "rank"), MakeText(r, "turnin"), MakeText(r, "unit")
    r.ticket, r.seen, r.have, r.tier = MakeText(r, "ticket"), MakeText(r, "seen"), MakeText(r, "have"),
      MakeText(r, "tier")
    r.item = MakeText(r, "item")
    r.item:ClearAllPoints()
    r.item:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.item:SetWidth(COLS.item[2] - ROW_H)
    r:SetScript("OnEnter", function(self)
      local e = self.entry
      if not e then
        return
      end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(e.t.id)
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format("Turn-in: %d for %d ticket%s%s", e.qty, e.tickets, e.tickets == 1 and "" or "s",
        e.learned and " |cff00ff00(seen in quest window)|r" or " |cffaaaaaa(guide data)|r"), 1, 1, 1)
      GameTooltip:AddLine("Source: " .. e.t.src, 0.8, 0.8, 0.8)
      if e.perTurnIn then
        GameTooltip:AddLine("Cost per turn-in: " .. Money(e.perTurnIn), 1, 1, 1)
      end
      if e.have and e.have > 0 then
        local n = math.floor(e.have / e.qty)
        GameTooltip:AddLine(string.format("You have %d (%d turn-in%s)", e.have, n, n == 1 and "" or "s"), 0.6, 1, 0.6)
      end
      if e.capped then
        GameTooltip:AddLine("Your Darkmoon reputation is past this tier (approximate cap).", 1, 0.4, 0.4, true)
      end
      GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.5, 0.5)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:SetScript("OnClick", function(self)
      if self.entry and IsModifiedClick("CHATLINK") then
        local _, link = ItemInfo(self.entry.t.id)
        if link and ChatEdit_InsertLink then
          ChatEdit_InsertLink(link)
        end
      end
    end)
    rows[i] = r
  end

  local search = Kit.Button(c, "Search all on AH", 150)
  search:SetPoint("BOTTOMLEFT", 0, 0)
  search:SetScript("OnClick", SearchAll)

  local function Toggle(key, label, anchor)
    local cb = Kit.Check(c)
    cb:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
    local text = Kit.Text(c, "GameFontHighlightSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    text:SetText(label)
    cb:SetScript("OnClick", function(self)
      ARLE:SetOption(F.id, key, self:GetChecked() and true or false)
    end)
    return cb, text
  end
  local capLabel
  f.cappedCheck, capLabel = Toggle("hideCapped", "Hide tiers past my reputation", search)
  f.bankCheck = Toggle("includeBank", "Count bank items", capLabel)

  f:SetScript("OnShow", function()
    Refresh()
  end)
  frame = f
end

Refresh = function()
  if not (frame and frame:IsShown()) then
    return
  end
  frame.cappedCheck:SetChecked(F.db.hideCapped and true or false)
  frame.bankCheck:SetChecked(F.db.includeBank ~= false)
  local list, rep = BuildList()
  local best
  for _, e in ipairs(list) do
    if not e.capped and e.perTicket then
      best = e
      break
    end
  end
  local repText = rep and string.format("DMF reputation %d", rep) or "DMF reputation unknown"
  if not AH.API() then
    frame.summary:SetText("|cffff8080Auctionator's API was not found: no prices.|r   |cffaaaaaa" .. repText .. "|r")
  elseif best then
    frame.summary:SetText(string.format("Best: |cffffffff%s|r at %s per ticket  (%d for %d tickets = %s)   "
      .. "|cffaaaaaa%s|r", best.name, Money(best.perTicket), best.qty, best.tickets, Money(best.perTurnIn), repText))
  else
    frame.summary:SetText("No Auctionator prices for these items yet: scan the AH or use \"Search all on AH\".   "
      .. "|cffaaaaaa" .. repText .. "|r")
  end
  for i, r in ipairs(rows) do
    local e = list[i]
    r.entry = e
    if not e then
      r:Hide()
    else
      r:Show()
      local dim = e.capped
      local function c(s)
        return dim and ("|cff707070" .. s .. "|r") or s
      end
      r.rank:SetText(c(tostring(i)))
      r.icon:SetTexture(e.icon or 134400)
      r.icon:SetDesaturated(dim)
      r.item:SetText(dim and c(e.name) or (e == best and ("|cff00ff00" .. e.name .. "|r") or e.name))
      r.turnin:SetText(c(string.format("%d > %d%s", e.qty, e.tickets, e.learned and "" or "*")))
      r.unit:SetText(e.unit and c(Money(e.unit)) or "|cff808080no price|r")
      r.ticket:SetText(e.perTicket and c(Money(e.perTicket)) or "|cff808080--|r")
      local seen = e.age == nil and "-" or (e.age == 0 and "today" or (e.age .. "d"))
      r.seen:SetText(c(seen))
      r.have:SetText(c(e.have > 0 and (e.have >= e.qty and ("|cff00ff00" .. e.have .. "|r") or tostring(e.have)) or "-"))
      r.tier:SetText(c(e.capped and ("T" .. e.t.tier .. " cap") or ("T" .. e.t.tier)))
    end
  end
end

function F:Toggle(show)
  if not frame then
    CreateWindow()
  end
  if show == nil then
    show = not frame:IsShown()
  end
  frame:SetShown(show)
end

function F:Forget()
  wipe(Learned())
  self:Print("learned counts cleared; using the built-in table.")
  Refresh()
end

-------------------------------------------------------------------------------
-- Learning real counts from the quest window
-------------------------------------------------------------------------------

local pending -- { id, qty, title }

local function OnQuestProgress()
  pending = nil
  local n = GetNumQuestItems and GetNumQuestItems() or 0
  for i = 1, n do
    local id = Items.IDFromLink(GetQuestItemLink("required", i))
    local _, _, count = GetQuestItemInfo("required", i)
    if id and byID[id] and count then
      pending = { id = id, qty = count, title = GetTitleText and GetTitleText() }
      return
    end
  end
end

local function OnQuestComplete()
  if not pending then
    return
  end
  if GetTitleText and pending.title and GetTitleText() ~= pending.title then
    pending = nil
    return
  end
  local n = GetNumQuestRewards and GetNumQuestRewards() or 0
  for i = 1, n do
    local id = Items.IDFromLink(GetQuestItemLink("reward", i))
    if id == TICKET_ID then
      local _, _, count = GetQuestItemInfo("reward", i)
      if count and count > 0 then
        local t = byID[pending.id]
        local learned = Learned()
        local old = learned[pending.id]
        learned[pending.id] = { qty = pending.qty, tickets = count }
        if (not old and (t.qty ~= pending.qty or t.tickets ~= count))
            or (old and (old.qty ~= pending.qty or old.tickets ~= count)) then
          F:Print(string.format("learned %s: %d for %d tickets (was %d for %d).", t.name, pending.qty, count,
            old and old.qty or t.qty, old and old.tickets or t.tickets))
        end
        Refresh()
      end
      break
    end
  end
  pending = nil
end

-------------------------------------------------------------------------------
-- Tooltip line (installed once; does nothing while the feature is off)
-------------------------------------------------------------------------------

local function AddTooltipLine(tt, id)
  if not (F._active and F.db.tooltip ~= false and id and byID[id]) then
    return
  end
  local t = byID[id]
  local qty, tickets = TurnIn(t)
  local _, link = ItemInfo(id)
  local unit = AH.Price(id, link)
  local text = string.format("Darkmoon: %d for %d ticket%s", qty, tickets, tickets == 1 and "" or "s")
  if unit then
    text = text .. " (" .. Money(unit * qty / tickets) .. " per ticket)"
  end
  tt:AddLine(text, 0.82, 0.42, 1)
end

local tooltipInstalled = false
local function InstallTooltip()
  if tooltipInstalled then
    return
  end
  tooltipInstalled = true
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
      if tt ~= GameTooltip and tt ~= ItemRefTooltip then
        return
      end
      AddTooltipLine(tt, data and data.id)
    end)
  elseif GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(tt)
      local _, link = tt:GetItem()
      AddTooltipLine(tt, Items.IDFromLink(link))
    end)
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- Auctionator keeps every callback for the session (there is no unregister),
-- so it is registered once; OnDBUpdate returns true once it's registered,
-- and the callback does nothing while the feature is off.
local dbHooked = false
function F:OnEnable()
  InstallTooltip()
  if not dbHooked and AH.API() then
    dbHooked = AH.OnDBUpdate(function()
      if F._active then
        Refresh()
      end
    end)
  elseif not AH.API() then
    self:Print("Auctionator API v1 not found; prices will be missing.")
  end
  self:On("QUEST_PROGRESS", OnQuestProgress)
  self:On("QUEST_COMPLETE", OnQuestComplete)
  self:On("GET_ITEM_INFO_RECEIVED", function(_, _, id)
    if id and byID[id] then
      Refresh()
    end
  end)
  self:On("BAG_UPDATE_DELAYED", Refresh)
  self:On("UPDATE_FACTION", Refresh)
  for _, t in ipairs(TURNINS) do
    ItemInfo(t.id) -- warm the item cache
  end
end

function F:OnDisable()
  if frame then
    frame:Hide()
  end
end

function F:OnOptionChanged()
  Refresh()
end

-- The standalone Auctionator_DarkmoonTickets' data (account wide
-- DarkmoonTicketsDB: learned = { [itemID] = { qty, tickets } }, hideCapped,
-- includeBank, tooltip). Replaces ours; entries that don't fit are skipped.
function F:Import()
  local old = _G.DarkmoonTicketsDB
  if type(old) ~= "table" then
    return
  end
  if type(old.learned) == "table" then
    local learned = {}
    for id, l in pairs(old.learned) do
      id = tonumber(id)
      local qty = type(l) == "table" and tonumber(l.qty)
      local tickets = type(l) == "table" and tonumber(l.tickets)
      if id and byID[id] and qty and qty > 0 and tickets and tickets > 0 then
        learned[id] = { qty = qty, tickets = tickets }
      end
    end
    self.db.learned = nil
    self.shared.learned = learned
  end
  for _, key in ipairs({ "hideCapped", "includeBank", "tooltip" }) do
    if type(old[key]) == "boolean" then
      self.db[key] = old[key]
    end
  end
end

function F:main(rest)
  rest = rest or ""
  if rest == "" or rest == "show" then
    self:Toggle()
  else
    self:Print("no command \"" .. rest .. "\". /arl dmf help lists them.")
  end
end

local function PrintBest(n)
  local list, rep = BuildList()
  local shown = 0
  F:Print(string.format("cheapest tickets from the last Auctionator scan%s:", rep and (" (DMF rep " .. rep .. ")") or ""))
  for _, e in ipairs(list) do
    if e.perTicket and not e.capped then
      shown = shown + 1
      print(string.format("   %d. %s - %s per ticket (%d for %d, %s per turn-in)", shown, e.link or e.name,
        Money(e.perTicket), e.qty, e.tickets, Money(e.perTurnIn)))
      if shown >= n then
        break
      end
    end
  end
  if shown == 0 then
    F:Print("no prices yet. Scan the AH with Auctionator first.")
  end
end

F.commands = {
  { name = "best", args = "[n]", help = "prints the n cheapest turn-ins to chat (default 5)", run = function(_, rest)
    PrintBest(tonumber(rest) or 5)
  end },
  { name = "learned", help = "ticket counts read from the quest window so far", always = true, run = function(self)
    local any = false
    for id, l in pairs(Learned()) do
      any = true
      print(string.format("   %s: %d for %d tickets", byID[id] and byID[id].name or id, l.qty, l.tickets))
    end
    if not any then
      self:Print("nothing learned yet; counts update when you turn a quest in.")
    end
  end },
  { name = "forget", help = "clears those and goes back to the built-in numbers", run = function(self) self:Forget() end },
  { name = "searchall", help = "searches all 21 items in Auctionator (AH open)", run = function() SearchAll() end },
}

ARLE:RegisterModule(F)
