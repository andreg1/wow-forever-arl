-- Logistics: the Merchant's Favor side. Every Waylaid Crate, sealed crate and
-- Shipping Label priced by gold per Favor, and the plan to a Favor goal (an
-- item the camp's vendors sell, picked on the tab).
--
-- A Waylaid Crate is filled with ONE of its bundles (N of one material), so
-- its cost is the crate's price + its cheapest bundle, each material at the
-- cheapest of buying it, a vendor or crafting it (Logistics.lua's W.Node: bars
-- smelted from ore, bolts woven from cloth...). A sealed crate or a label is
-- only its own price. With "use what I have" on, crates and materials in the
-- bags and bank count as free. The Favor each pays is ItemTree's (Supplies
-- `sealed[].f`, `labels[].f`); crates it doesn't know the Favor of (Artisan
-- and up) have no per Favor.
--
-- The plan takes the cheapest per Favor first, as many of each as are listed
-- (the scan's quantity; one where only Auctionator's price is known), at the
-- lowest price: later listings cost more, so its total is an estimate ("about").
-- Data and scan: Logistics.lua (ns.Logistics); UI: LogisticsTab.lua.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Items = ARLE.Lib.Items

local PLAN_MAX = 10 -- crates in the plan when no goal is set
local PLAN_COPIES = 50 -- copies of one listing the plan counts at most

local C = {}
ns.LogisticsCrates = C

local function W()
  return ns.Logistics
end

-- Every crate priced: { c, price, src, qty, age, held, listed, crateCost, bundle, node, need, fill, bundles,
-- total, perFavor }, the cheapest per Favor first. Call W.ResetCosts() first in a new round.
function C.Evaluate()
  local L = W()
  local F = L.F
  local bags = F.db.useBags ~= false
  local out = {}
  for _, c in ipairs(L.Crates()) do
    local e = { c = c, kind = c.kind }
    e.price, e.src, e.qty, e.age = L.Price(c.id)
    e.held = Items.Count(c.id, true)
    e.listed = e.price ~= nil
    e.crateCost = (bags and e.held > 0) and 0 or e.price
    if #c.bundles == 0 then
      e.fill = 0
    else
      e.bundles = {}
      for _, b in ipairs(c.bundles) do
        local have = Items.Count(b.item, true)
        local need = bags and math.max(0, b.count - have) or b.count
        local node = L.Node(b.item, 0)
        local fill
        if need == 0 then
          fill = 0
        elseif node and node.cost then
          fill = node.cost * need
        end
        local x = { item = b.item, count = b.count, have = have, need = need, node = node, fill = fill }
        e.bundles[#e.bundles + 1] = x
        if fill and (not e.fill or fill < e.fill) then
          e.fill, e.bundle = fill, x
        end
      end
      if e.bundle then
        e.node, e.need = e.bundle.node, e.bundle.need
      end
    end
    if e.crateCost and e.fill then
      e.total = e.crateCost + e.fill
      e.perFavor = c.favor and e.total / c.favor or nil
    end
    out[#out + 1] = e
  end
  table.sort(out, function(a, b)
    if (a.perFavor ~= nil) ~= (b.perFavor ~= nil) then
      return a.perFavor ~= nil
    end
    if a.perFavor and b.perFavor and a.perFavor ~= b.perFavor then
      return a.perFavor < b.perFavor
    end
    return a.c.id < b.c.id
  end)
  return out
end

-- The cheapest Favor for sale now (an entry from C.Evaluate), or nil: what a Favor spent on a receipt costs.
-- What you hold counts at its price here, since spending it on a receipt means not turning it in.
function C.BestPerFavor()
  for _, e in ipairs(C.Evaluate()) do
    if e.perFavor and e.listed then
      return e
    end
  end
end

-- The Favor goal: { favor, item, have, need } or nil when none is set.
function C.Goal()
  local L = W()
  local db = L.F.db
  local goal = tonumber(db.favorGoal) or 0
  if goal <= 0 then
    return nil
  end
  local have = L.Favor()
  return { favor = goal, item = tonumber(db.favorGoalItem) or 0, have = have,
    need = have and math.max(0, goal - have) or goal }
end

-- The cheapest crates to buy now until the goal's Favor is covered (or PLAN_MAX without a goal): marks e.plan and
-- e.planCount; returns { count, cost, favor, need, short }.
function C.Plan(list, goal)
  local need = goal and goal.need
  local p = { count = 0, cost = 0, favor = 0, need = need }
  for _, e in ipairs(list) do
    e.plan, e.planCount = nil, nil
    if e.perFavor and (e.listed or e.crateCost == 0) then
      local enough = need and p.favor >= need or (not need and p.count >= PLAN_MAX)
      if not enough then
        local copies = 1
        if need then
          local avail = e.crateCost == 0 and e.held or (e.qty or 1)
          copies = math.min(math.max(1, avail), PLAN_COPIES, math.ceil((need - p.favor) / e.c.favor))
        end
        e.plan, e.planCount = true, copies
        p.count = p.count + copies
        p.cost = p.cost + e.total * copies
        p.favor = p.favor + e.c.favor * copies
      end
    end
  end
  p.short = need and p.favor < need or false
  return p
end
