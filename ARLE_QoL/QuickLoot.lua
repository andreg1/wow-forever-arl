-- Quick Loot: takes everything from the loot window as soon as it opens.
--
-- Our own code, written against Blizzard's API. EllesmereUI has a similar
-- option (EllesmereUIQoL "Quick Loot"), but its code is all rights reserved,
-- so nothing of it is used. While EllesmereUI's own Quick Loot is on
-- (EllesmereUIDB.quickLoot), this one stands aside so the two don't both loot.
--
-- How: on LOOT_READY (also with the game's Auto Loot on; skipped while Shift
-- is held), each slot is taken with LootSlot, 0.05 s apart, as EllesmereUI's
-- does; an empty window is closed. A loot "generation"
-- is bumped on LOOT_CLOSED so timers left from a closed window do nothing.
-- What stays in the window, on purpose:
--  * slots under a group roll or master loot (GetLootSlotInfo "locked");
--  * a bind-on-pickup item: LootSlot raises Blizzard's own bind confirm, which
--    we never answer, and the window is never closed while a slot is left;
--  * items that don't fit: free bag slots (by bag family) and room on partial
--    stacks are counted before looting, and an "inventory full" error stops
--    the run. One chat line says how many were left.
-- Only plain addon calls (LootSlot, CloseLoot): nothing protected, nothing of
-- Blizzard's loot frame is touched.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local F = {
  id = "QuickLoot",
  addon = ADDON,
  title = "Quick Loot",
  group = "QualityOfLife",
  command = "loot",
  commandHelp = "loots everything at once",
  description = "Takes all the loot as soon as the window opens (hold Shift to open it normally). "
    .. "Leaves group rolls, bind-on-pickup confirms and items that don't fit in your bags in the window.",
  options = {
    { key = "chat", type = "boolean", label = "Say in chat when items don't fit", default = true },
    { type = "info", text = function(def) return def:GetStatus() end },
  },
}

local SPACING = 0.05
local lootGen = 0
local stopped -- this window hit "inventory full"

-- EllesmereUI's own Quick Loot is on.
local function EllesmereQuickLootOn()
  local db = _G.EllesmereUIDB
  return type(db) == "table" and db.quickLoot == true
end

local function SlotType(slot)
  if GetLootSlotType then
    local ok, t = pcall(GetLootSlotType, slot)
    if ok then
      return t
    end
  end
end

local ITEM_TYPE = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

-------------------------------------------------------------------------------
-- Bag room
-------------------------------------------------------------------------------

local band = bit and bit.band

-- free[i] = { free = n, family = bagFamily } per bag.
local function FreeSlots()
  local list = {}
  if not (C_Container and C_Container.GetContainerNumFreeSlots) then
    return list
  end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    local ok, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
    if ok and type(free) == "number" and free > 0 then
      list[#list + 1] = { free = free, family = type(family) == "number" and family or 0 }
    end
  end
  return list
end

local function ItemFamily(itemID)
  local fn = (C_Item and C_Item.GetItemFamily) or _G.GetItemFamily
  if fn then
    local ok, family = pcall(fn, itemID)
    if ok and type(family) == "number" then
      return family
    end
  end
  return 0
end

local function MaxStack(itemID)
  local _, _, _, _, _, _, _, stack = ARLE.Lib.Items.GetInfo(itemID)
  return type(stack) == "number" and stack or nil
end

local KEY_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Key) or 13

