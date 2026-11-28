-- Craftsman's Writs: a tab on the auction house that prices every Craftsman's
-- Writ for sale, with what its quest asks for (bought, crafted from materials
-- or from a vendor), and ranks them by gold per reputation with your side's
-- supply camp (Durotar Supply and Logistics / Azeroth Commerce Authority), so
-- the reputation is farmed as cheaply as possible.
--
-- The writs: a writ is a bind-on-equip paper that starts a daily quest asking
-- for one crafted item (sometimes several). The quest gives reputation by the
-- writ's rank (Journeyman 75, Expert 125, Artisan 200) and a Coin Pouch.
-- Which writ asks for what, the ranks, the reputation and the recipes are read
-- at run time from ItemTree's data (ItemTree, all rights reserved: its tables
-- are read through its own loader `ItemTree.Data:Get` and `ItemTreeAPI`, never
-- copied into ARL): "Supplies" (writs, writRanks, camps), "Uses" (the recipes
-- that make an item, `p`) and the recipe rows (`GetRecipe`: `re` reagents,
-- `out` what one craft makes). Vendor prices come from ItemTreeAPI's item
-- facts (`vendors.buyPrice`). Without ItemTree the tab says so.
--
-- The scan (the Scan button, AH open): C_AuctionHouse browse queries, one at a
-- time when the throttle says ready: the writs first (by item key in batches
-- with `SearchForItemKeys` where the client has it, else a keyword search for
-- the writs' shared name), then what the listed writs ask for and every
-- material down to CRAFT_DEPTH (by item key, else one search per name). Only
-- the lowest unit price and the quantity are kept, per realm, in
-- `shared.writScans` (a day old counts as stale: Auctionator's price stands in
-- for an item the scan didn't see). Auctionator (its LibAHTab-1-0, a LibStub
-- library meant for this) adds the tab; nothing is written on Blizzard's AH.
--
-- The cost of a writ: its price (free when you hold one and "use what I have"
-- is on) + its count of the item at the cheapest of buying it, a vendor, or
-- crafting it (recipes you know, or any with "crafts I don't know"; each
-- material priced the same way, recursively). Per reputation = cost / rep.
-- The plan: the cheapest writs not done today, one of each, until the next
-- standing is reached (or PLAN_MAX of them).
--
-- UI: CraftsmansWritsTab.lua (ns.WritsTab).
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items = ARLE.Lib, ARLE.Lib.Items
local AH = ARLE.Bridge.Auctionator

local CAMPS = { Alliance = 2586, Horde = 2587 } -- reputation ids, when ItemTree names none
local CAMP_NAMES = { [2586] = "Azeroth Commerce Authority", [2587] = "Durotar Supply and Logistics" }
local RANK_NAMES = { [2] = "Journeyman", [3] = "Expert", [4] = "Artisan" }
local RANK_REP = { [2] = 75, [3] = 125, [4] = 200 } -- when ItemTree's rank row states none
local CRAFT_DEPTH = 3 -- crafted materials looked into this many steps down
local QUERY_TIMEOUT = 12 -- seconds for one query's results
local KEY_BATCH = 40 -- item keys per SearchForItemKeys
local STALE = 86400 -- seconds: an older scan price gives way to Auctionator's
local PLAN_MAX = 10 -- writs in the plan when no next standing reads
local PUMP = 0.2 -- seconds between scan steps
local NAME_TRIES = 4 -- a name search waits this many times (1 s apart) for the item's name to load

local F = {
  id = "CraftsmansWrits",
  addon = ADDON,
  title = "Craftsman's Writs",
  group = "Auctionator",
  extends = "Auctionator",
  command = "writs",
  commandArgs = "[scan|best [n]|stop]",
  commandHelp = "Craftsman's Writs priced at the auction house, cheapest reputation first",
  mainHelp = "says how the last scan went",
  description = "A Writs tab on the auction house: scans every Craftsman's Writ and what its quest asks for "
    .. "(bought or crafted from materials) and ranks them by gold per reputation with your supply camp. Needs "
    .. "ItemTree for the writ data.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "useBags", type = "boolean", label = "Count writs and items I already have as free", default = true,
      cmd = "bags" },
    { key = "anyCraft", type = "boolean", label = "Price crafts I don't know too (someone else crafts them)",
      default = false, cmd = "anycraft" },
    { key = "hideDone", type = "boolean", label = "Hide writs done today", default = true, cmd = "hidedone" },
    { key = "showUnlisted", type = "boolean", label = "Show writs nobody is selling", default = false,
      cmd = "unlisted" },
    { key = "scanOnOpen", type = "boolean", label = "Scan when I open the Writs tab (if the last scan is over "
      .. "15 minutes old)", default = false, cmd = "autoscan" },
  },
}

