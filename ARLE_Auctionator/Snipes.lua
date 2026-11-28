-- Snipes: the auctions selling for less than a vendor pays for the same items,
-- so buying them and selling them to a vendor is a sure profit. Shown in the
-- ARL tab on the auction house (SnipesTab.lua).
--
-- Where the auctions come from (all through Blizzard's C_AuctionHouse API;
-- Auctionator is all rights reserved, none of its code or internals is used):
--   1. Our own Scan (the panel's button, `/arl snipes scan`): an empty browse
--      search (SendBrowseQuery), paged to the end (RequestMoreBrowseResults).
--   2. Auctionator's own "Full Scan": with its "replicate scan" option off (its
--      default, and what Forever players have), that is the same empty browse
--      search, paged by Auctionator. Every browse result goes through our
--      collector too (AUCTION_HOUSE_BROWSE_RESULTS_UPDATED / _ADDED), and when
--      Auctionator's public "done" callback (Auctionator.API.v1.RegisterForDBUpdate)
--      comes after at least PASSIVE_MIN items, that was a full scan: we take
--      it. (0.21.0 / 0.21.1 only listened for the replicate list below, which
--      this kind of scan never makes: nothing was found.)
--   3. Auctionator's replicate scan (that option on): REPLICATE_ITEM_LIST_UPDATE,
--      read at once through GetNumReplicateItems / GetReplicateItemInfo, SLICE
--      a frame; exact auctions, kept even if the list goes away mid-read.
--
-- A browse row is one item: its lowest price (each) and the quantity listed.
-- An item whose lowest price is under its vendor price (GetItemInfo's 11th
-- value) by enough that all it lists could make the minimum profit is listed
-- right away from that (profit "up to": as if all were at the lowest price).
-- 0.21.1-pre looked every one up on its own after the scan, one server search
-- each, and 70 took minutes (the user: "too slow"); now that's on demand:
-- "Check top N" (`S.CheckTop`) looks the top rows up (SendSearchQuery, price
-- order, our own auctions apart: ITEM_ / COMMODITY_SEARCH_RESULTS_UPDATED) and
-- puts their exact auctions under vendor price in their place ("exact"); a
-- search that comes back empty is sent again (like Auctionator's own search
-- scan does), one that never answers (DETAIL_WAIT) keeps its row.
--
-- Results, per item (cheapest auctions first, most profit first), go to
-- `shared.snipeScans[realm]` (in SHARED_ONLY). Buying goes through
-- Auctionator's Shopping tab (MultiSearchExact): a listing may be gone by then.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items = ARLE.Lib, ARLE.Lib.Items
local AH = ARLE.Bridge.Auctionator

local SLICE = 1500 -- replicate auctions read per frame
local RETRIES = 3 -- passes over items whose data wasn't loaded
local RETRY_WAIT = 1.5 -- seconds between those passes
local MAX_ROWS = 300 -- items kept
local MAX_AUCTIONS = 25 -- auctions kept per item
local PASSIVE_MIN = 1000 -- browse items seen before Auctionator's "done" counts as its full scan
local PUMP = 0.2 -- seconds between our query steps
local BROWSE_WAIT = 20 -- seconds without a browse page before our scan gives up on the rest
local CHECK_TOP = 20 -- rows "Check top" looks up one by one
local DETAIL_WAIT = 8 -- seconds for one lookup's answer
local DETAIL_TRIES = 3 -- sends of one lookup that comes back empty
local DETAIL_PAGES = 3 -- pages of one item's auctions, while they're all still under vendor price

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
  commandArgs = "[scan|stop|check [n]|read|list [n]]",
  commandHelp = "auctions selling below vendor price, from a full scan (ours or Auctionator's)",
  mainHelp = "says what the last scan found",
  description = "Lists the auctions selling for less than a vendor pays for the same items, so buying and vendoring "
    .. "them is a sure profit. Scan from its panel in the ARL tab on the auction house, or run Auctionator's full "
    .. "scan: either fills the list.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "minProfit", type = "select", label = "Smallest profit per auction worth listing", values = profitValues,
      default = 100, cmd = "min" },
    { key = "chat", type = "boolean", label = "Tell me in chat what a scan found", default = true, cmd = "chat" },
  },
}