-- Takes room for quantity x itemID out of free (and stackRoom); false only
-- when it surely doesn't fit. Anything we can't judge (no link, item data
-- not loaded yet, keys that go to the keyring) is tried, as EllesmereUI
-- would: the worst case is the game's own "inventory full" error.
local function TakeRoom(free, stackRoom, itemID, quantity)
  quantity = type(quantity) == "number" and quantity > 0 and quantity or 1
  if not itemID then
    return true
  end
  local _, _, _, _, _, classID = ARLE.Lib.Items.GetInfoInstant(itemID)
  if classID == KEY_CLASS or not MaxStack(itemID) then
    return true
  end
  do
    local room = stackRoom[itemID]
    if room == nil then
      room = 0
      local max = MaxStack(itemID)
      if max and max > 1 then
        local have = ARLE.Lib.Items.Count(itemID) % max
        if have > 0 then
          room = max - have
        end
      end
    end
    if quantity <= room then
      stackRoom[itemID] = room - quantity
      return true
    end
  end
  local family = ItemFamily(itemID)
  -- Special bags first (a soul shard goes in the shard bag), then any bag.
  for pass = 1, 2 do
    for _, bag in ipairs(free) do
      local fits
      if pass == 1 then
        fits = bag.family ~= 0 and band and band(bag.family, family) ~= 0
      else
        fits = bag.family == 0
      end
      if fits and bag.free > 0 then
        bag.free = bag.free - 1
        local max = MaxStack(itemID)
        stackRoom[itemID] = max > quantity and (max - quantity) or 0
        return true
      end
    end
  end
  return false
end

-------------------------------------------------------------------------------
-- Looting
-------------------------------------------------------------------------------

local function Paused()
  return EllesmereQuickLootOn()
end

-- Runs with the game's own Auto Loot on as well (as EllesmereUI's does): it
-- takes the slots faster than the client does; a slot already taken is a
-- no-op.
function F:OnLootReady()
  if IsShiftKeyDown() or Paused() then
    return
  end
  lootGen = lootGen + 1
  stopped = false
  local gen = lootGen
  local count = GetNumLootItems() or 0
  if count == 0 then
    CloseLoot()
    return
  end
  local free, stackRoom = FreeSlots(), {}
  local queue, left = {}, 0
  for slot = 1, count do
    local _, _, quantity, _, _, locked = GetLootSlotInfo(slot)
    if locked then
      -- Under a roll or master loot: not ours to take.
    elseif SlotType(slot) ~= ITEM_TYPE then
      queue[#queue + 1] = { slot = slot } -- coins and currency always fit
    else
      local itemID = ARLE.Lib.Items.IDFromLink(GetLootSlotLink and GetLootSlotLink(slot))
      if TakeRoom(free, stackRoom, itemID, quantity) then
        queue[#queue + 1] = { slot = slot, item = true }
      else
        left = left + 1
      end
    end
  end
  for i, entry in ipairs(queue) do
    self:After(SPACING * i, function()
      -- After an "inventory full" error, coins and currency are still taken.
      if lootGen == gen and not (stopped and entry.item) then
        LootSlot(entry.slot)
      end
    end)
  end
  if left > 0 and self.db.chat then
    self:Print(string.format("bags full: %d item%s left in the loot window.", left, left == 1 and "" or "s"))
  end
end

function F:OnLootClosed()
  lootGen = lootGen + 1
end

local FULL = {}

function F:OnUIError(_, _, message)
  if FULL[message] and not stopped then
    stopped = true
    if self.db.chat then
      self:Print("bags full: the rest stays in the loot window.")
    end
  end
end

function F:OnEnable()
  FULL = {}
  for _, key in ipairs({ "ERR_INV_FULL", "ERR_BAG_FULL", "ERR_ITEM_MAX_COUNT" }) do
    if type(_G[key]) == "string" then
      FULL[_G[key]] = true
    end
  end
  self:On("LOOT_READY", self.OnLootReady)
  self:On("LOOT_CLOSED", self.OnLootClosed)
  self:On("UI_ERROR_MESSAGE", self.OnUIError)
end

function F:OnDisable()
  lootGen = lootGen + 1
end

function F:GetStatus()
  if Paused() then
    return "Paused: EllesmereUI's Quick Loot is on (turn it off there to use this one)"
  end
  return "Active · hold Shift while looting to open the window normally"
end

ARLE:RegisterModule(F)
