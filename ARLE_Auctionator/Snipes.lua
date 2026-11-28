-- Snipes: after every Auctionator full scan, the auctions whose buyout is
-- below what a vendor pays for the same items, so buying them and selling
-- them to a vendor is a sure profit. Shown in the ARL tab on the auction house
-- (SnipesTab.lua).
--
-- How: Auctionator's full scan asks the server for every auction at once
-- (C_AuctionHouse.ReplicateItems). The server's answer fires
-- REPLICATE_ITEM_LIST_UPDATE (a Blizzard event), and we read the same list
-- right then, alongside Auctionator, through Blizzard's API
-- (GetNumReplicateItems / GetReplicateItemInfo / GetReplicateItemLink), SLICE
-- auctions a frame. (0.21.0 waited for Auctionator's "done" callback first, and
-- on Forever the list was already gone by then: GetNumReplicateItems said 0.)
-- If the list changes or empties while we read, what was read is kept
-- (marked partial). Auctionator's public "done" callback
-- (Auctionator.API.v1.RegisterForDBUpdate) only starts a read when one is
-- still owed. What happened is kept in `char.diag` for /arl report. Auctionator is all rights
-- reserved: none of its code or internals is used. The vendor price is the
-- item's own sell price (GetItemInfo's 11th value); an auction counts when
-- count x vendor price - buyout >= the minimum profit (buyout only, never
-- bids, never your own auctions). Items whose data isn't loaded yet are asked
-- for and read again (RETRIES times, RETRY_WAIT apart).
--
-- Results, grouped per item (cheapest auctions first, most profit first), go
-- to `shared.snipeScans[realm]` (in SHARED_ONLY) so the tab shows the last
-- scan's after a /reload. Buying goes through Auctionator's Shopping tab
-- (MultiSearchExact), like Logistics: a listing may be gone by then.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items = ARLE.Lib, ARLE.Lib.Items
local AH = ARLE.Bridge.Auctionator

local SLICE = 1500 -- auctions read per frame
local RETRIES = 3 -- passes over auctions whose item data wasn't loaded
local RETRY_WAIT = 1.5 -- seconds between those passes
local MAX_ROWS = 300 -- items kept
local MAX_AUCTIONS = 25 -- auctions kept per item

local profitValues = {
  { value = 1, label = "Any profit" },
  { value = 100, label = "1 silver" },
  { value = 1000, label = "10 silver" },
  { value = 10000, label = "1 gold" },
  { value = 100000, label = "10 gold" },
}

local F = {
  id = "Snipes",
  addon = ADDON,
  title = "Snipes",
  group = "Auctionator",
  extends = "Auctionator",
  command = "snipes",
  commandArgs = "[read|list [n]]",
  commandHelp = "auctions selling below vendor price, from Auctionator's last full scan",
  mainHelp = "says what the last full scan found",
  description = "After every Auctionator full scan, lists the auctions selling for less than a vendor pays for the "
    .. "same items, so buying and vendoring them is a sure profit. Shown in the ARL tab on the auction house.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "minProfit", type = "select", label = "Smallest profit per auction worth listing", values = profitValues,
      default = 100, cmd = "min" },
    { key = "chat", type = "boolean", label = "Tell me in chat what a full scan found", default = true, cmd = "chat" },
  },
}

local S = {} -- what SnipesTab.lua reads
ns.Snipes = S
S.F = F

local job = { running = false } -- the read in progress
S.job = job
local pending = nil -- GetTime() of a replicate answer not read yet

local function Store()
  local all = type(F.shared.snipeScans) == "table" and F.shared.snipeScans or {}
  F.shared.snipeScans = all
  local realm = Lib.Plain(GetRealmName and GetRealmName()) or "?"
  local s = all[realm]
  if type(s) ~= "table" or type(s.rows) ~= "table" then
    s = { at = 0, total = 0, rows = {} }
    all[realm] = s
  end
  return s
end
S.Store = Store

