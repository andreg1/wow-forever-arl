-- ARLE.Bridge for the other outside addons:
--   FDJ          DungeonJournal (ForeverDungeonJournal_NS: bosses, loot, quests)
--   FLB          Forever Leveling BiS (ForeverLevelingBiS_API v2+: gains, specs,
--                weights). Public API only: its license forbids copying its code.
--   Auctionator  Auctionator.API.v1 (prices, ages, DB update callback, searches)
--   EUI          EllesmereUI's plugin surfaces (quest tracker rows, bags)
local _, ns = ...
local ARLE = ns.ARLE
local B = ARLE.Bridge

function B.FDJ()
  local fdj = _G.ForeverDungeonJournal_NS
  if type(fdj) == "table" and type(fdj.DB) == "table" then
    return fdj
  end
end

function B.FLB()
  local api = _G.ForeverLevelingBiS_API
  if type(api) == "table" and (api.version or 1) >= 2 and api.GetGain then
    return api
  end
end

-------------------------------------------------------------------------------
-- Auctionator
-------------------------------------------------------------------------------

local A = {}
B.Auctionator = A
local CALLER = "ARL Extensions"

function A.API()
  local a = _G.Auctionator
  local v1 = type(a) == "table" and type(a.API) == "table" and a.API.v1
  return type(v1) == "table" and v1 or nil
end

-- Every v1 call raises an error on bad state (e.g. a search with the AH
-- closed), so each one is pcall'd.
local function Call(name, ...)
  local api = A.API()
  if not api or type(api[name]) ~= "function" then
    return nil
  end
  local ok, a, b = pcall(api[name], CALLER, ...)
  if ok then
    return a, b
  end
end

function A.Price(itemID, link)
  local price = link and Call("GetAuctionPriceByItemLink", link)
  return price or Call("GetAuctionPriceByItemID", itemID)
end

function A.Age(itemID)
  return Call("GetAuctionAgeByItemID", itemID)
end

-- True once registered (RegisterForDBUpdate returns nothing, so success is
-- the pcall's, not its result). Callers register once per session.
function A.OnDBUpdate(fn)
  local api = A.API()
  if not api or type(api.RegisterForDBUpdate) ~= "function" then
    return false
  end
  return (pcall(api.RegisterForDBUpdate, CALLER, fn))
end

function A.SearchExact(names)
  local api = A.API()
  if not api or type(api.MultiSearchExact) ~= "function" then
    return false, "Auctionator can't search from addons (update Auctionator?)"
  end
  local ok, err = pcall(api.MultiSearchExact, CALLER, names)
  return ok, err
end

-------------------------------------------------------------------------------
-- EllesmereUI
-------------------------------------------------------------------------------

local E = {}
B.EUI = E

function E.Get()
  return type(_G.EllesmereUI) == "table" and _G.EllesmereUI or nil
end

function E.Bags()
  return type(_G.EUI_Bags) == "table" and _G.EUI_Bags or nil
end

function E.CategoryManager()
  return type(_G.EUI_CategoryManager) == "table" and _G.EUI_CategoryManager or nil
end