local S = {} -- what SnipesTab.lua reads
ns.Snipes = S
S.F = F

-- job: the work in progress. phase nil (idle), "browse" (our scan paging), "check" (vendor prices loading),
-- "detail" (looking candidates up), "replicate" (reading the replicate list).
local job = {}
S.job = job
local seen = {} -- browse results since the last new search: itemID -> { key, price, qty, own }
local seenCount = 0
local pendingReplicate = false

local function Diag()
  local d = type(F.char.diag) == "table" and F.char.diag or {}
  F.char.diag = d
  return d
end

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

function S.Busy()
  return job.phase ~= nil
end

local function Notify()
  if ns.SnipesTab then
    ns.SnipesTab.Refresh()
  end
end

local function MinProfit()
  return math.max(1, tonumber(F.db.minProfit) or 100)
end

local function AHOpen()
  return AuctionHouseFrame and AuctionHouseFrame:IsShown() and C_AuctionHouse ~= nil
end

local function Ready()
  return Lib.Call(C_AuctionHouse.IsThrottledMessageSystemReady) ~= false
end

local function PriceSorts()
  local e = Enum and Enum.AuctionHouseSortOrder
  return e and { { sortOrder = e.Price, reverseSort = false } } or {}
end

-- What a vendor pays for one: copper, 0 for nothing, nil while the item's data isn't loaded (asked for).
local sellMemo = {}
local function VendorSell(id)
  local v = sellMemo[id]
  if v then
    return v
  end
  local get = C_Item and C_Item.GetItemInfo or GetItemInfo
  local name, _, _, _, _, _, _, _, _, _, sell = Lib.Call(get, id)
  if not name then
    if C_Item and C_Item.RequestLoadItemDataByID then
      Lib.Call(C_Item.RequestLoadItemDataByID, id)
    end
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

-------------------------------------------------------------------------------
-- Results
-------------------------------------------------------------------------------

