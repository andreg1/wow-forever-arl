-- BoE Category: bind-on-equip items not yet bound get their own "BoE"
-- category in EllesmereUI Bags.
--
-- EllesmereUI Bags is all rights reserved: only its public category API is
-- used, through ARLE.Bridge.EUI (EUI_CategoryManager):
--   RegisterVirtualCategory: a runtime-only category; EllesmereUI asks its
--     classify(itemLink, itemID, bag, slot, quality) before its own rules, in
--     the providers' order (Item Lock's "Locked" is 0, ours is after it, so a
--     padlocked BoE stays in "Locked"). User item assignments and Junk still
--     come first, as EllesmereUI decides. Nothing is saved in its settings.
--   UnregisterVirtualCategory when the feature goes off.
--   RefreshVirtualCategories when our answers change (item data loaded,
--     settings changed); in combat it waits until the fight ends, as Item
--     Lock's does.
-- An item counts as BoE when GetItemInfo's bindType is 2 (on equip) and its
-- bag slot says it isn't bound (C_Container.GetContainerItemInfo isBound).
-- Items without a bag slot (EllesmereUI's offline views) aren't claimed: we
-- can't tell whether they're bound.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib
local Items = Lib.Items
local EUI = ARLE.Bridge.EUI

local CATEGORY_ID = "ARLE_BoE"
local CATEGORY_ORDER = 10 -- after Item Lock's "Locked" (0)
local CATEGORY_ICON = "Interface\\Icons\\INV_Chest_Chain_05"
local BIND_ON_EQUIP = 2
local BIND_ON_USE = 3
local REFRESH_DELAY = 0.5 -- seconds: one refresh for a burst of item data

local qualityValues = {
  { value = 0, label = "Any quality" },
  { value = 2, label = "Uncommon and better" },
  { value = 3, label = "Rare and better" },
  { value = 4, label = "Epic and better" },
}

local F = {
  id = "BoECategory",
  addon = ADDON,
  title = "BoE Category",
  group = "EllesmereUI",
  extends = "EllesmereUIBags",
  command = "boe",
  commandHelp = "puts bind-on-equip items in their own bag category",
  description = "Bind-on-equip items that aren't bound yet go to their own \"BoE\" category in EllesmereUI's bags, "
    .. "so you can see what you can still sell or mail.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "minQuality", type = "select", label = "Which BoE items", values = qualityValues, default = 0,
      cmd = "quality" },
    { key = "bindOnUse", type = "boolean", label = "Bind-on-use items go there too", default = false, cmd = "use" },
  },
}

local registered = false
local refreshQueued = false
local waitingForCombat = false

local function Manager()
  local manager = EUI.CategoryManager()
  if manager and type(manager.RegisterVirtualCategory) == "function" then
    return manager
  end
end

-- EllesmereUI's question: is this bag item ours?
local function Classify(_, itemID, bag, slot, quality)
  if not F._active or bag == nil or slot == nil or type(itemID) ~= "number" then
    return false
  end
  local _, _, rarity, _, _, _, _, _, _, _, _, _, _, bindType = Items.GetInfo(itemID)
  bindType = Lib.Plain(bindType)
  if bindType ~= BIND_ON_EQUIP and not (bindType == BIND_ON_USE and F.db.bindOnUse) then
    return false
  end
  quality = Lib.Plain(quality) or Lib.Plain(rarity) or 0
  if quality < (tonumber(F.db.minQuality) or 0) then
    return false
  end
  local info = Lib.Call(C_Container.GetContainerItemInfo, bag, slot)
  if not Lib.Readable(info) or Lib.Plain(info.isBound) ~= false then
    return false -- bound, or we can't tell
  end
  return true
end

-- Asks EllesmereUI to classify again (after a fight if one is on).
local function Refresh()
  if not registered then
    return
  end
  if InCombatLockdown() then
    waitingForCombat = true
    F:Debug("refresh waits for the end of combat")
    return
  end
  local manager = Manager()
  if manager and manager.RefreshVirtualCategories then
    manager:RefreshVirtualCategories()
    F:Debug("asked EllesmereUI to sort again")
  end
end

function F:OnItemInfo()
  if refreshQueued then
    return
  end
  refreshQueued = true
  self:After(REFRESH_DELAY, function()
    refreshQueued = false
    Refresh()
  end)
end

function F:OnEnable()
  refreshQueued, waitingForCombat = false, false
  local manager = Manager()
  if not manager then
    self:Print("EllesmereUI Bags' category API was not found (did it change?); BoE items stay where they are.")
    return
  end
  registered = manager:RegisterVirtualCategory(CATEGORY_ID, {
    name = "BoE",
    icon = CATEGORY_ICON,
    order = CATEGORY_ORDER,
    classify = Classify,
  }) and true or false
  if not registered then
    self:Print("EllesmereUI Bags refused the BoE category; BoE items stay where they are.")
    return
  end
  self:Debug("BoE category registered")
  self:On("GET_ITEM_INFO_RECEIVED", self.OnItemInfo)
  self:On("PLAYER_REGEN_ENABLED", function()
    if waitingForCombat then
      waitingForCombat = false
      Refresh()
    end
  end)
end

function F:OnDisable()
  if not registered then
    return
  end
  registered = false
  -- Disable can come in combat (the error breaker): the unregister waits.
  ARLE.Secure:Run(function()
    local manager = Manager()
    if manager and manager.UnregisterVirtualCategory then
      manager:UnregisterVirtualCategory(CATEGORY_ID)
    end
  end, "BoECategory.unregister")
end

function F:OnOptionChanged()
  Refresh()
end

function F:GetStatus()
  if not registered then
    return "Waiting · EllesmereUI Bags' category API isn't available"
  end
  local which = "every BoE item"
  for _, v in ipairs(qualityValues) do
    if v.value == self.db.minQuality and v.value > 0 then
      which = "BoE items, " .. v.label:lower()
    end
  end
  return "Active · " .. which .. (self.db.bindOnUse and " and bind-on-use items" or "")
    .. " go to the \"BoE\" category" .. (waitingForCombat and " (re-sorting after combat)" or "")
end

ARLE:RegisterModule(F)
