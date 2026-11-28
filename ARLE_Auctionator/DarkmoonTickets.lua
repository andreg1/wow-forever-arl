-- Darkmoon Faire: the cheapest way to Darkmoon Prize Tickets and Darkmoon
-- Faire reputation on WoW Forever, and where and when the Faire is. Shown as
-- the Darkmoon panel in the ARL tab on the auction house (DarkmoonTab.lua).
-- Started as Auctionator_DarkmoonTickets by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons; reworked in 0.22.0.
--
-- What Forever does (researched 2026-11-28 from wowforever.be's reputation
-- guide and wofwforever.com's Faire guide, cross-checked with ItemTree's data):
--   * 21 turn-ins in 5 tiers at four NPCs pay 1 / 4 / 8 / 12 / 20 tickets and
--     100 Darkmoon Faire reputation each; a tier stops being offered once the
--     reputation reaches its cut (500 / 1100 / 1700 / 2500 into Neutral, the
--     last at 5999 into Friendly; some players report ~2000 into Friendly).
--   * Prize Tickets are a currency on Forever (515), not the Classic item 19182.
--   * A Darkmoon card deck (Beasts, Elementals, Portals, Warlords) handed to
--     Professor Thaddeus Paleo gives 150 reputation (and a level 60 trinket),
--     with no cut: past the turn-ins, decks are the way on.
--   * The Faire alternates monthly between Elwynn Forest (south of Goldshire)
--     and Mulgore (at the foot of Thunder Bluff): it arrives on the month's
--     first Friday, opens the Monday after and closes a week later (Nov 9-15
--     2026 Elwynn, Dec 7-13 Mulgore, Jan 4-10 2027 Elwynn, ...).
--
-- Where and when: the game calendar first (C_Calendar: the Faire's holiday
-- day events, ids 263 Elwynn / 264 Mulgore, or their textures; facts from
-- Forever's Holidays table that ItemTree documents), else the rule above
-- ("expected"). The month offset is counted from the month the calendar shows,
-- so a player browsing the calendar changes nothing.
--
-- Costs: each item at the cheapest of buying it, a vendor, or crafting it,
-- through Logistics.lua's costing (ns.Logistics.Node: ItemTree's recipes,
-- this realm's scan, else Auctionator's price; its "crafts I don't know"
-- switch applies); a deck at the cheaper of the deck and its eight cards
-- (ItemTree's combine recipe). Without ItemTree: Auctionator's prices only.
--
-- Learned counts: turning a quest in reads the count asked (QUEST_PROGRESS)
-- and the tickets paid (QUEST_COMPLETE: the ticket currency, or the old item)
-- into `shared.learned`, which beats the built-in numbers.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local AH, Items = ARLE.Bridge.Auctionator, ARLE.Lib.Items
local Lib = ARLE.Lib

local TICKET_ITEM = 19182 -- Classic's ticket item (still read, in case)
local TICKET_CURRENCY = 515 -- Forever's Darkmoon Prize Ticket
local FACTION_ID = 909 -- Darkmoon Faire
local TURNIN_REP = 100
local DECK_REP = 150
local PLAN_MAX = 200 -- turn-ins or decks the plan counts at most
local CALENDAR_STALE = 600 -- seconds a calendar read is kept

-- A tier is offered while the Faire reputation (absolute, Neutral = 0) is below this.
local TIER_CAP = { [1] = 500, [2] = 1100, [3] = 1700, [4] = 2500, [5] = 8999 }

local TURNINS = {
  { id = 3240, name = "Coarse Weightstone", qty = 10, tickets = 1, tier = 1, src = "Blacksmithing" },
  { id = 4363, name = "Copper Modulator", qty = 5, tickets = 1, tier = 1, src = "Engineering" },
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
  { id = 7945, name = "Big Black Mace", qty = 1, tickets = 12, tier = 4, src = "Blacksmithing" },
  { id = 11590, name = "Mechanical Repair Kit", qty = 6, tickets = 12, tier = 4, src = "Engineering" },
  { id = 8185, name = "Turtle Scale Leggings", qty = 1, tickets = 12, tier = 4, src = "Leatherworking" },
  { id = 5117, name = "Vibrant Plume", qty = 5, tickets = 12, tier = 4, src = "Beast drop" },
  { id = 12644, name = "Dense Grinding Stone", qty = 8, tickets = 20, tier = 5, src = "Blacksmithing" },
  { id = 15994, name = "Thorium Widget", qty = 6, tickets = 20, tier = 5, src = "Engineering" },
  { id = 15564, name = "Rugged Armor Kit", qty = 8, tickets = 20, tier = 5, src = "Leatherworking" },
  { id = 11404, name = "Evil Bat Eye", qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
  { id = 19933, name = "Glowing Scorpid Blood", qty = 10, tickets = 20, tier = 5, src = "Beast drop" },
}

-- The four decks and their cards (when ItemTree can't say): Ace to Eight.
local DECKS = {
  { id = 19228, name = "Beasts Deck", cards = { 19227, 19230, 19231, 19232, 19233, 19234, 19235, 19236 } },
  { id = 19267, name = "Elementals Deck", cards = { 19268, 19269, 19270, 19271, 19272, 19273, 19274, 19275 } },
  { id = 19277, name = "Portals Deck", cards = { 19276, 19278, 19279, 19280, 19281, 19282, 19283, 19284 } },
  { id = 19257, name = "Warlords Deck", cards = { 19258, 19259, 19260, 19261, 19262, 19263, 19264, 19265 } },
}

-- What tickets buy at Gelvas Grimegate, for the ticket goal.
local PRIZES = {
  { id = 19295, name = "Darkmoon Flower", tickets = 5 },
  { id = 19298, name = "Minor Darkmoon Prize", tickets = 5 },
  { id = 19292, name = "Last Month's Mutton", tickets = 10 },
  { id = 19297, name = "Lesser Darkmoon Prize", tickets = 12 },
  { id = 19296, name = "Greater Darkmoon Prize", tickets = 40 },
  { id = 19291, name = "Darkmoon Storage Box", tickets = 50 },
  { id = 19293, name = "Last Year's Mutton", tickets = 50 },
  { id = 19491, name = "Amulet of the Darkmoon", tickets = 1200 },
  { id = 19426, name = "Orb of the Darkmoon", tickets = 1200 },
}

-- Where the Faire stands: the calendar's holiday ids and textures, and each site.
local HOLIDAYS = { [263] = "elwynn", [264] = "mulgore" }
local TEXTURES = { [235446] = "elwynn", [235447] = "elwynn", [235448] = "elwynn", [235449] = "mulgore",
  [235450] = "mulgore", [235451] = "mulgore" }
local SITES = {
  elwynn = { map = 1429, x = 0.42, y = 0.70, zone = "Elwynn Forest", spot = "south of Goldshire" },
  mulgore = { map = 1412, x = 0.37, y = 0.38, zone = "Mulgore", spot = "at the foot of Thunder Bluff" },
}
local RULE_FROM = { year = 2026, month = 11, site = "elwynn" } -- the alternation's known month

local byID = {}
for _, t in ipairs(TURNINS) do
  byID[t.id] = t
end

local F = {
  id = "DarkmoonTickets",
  addon = ADDON,
  title = "Darkmoon Faire",
  group = "Auctionator",
  extends = "Auctionator",
  command = "dmf",
  commandArgs = "[best [n]|rep [n]|when|learned|forget]",
  commandHelp = "the Darkmoon Faire: where and when, and the cheapest tickets and reputation",
  mainHelp = "says where and when the Faire is",
  description = "The cheapest way to Darkmoon Prize Tickets and Darkmoon Faire reputation (turn-ins bought or "
    .. "crafted, and card decks), and where and when the Faire is: the Darkmoon panel in the ARL tab on the "
    .. "auction house.",
  defaults = { view = "tickets", ticketGoal = 0, ticketGoalItem = 0 },
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "hideCapped", type = "boolean", label = "Hide turn-ins past my reputation", default = false,
      cmd = "hidecapped" },
    { key = "includeBank", type = "boolean", label = "Count bank items", default = true, cmd = "bank" },
    ARLE.Options.Preset.Tooltip({ label = "Tooltip line on turn-in items" }),
    { type = "button", label = "Forget learned ticket counts", confirm = "Click again to forget them", nocmd = true,
      desc = "back to the built-in numbers", run = function(def) def:Forget() end },
  },
}

local D = {} -- what DarkmoonTab.lua reads
ns.Darkmoon = D
D.F, D.PRIZES, D.SITES, D.TICKET_CURRENCY = F, PRIZES, SITES, TICKET_CURRENCY
D.TURNIN_REP, D.DECK_REP = TURNIN_REP, DECK_REP

local function Notify()
  if ns.DarkmoonTab then
    ns.DarkmoonTab.Refresh()
  end
end
D.Notify = Notify

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

-- Learned counts are facts about the quests, the same for every character (shared). A copy left in this
-- character's settings (from when settings were account wide) is merged in once.
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
D.TurnIn = TurnIn

local function ItemInfo(id)
  local name, link, _, _, _, _, _, _, _, icon = Items.GetInfo(id)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
  if not icon and Items.GetIcon then
    icon = Items.GetIcon(id)
  end
  return name, link, icon
end
D.ItemInfo = ItemInfo

-- The Faire's standing: Logistics' reader when there, else a small one of our own.
function D.Standing()
  local L = ns.Logistics
  if L and L.FactionStanding then
    return L.FactionStanding(FACTION_ID, "Darkmoon Faire")
  end
  local d = C_Reputation and C_Reputation.GetFactionDataByID and Lib.Call(C_Reputation.GetFactionDataByID, FACTION_ID)
  if Lib.Readable(d) then
    return { id = FACTION_ID, name = Lib.Str(d.name) or "Darkmoon Faire", reaction = d.reaction,
      value = d.currentStanding }
  end
end

-- Tickets held: the currency, else the Classic item.
function D.Tickets()
  local c = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo
  local info = c and Lib.Call(c, TICKET_CURRENCY)
  if Lib.Readable(info) and Lib.Plain(info.quantity) then
    return Lib.Plain(info.quantity), Lib.Plain(info.iconFileID)
  end
  return Items.Count(TICKET_ITEM, true), nil
end

local function IsCapped(tier, rep)
  local cap = TIER_CAP[tier]
  return cap ~= nil and rep ~= nil and rep >= cap
end

-- One item's cheapest way: a Logistics node { cost, src, buy, craft, known, ... } (or a plain auction price).
local function Cost(id)
  local L = ns.Logistics
  if L and L.Node then
    local n = L.Node(id, 0)
    if n then
      return n
    end
  end
  local p = AH.Price(id)
  return { id = id, cost = p, buy = p, src = p and "buy" or nil }
end
D.Cost = Cost

-- A deck's cards, from ItemTree's combine recipe when it has one.
local function DeckCards(deck)
  local it = rawget(_G, "ItemTree")
  local data = type(it) == "table" and it.Data
  if type(data) == "table" and type(data.GetUses) == "function" and type(data.GetRecipe) == "function" then
    local ok, uses = pcall(data.GetUses, data, deck.id)
    for _, spell in ipairs(ok and type(uses) == "table" and type(uses.p) == "table" and uses.p or {}) do
      local okR, r = pcall(data.GetRecipe, data, spell)
      if okR and type(r) == "table" and type(r.re) == "table" and type(r.out) == "table" and r.out[1] == deck.id then
        local cards = {}
        for _, re in ipairs(r.re) do
          cards[#cards + 1] = tonumber(re[1])
        end
        if #cards > 0 then
          return cards
        end
      end
    end
  end
  return deck.cards
end

-- Every way, priced: turn-ins { kind "turnin", t, qty, tickets, learned, node, unit, perTurnIn, perTicket,
-- perRep, have, capped, cap } and decks { kind "deck", deck, node, cards, cardsCost, cost, perRep, have }.
function D.Evaluate()
  if ns.Logistics and ns.Logistics.ResetCosts then
    ns.Logistics.ResetCosts()
  end
  local st = D.Standing()
  local rep = st and st.value
  local bank = F.db.includeBank ~= false
  local out = {}
  for _, t in ipairs(TURNINS) do
    local name, link, icon = ItemInfo(t.id)
    local qty, tickets, learned = TurnIn(t)
    local node = Cost(t.id)
    local e = { kind = "turnin", t = t, id = t.id, name = name or t.name, link = link, icon = icon, qty = qty,
      tickets = tickets, learned = learned, node = node, unit = node and node.cost,
      have = Items.Count(t.id, bank), capped = IsCapped(t.tier, rep), cap = TIER_CAP[t.tier], rep = TURNIN_REP }
    if e.unit then
      e.perTurnIn = e.unit * qty
      e.perTicket = e.perTurnIn / tickets
      if not e.capped then
        e.perRep = e.perTurnIn / TURNIN_REP
      end
    end
    out[#out + 1] = e
  end
  for _, deck in ipairs(DECKS) do
    local name, link, icon = ItemInfo(deck.id)
    local node = Cost(deck.id)
    local e = { kind = "deck", deck = deck, id = deck.id, name = name or deck.name, link = link, icon = icon,
      node = node, have = Items.Count(deck.id, bank), rep = DECK_REP, qty = 1 }
    local cards, sum = DeckCards(deck), 0
    e.cards = {}
    for _, c in ipairs(cards) do
      local n = Cost(c)
      e.cards[#e.cards + 1] = { id = c, node = n, have = Items.Count(c, bank) }
      if sum and n and n.cost then
        sum = sum + n.cost
      else
        sum = nil
      end
    end
    e.cardsCost = sum
    local deckCost = node and node.cost
    if deckCost and (not sum or deckCost <= sum) then
      e.cost, e.via = deckCost, "deck"
    elseif sum then
      e.cost, e.via = sum, "cards"
    end
    e.perTurnIn = e.cost
    e.perRep = e.cost and e.cost / DECK_REP
    out[#out + 1] = e
  end
  return out, st
end

-- The list for one view, sorted: "tickets" (turn-ins by gold per ticket, past the cut last) or "rep" (what still
-- gives reputation, by gold per reputation).
function D.Sorted(all, view)
  local list = {}
  for _, e in ipairs(all) do
    if view == "rep" then
      if e.kind == "deck" or not e.capped or not F.db.hideCapped then
        list[#list + 1] = e
      end
    elseif e.kind == "turnin" and not (e.capped and F.db.hideCapped) then
      list[#list + 1] = e
    end
  end
  local key = view == "rep" and "perRep" or "perTicket"
  table.sort(list, function(a, b)
    local ca, cb = view ~= "rep" and a.capped or false, view ~= "rep" and b.capped or false
    if ca ~= cb then
      return not ca
    end
    if (a[key] ~= nil) ~= (b[key] ~= nil) then
      return a[key] ~= nil
    end
    if a[key] and b[key] and a[key] ~= b[key] then
      return a[key] < b[key]
    end
    return a.id < b.id
  end)
  return list, key
end

-- The cheapest way to a goal, as many of each as the cuts allow: view "tickets" (need = tickets) or "rep"
-- (need = reputation). Each turn-in adds 100 reputation, so a tier stops when its cut is reached either way.
-- Marks e.plan / e.planCount; returns { count, cost, got, need, short }.
function D.Plan(list, view, need, rep)
  local p = { count = 0, cost = 0, got = 0, need = need }
  for _, e in ipairs(list) do
    e.plan, e.planCount = nil, nil
  end
  if not need or need <= 0 then
    return p
  end
  rep = rep or 0
  local key = view == "rep" and "perRep" or "perTicket"
  for _, e in ipairs(list) do
    if p.got >= need or p.count >= PLAN_MAX then
      break
    end
    if e[key] and e.perTurnIn then
      local gain = view == "rep" and e.rep or e.tickets
      local n = math.ceil((need - p.got) / gain)
      if e.kind == "turnin" then
        local left = e.cap and math.ceil((e.cap - rep) / TURNIN_REP) or n
        n = math.min(n, math.max(0, left))
      end
      n = math.min(n, PLAN_MAX - p.count)
      if n > 0 then
        e.plan, e.planCount = true, n
        p.count, p.cost, p.got = p.count + n, p.cost + e.perTurnIn * n, p.got + gain * n
        rep = rep + e.rep * n
      end
    end
  end
  p.short = p.got < need
  return p
end

-------------------------------------------------------------------------------
-- Where and when
-------------------------------------------------------------------------------

local function DayStart(y, m, d)
  return time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
end

-- The rule: the month's first Friday it arrives, the Monday after it opens, a week later it's gone; the sites
-- alternate from RULE_FROM.
local function RuleFor(y, m)
  local friday
  for d = 1, 7 do
    if date("*t", DayStart(y, m, d) + 43200).wday == 6 then
      friday = d
      break
    end
  end
  local setup = DayStart(y, m, friday)
  local open = DayStart(y, m, friday + 3)
  local close = DayStart(y, m, friday + 10)
  local months = (y * 12 + m) - (RULE_FROM.year * 12 + RULE_FROM.month)
  local site = months % 2 == 0 and RULE_FROM.site or (RULE_FROM.site == "elwynn" and "mulgore" or "elwynn")
  return { site = site, setup = setup, open = open, close = close, source = "expected" }
end

local function NextMonth(y, m)
  if m == 12 then
    return y + 1, 1
  end
  return y, m + 1
end

local function CalTime(t)
  if not Lib.Readable(t) then
    return nil
  end
  local y, m, d = Lib.Plain(t.year), Lib.Plain(t.month), Lib.Plain(t.monthDay)
  if y and m and d then
    return time({ year = y, month = m, day = d, hour = Lib.Plain(t.hour) or 0, min = Lib.Plain(t.minute) or 0,
      sec = 0 })
  end
end

-- The calendar's Faire runs in this month and the next: { { site, open, close } }, or nil when it can't say.
local calendar = { at = -1e9 }
local function ReadCalendar()
  local C = C_Calendar
  local now = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime
    and Lib.Call(C_DateAndTime.GetCurrentCalendarTime)
  if not (C and C.GetMonthInfo and C.GetNumDayEvents and C.GetDayEvent and Lib.Readable(now)) then
    return nil
  end
  local shown = Lib.Call(C.GetMonthInfo, 0)
  if not Lib.Readable(shown) or not shown.year or not shown.month then
    return nil
  end
  local base = (Lib.Plain(now.year) * 12 + Lib.Plain(now.month)) - (shown.year * 12 + shown.month)
  local runs, any = {}, false
  for k = 0, 1 do
    local offset = base + k
    local info = Lib.Call(C.GetMonthInfo, offset)
    local days = Lib.Readable(info) and Lib.Plain(info.numDays) or 0
    for day = 1, days do
      local n = Lib.Call(C.GetNumDayEvents, offset, day) or 0
      if n > 0 then
        any = true
      end
      for i = 1, n do
        local e = Lib.Call(C.GetDayEvent, offset, day, i)
        if Lib.Readable(e) and Lib.Plain(e.calendarType) == "HOLIDAY" then
          local site = HOLIDAYS[Lib.Plain(e.eventID) or 0] or TEXTURES[Lib.Plain(e.iconTexture) or 0]
          if not site then
            local title = Lib.Str(e.title)
            if title and title:find("Darkmoon") then
              site = "elwynn" -- (named but not placed: see below)
              e.unplaced = true
            end
          end
          if site then
            local open, close = CalTime(e.startTime), CalTime(e.endTime)
            local key = (open or 0) .. ":" .. site
            if open and close and not runs[key] then
              runs[key] = true
              runs[#runs + 1] = { site = site, open = open, close = close, source = "calendar",
                unplaced = e.unplaced }
            end
          end
        end
      end
    end
  end
  if not any then
    return nil -- (the calendar hasn't loaded its events yet)
  end
  table.sort(runs, function(a, b)
    return a.open < b.open
  end)
  return runs
end

-- The Faire now or next: { state "open" / "setup" / "soon", site (SITES key), open, close, setup, source }.
function D.Faire()
  local now = time()
  if GetTime() - calendar.at > CALENDAR_STALE then
    calendar.at = GetTime()
    calendar.runs = ReadCalendar()
    if not calendar.runs and C_Calendar and C_Calendar.OpenCalendar then
      Lib.Call(C_Calendar.OpenCalendar) -- (asks for the events; CALENDAR_UPDATE_EVENT_LIST reads them again)
    end
  end
  local pick
  for _, r in ipairs(calendar.runs or {}) do
    if r.close > now then
      pick = { site = r.site, open = r.open, close = r.close, setup = r.open - 3 * 86400, source = "calendar" }
      if r.unplaced then
        pick.site = RuleFor(tonumber(date("%Y", r.open)), tonumber(date("%m", r.open))).site
      end
      break
    end
  end
  if not pick then
    local t = date("*t", now)
    pick = RuleFor(t.year, t.month)
    if pick.close <= now then
      pick = RuleFor(NextMonth(t.year, t.month))
    end
  end
  pick.state = now >= pick.open and "open" or now >= pick.setup and "setup" or "soon"
  pick.siteInfo = SITES[pick.site]
  local map = C_Map and C_Map.GetMapInfo and Lib.Call(C_Map.GetMapInfo, pick.siteInfo.map)
  pick.zone = Lib.Readable(map) and Lib.Str(map.name) or pick.siteInfo.zone
  return pick
end

local function Days(seconds)
  local d = math.floor(seconds / 86400)
  if d >= 1 then
    return ("%d day%s"):format(d, d == 1 and "" or "s")
  end
  local h = math.max(1, math.floor(seconds / 3600))
  return ("%d hour%s"):format(h, h == 1 and "" or "s")
end

-- The Faire's last day: the calendar closes it early on a Monday morning, which is still Sunday's Faire.
local function LastDay(close)
  return close - 6 * 3600
end

-- One line: "Open now in Elwynn Forest (south of Goldshire) · closes in 3 days".
function D.FaireText(f)
  f = f or D.Faire()
  local now = time()
  local where = ("%s (%s)"):format(f.zone, f.siteInfo.spot)
  local text
  if f.state == "open" then
    text = ("|cff40ff40Open now|r in %s · until %s (%s left)"):format(where, date("%a %d %b", LastDay(f.close)),
      Days(f.close - now))
  elseif f.state == "setup" then
    text = ("|cffffd100Setting up|r in %s · opens in %s, %s"):format(where, Days(f.open - now),
      date("%a %d %b", f.open))
  else
    text = ("Next: %s · %s to %s (in %s)"):format(where, date("%a %d %b", f.open), date("%a %d %b", LastDay(f.close)),
      Days(f.open - now))
  end
  if f.source ~= "calendar" then
    text = text .. " |cff909090(expected)|r"
  end
  return text
end

-- A map pin on the Faire.
function D.Pin()
  local f = D.Faire()
  local s = f.siteInfo
  if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
    F:Print(("the Faire: %s, %s (%.0f, %.0f)."):format(f.zone, s.spot, s.x * 100, s.y * 100))
    return
  end
  local point = Lib.Call(UiMapPoint.CreateFromCoordinates, s.map, s.x, s.y)
  if point and Lib.Call(C_Map.SetUserWaypoint, point) ~= false then
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
      Lib.Call(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    F:Print(("map pin set on the Faire: %s, %s."):format(f.zone, s.spot))
  end
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

-- The tickets a quest window pays: the currency (Forever), else the item.
local function RewardTickets()
  local nc = GetNumRewardCurrencies and Lib.Call(GetNumRewardCurrencies) or 0
  for i = 1, nc do
    local id = GetQuestCurrencyID and Lib.Call(GetQuestCurrencyID, "reward", i)
    local amount
    if C_QuestOffer and C_QuestOffer.GetQuestRewardCurrencyInfo then
      local info = Lib.Call(C_QuestOffer.GetQuestRewardCurrencyInfo, "reward", i)
      if Lib.Readable(info) then
        id = id or Lib.Plain(info.currencyID)
        amount = Lib.Plain(info.totalRewardAmount) or Lib.Plain(info.baseRewardAmount)
      end
    end
    if not amount and GetQuestCurrencyInfo then
      local _, _, a = Lib.Call(GetQuestCurrencyInfo, "reward", i)
      amount = a
    end
    if id == TICKET_CURRENCY and amount and amount > 0 then
      return amount
    end
  end
  local n = GetNumQuestRewards and GetNumQuestRewards() or 0
  for i = 1, n do
    if Items.IDFromLink(GetQuestItemLink("reward", i)) == TICKET_ITEM then
      local _, _, count = GetQuestItemInfo("reward", i)
      return count
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
  local count = RewardTickets()
  if count and count > 0 then
    local t = byID[pending.id]
    local learned = Learned()
    local old = learned[pending.id]
    learned[pending.id] = { qty = pending.qty, tickets = count }
    if (not old and (t.qty ~= pending.qty or t.tickets ~= count))
        or (old and (old.qty ~= pending.qty or old.tickets ~= count)) then
      F:Print(("learned %s: %d for %d tickets (was %d for %d)."):format(t.name, pending.qty, count,
        old and old.qty or t.qty, old and old.tickets or t.tickets))
    end
    Notify()
  else
    F:Debug("quest complete for %s: no ticket reward read", tostring(pending.id))
  end
  pending = nil
end

function F:Forget()
  wipe(Learned())
  self:Print("learned counts cleared; using the built-in table.")
  Notify()
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
  local node = Cost(id)
  local text = ("Darkmoon: %d for %d ticket%s"):format(qty, tickets, tickets == 1 and "" or "s")
  if node and node.cost then
    text = text .. " (" .. Lib.FormatMoney(math.floor(node.cost * qty / tickets + 0.5)) .. " per ticket)"
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
    -- (registered for the session: off, it returns at once; a hidden tooltip table or id, in combat or an
    -- instance, is never read; errors caught)
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
      if not F._active or (tt ~= GameTooltip and tt ~= ItemRefTooltip) then
        return
      end
      if type(data) ~= "table" or Lib.IsSecret(data) then
        return
      end
      local id = data.id
      if type(id) ~= "number" or Lib.IsSecret(id) then
        return
      end
      ARLE.Debug.Call(F, AddTooltipLine, tt, id)
    end)
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- Auctionator keeps every callback for the session (there is no unregister), so it is registered once and does
-- nothing while the feature is off.
local dbHooked = false
function F:OnEnable()
  InstallTooltip()
  pending = nil
  calendar.at = -1e9
  if not dbHooked and AH.API() then
    dbHooked = AH.OnDBUpdate(function()
      if F._active then
        Notify()
      end
    end)
  end
  self:On("QUEST_PROGRESS", OnQuestProgress)
  self:On("QUEST_COMPLETE", OnQuestComplete)
  self:On("GET_ITEM_INFO_RECEIVED", function(_, _, id)
    if id and byID[id] then
      self:Debounce("dmf.items", 0.5, Notify)
    end
  end)
  self:On("BAG_UPDATE_DELAYED", function()
    self:Debounce("dmf.bags", 0.5, Notify)
  end)
  self:On("UPDATE_FACTION", function()
    self:Debounce("dmf.rep", 0.5, Notify)
  end)
  self:On("CURRENCY_DISPLAY_UPDATE", function()
    self:Debounce("dmf.tickets", 0.5, Notify)
  end)
  self:On("CALENDAR_UPDATE_EVENT_LIST", function()
    calendar.at = -1e9
    self:Debounce("dmf.calendar", 1, Notify)
  end)
  self:On("AUCTION_HOUSE_SHOW", function()
    if ns.DarkmoonTab then
      ns.DarkmoonTab.Attach()
    end
  end)
  for _, t in ipairs(TURNINS) do
    ItemInfo(t.id) -- warm the item cache
  end
  if ns.DarkmoonTab then
    ns.DarkmoonTab.Enable()
  end
end

function F:OnDisable()
  if ns.DarkmoonTab then
    ns.DarkmoonTab.Disable()
  end
end

function F:OnOptionChanged()
  Notify()
end

-- The standalone Auctionator_DarkmoonTickets' data (account wide DarkmoonTicketsDB: learned = { [itemID] = { qty,
-- tickets } }, hideCapped, includeBank, tooltip). Replaces ours; entries that don't fit are skipped.
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

local function PrintBest(view, n)
  local all, st = D.Evaluate()
  local list, key = D.Sorted(all, view)
  local shown = 0
  F:Print(("cheapest %s%s:"):format(view == "rep" and "Darkmoon Faire reputation" or "Prize Tickets",
    st and st.value and (" (reputation " .. st.value .. ")") or ""))
  for _, e in ipairs(list) do
    if e[key] and not (view ~= "rep" and e.capped) then
      shown = shown + 1
      if e.kind == "deck" then
        print(("   %d. %s (%s): %s per reputation, 150 a deck"):format(shown, e.link or e.name,
          e.via == "cards" and "its 8 cards" or "the deck", Lib.FormatMoney(math.floor(e[key] + 0.5))))
      else
        print(("   %d. %s x%d: %s per %s (%d tickets, %s per turn-in)"):format(shown, e.link or e.name, e.qty,
          Lib.FormatMoney(math.floor(e[key] + 0.5)), view == "rep" and "reputation" or "ticket", e.tickets,
          Lib.FormatMoney(math.floor(e.perTurnIn + 0.5))))
      end
      if shown >= n then
        break
      end
    end
  end
  if shown == 0 then
    F:Print("no prices yet: scan the auction house (Auctionator's full scan, or Snipes' Scan) first.")
  end
end

function F:main(rest)
  rest = rest or ""
  if rest == "" or rest == "when" then
    self:Print("Darkmoon Faire: " .. D.FaireText())
  else
    self:Print("no command \"" .. rest .. "\". /arl dmf help lists them.")
  end
end

F.commands = {
  { name = "best", args = "[n]", help = "prints the n cheapest turn-ins per ticket (default 5)", run = function(_, rest)
    PrintBest("tickets", tonumber(rest) or 5)
  end },
  { name = "rep", args = "[n]", help = "prints the n cheapest ways to reputation (default 5)", run = function(_, rest)
    PrintBest("rep", tonumber(rest) or 5)
  end },
  { name = "pin", help = "puts a map pin on the Faire", run = function() D.Pin() end },
  { name = "learned", help = "ticket counts read from the quest window so far", always = true, run = function(self)
    local any = false
    for id, l in pairs(Learned()) do
      any = true
      print(("   %s: %d for %d tickets"):format(byID[id] and byID[id].name or id, l.qty, l.tickets))
    end
    if not any then
      self:Print("nothing learned yet; counts update when you turn a quest in.")
    end
  end },
  { name = "forget", help = "clears those and goes back to the built-in numbers", run = function(self) self:Forget() end },
}

function F:GetStatus()
  local ok, text = pcall(D.FaireText)
  return "Active · " .. (ok and text or "the Faire's dates aren't known yet")
end

ARLE:RegisterModule(F)