function S.Hidden()
  local h = type(F.shared.snipeHidden) == "table" and F.shared.snipeHidden or {}
  F.shared.snipeHidden = h
  return h
end

local function Notify()
  if ns.SnipesTab then
    ns.SnipesTab.Refresh()
  end
end

-- What a vendor pays for one: copper, 0 for nothing, nil while the item's data isn't loaded.
local sellMemo = {}
local function VendorSell(id)
  local v = sellMemo[id]
  if v then
    return v
  end
  local get = C_Item and C_Item.GetItemInfo or GetItemInfo
  local name, _, _, _, _, _, _, _, _, _, sell = Lib.Call(get, id)
  if not name then
    return nil
  end
  v = Lib.Plain(sell) or 0
  sellMemo[id] = v
  return v
end
S.VendorSell = VendorSell

local function MyNames()
  local full = ARLE:MyName()
  return full, full and full:match("^(%S+)")
end

local function Diag()
  local d = type(F.char.diag) == "table" and F.char.diag or {}
  F.char.diag = d
  return d
end

local function Finish(reason)
  job.running = false
  Diag().lastEnd = ("%s %s (%d of %d read)"):format(date("%H:%M:%S"), tostring(reason), job.index or 0,
    job.total or 0)
  if reason == "partial" then
    job.partial = true
    reason = "done"
  end
  if reason ~= "done" then
    job.last = "stopped: " .. tostring(reason)
    F:Debug("read stopped: %s", tostring(reason))
    Notify()
    return
  end
  -- per item, the most profit first
  local byItem = {}
  for _, a in ipairs(job.hits) do
    local row = byItem[a.id]
    if not row then
      row = { id = a.id, link = a.link, vendor = a.vendor, auctions = {}, count = 0, cost = 0, profit = 0 }
      byItem[a.id] = row
    end
    row.auctions[#row.auctions + 1] = { count = a.count, buyout = a.buyout, unit = a.buyout / a.count,
      profit = a.profit, link = a.link }
    row.count, row.cost, row.profit = row.count + a.count, row.cost + a.buyout, row.profit + a.profit
  end
  local rows = {}
  for _, row in pairs(byItem) do
    table.sort(row.auctions, function(x, y)
      return x.unit < y.unit
    end)
    row.best = row.auctions[1].unit
    row.n = #row.auctions
    for i = MAX_AUCTIONS + 1, #row.auctions do
      row.auctions[i] = nil
    end
    rows[#rows + 1] = row
  end
  table.sort(rows, function(x, y)
    if x.profit ~= y.profit then
      return x.profit > y.profit
    end
    return x.id < y.id
  end)
  for i = MAX_ROWS + 1, #rows do
    rows[i] = nil
  end
  local s = Store()
  s.at, s.total, s.rows, s.skipped = time(), job.total, rows, #job.retry
  local profit = 0
  for _, row in ipairs(rows) do
    profit = profit + row.profit
  end
  s.partial = job.partial and job.index or nil
  job.last = ("%d items in %d auctions below vendor price, %s profit%s"):format(#rows, #job.hits,
    Lib.FormatMoney(profit), job.partial and (" (the list went away after %d of %d auctions)"):format(job.index,
    job.total) or "")
  F:Debug("read done: %d auctions read, %s, %d without item data", job.total, job.last, #job.retry)
  if F.db.chat ~= false then
    if #rows > 0 then
      F:Print(("Snipes: %s. See the ARL tab on the auction house."):format(job.last))
    else
      F:Print("Snipes: nothing below vendor price in this full scan.")
    end
  end
  Notify()
end

-- One auction: a hit when its buyout beats the vendor by the minimum profit; nil when its item isn't loaded.
local function Check(i, minProfit, me, meShort)
  local info = { Lib.Call(C_AuctionHouse.GetReplicateItemInfo, i) }
  local count, buyout, owner, ownerFull, id = info[3], info[10], info[14], info[15], info[17]
  count, buyout, id = Lib.Plain(count), Lib.Plain(buyout), Lib.Plain(id)
  if not (id and count and count > 0 and buyout and buyout > 0) then
    return true
  end
  owner, ownerFull = Lib.Plain(owner), Lib.Plain(ownerFull)
  if owner and (owner == me or owner == meShort or ownerFull == me) then
    return true
  end
  local vendor = VendorSell(id)
  if vendor == nil then
    if C_Item and C_Item.RequestLoadItemDataByID then
      Lib.Call(C_Item.RequestLoadItemDataByID, id)
    end
    return nil
  end
  local profit = vendor * count - buyout
  if vendor > 0 and profit >= minProfit then
    job.hits[#job.hits + 1] = { id = id, count = count, buyout = buyout, vendor = vendor, profit = profit,
      link = Lib.Call(C_AuctionHouse.GetReplicateItemLink, i) }
  end
  return true
end

local Step
local function Retry()
  if not job.running then
    return
  end
  if Lib.Call(C_AuctionHouse.GetNumReplicateItems) ~= job.total then
    F:Debug("the list changed before the second pass: keeping what was read")
    Finish("partial")
    return
  end
  local list = job.retry
  job.retry = {}
  local minProfit = math.max(1, tonumber(F.db.minProfit) or 100)
  local me, meShort = MyNames()
  for _, i in ipairs(list) do
    if not Check(i, minProfit, me, meShort) then
      job.retry[#job.retry + 1] = i
    end
  end
  job.tries = job.tries + 1
  if #job.retry > 0 and job.tries < RETRIES then
    F:After(RETRY_WAIT, Retry)
  else
    Finish("done")
  end
end

Step = function()
  if not job.running then
    return
  end
  if Lib.Call(C_AuctionHouse.GetNumReplicateItems) ~= job.total then
    F:Debug("the list changed or went away at %d of %d: keeping what was read", job.index, job.total)
    Finish("partial")
    return
  end
  local minProfit = math.max(1, tonumber(F.db.minProfit) or 100)
  local me, meShort = MyNames()
  local stop = math.min(job.total, job.index + SLICE)
  for i = job.index, stop - 1 do
    if not Check(i, minProfit, me, meShort) then
      job.retry[#job.retry + 1] = i
    end
  end
  job.index = stop
  Notify()
  if job.index < job.total then
    F:After(0, Step)
  elseif #job.retry > 0 then
    F:Debug("%d auctions wait for their item data", #job.retry)
    job.tries = 0
    F:After(RETRY_WAIT, Retry)
  else
    Finish("done")
  end
end

-- Read the replicate list the client holds (Auctionator's last full scan this session).
function S.Read(why)
  if job.running then
    return false, "already reading"
  end
  if not (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems) then
    return false, "this client has no full scan list"
  end
  local n = Lib.Plain(Lib.Call(C_AuctionHouse.GetNumReplicateItems)) or 0
  Diag().lastTry = ("%s %s: %d auctions"):format(date("%H:%M:%S"), tostring(why), n)
  if n <= 0 then
    return false, "the game holds no full scan list right now: run a full scan in Auctionator (its Auctionator "
      .. "tab) with Snipes on, and it's read as the auctions arrive"
  end
  pending = nil
  job.running, job.index, job.total, job.hits, job.retry, job.tries = true, 0, n, {}, {}, 0
  job.partial = false
  F:Debug("reading %d auctions (%s)", n, tostring(why))
  Notify()
  F:After(0, Step)
  return true
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- Auctionator keeps every callback for the session (there's no unregister), so it's registered once and does
-- nothing while the feature is off or no full scan answer is waiting.
local dbHooked = false

function F:OnEnable()
  job.running, pending = false, nil
  wipe(sellMemo)
  if not dbHooked and AH.API() then
    dbHooked = AH.OnDBUpdate(function()
      if F._active and pending and not job.running then
        F:Debug("Auctionator finished its full scan and ours wasn't read yet: reading it")
        S.Read("Auctionator's done")
      end
    end)
  end
  self:On("REPLICATE_ITEM_LIST_UPDATE", function()
    local n = Lib.Plain(Lib.Call(C_AuctionHouse.GetNumReplicateItems)) or 0
    Diag().lastAnswer = ("%s %d auctions"):format(date("%H:%M:%S"), n)
    F:Debug("the server answered a full scan (%d auctions): reading it now", n)
    if job.running and job.total == n then
      return -- (the same answer again)
    end
    if job.running then
      Finish("a new full scan")
    end
    pending = GetTime()
    local ok, err = S.Read("the server's answer")
    if not ok then
      F:Debug("can't read the server's answer: %s", tostring(err))
    end
  end)
  self:On("AUCTION_HOUSE_SHOW", function()
    if ns.SnipesTab then
      ns.SnipesTab.Attach()
    end
  end)
  self:On("AUCTION_HOUSE_CLOSED", function()
    pending = nil
    if job.running then
      Finish("the auction house closed")
    end
  end)
  if ns.SnipesTab then
    ns.SnipesTab.Enable()
  end
end

function F:OnDisable()
  job.running, pending = false, nil
  if ns.SnipesTab then
    ns.SnipesTab.Disable()
  end
end

function F:OnOptionChanged()
  Notify()
end

function F:main()
  self:Print(self:GetStatus())
end

F.commands = {
  { name = "read", help = "reads Auctionator's last full scan again (auction house open)", run = function(self)
    local ok, err = S.Read("command")
    if not ok then
      self:Print("can't: " .. err .. ".")
    end
  end },
  { name = "list", args = "[n]", help = "prints the n most profitable snipes (default 5)", run = function(self, rest)
    local s = Store()
    local n = tonumber(rest) or 5
    if #s.rows == 0 then
      self:Print("nothing yet: run a full scan in Auctionator with the auction house open.")
      return
    end
    self:Print(("last full scan %s ago:"):format(Lib.FormatDuration(time() - s.at)))
    for i, row in ipairs(s.rows) do
      if i > n then
        break
      end
      print(("   %d. %s x%d: buy %s, vendor %s, profit %s"):format(i, row.link or Items.Link(row.id), row.count,
        Lib.FormatMoney(row.cost), Lib.FormatMoney(row.vendor * row.count), Lib.FormatMoney(row.profit)))
    end
  end },
}

function F:GetStatus()
  if not AH.API() then
    return "Active · waiting for Auctionator"
  end
  if job.running then
    return ("Active · reading the full scan: %d of %d"):format(job.index or 0, math.max(job.total or 0, 1))
  end
  if pending then
    return "Active · the server answered a full scan: waiting for Auctionator to finish"
  end
  local s = Store()
  if not s.at or s.at == 0 then
    return "Active · no full scan yet: run one in Auctionator (its Auctionator tab)"
  end
  return ("Active · last full scan %s ago%s"):format(Lib.FormatDuration(time() - s.at),
    job.last and (" · " .. job.last) or (" · " .. #s.rows .. " items"))
end

function F:ReportDetails()
  local s = Store()
  local d = type(F.char.diag) == "table" and F.char.diag or {}
  return {
    ("Auctionator API: %s, DB callback: %s"):format(AH.API() and "yes" or "no", dbHooked and "yes" or "no"),
    ("Server's last full scan answer: %s"):format(tostring(d.lastAnswer or "none seen")),
    ("Last read try: %s · last end: %s"):format(tostring(d.lastTry or "-"), tostring(d.lastEnd or "-")),
    ("Replicate list now: %s auctions"):format(tostring(C_AuctionHouse and Lib.Call(C_AuctionHouse.GetNumReplicateItems))),
    ("Last read: %s, %d auctions, %d items, %d without item data"):format(
      s.at and s.at > 0 and date("%Y-%m-%d %H:%M", s.at) or "never", s.total or 0, #s.rows, s.skipped or 0),
    "Last: " .. tostring(job.last or "-"),
  }
end

ARLE:RegisterModule(F)
