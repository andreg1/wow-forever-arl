-- ARLE.Lib.Items: item lookups shared by features.
local _, ns = ...
local ARLE = ns.ARLE
local I = {}
ARLE.Lib.Items = I

-- Looked up on each call (C_Item first, then the old globals), so a client
-- or addon that fills these in later is still used.
local function API(modern, old)
  return function(...)
    local fn = (C_Item and C_Item[modern]) or _G[old]
    if fn then
      return fn(...)
    end
  end
end
I.GetInfo = API("GetItemInfo", "GetItemInfo")
I.GetInfoInstant = API("GetItemInfoInstant", "GetItemInfoInstant")
I.GetIcon = API("GetItemIconByID", "GetItemIcon")
local GetItemSpell = API("GetItemSpell", "GetItemSpell")
local GetItemCount = API("GetItemCount", "GetItemCount")

function I.IDFromLink(link)
  if type(link) == "number" then
    return link
  end
  return tonumber(tostring(link or ""):match("item:(%d+)"))
end

-- Weapon (2) / Fishing Pole (20).
function I.IsFishingPole(itemID)
  if not itemID or not I.GetInfoInstant then
    return false
  end
  local _, _, _, _, _, classID, subclassID = I.GetInfoInstant(itemID)
  return classID == 2 and subclassID == 20
end

-- Has a "Use:" effect (the item can be used, not just carried).
function I.HasUseSpell(itemID)
  if not itemID or not GetItemSpell then
    return false
  end
  local ok, name = pcall(GetItemSpell, itemID)
  return ok and name ~= nil
end

function I.Count(itemID, includeBank)
  if not itemID or not GetItemCount then
    return 0
  end
  return GetItemCount(itemID, includeBank) or 0
end

-- Name (or "item 1234" until the client has it), and asks the server for it.
function I.Name(itemID)
  local name = I.GetInfo and I.GetInfo(itemID)
  if not name and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
  return name or ("item " .. tostring(itemID))
end

function I.Link(itemID)
  local _, link = I.GetInfo and I.GetInfo(itemID)
  return link or ("[" .. I.Name(itemID) .. "]")
end

-- Bag and slot of the first stack of an item in the bags, or nil.
function I.FindInBags(itemID)
  if not (C_Container and C_Container.GetContainerNumSlots) then
    return nil
  end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      if C_Container.GetContainerItemID(bag, slot) == itemID then
        return bag, slot
      end
    end
  end
end