local W = {} -- what CraftsmansWritsTab.lua reads
ns.Writs = W
W.F = F
W.RANK_NAMES = RANK_NAMES

-------------------------------------------------------------------------------
-- ItemTree's data (read at run time through its own loader, never copied)
-------------------------------------------------------------------------------

local data = { list = nil, byId = {}, ranks = {}, camps = {} }

local function TreeData()
  local it = rawget(_G, "ItemTree")
  local d = type(it) == "table" and it.Data
  if type(d) == "table" and type(d.Get) == "function" then
    return d
  end
end

local function TreeGet(name)
  local d = TreeData()
  if not d then
    return nil
  end
  local ok, t = pcall(d.Get, d, name)
  return ok and type(t) == "table" and t or nil
end

local function Whole(v)
  v = tonumber(v)
  return v and v == v and math.floor(v) or nil
end

-- The writ list, built once: { id, quest, item, count, rank, rep, repGuess }.
function W.Load()
  if data.list then
    return true
  end
  local api = rawget(_G, "ItemTreeAPI")
  if type(api) == "table" and type(api.RequestData) == "function" then
    pcall(api.RequestData)
  end
  local s = TreeGet("Supplies")
  if not (s and type(s.writs) == "table") then
    return false
  end
  data.ranks = type(s.writRanks) == "table" and s.writRanks or {}
  data.camps = type(s.camps) == "table" and s.camps or {}
  local list = {}
  for id, row in pairs(s.writs) do
    id = Whole(id)
    local item = type(row) == "table" and Whole(row.i)
    if id and item then
      local rank = Whole(row.t) or 0
      local rr = type(data.ranks[rank]) == "table" and data.ranks[rank] or {}
      local rep = Whole(rr.r)
      local w = {
        id = id,
        quest = Whole(row.q),
        item = item,
        count = math.max(1, Whole(row.n) or 1),
        rank = rank,
        rep = rep or RANK_REP[rank],
        repGuess = rep == nil or rr.rp == 1,
        pouch = Whole(rr.pm),
      }
      if w.rep and w.rep > 0 then
        list[#list + 1] = w
        data.byId[id] = w
      end
    end
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  data.list = list
  F:Debug("loaded %d writs from ItemTree", #list)
  return true
end

function W.List()
  return data.list or {}
end

-- The recipes that make an item (spell ids; item combines and crate bundles left out).
local function Producers(id)
  local d = TreeData()
  if not (d and type(d.GetUses) == "function") then
    return {}
  end
  local ok, row = pcall(d.GetUses, d, id)
  return ok and type(row) == "table" and type(row.p) == "table" and row.p or {}
end

local function Recipe(spell)
  local d = TreeData()
  if not (d and type(d.GetRecipe) == "function") or type(spell) ~= "number" or spell <= 0 then
    return nil
  end
  local ok, r = pcall(d.GetRecipe, d, spell)
  if ok and type(r) == "table" and r.src ~= "item" and type(r.re) == "table" and type(r.out) == "table" then
    return r
  end
end
W.Recipe = Recipe

local vendorMemo = {}
-- A vendor's price for one, from ItemTree's item facts, or nil.
local function VendorPrice(id)
  local v = vendorMemo[id]
  if v ~= nil then
    return v or nil
  end
  local api = rawget(_G, "ItemTreeAPI")
  local price = false
  if type(api) == "table" and type(api.GetItemFacts) == "function" then
    local ok, facts = pcall(api.GetItemFacts, id)
    local vendors = ok and type(facts) == "table" and facts.vendors
    if type(vendors) == "table" and ((tonumber(vendors.count) or 0) > 0 or vendors.everywhere) then
      local p = tonumber(vendors.buyPrice)
      price = p and p > 0 and p or false
    end
  end
  vendorMemo[id] = price
  return price or nil
end
W.VendorPrice = VendorPrice

-- Recipes: does the character know it.
local knownMemo = {}
local function Known(spell)
  local k = knownMemo[spell]
  if k == nil then
    k = Lib.Call(IsPlayerSpell, spell) == true
    if not k and C_SpellBook and C_SpellBook.IsSpellKnown then
      k = Lib.Call(C_SpellBook.IsSpellKnown, spell) == true
    end
    knownMemo[spell] = k
  end
  return k
end
W.Known = Known

-------------------------------------------------------------------------------
-- Prices (this realm's scan, else Auctionator's)
-------------------------------------------------------------------------------

local function ScanStore()
  local all = type(F.shared.writScans) == "table" and F.shared.writScans or {}
  F.shared.writScans = all
  local realm = Lib.Plain(GetRealmName and GetRealmName()) or "?"
  local s = all[realm]
  if type(s) ~= "table" or type(s.prices) ~= "table" or type(s.searched) ~= "table" then
    s = { at = 0, prices = {}, searched = {} }
    all[realm] = s
  end
  return s
end
W.ScanStore = ScanStore

-- Lowest unit price on the AH: copper, source ("scan" / "auctionator"), quantity listed, age in seconds / days.
function W.Price(id)
  local s = ScanStore()
  local searched = s.searched[id]
  local fresh = searched and time() - searched < STALE
  local p = s.prices[id]
  if fresh then
    if p then
      return p.p, "scan", p.q, time() - searched
    end
    return nil, "none"
  end
  local a = AH.Price(id)
  if a then
    return a, "auctionator", nil, AH.Age(id)
  end
  if p then
    return p.p, "old", p.q, time() - searched
  end
end

-------------------------------------------------------------------------------
-- Costs
-------------------------------------------------------------------------------

local memo, visiting = {}, {}

-- How to get one of an item at the lowest cost: { id, cost, src ("buy" / "vendor" / "craft"),
-- buy, vendor, craft, spell, yield, known, parts = { { id, count, node } } }; cost nil when nothing prices it.
local function Node(id, depth)
  local key = id * 10 + depth
  if memo[key] then
    return memo[key]
  end
  if visiting[id] then
    return nil
  end
  visiting[id] = true
  local n = { id = id }
  n.buy, n.buySrc = W.Price(id)
  n.vendor = VendorPrice(id)
  if depth < CRAFT_DEPTH and not n.vendor then
    for _, spell in ipairs(Producers(id)) do
      local r = Recipe(spell)
      if r and Whole(r.out[1]) == id then
        local known = Known(spell)
        if known or F.db.anyCraft then
          local total, parts, ok = 0, {}, true
          for _, re in ipairs(r.re) do
            local rid, count = Whole(re[1]), Whole(re[2]) or 1
            local sub = rid and Node(rid, depth + 1)
            if not (sub and sub.cost) then
              ok = false
              break
            end
            total = total + sub.cost * count
            parts[#parts + 1] = { id = rid, count = count, node = sub }
          end
          if ok and #parts > 0 then
            local yield = math.max(1, Whole(r.out[2]) or 1)
            local unit = total / yield
            -- (a recipe you know beats one you don't at the same cost)
            if not n.craft or unit < n.craft or (unit == n.craft and known and not n.known) then
              n.craft, n.spell, n.parts, n.yield, n.known = unit, spell, parts, yield, known
            end
          end
        end
      end
    end
  end
  for _, src in ipairs({ "vendor", "buy", "craft" }) do
    local c = n[src]
    if c and (not n.cost or c < n.cost) then
      n.cost, n.src = c, src
    end
  end
  visiting[id] = nil
  memo[key] = n
  return n
end

local function QuestDone(q)
  if not (q and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) then
    return false
  end
  return Lib.Call(C_QuestLog.IsQuestFlaggedCompleted, q) == true
end

-- Every writ priced: { w, writPrice, writSrc, writQty, writAge, haveWrit, haveItem, need, node, writCost, fill,
-- total, perRep, done, listed }, the cheapest per reputation first.
function W.Evaluate()
  wipe(memo)
  wipe(visiting)
  wipe(knownMemo)
  local out = {}
  local bags = F.db.useBags ~= false
  for _, w in ipairs(W.List()) do
    local e = { w = w }
    e.writPrice, e.writSrc, e.writQty, e.writAge = W.Price(w.id)
    e.haveWrit = Items.Count(w.id, true)
    e.haveItem = Items.Count(w.item, true)
    e.done = QuestDone(w.quest)
    e.listed = e.writPrice ~= nil
    e.node = Node(w.item, 0)
    e.need = bags and math.max(0, w.count - e.haveItem) or w.count
    if e.need == 0 then
      e.fill = 0
    elseif e.node and e.node.cost then
      e.fill = e.node.cost * e.need
    end
    if bags and e.haveWrit > 0 then
      e.writCost = 0
    else
      e.writCost = e.writPrice
    end
    if e.writCost and e.fill then
      e.total = e.writCost + e.fill
      e.perRep = e.total / w.rep
    end
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    if a.done ~= b.done then
      return not a.done
    end
    if (a.perRep ~= nil) ~= (b.perRep ~= nil) then
      return a.perRep ~= nil
    end
    if a.perRep and b.perRep and a.perRep ~= b.perRep then
      return a.perRep < b.perRep
    end
    return a.w.id < b.w.id
  end)
  return out
end

-------------------------------------------------------------------------------
-- Standing and the plan
-------------------------------------------------------------------------------

function W.Camp()
  local faction = Lib.Plain((UnitFactionGroup("player")))
  local side = faction == "Alliance" and 1 or faction == "Horde" and 2 or nil
  return side and (Whole(data.camps[side]) or CAMPS[faction]) or nil
end

-- { id, name, reaction, label, into, size, toNext } or nil.
function W.Standing()
  local camp = W.Camp()
  if not camp then
    return nil
  end
  local s = { id = camp, name = CAMP_NAMES[camp] }
  local d = C_Reputation and C_Reputation.GetFactionDataByID and Lib.Call(C_Reputation.GetFactionDataByID, camp)
  if Lib.Readable(d) and d.reaction then
    s.name = Lib.Str(d.name) or s.name
    s.reaction = d.reaction
    local low, high, value = d.currentReactionThreshold, d.nextReactionThreshold, d.currentStanding
    if low and high and value then
      s.into, s.size = value - low, high - low
    end
  elseif GetFactionInfoByID then
    local name, _, reaction, low, high, value = Lib.Call(GetFactionInfoByID, camp)
    if reaction then
      s.name, s.reaction = Lib.Str(name) or s.name, reaction
      if low and high and value then
        s.into, s.size = value - low, high - low
      end
    end
  end
  if s.reaction then
    s.label = Lib.Str(_G["FACTION_STANDING_LABEL" .. s.reaction]) or ("Rank " .. s.reaction)
    s.nextLabel = s.reaction < 8 and Lib.Str(_G["FACTION_STANDING_LABEL" .. (s.reaction + 1)]) or nil
    if s.into and s.size and s.size > 0 and s.reaction < 8 then
      s.toNext = math.max(0, s.size - s.into)
    end
  end
  return s
end

-- The cheapest writs to buy now: one of each, not done today, priced; until the next standing is reached (or
-- PLAN_MAX). Marks e.plan; returns { count, cost, rep, toNext }.
function W.Plan(list, standing)
  local goal = standing and standing.toNext
  local p = { count = 0, cost = 0, rep = 0, toNext = goal }
  for _, e in ipairs(list) do
    e.plan = nil
    if not e.done and e.total and (e.listed or e.writCost == 0) then
      local enough = goal and p.rep >= goal or (not goal and p.count >= PLAN_MAX)
      if not enough then
        e.plan = true
        p.count, p.cost, p.rep = p.count + 1, p.cost + e.total, p.rep + e.w.rep
      end
    end
  end
  return p
end

-------------------------------------------------------------------------------
-- The scan
-------------------------------------------------------------------------------

local scan = { running = false }
W.scan = scan

local function AHOpen()
  return AuctionHouseFrame and AuctionHouseFrame:IsShown() and C_AuctionHouse ~= nil
end

local function Sorts()
  local e = Enum and Enum.AuctionHouseSortOrder
  return e and { { sortOrder = e.Price, reverseSort = false } } or {}
end

local function Notify()
  if ns.WritsTab then
    ns.WritsTab.Refresh()
  end
end

-- The writs' shared name in this client's language ("Craftsman's Writ"), from a writ's own name.
local function WritKeyword()
  for _, w in ipairs(W.List()) do
    local name = Items.GetInfo and Items.GetInfo(w.id)
    if type(name) == "string" then
      local head = name:match("^(.-)%s*[:%-]%s") or name:match("^(.-)%s*:")
      if head and #head > 3 then
        return head
      end
    end
  end
  return "Craftsman's Writ"
end

-- The materials of an item down to CRAFT_DEPTH, for every recipe (known or not, so "crafts I don't know"
-- needs no new scan); vendor-sold ones left out: a vendor's price is fixed.
local function Gather(id, depth, into)
  if into[id] ~= nil then
    return
  end
  if VendorPrice(id) then
    into[id] = false
    return
  end
  into[id] = true
  if depth >= CRAFT_DEPTH then
    return
  end
  for _, spell in ipairs(Producers(id)) do
    local r = Recipe(spell)
    if r and Whole(r.out[1]) == id then
      for _, re in ipairs(r.re) do
        local rid = Whole(re[1])
        if rid then
          Gather(rid, depth + 1, into)
        end
      end
    end
  end
end

local function Queue(ids, label)
  local useKeys = C_AuctionHouse.SearchForItemKeys and C_AuctionHouse.MakeItemKey and not scan.noKeys
  if useKeys then
    for i = 1, #ids, KEY_BATCH do
      local batch = {}
      for j = i, math.min(#ids, i + KEY_BATCH - 1) do
        batch[#batch + 1] = ids[j]
      end
      scan.queue[#scan.queue + 1] = { kind = "keys", ids = batch, label = label }
    end
  else
    for _, id in ipairs(ids) do
      scan.queue[#scan.queue + 1] = { kind = "name", ids = { id }, label = label }
    end
  end
  scan.total = scan.total + #ids
end

-- After the writs: what the listed (or held) writs ask for, and their materials.
local function QueueItems()
  local want = {}
  for _, w in ipairs(W.List()) do
    if scan.found[w.id] or Items.Count(w.id, true) > 0 then
      Gather(w.item, 0, want)
    end
  end
  local ids = {}
  for id, yes in pairs(want) do
    if yes then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  F:Debug("scan: %d items and materials to price", #ids)
  Queue(ids, "items")
end

local function Finish(reason)
  if not scan.running then
    return
  end
  scan.running = false
  scan.current = nil
  local s = ScanStore()
  if reason == "done" then
    s.at = time()
    local writs, items = 0, 0
    for id in pairs(scan.found) do
      if data.byId[id] then
        writs = writs + 1
      else
        items = items + 1
      end
    end
    scan.last = ("%d writs for sale, %d items priced"):format(writs, items)
    F:Debug("scan done: %s", scan.last)
  else
    scan.last = "stopped: " .. tostring(reason)
    F:Debug("scan stopped: %s", tostring(reason))
  end
  Notify()
end
W.Stop = Finish

-- One query's results (GetBrowseResults or the ADDED list): the lowest unit price per item.
local function Take(results)
  local q = scan.current
  if not (q and Lib.Readable(results)) then
    return
  end
  local s = ScanStore()
  for _, r in ipairs(results) do
    local key = Lib.Readable(r) and r.itemKey
    local id = Lib.Readable(key) and Lib.Plain(key.itemID)
    local price = Lib.Plain(r.minPrice)
    if id and q.want[id] and price and price > 0 then
      local old = scan.found[id] and s.prices[id]
      if not old or price < old.p then
        s.prices[id] = { p = price, q = Lib.Plain(r.totalQuantity) }
      end
      scan.found[id] = true
    end
  end
end

local function QueryDone()
  local q = scan.current
  if not q then
    return
  end
  local s = ScanStore()
  local now = time()
  for id in pairs(q.want) do
    s.searched[id] = now
    if not scan.found[id] then
      s.prices[id] = nil
    end
  end
  scan.done = scan.done + (q.kind == "keyword" and 1 or #q.ids)
  scan.current = nil
  if q.label == "writs" and not scan.itemsQueued then
    local more = false
    for _, other in ipairs(scan.queue) do
      if other.label == "writs" then
        more = true
        break
      end
    end
    if not more then
      scan.itemsQueued = true
      QueueItems()
    end
  end
  Notify()
end

local function Send(q)
  q.want = {}
  for _, id in ipairs(q.ids or {}) do
    q.want[id] = true
  end
  if q.kind == "keyword" then
    for _, w in ipairs(W.List()) do
      q.want[w.id] = true
    end
  end
  local ok, err
  if q.kind == "keys" then
    local keys = {}
    for _, id in ipairs(q.ids) do
      keys[#keys + 1] = C_AuctionHouse.MakeItemKey(id)
    end
    ok, err = pcall(C_AuctionHouse.SearchForItemKeys, keys, Sorts())
    if not ok then
      -- (this client can't: every query left goes by name)
      F:Debug("SearchForItemKeys failed (%s): searching by name", tostring(err))
      scan.noKeys = true
      local rest = {}
      for _, id in ipairs(q.ids) do
        rest[#rest + 1] = { kind = "name", ids = { id }, label = q.label }
      end
      for _, other in ipairs(scan.queue) do
        if other.kind == "keys" then
          for _, id in ipairs(other.ids) do
            rest[#rest + 1] = { kind = "name", ids = { id }, label = other.label }
          end
        else
          rest[#rest + 1] = other
        end
      end
      scan.queue = rest
      return false
    end
  else
    local text = q.text
    if q.kind == "name" then
      text = Items.GetInfo and Items.GetInfo(q.ids[1])
      if type(text) ~= "string" then
        Items.Name(q.ids[1]) -- (asks the server; tried again at the end, NAME_TRIES times at most)
        q.tries = (q.tries or 0) + 1
        if q.tries < NAME_TRIES then
          q.waitUntil = GetTime() + 1
          scan.queue[#scan.queue + 1] = q
        end
        return false
      end
    end
    ok, err = pcall(C_AuctionHouse.SendBrowseQuery, { searchString = text, sorts = Sorts(), filters = {},
      itemClassFilters = {} })
    if not ok then
      F:Debug("browse query failed: %s", tostring(err))
      return false
    end
  end
  q.sentAt = GetTime()
  scan.current = q
  return true
end

local function Ready()
  return Lib.Call(C_AuctionHouse.IsThrottledMessageSystemReady) ~= false
end

local function Pump()
  if not scan.running then
    return
  end
  if not AHOpen() then
    Finish("the auction house closed")
    return
  end
  local q = scan.current
  if q then
    if q.more and Ready() then
      q.more = false
      q.sentAt = GetTime()
      Lib.Call(C_AuctionHouse.RequestMoreBrowseResults)
    elseif GetTime() - q.sentAt > QUERY_TIMEOUT then
      F:Debug("query timed out (%s)", q.kind)
      QueryDone()
    end
    return
  end
  if not Ready() then
    return
  end
  local tried = 0
  while #scan.queue > 0 and tried < #scan.queue do
    local nextQ = table.remove(scan.queue, 1)
    if nextQ.waitUntil and nextQ.waitUntil > GetTime() then
      -- (a name still loading: back of the queue, and wait for it if it's all that's left)
      scan.queue[#scan.queue + 1] = nextQ
      tried = tried + 1
    elseif Send(nextQ) then
      return
    end
  end
  if #scan.queue == 0 then
    Finish("done")
  end
end

function W.OnBrowse(event, ...)
  local q = scan.current
  if not (scan.running and q) then
    return
  end
  if event == "AUCTION_HOUSE_BROWSE_FAILURE" then
    F:Debug("browse failure")
    QueryDone()
    return
  end
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    Take(...)
  else
    Take(Lib.Call(C_AuctionHouse.GetBrowseResults))
  end
  if Lib.Call(C_AuctionHouse.HasFullBrowseResults) == false then
    q.more = true
    q.sentAt = GetTime()
  else
    QueryDone()
  end
end

function W.StartScan()
  if scan.running then
    return false, "a scan is already running"
  end
  if not W.Load() then
    return false, "ItemTree's writ data isn't there (install or turn on ItemTree)"
  end
  if not AHOpen() then
    return false, "open the auction house first"
  end
  scan.running, scan.queue, scan.found = true, {}, {}
  scan.total, scan.done, scan.current, scan.itemsQueued = 0, 0, nil, false
  scan.startedAt = time()
  local ids, mats = {}, {}
  for _, w in ipairs(W.List()) do
    ids[#ids + 1] = w.id
    Items.Name(w.id)
    Gather(w.item, 0, mats)
  end
  for id, yes in pairs(mats) do
    if yes then
      Items.Name(id) -- (the names load while the writs are searched)
    end
  end
  if C_AuctionHouse.SearchForItemKeys and not scan.noKeys then
    Queue(ids, "writs")
  else
    scan.queue[1] = { kind = "keyword", text = WritKeyword(), ids = {}, label = "writs" }
    scan.total = scan.total + 1
  end
  F:Debug("scan started: %d queries queued", #scan.queue)
  Notify()
  return true
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

local function Money(copper)
  return copper and Lib.FormatMoney(math.floor(copper + 0.5)) or "--"
end
W.Money = Money

function F:OnEnable()
  wipe(vendorMemo)
  scan.running, scan.current = false, nil
  self:On("AUCTION_HOUSE_SHOW", function()
    if ns.WritsTab then
      ns.WritsTab.Attach()
    end
  end)
  self:On("AUCTION_HOUSE_CLOSED", function()
    if scan.running then
      Finish("the auction house closed")
    end
  end)
  for _, ev in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_BROWSE_FAILURE" }) do
    self:On(ev, function(_, event, ...)
      W.OnBrowse(event, ...)
    end)
  end
  self:On("BAG_UPDATE_DELAYED", function()
    self:Debounce("writs.bags", 0.5, Notify)
  end)
  self:On("QUEST_TURNED_IN", function()
    self:Debounce("writs.quest", 1, Notify)
  end)
  self:On("UPDATE_FACTION", function()
    self:Debounce("writs.rep", 0.5, Notify)
  end)
  self:Ticker(PUMP, Pump)
  if ns.WritsTab then
    ns.WritsTab.Enable()
  end
end

function F:OnDisable()
  if scan.running then
    Finish("turned off")
  end
  if ns.WritsTab then
    ns.WritsTab.Disable()
  end
end

function F:OnOptionChanged()
  Notify()
end

function F:main()
  self:Print(self:GetStatus())
end

local function PrintBest(n)
  if not W.Load() then
    F:Print("ItemTree's writ data isn't there: install or turn on ItemTree.")
    return
  end
  local list = W.Evaluate()
  local shown = 0
  F:Print("cheapest writs per reputation:")
  for _, e in ipairs(list) do
    if e.perRep and not e.done and (e.listed or e.writCost == 0) then
      shown = shown + 1
      print(("   %d. %s + %d %s: %s (%s per reputation, %d rep)"):format(shown, Items.Link(e.w.id), e.w.count,
        Items.Name(e.w.item), Money(e.total), Money(e.perRep), e.w.rep))
      if shown >= n then
        break
      end
    end
  end
  if shown == 0 then
    F:Print("no prices yet: open the auction house and click Scan on the Writs tab.")
  end
end

F.commands = {
  { name = "scan", help = "scans the writs and their materials (auction house open)", run = function(self)
    local ok, err = W.StartScan()
    if not ok then
      self:Print("can't scan: " .. err .. ".")
    end
  end },
  { name = "stop", help = "stops a scan", run = function(self)
    if scan.running then
      Finish("stopped")
    else
      self:Print("no scan is running.")
    end
  end },
  { name = "best", args = "[n]", help = "prints the n cheapest writs per reputation (default 5)", run = function(_, rest)
    PrintBest(tonumber(rest) or 5)
  end },
}

function F:GetStatus()
  if not TreeData() then
    return "Active · waiting for ItemTree (it has the writ data)"
  end
  if scan.running then
    return ("Active · scanning the auction house: %d of %d"):format(scan.done or 0, math.max(scan.total or 0, 1))
  end
  local s = ScanStore()
  if not s.at or s.at == 0 then
    return "Active · no scan yet: open the auction house, Writs tab, Scan"
  end
  return ("Active · last scan %s ago%s"):format(Lib.FormatDuration(time() - s.at),
    scan.last and (" · " .. scan.last) or "")
end

function F:ReportDetails()
  local s = ScanStore()
  local n = 0
  for _ in pairs(s.prices) do
    n = n + 1
  end
  return {
    ("ItemTree data: %s, %d writs"):format(TreeData() and "yes" or "no", #W.List()),
    ("SearchForItemKeys: %s%s"):format(C_AuctionHouse and C_AuctionHouse.SearchForItemKeys and "yes" or "no",
      scan.noKeys and " (failed, by name)" or ""),
    ("Stored prices: %d, last scan %s"):format(n, s.at and s.at > 0 and date("%Y-%m-%d %H:%M", s.at) or "never"),
    "Last: " .. tostring(scan.last or "-"),
  }
end

ARLE:RegisterModule(F)
