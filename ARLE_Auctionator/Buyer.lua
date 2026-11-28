-- Buyer: the ARL tab's shopping list, bought one press at a time (0.23.0, the
-- user's request: a button that buys what our AH panels' plans need, in the
-- quantities they need).
--
-- The game takes a purchase (C_AuctionHouse.PlaceBid, ConfirmCommoditiesPurchase)
-- only from a click or key press, one purchase per press, so this can't buy a
-- whole list in one click. The "Buy next" button (frame ARLE_BuyNext, also a
-- key binding in the host's Bindings.xml) does the next step each press:
-- - a commodity: one press asks the price for the quantity
--   (StartCommoditiesPurchase), the next confirms it once COMMODITY_PRICE_UPDATED
--   says it's still at or under the line's cap;
-- - an item: one press buys the cheapest auction that fits (PlaceBid).
-- Searching (SendSearchQuery, price order) needs no press and runs by itself
-- whenever a line comes up or after a purchase.
--
-- Lines come from the panels (B.Load(from, items): Logistics' plan, Darkmoon's
-- plan, Snipes' rows); loading a panel again replaces that panel's lines. Each
-- line has a cap per item: the plan's price + the margin from the Auction House
-- settings (Snipes: under the vendor price, always). Never pays more than the
-- cap, never buys more than the line needs (a bigger stack only when it costs
-- no more than the line's remaining need at the cap), never our own auctions,
-- never past the gold on hand. Waits while a Logistics or Snipes scan runs.
--
-- Blizzard's C_AuctionHouse API only (Auctionator is all rights reserved). The
-- events go through the Auction House entry (AuctionHouse.lua: B.Enable(def)),
-- which owns them.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items = ARLE.Lib, ARLE.Lib.Items
local Kit, Skin = ARLE.UI.Kit, ARLE.Skin

local SEARCH_WAIT = 8 -- s without a search answer: ask again
local SEARCH_TRIES = 3 -- then the line is skipped
local BUY_WAIT = 8 -- s without a purchase answer: look again
local MAX_PAGES = 3 -- item search pages read for an auction that fits
local MAX_FAILS = 3 -- failed purchases before a line is skipped
local BUTTON_NAME = "ARLE_BuyNext"

local B = {}
ns.Buyer = B

local def -- the Auction House entry (owner of the events, the traces, the margin)
local lines = {} -- { from, id, key, need, unit, cap, hard, bought, spent, skip, fails }
local step = "idle" -- idle / search / ready / start / confirm / buying
local cur -- the line being bought
local offer -- { commodity, qty, unit, total } or { auctionID, qty, buyout }
local sent = { at = 0, tries = 0, pages = 0 }
local note -- the last thing worth saying on the bar
local bar -- the bar's frame
local listeners = {}

local function Money(c)
  return c and Lib.FormatMoney(math.floor(c + 0.5)) or "?"
end

local function Name(id)
  local name = Items.GetInfo and Items.GetInfo(id)
  return name or Items.Name(id)
end

local function Margin()
  local m = def and tonumber(def.db.buyMargin)
  return (m or 10) / 100
end

local function AHOpen()
  return AuctionHouseFrame and AuctionHouseFrame:IsShown() and C_AuctionHouse ~= nil
end

local function Ready()
  local f = C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady
  return not f or Lib.Call(f) ~= false
end

local function PriceSorts()
  local e = Enum and Enum.AuctionHouseSortOrder
  return e and { { sortOrder = e.Price, reverseSort = false } } or {}
end

local function Trace(fmt, ...)
  if def then
    def:Debug(fmt, ...)
  end
end

local function Notify()
  for _, fn in ipairs(listeners) do
    fn()
  end
  if bar then
    B.Paint()
  end
end

-- A scan of ours is using the auction house's searches.
local function ScanBusy()
  local W, S = ns.Logistics, ns.Snipes
  if W and W.scan and W.scan.running then
    return "Logistics is scanning"
  end
  if S and S.Busy and S.Busy() then
    return "Snipes is scanning"
  end
end

local function Left(line)
  return math.max(0, line.need - line.bought)
end

local function NextLine()
  for _, line in ipairs(lines) do
    if not line.skip and Left(line) > 0 then
      return line
    end
  end
end

-------------------------------------------------------------------------------
-- The list
-------------------------------------------------------------------------------

-- What a plan item costs to get, as bought items: node = Logistics' W.Node ({ src, id, buy, yield, parts }),
-- qty = how many. into[id] = { qty, unit, mat (the part reached through a craft) }.
function B.Collect(node, qty, into, mat)
  if not node or not qty or qty <= 0 then
    return
  end
  if node.src == "buy" then
    B.Add(into, node.id, qty, node.buy, mat)
  elseif node.src == "craft" then
    local crafts = math.ceil(qty / math.max(1, node.yield or 1))
    for _, part in ipairs(node.parts or {}) do
      B.Collect(part.node, crafts * (part.count or 1), into, true)
    end
  end
end

function B.Add(into, id, qty, unit, mat)
  if not id or not qty or qty <= 0 then
    return
  end
  local x = into[id] or { qty = 0, mat = 0 }
  into[id] = x
  x.qty = x.qty + qty
  if mat then
    x.mat = x.mat + qty
  end
  if unit and (not x.unit or unit > x.unit) then
    x.unit = unit
  end
end

local function Sort()
  table.sort(lines, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.seq < b.seq
  end)
end

local ORDER = { Logistics = 1, Darkmoon = 2, Snipes = 3 }
local seq = 0

-- A panel's list: into = { [id] = { qty, unit, mat, hard, key } } (B.Collect / B.Add; `hard` = a fixed cap per
-- item, e.g. Snipes' vendor price - 1). Replaces that panel's lines. Materials reached through a craft count
-- the ones in your bags. Returns how many lines and the most it could cost.
function B.Load(from, into)
  local keep = {}
  for _, line in ipairs(lines) do
    if line.from ~= from then
      keep[#keep + 1] = line
    end
  end
  lines = keep
  if cur and cur.from == from then
    B.Reset()
  end
  local m, count, most = Margin(), 0, 0
  for id, x in pairs(into) do
    local need = x.qty
    if x.mat and x.mat > 0 then
      need = need - math.min(x.mat, Items.Count(id, false))
    end
    local cap = x.hard or (x.unit and math.floor(x.unit * (1 + m) + 0.5))
    if need > 0 and cap and cap > 0 then
      seq = seq + 1
      lines[#lines + 1] = { from = from, id = id, key = x.key, need = need, unit = x.unit or cap, cap = cap,
        hard = x.hard ~= nil, bought = 0, spent = 0, fails = 0, order = ORDER[from] or 9, seq = seq }
      Name(id)
      count, most = count + 1, most + need * cap
    end
  end
  Sort()
  note = nil
  Trace("buy list from %s: %d lines, at most %s", from, count, Money(most))
  B.Pump()
  Notify()
  return count, most
end

function B.Clear()
  if step == "start" or step == "confirm" then
    Lib.Call(C_AuctionHouse.CancelCommoditiesPurchase)
  end
  wipe(lines)
  cur, offer, step, note = nil, nil, "idle", nil
  Notify()
end

function B.Lines()
  return lines
end

function B.Active()
  return NextLine() ~= nil
end

-- Back to searching the current line (a closed AH, a changed price, a failed buy).
function B.Reset()
  if step == "start" or step == "confirm" then
    Lib.Call(C_AuctionHouse.CancelCommoditiesPurchase)
  end
  step, offer, cur = "idle", nil, nil
end

-------------------------------------------------------------------------------
-- Searching
-------------------------------------------------------------------------------

local function Skip(line, why)
  line.skip = why
  Trace("buy: %s skipped: %s", Name(line.id), why)
  note = ("%s skipped: %s"):format(Name(line.id), why)
  step, offer, cur = "idle", nil, nil
end

local function Key(line)
  if line.key then
    return line.key
  end
  return Lib.Call(C_AuctionHouse.MakeItemKey, line.id)
end

local function Search(line)
  local key = Key(line)
  if not key then
    Skip(line, "no item key")
    return
  end
  local ok = pcall(C_AuctionHouse.SendSearchQuery, key, PriceSorts(), true)
  sent.at, sent.pages = GetTime(), 1
  sent.tries = sent.tries + 1
  cur, step, offer = line, "search", nil
  if not ok then
    Trace("buy: SendSearchQuery failed for %d", line.id)
  end
end

-- The commodity's answer: how many at or under the cap (ours left out), up to what's left of the line.
local function ReadCommodity(line)
  local n = Lib.Call(C_AuctionHouse.GetNumCommoditySearchResults, line.id) or 0
  local want, qty, total = Left(line), 0, 0
  for i = 1, n do
    local r = Lib.Call(C_AuctionHouse.GetCommoditySearchResultInfo, line.id, i)
    if Lib.Readable(r) then
      local unit, q = Lib.Plain(r.unitPrice), Lib.Plain(r.quantity)
      local mine = Lib.Plain(r.numOwnerItems) or (Lib.Plain(r.containsOwnerItem) and q) or 0
      if unit and q then
        if unit > line.cap then
          break
        end
        q = math.min(q - math.min(q, mine), want - qty)
        if q > 0 then
          qty, total = qty + q, total + q * unit
        end
        if qty >= want then
          break
        end
      end
    end
  end
  return qty, total
end

local function Mine(r)
  if Lib.Plain(r.containsOwnerItem) == true then
    return true
  end
  local me = ARLE:MyName()
  local short = me and me:match("^(%S+)")
  if Lib.Readable(r.owners) then
    for _, o in ipairs(r.owners) do
      o = Lib.Plain(o)
      if o and (o == me or o == short) then
        return true
      end
    end
  end
  return false
end

-- The item's answer: the cheapest auction per item that fits.
local function ReadItem(line, key)
  local n = Lib.Call(C_AuctionHouse.GetNumItemSearchResults, key) or 0
  local want, best = Left(line), nil
  for i = 1, n do
    local r = Lib.Call(C_AuctionHouse.GetItemSearchResultInfo, key, i)
    if Lib.Readable(r) then
      local id, buyout, q = Lib.Plain(r.auctionID), Lib.Plain(r.buyoutAmount), Lib.Plain(r.quantity) or 1
      if id and buyout and buyout > 0 and q > 0 and not Mine(r) then
        local unit = buyout / q
        local fits = unit <= line.cap and (q <= want or buyout <= want * line.cap)
        if fits and (not best or unit < best.buyout / best.qty) then
          best = { auctionID = id, qty = q, buyout = buyout }
        end
      end
    end
  end
  return best
end

local function Offer(o)
  offer = o
  step = "ready"
  sent.tries = 0
  Notify()
end

local function OnResults(event, arg)
  if step ~= "search" and step ~= "buying" then
    return
  end
  local line = cur
  if not line then
    return
  end
  local commodity = event == "COMMODITY_SEARCH_RESULTS_UPDATED"
  local id = commodity and Lib.Plain(arg) or (Lib.Readable(arg) and Lib.Plain(arg.itemID))
  if id ~= line.id then
    return
  end
  if step == "buying" then
    -- (an item bought without its completion event: the auction gone from the fresh list counts as bought)
    if not commodity and offer and offer.auctionID and offer.checking then
      local key = arg
      local n, gone = Lib.Call(C_AuctionHouse.GetNumItemSearchResults, key) or 0, true
      for i = 1, n do
        local r = Lib.Call(C_AuctionHouse.GetItemSearchResultInfo, key, i)
        if Lib.Readable(r) and Lib.Plain(r.auctionID) == offer.auctionID then
          gone = false
        end
      end
      if gone then
        B.Bought(offer.qty, offer.buyout, true)
        return
      end
      step = "search" -- (still listed: not bought; this fresh list picks again)
    else
      return
    end
  end
  if commodity then
    local qty, total = ReadCommodity(line)
    if qty <= 0 then
      Skip(line, ("none at or under %s"):format(Money(line.cap)))
      Notify()
      B.Pump()
      return
    end
    Offer({ commodity = true, qty = qty, total = total, unit = total / qty })
  else
    local best = ReadItem(line, arg)
    if best then
      Offer(best)
      return
    end
    local full = Lib.Call(C_AuctionHouse.HasFullItemSearchResults, arg)
    if full == false and sent.pages < MAX_PAGES then
      sent.pages, sent.at = sent.pages + 1, GetTime()
      Lib.Call(C_AuctionHouse.RequestMoreItemSearchResults, arg)
      return
    end
    Skip(line, ("none at or under %s"):format(Money(line.cap)))
    Notify()
    B.Pump()
  end
end

-------------------------------------------------------------------------------
-- Buying
-------------------------------------------------------------------------------

function B.Bought(qty, cost, unconfirmed)
  local line = cur
  if not line then
    return
  end
  line.bought = line.bought + qty
  line.spent = line.spent + (cost or 0)
  note = ("Bought %d x %s for %s%s"):format(qty, Name(line.id), Money(cost), unconfirmed and " (seen gone)" or "")
  Trace("buy: %s", note)
  step, offer = "idle", nil
  sent.tries = 0
  if Left(line) <= 0 then
    cur = nil
  end
  Notify()
  B.Pump()
end

local function Failed(why)
  local line = cur
  if not line then
    return
  end
  line.fails = line.fails + 1
  note = ("Couldn't buy %s: %s"):format(Name(line.id), why)
  Trace("buy: %s", note)
  step, offer = "idle", nil
  if line.fails >= MAX_FAILS then
    Skip(line, "failed " .. line.fails .. " times")
  end
  Notify()
  B.Pump()
end

-- What the next press does, in words: text, and whether a press does anything now.
function B.NextText()
  local line = cur or NextLine()
  if not line then
    local skipped = 0
    for _, l in ipairs(lines) do
      if l.skip then
        skipped = skipped + 1
      end
    end
    if skipped > 0 then
      return ("Done, %d skipped (see the tooltip)"):format(skipped), false
    end
    return #lines > 0 and "All bought" or "Nothing to buy", false
  end
  local name = Name(line.id)
  if not AHOpen() then
    return "Open the auction house", false
  end
  local busy = ScanBusy()
  if busy then
    return busy .. "...", false
  end
  if step == "ready" and offer then
    if offer.commodity then
      return ("Buy %d x %s, about %s"):format(offer.qty, name, Money(offer.total)), true
    end
    return ("Buy %d x %s for %s"):format(offer.qty, name, Money(offer.buyout)), true
  elseif step == "start" then
    return ("Asking the price of %d x %s..."):format(offer and offer.qty or 0, name), false
  elseif step == "confirm" and offer then
    return ("Confirm %d x %s for %s"):format(offer.qty, name, Money(offer.total)), true
  elseif step == "buying" then
    return ("Buying %s..."):format(name), false
  end
  return ("Looking up %s..."):format(name), false
end

-- One press: the next step of the current line. Must come from a click or key press.
function B.Press()
  if not AHOpen() then
    return
  end
  if step == "ready" and offer and cur then
    if offer.commodity then
      if GetMoney() < offer.total then
        note = "Not enough gold"
        Notify()
        return
      end
      local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, cur.id, offer.qty)
      if not ok then
        Failed("the auction house refused to quote")
        return
      end
      step, sent.at = "start", GetTime()
    else
      if GetMoney() < offer.buyout then
        note = "Not enough gold"
        Notify()
        return
      end
      local ok = pcall(C_AuctionHouse.PlaceBid, offer.auctionID, offer.buyout)
      if not ok then
        Failed("the auction house refused")
        return
      end
      step, sent.at = "buying", GetTime()
    end
  elseif step == "confirm" and offer and cur then
    if GetMoney() < offer.total then
      B.Reset()
      note = "Not enough gold"
      Notify()
      return
    end
    local ok = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, cur.id, offer.qty)
    if not ok then
      Failed("the auction house refused")
      return
    end
    step, sent.at = "buying", GetTime()
  end
  Notify()
end

local function OnPrice(_, unit, total)
  if step ~= "start" or not (offer and cur) then
    return
  end
  unit, total = Lib.Plain(unit), Lib.Plain(total)
  if not total then
    Failed("no price came")
    return
  end
  unit = unit or total / offer.qty
  if unit > cur.cap or total > offer.qty * cur.cap then
    Lib.Call(C_AuctionHouse.CancelCommoditiesPurchase)
    note = ("%s went up to %s each: looking again"):format(Name(cur.id), Money(unit))
    Trace("buy: %s", note)
    step, offer = "idle", nil
    Notify()
    B.Pump()
    return
  end
  offer.total, offer.unit = total, unit
  step = "confirm"
  Notify()
end

local function OnCommodityDone(event)
  if step ~= "buying" or not (offer and offer.commodity) then
    return
  end
  if event == "COMMODITY_PURCHASE_SUCCEEDED" then
    B.Bought(offer.qty, offer.total)
  else
    Failed("the purchase failed (someone was faster?)")
  end
end

local function OnItemDone(_, auctionID)
  if step ~= "buying" or not (offer and offer.auctionID) then
    return
  end
  auctionID = Lib.Plain(auctionID)
  if auctionID == nil or auctionID == offer.auctionID then
    B.Bought(offer.qty, offer.buyout)
  end
end

local function OnError()
  if step == "buying" or step == "start" then
    Failed("the auction house said no")
  end
end

-------------------------------------------------------------------------------
-- The pump: searches when a line comes up, waits out the throttle and our scans, gives up on silence.
-------------------------------------------------------------------------------

function B.Pump()
  if not AHOpen() then
    if step ~= "idle" then
      B.Reset()
    end
    return
  end
  local now = GetTime()
  if step == "idle" then
    local line = NextLine()
    if not line or ScanBusy() or not Ready() then
      return
    end
    if line ~= cur then
      sent.tries = 0
    end
    Search(line)
    Notify()
  elseif step == "search" then
    if now - sent.at > SEARCH_WAIT then
      if sent.tries >= SEARCH_TRIES then
        Skip(cur, "no answer")
        Notify()
      elseif Ready() then
        Search(cur)
      end
    end
  elseif step == "start" then
    if now - sent.at > SEARCH_WAIT then
      Failed("no price came")
    end
  elseif step == "buying" then
    if now - sent.at > BUY_WAIT and offer then
      if offer.commodity then
        Failed("no answer")
      elseif not offer.checking and Ready() then
        -- (no completion event: a fresh search says whether the auction is gone)
        offer.checking = true
        sent.at = now
        pcall(C_AuctionHouse.SendSearchQuery, Key(cur), PriceSorts(), true)
      elseif offer.checking then
        Failed("no answer")
      end
    end
  end
end

-------------------------------------------------------------------------------
-- The bar on the ARL tab (ARLTab.lua builds it into its strip)
-------------------------------------------------------------------------------

function B.OnChange(fn)
  listeners[#listeners + 1] = fn
end

local function Totals()
  local need, got, spent, most = 0, 0, 0, 0
  for _, line in ipairs(lines) do
    if not line.skip then
      need = need + line.need
      most = most + Left(line) * line.cap
    end
    got = got + math.min(line.bought, line.need)
    spent = spent + line.spent
  end
  return got, need, spent, most
end

local function BarTip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
  GameTooltip:AddLine("Buy list", 1, 1, 1)
  GameTooltip:AddLine("Each press (click, or the key bound under Key Bindings > AddOns > ARL Extensions) does the "
    .. "next step: a stack of a commodity takes two presses (the price, then confirm), an auction one.", 0.8, 0.8,
    0.8, true)
  local from
  for _, line in ipairs(lines) do
    if line.from ~= from then
      from = line.from
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(from, 1, 0.82, 0)
    end
    local r, g, b = 1, 1, 1
    local right = ("%d / %d"):format(line.bought, line.need)
    if line.skip then
      r, g, b = 0.6, 0.6, 0.6
      right = right .. " · " .. line.skip
    elseif Left(line) == 0 then
      r, g, b = 0.25, 1, 0.25
    end
    GameTooltip:AddDoubleLine(("%s  (up to %s each)"):format(Name(line.id), Money(line.cap)), right, r, g, b, r, g, b)
  end
  local got, need, spent, most = Totals()
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Spent", Money(spent), 1, 0.82, 0, 1, 1, 1)
  if most > 0 then
    GameTooltip:AddDoubleLine("The rest, at most", Money(most), 1, 0.82, 0, 1, 1, 1)
  end
  GameTooltip:AddLine("Bought items may come by mail: collect them before making a plan again, or it buys them "
    .. "twice.", 0.5, 0.5, 0.5, true)
  GameTooltip:Show()
end

-- Built by ARLTab into its strip: [text] [Buy next] [x]; shown while the list has lines.
function B.BuildBar(parent, owner)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(400, 18)
  local clear = Kit.SmallButton(f, "x", 20)
  clear:SetPoint("RIGHT")
  local btn = CreateFrame("Button", BUTTON_NAME, f, "UIPanelButtonTemplate")
  btn:SetSize(96, 18)
  btn:SetText("Buy next")
  Skin:Button(btn)
  btn:SetPoint("RIGHT", clear, "LEFT", -4, 0)
  btn:RegisterForClicks("AnyUp")
  local text = Kit.Text(f, "GameFontHighlightSmall")
  text:SetPoint("RIGHT", btn, "LEFT", -6, 0)
  text:SetPoint("LEFT")
  text:SetJustifyH("RIGHT")
  text:SetWordWrap(false)
  f.text, f.btn = text, btn
  owner:Script(btn, "OnClick", function()
    B.Press()
  end)
  owner:Script(clear, "OnClick", function()
    B.Clear()
  end)
  for _, w in ipairs({ btn, f }) do
    w:EnableMouse(true)
    owner:Script(w, "OnEnter", BarTip)
    owner:Script(w, "OnLeave", GameTooltip_Hide)
  end
  owner:Script(clear, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "Clear the buy list", "Drops what's left to buy (nothing bought is undone).")
  end)
  owner:Script(clear, "OnLeave", GameTooltip_Hide)
  bar = f
  B.Paint()
  return f
end

function B.Paint()
  if not bar then
    return
  end
  bar:SetShown(#lines > 0)
  if #lines == 0 then
    return
  end
  local text, live = B.NextText()
  local got, need = Totals()
  local key = GetBindingKey and GetBindingKey("CLICK " .. BUTTON_NAME .. ":LeftButton")
  local r, g, b = Skin:Accent()
  local head = ("|c%s%d/%d|r  "):format(Lib.Hex(r, g, b), got, need)
  local tail = note and not live and ("  |cff999999%s|r"):format(note) or ""
  bar.text:SetText(head .. text .. tail)
  bar.btn:SetText(key and ("Buy next (%s)"):format(GetBindingText and GetBindingText(key) or key) or "Buy next")
  bar.btn:SetAlpha(live and 1 or 0.55)
  bar.btn:SetWidth(key and 130 or 96)
end

-------------------------------------------------------------------------------
-- From the Auction House entry
-------------------------------------------------------------------------------

function B.Enable(owner)
  def = owner
  step, offer, cur = "idle", nil, nil
  -- (the feature's event frame calls fn(feature, event, ...): ours take (event, ...))
  local function On(event, fn)
    owner:On(event, function(_, ...)
      fn(...)
    end)
  end
  On("COMMODITY_SEARCH_RESULTS_UPDATED", OnResults)
  On("ITEM_SEARCH_RESULTS_UPDATED", OnResults)
  On("COMMODITY_PRICE_UPDATED", OnPrice)
  On("COMMODITY_PRICE_UNAVAILABLE", function()
    if step == "start" then
      Failed("no price for that quantity now")
    end
  end)
  On("COMMODITY_PURCHASE_SUCCEEDED", OnCommodityDone)
  On("COMMODITY_PURCHASE_FAILED", OnCommodityDone)
  On("AUCTION_HOUSE_PURCHASE_COMPLETED", OnItemDone)
  On("AUCTION_HOUSE_SHOW_ERROR", OnError)
  On("AUCTION_HOUSE_CLOSED", function()
    B.Reset()
    Notify()
  end)
  owner:Ticker(0.25, function()
    if #lines > 0 then
      B.Pump()
      if bar and bar:IsVisible() then
        B.Paint()
      end
    end
  end)
end

function B.Disable()
  B.Clear()
  def = nil
end

-- For /arl report.
function B.Report()
  local out = {}
  local got, need, spent = Totals()
  out[#out + 1] = ("Buy list: %d lines, %d/%d bought, %s spent, step %s"):format(#lines, got, need, Money(spent), step)
  if note then
    out[#out + 1] = "  last: " .. note
  end
  return out
end