-- Exact rows from auctions: hits = { { id, link, count, buyout, vendor, profit } } -> one row per item.
local function ExactRows(hits)
  local byItem = {}
  for _, a in ipairs(hits) do
    local row = byItem[a.id]
    if not row then
      row = { id = a.id, link = a.link, vendor = a.vendor, auctions = {}, count = 0, cost = 0, profit = 0 }
      byItem[a.id] = row
    end
    row.link = row.link or a.link
    row.auctions[#row.auctions + 1] = { count = a.count, buyout = a.buyout, unit = a.buyout / a.count,
      profit = a.profit }
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
    row.exact = true
    row.each = row.vendor - row.best
    rows[#rows + 1] = row
  end
  return rows
end

-- Rows straight from a browse: candidates = { { id, key, price, qty, vendor, edge, own } }.
local function BrowseRows(candidates)
  local rows = {}
  for _, c in ipairs(candidates) do
    rows[#rows + 1] = { id = c.id, key = c.key, vendor = c.vendor, best = c.price, count = c.qty, each = c.edge,
      cost = c.price * c.qty, profit = c.edge * c.qty, own = c.own, exact = false }
  end
  return rows
end

-- Sorted, cut, stored and said.
local function Save(rows, total, source, partial, quiet)
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
  s.at, s.total, s.rows, s.source, s.partial = time(), total, rows, source, partial
  local profit, upTo = 0, false
  for _, row in ipairs(rows) do
    profit = profit + row.profit
    upTo = upTo or not row.exact
  end
  job.last = ("%d items below vendor price, %s%s profit%s"):format(#rows, upTo and "up to " or "",
    Lib.FormatMoney(math.floor(profit)), partial and " (partial)" or "")
  Diag().lastEnd = ("%s %s: %s"):format(date("%H:%M:%S"), source, job.last)
  F:Debug("published from %s: %s", source, job.last)
  if F.db.chat ~= false and not quiet then
    if #rows > 0 then
      F:Print(("Snipes: %s. See the ARL tab on the auction house."):format(job.last))
    else
      F:Print("Snipes: nothing below vendor price in this scan.")
    end
  end
  Notify()
end

local function Publish(hits, total, source, partial)
  Save(ExactRows(hits), total, source, partial)
end

local function Stop(reason)
  if job.phase then
    F:Debug("stopped (%s) during %s", tostring(reason), job.phase)
  end
  job.phase = nil
  job.query = nil
  job.stopped = reason
  Notify()
end
S.Stop = Stop

-------------------------------------------------------------------------------
-- Browse: collect, then candidates, then the lookups
-------------------------------------------------------------------------------

local function TakeBrowse(results)
  if not Lib.Readable(results) then
    return
  end
  for _, r in ipairs(results) do
    local key = Lib.Readable(r) and r.itemKey
    local id = Lib.Readable(key) and Lib.Plain(key.itemID)
    local price, qty = Lib.Plain(r.minPrice), Lib.Plain(r.totalQuantity)
    if id and price and price > 0 and qty and qty > 0 then
      local old = seen[id]
      if not old then
        seenCount = seenCount + 1
      end
      if not old or price < old.price then
        seen[id] = { price = price, qty = qty, own = Lib.Plain(r.containsOwnerItem) == true,
          key = { itemID = id, itemLevel = Lib.Plain(key.itemLevel) or 0, itemSuffix = Lib.Plain(key.itemSuffix) or 0,
            battlePetSpeciesID = Lib.Plain(key.battlePetSpeciesID) or 0 } }
      end
    end
  end
end

-- Every item seen: those under vendor price become candidates; unloaded items are read again (RETRIES).
local function Check()
  local minProfit = MinProfit()
  local waiting = {}
  for id, s in pairs(job.pool) do
    local vendor = VendorSell(id)
    if vendor == nil then
      waiting[id] = s
    elseif vendor > s.price and (vendor - s.price) * s.qty >= minProfit then
      -- (each one's edge times all listed: the most it could be; the lookup finds the real auctions)
      job.candidates[#job.candidates + 1] = { id = id, key = s.key, price = s.price, qty = s.qty, vendor = vendor,
        edge = vendor - s.price, own = s.own }
    end
  end
  job.pool = waiting
  job.tries = (job.tries or 0) + 1
  if next(waiting) and job.tries < RETRIES then
    F:After(RETRY_WAIT, function()
      if job.phase == "check" then
        Check()
      end
    end)
    return
  end
  local left = 0
  for _ in pairs(waiting) do
    left = left + 1
  end
  job.skipped = left
  F:Debug("%d of %d items under vendor price (%d without item data)", #job.candidates, job.seen, left)
  job.phase = nil
  Save(BrowseRows(job.candidates), job.seen, job.source)
end

-- A full browse is in (ours, or Auctionator's): from here on it's ours to finish.
local function FromBrowse(source)
  local pool = {}
  for id, s in pairs(seen) do
    pool[id] = s
  end
  job.phase, job.source, job.pool, job.seen = "check", source, pool, seenCount
  job.candidates, job.hits, job.tries, job.skipped = {}, {}, 0, 0
  Diag().lastBrowse = ("%s %s: %d items"):format(date("%H:%M:%S"), source, seenCount)
  F:Debug("%s: %d items seen", source, seenCount)
  Notify()
  Check()
end

-- One candidate's own auctions, read: hits under vendor price, ours left out. Returns whether to page on.
local function ReadDetail(q)
  local c, minProfit, more = q.c, MinProfit(), true
  local me, meShort = MyNames()
  if q.commodity then
    local n = Lib.Call(C_AuctionHouse.GetNumCommoditySearchResults, c.id) or 0
    for i = q.read + 1, n do
      local r = Lib.Call(C_AuctionHouse.GetCommoditySearchResultInfo, c.id, i)
      if Lib.Readable(r) then
        local unit, qty = Lib.Plain(r.unitPrice), Lib.Plain(r.quantity)
        local mine = Lib.Plain(r.numOwnerItems) or (Lib.Plain(r.containsOwnerItem) and qty) or 0
        if unit and qty then
          qty = qty - math.min(qty, mine)
          if unit >= c.vendor then
            more = false
          elseif qty > 0 and (c.vendor - unit) * qty >= minProfit then
            q.hits[#q.hits + 1] = { id = c.id, count = qty, buyout = unit * qty, vendor = c.vendor,
              profit = (c.vendor - unit) * qty }
          end
        end
      end
    end
    q.read = n
  else
    local n = Lib.Call(C_AuctionHouse.GetNumItemSearchResults, c.key) or 0
    for i = q.read + 1, n do
      local r = Lib.Call(C_AuctionHouse.GetItemSearchResultInfo, c.key, i)
      if Lib.Readable(r) then
        local buyout, qty = Lib.Plain(r.buyoutAmount), Lib.Plain(r.quantity) or 1
        local own = Lib.Plain(r.containsOwnerItem) == true
        local owners = Lib.Readable(r.owners) and r.owners
        if owners and not own then
          for _, o in ipairs(owners) do
            o = Lib.Plain(o)
            if o == me or o == meShort then
              own = true
            end
          end
        end
        if buyout and buyout > 0 and qty > 0 then
          if buyout / qty >= c.vendor then
            more = false
          elseif not own and c.vendor * qty - buyout >= minProfit then
            q.hits[#q.hits + 1] = { id = c.id, count = qty, buyout = buyout, vendor = c.vendor,
              profit = c.vendor * qty - buyout, link = Lib.Plain(r.itemLink) }
          end
        end
      end
    end
    q.read = n
  end
  return more
end

local function DetailDone(q, ok)
  if ok then
    for _, h in ipairs(q.hits) do
      job.hits[#job.hits + 1] = h
    end
  else
    F:Debug("no answer for item %d: keeping its row", q.c.id)
    job.failed[q.c.id] = true
  end
  job.query = nil
  job.done = job.done + 1
  Notify()
end

local function SendDetail(q)
  q.tries = q.tries + 1
  q.read, q.hits, q.pages = 0, {}, 1
  local ok = pcall(C_AuctionHouse.SendSearchQuery, q.c.key, PriceSorts(), true)
  q.sentAt = GetTime()
  if not ok then
    F:Debug("SendSearchQuery failed for item %d", q.c.id)
    DetailDone(q, false)
  end
end

-- The lookups are done: the rows looked up are replaced by their exact auctions (gone when none is left under
-- vendor price), the ones without an answer stay as they were.
local function Merge()
  local s = Store()
  local exact = ExactRows(job.hits)
  local found = {}
  for _, row in ipairs(exact) do
    found[row.id] = row
  end
  local rows, gone = {}, 0
  for _, row in ipairs(s.rows) do
    if not job.looked[row.id] or job.failed[row.id] then
      rows[#rows + 1] = row
    elseif found[row.id] then
      found[row.id].key = row.key
      rows[#rows + 1] = found[row.id]
    else
      gone = gone + 1
    end
  end
  job.phase = nil
  Save(rows, s.total, s.source, s.partial, true)
  if F.db.chat ~= false then
    local silent = 0
    for _ in pairs(job.failed) do
      silent = silent + 1
    end
    F:Print(("Snipes: checked %d items, %d still under vendor price%s%s."):format(job.total, #exact,
      gone > 0 and (", %d sold or gone"):format(gone) or "",
      silent > 0 and (", %d didn't answer (kept as they were)"):format(silent) or ""))
  end
end

local function NextDetail()
  local c = table.remove(job.queue, 1)
  if not c then
    Merge()
    return
  end
  local status = C_AuctionHouse.GetItemCommodityStatus and Lib.Call(C_AuctionHouse.GetItemCommodityStatus, c.id)
  local commodity = Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity
  job.query = { c = c, commodity = commodity, tries = 0 }
  SendDetail(job.query)
end

-- ITEM_ / COMMODITY_SEARCH_RESULTS_UPDATED for the item being looked up.
local function OnDetail(event, arg)
  local q = job.query
  if job.phase ~= "detail" or not q then
    return
  end
  local id = event == "COMMODITY_SEARCH_RESULTS_UPDATED" and Lib.Plain(arg)
    or (Lib.Readable(arg) and Lib.Plain(arg.itemID))
  if id ~= q.c.id then
    return
  end
  q.commodity = event == "COMMODITY_SEARCH_RESULTS_UPDATED"
  local key = q.commodity and Lib.Call(C_AuctionHouse.MakeItemKey, id) or q.c.key
  local has = Lib.Call(C_AuctionHouse.HasSearchResults, key)
  local full, qty
  if q.commodity then
    full = Lib.Call(C_AuctionHouse.HasFullCommoditySearchResults, id)
    qty = Lib.Call(C_AuctionHouse.GetCommoditySearchResultsQuantity, id)
  else
    full = Lib.Call(C_AuctionHouse.HasFullItemSearchResults, q.c.key)
    qty = Lib.Call(C_AuctionHouse.GetItemSearchResultsQuantity, q.c.key)
  end
  if has == false or (has and full == false and qty == 0) then
    -- (an empty answer the server sometimes gives: ask again)
    q.resend = q.tries < DETAIL_TRIES
    if not q.resend then
      DetailDone(q, false)
    end
    return
  end
  local more = ReadDetail(q)
  if more and full == false and q.pages < DETAIL_PAGES then
    q.pages = q.pages + 1
    q.more = true
    q.sentAt = GetTime()
    return
  end
  DetailDone(q, true)
end

-- Our scan's browse pages and the lookups, one step at a time (the throttle decides).
local function Pump()
  if job.phase == "browse" then
    if not AHOpen() then
      Stop("the auction house closed")
      return
    end
    if job.more and Ready() then
      job.more = false
      job.pageAt = GetTime()
      Lib.Call(C_AuctionHouse.RequestMoreBrowseResults)
    elseif GetTime() - (job.pageAt or 0) > BROWSE_WAIT then
      F:Debug("no browse page for %d s: taking what came", BROWSE_WAIT)
      FromBrowse("your scan (cut short)")
    end
  elseif job.phase == "detail" then
    if not AHOpen() then
      -- (the rest keep their rows)
      for _, c in ipairs(job.queue) do
        job.failed[c.id] = true
      end
      if job.query then
        DetailDone(job.query, false)
      end
      job.queue = {}
      Merge()
      return
    end
    local q = job.query
    if q then
      if (q.resend or q.more) and Ready() then
        if q.resend then
          q.resend = false
          SendDetail(q)
        else
          q.more = false
          q.sentAt = GetTime()
          if q.commodity then
            Lib.Call(C_AuctionHouse.RequestMoreCommoditySearchResults, q.c.id)
          else
            Lib.Call(C_AuctionHouse.RequestMoreItemSearchResults, q.c.key)
          end
        end
      elseif GetTime() - q.sentAt > DETAIL_WAIT then
        if q.read > 0 then
          DetailDone(q, true)
        elseif q.tries < DETAIL_TRIES and Ready() then
          SendDetail(q)
        else
          DetailDone(q, false)
        end
      end
    elseif Ready() then
      NextDetail()
    end
  end
end

-- Browse events: always collected (Auctionator's full scan is one); our scan also pages on.
local function OnBrowse(event, ...)
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    wipe(seen)
    seenCount = 0
    TakeBrowse(Lib.Call(C_AuctionHouse.GetBrowseResults))
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    TakeBrowse(...)
  elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" and job.phase == "browse" then
    F:Debug("browse failure: taking what came")
    FromBrowse("your scan (cut short)")
    return
  end
  if job.phase == "browse" then
    job.pageAt = GetTime()
    if Lib.Call(C_AuctionHouse.HasFullBrowseResults) == false then
      job.more = true
    else
      FromBrowse("your scan")
    end
    Notify()
  end
end

function S.Scan()
  if job.phase then
    return false, "a scan is already running"
  end
  if not AHOpen() then
    return false, "open the auction house first"
  end
  wipe(seen)
  seenCount = 0
  local ok = pcall(C_AuctionHouse.SendBrowseQuery, { searchString = "", sorts = {}, filters = {},
    itemClassFilters = {} })
  if not ok then
    return false, "the auction house refused the search"
  end
  job.phase, job.more, job.pageAt, job.stopped = "browse", false, GetTime(), nil
  Diag().lastScan = date("%H:%M:%S")
  F:Debug("our scan started")
  Notify()
  return true
end

-- Look the top rows (not exact yet, not hidden) up one by one for their exact auctions.
function S.CheckTop(n)
  if job.phase then
    return false, "a scan is already running"
  end
  if not (AHOpen() and C_AuctionHouse.SendSearchQuery) then
    return false, "open the auction house first"
  end
  local hidden, queue, looked = S.Hidden(), {}, {}
  for _, row in ipairs(Store().rows) do
    if #queue >= (n or CHECK_TOP) then
      break
    end
    if not row.exact and row.key and not hidden[row.id] then
      queue[#queue + 1] = { id = row.id, key = row.key, price = row.best, qty = row.count, vendor = row.vendor,
        edge = row.each }
      looked[row.id] = true
    end
  end
  if #queue == 0 then
    return false, "nothing left to check: every row shown is already exact"
  end
  job.phase, job.queue, job.looked, job.failed, job.hits = "detail", queue, looked, {}, {}
  job.done, job.total, job.query = 0, #queue, nil
  F:Debug("checking %d rows", #queue)
  Notify()
  return true
end
S.CHECK_TOP = CHECK_TOP

-- Seen in the current browse (for the panel while scanning).
function S.Seen()
  return seenCount
end

-------------------------------------------------------------------------------
-- The replicate list (Auctionator's "replicate scan" option)
-------------------------------------------------------------------------------

local function CheckReplicate(i, minProfit, me, meShort)
  local info = { Lib.Call(C_AuctionHouse.GetReplicateItemInfo, i) }
  local count, buyout, owner, ownerFull, id = info[3], info[10], info[14], info[15], info[17]
  if not (id and count and count > 0 and buyout and buyout > 0) then
    return true
  end
  if owner and (owner == me or owner == meShort or ownerFull == me) then
    return true
  end
  local vendor = VendorSell(id)
  if vendor == nil then
    return nil
  end
  local profit = vendor * count - buyout
  if vendor > 0 and profit >= minProfit then
    job.hits[#job.hits + 1] = { id = id, count = count, buyout = buyout, vendor = vendor, profit = profit,
      link = Lib.Call(C_AuctionHouse.GetReplicateItemLink, i) }
  end
  return true
end

local ReplicateStep
local function ReplicateRetry()
  if job.phase ~= "replicate" then
    return
  end
  if Lib.Call(C_AuctionHouse.GetNumReplicateItems) ~= job.total then
    job.phase = nil
    Publish(job.hits, job.total, job.source, true)
    return
  end
  local list = job.retry
  job.retry = {}
  local minProfit, me, meShort = MinProfit(), MyNames()
  for _, i in ipairs(list) do
    if not CheckReplicate(i, minProfit, me, meShort) then
      job.retry[#job.retry + 1] = i
    end
  end
  job.tries = job.tries + 1
  if #job.retry > 0 and job.tries < RETRIES then
    F:After(RETRY_WAIT, ReplicateRetry)
  else
    job.phase = nil
    Publish(job.hits, job.total, job.source)
  end
end

ReplicateStep = function()
  if job.phase ~= "replicate" then
    return
  end
  if Lib.Call(C_AuctionHouse.GetNumReplicateItems) ~= job.total then
    F:Debug("the replicate list changed at %d of %d: keeping what was read", job.done, job.total)
    job.phase = nil
    Publish(job.hits, job.done, job.source, true)
    return
  end
  local minProfit, me, meShort = MinProfit(), MyNames()
  local stop = math.min(job.total, job.done + SLICE)
  for i = job.done, stop - 1 do
    if not CheckReplicate(i, minProfit, me, meShort) then
      job.retry[#job.retry + 1] = i
    end
  end
  job.done = stop
  Notify()
  if job.done < job.total then
    F:After(0, ReplicateStep)
  elseif #job.retry > 0 then
    job.tries = 0
    F:After(RETRY_WAIT, ReplicateRetry)
  else
    job.phase = nil
    Publish(job.hits, job.total, job.source)
  end
end

-- Read the replicate list the client holds now.
function S.Read(why)
  if job.phase then
    return false, "a scan is already running"
  end
  if not (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems) then
    return false, "this client has no replicate list"
  end
  local n = Lib.Call(C_AuctionHouse.GetNumReplicateItems) or 0
  Diag().lastTry = ("%s %s: %d auctions"):format(date("%H:%M:%S"), tostring(why), n)
  if n <= 0 then
    return false, "the game holds no replicate list (that's only Auctionator's \"replicate scan\" option): use Scan"
  end
  pendingReplicate = false
  job.phase, job.source, job.done, job.total, job.hits, job.retry, job.tries = "replicate", "the replicate list", 0,
    n, {}, {}, 0
  Notify()
  F:After(0, ReplicateStep)
  return true
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

-- Auctionator keeps every callback for the session (there's no unregister), so it's registered once and does
-- nothing while the feature is off.
local dbHooked = false

local function OnAuctionatorDone()
  if not F._active or job.phase then
    return
  end
  if pendingReplicate then
    S.Read("Auctionator's done")
  elseif seenCount >= PASSIVE_MIN then
    F:Debug("Auctionator finished a search over %d items: its full scan", seenCount)
    FromBrowse("Auctionator's full scan")
    wipe(seen)
    seenCount = 0
  end
end

function F:OnEnable()
  job.phase, job.query, pendingReplicate = nil, nil, false
  wipe(sellMemo)
  wipe(seen)
  seenCount = 0
  if not dbHooked and AH.API() then
    dbHooked = AH.OnDBUpdate(function()
      ARLE.Debug.Call(F, OnAuctionatorDone)
    end)
  end
  for _, ev in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_BROWSE_FAILURE" }) do
    self:On(ev, function(_, event, ...)
      OnBrowse(event, ...)
    end)
  end
  for _, ev in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED" }) do
    self:On(ev, function(_, event, arg)
      OnDetail(event, arg)
    end)
  end
  self:On("REPLICATE_ITEM_LIST_UPDATE", function()
    local n = Lib.Call(C_AuctionHouse.GetNumReplicateItems) or 0
    Diag().lastAnswer = ("%s %d auctions"):format(date("%H:%M:%S"), n)
    if job.phase == "replicate" and job.total == n then
      return
    end
    pendingReplicate = true
    if not job.phase then
      S.Read("the server's answer")
    end
  end)
  self:On("AUCTION_HOUSE_SHOW", function()
    if ns.SnipesTab then
      ns.SnipesTab.Attach()
    end
  end)
  self:On("AUCTION_HOUSE_CLOSED", function()
    pendingReplicate = false
    if job.phase == "browse" or job.phase == "replicate" then
      Stop("the auction house closed")
    end
  end)
  self:Ticker(PUMP, Pump)
  if ns.SnipesTab then
    ns.SnipesTab.Enable()
  end
end

function F:OnDisable()
  job.phase, job.query, pendingReplicate = nil, nil, false
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
  { name = "scan", help = "scans the whole auction house for snipes (auction house open)", run = function(self)
    local ok, err = S.Scan()
    if not ok then
      self:Print("can't scan: " .. err .. ".")
    end
  end },
  { name = "stop", help = "stops a scan", run = function(self)
    if job.phase then
      Stop("stopped")
    else
      self:Print("no scan is running.")
    end
  end },
  { name = "check", args = "[n]", help = "looks the top n rows up for their exact auctions (default 20)",
    run = function(self, rest)
      local ok, err = S.CheckTop(tonumber(rest))
      if not ok then
        self:Print("can't: " .. err .. ".")
      end
    end },
  { name = "read", help = "reads Auctionator's replicate list (its \"replicate scan\" option)", run = function(self)
    local ok, err = S.Read("command")
    if not ok then
      self:Print("can't: " .. err .. ".")
    end
  end },
  { name = "list", args = "[n]", help = "prints the n most profitable snipes (default 5)", run = function(self, rest)
    local s = Store()
    local n = tonumber(rest) or 5
    if #s.rows == 0 then
      self:Print("nothing yet: open the auction house and Scan on the Snipes panel (ARL tab).")
      return
    end
    self:Print(("last scan %s ago:"):format(Lib.FormatDuration(time() - s.at)))
    for i, row in ipairs(s.rows) do
      if i > n then
        break
      end
      print(("   %d. %s x%d at %s each, vendor %s each: profit %s%s"):format(i, row.link or Items.Link(row.id),
        row.count, Lib.FormatMoney(math.floor(row.best)), Lib.FormatMoney(row.vendor),
        row.exact and "" or "up to ", Lib.FormatMoney(math.floor(row.profit))))
    end
  end },
}

-- What's happening, for the panel and the status line.
function S.Doing()
  if job.phase == "browse" then
    return ("Scanning the auction house: %d items so far"):format(seenCount)
  elseif job.phase == "check" then
    return ("Checking %d items against vendor prices"):format(job.seen or 0)
  elseif job.phase == "detail" then
    return ("Checking each auction: %d / %d items"):format(job.done or 0, math.max(job.total or 0, 1))
  elseif job.phase == "replicate" then
    return ("Reading the full scan: %d / %d auctions"):format(job.done or 0, math.max(job.total or 0, 1))
  end
end

function F:GetStatus()
  local doing = S.Doing()
  if doing then
    return "Active · " .. doing
  end
  local s = Store()
  if not s.at or s.at == 0 then
    return "Active · no scan yet: auction house, ARL tab, Snipes, Scan (or Auctionator's full scan)"
  end
  return ("Active · last scan %s ago%s"):format(Lib.FormatDuration(time() - s.at),
    job.last and (" · " .. job.last) or (" · " .. #s.rows .. " items"))
end

function F:ReportDetails()
  local s = Store()
  local d = type(F.char.diag) == "table" and F.char.diag or {}
  return {
    ("Auctionator API: %s, done callback: %s"):format(AH.API() and "yes" or "no", dbHooked and "yes" or "no"),
    ("Now: %s · browse items seen %d"):format(S.Doing() or "idle", seenCount),
    ("Last own scan started: %s · last full browse taken: %s"):format(tostring(d.lastScan or "-"),
      tostring(d.lastBrowse or "-")),
    ("Replicate answer: %s · read try: %s"):format(tostring(d.lastAnswer or "-"), tostring(d.lastTry or "-")),
    ("Last result: %s"):format(tostring(d.lastEnd or "-")),
    ("Stored: %s, %d items seen, %d rows, from %s"):format(s.at and s.at > 0 and date("%Y-%m-%d %H:%M", s.at)
      or "never", s.total or 0, #s.rows, tostring(s.source or "-")),
  }
end

ARLE:RegisterModule(F)
