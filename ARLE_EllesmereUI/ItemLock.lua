-- Item Lock: Alt+Right-click a bag item to lock it, so it can't be sold or
-- destroyed; items in your gear sets are protected the same way.
-- Based on EllesmereUIBags_ItemLock by andreg1 (MIT),
-- https://github.com/andreg1/wow-forever-addons
--
-- EllesmereUI Bags public surfaces only (ARLE.Bridge.EUI):
--   EUI_Bags.RegisterItemOverlayIcon: the padlock on locked items, and which
--     bag slot is under the mouse (grid, list and bank views).
--   EUI_CategoryManager:IsJunk: locked items are never junk, so Sell Junk
--     skips them (wrapped while the feature is on).
--   EUI_CategoryManager:RegisterVirtualCategory: a runtime-only "Locked"
--     category that claims every padlocked item. Nothing is saved into
--     Ellesmere's category settings.
-- Locks are per character, by item ID (every copy of the item is locked).
--
-- Gear sets: every item in one of the character's equipment sets is protected
-- with no lock needed. It goes by item ID, from C_EquipmentSet.GetItemIDs:
-- GetItemLocations crashes the WoW Forever client for some sets.
--
-- Protection:
--   Destroy: the item is taken off the cursor when the delete confirmation
--     opens, so confirming deletes nothing. (Upstream also hides the popup;
--     we don't: hiding a Blizzard popup from addon code taints the Escape key
--     and the character pane, the bug fixed in ARLE 0.4.3.)
--   Sell by right-click at a merchant: a plain blocker covers the hovered
--     locked slot while a merchant is open (left-click and drag still work).
--   Any other sale (dragging onto the merchant, other addons): bought back.
-- Taint: nothing is written onto Ellesmere's secure slot buttons; slots only
-- get OnEnter / OnLeave hooks (out of combat); the blocker is placed by
-- coordinates, never anchored to a slot.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local EUI = ARLE.Bridge.EUI
local Items = ARLE.Lib.Items

local LOCK_TEXTURE = "Interface\\AddOns\\" .. ADDON .. "\\media\\lock.tga"
local CATEGORY_ID = "ARLE_ItemLock"
local DELETE_POPUPS = {
  DELETE_ITEM = true,
  DELETE_GOOD_ITEM = true,
  DELETE_QUEST_ITEM = true,
  DELETE_GOOD_QUEST_ITEM = true,
}

local F = {
  id = "ItemLock",
  addon = ADDON,
  title = "Item Lock",
  group = "EllesmereUI",
  extends = "EllesmereUIBags",
  command = "lock",
  commandArgs = "[<item link>|list|clear|on|off|set]",
  commandHelp = "locks bag items so they can't be sold or destroyed",
  mainHelp = "with an item link (shift-click it) or item ID: locks or unlocks it; alone: status",
  description = "Alt+Right-click a bag item to lock it so it can't be sold or destroyed. Gear set items are protected too.",
  options = {
    { key = "protectSets", type = "boolean", label = "Protect items in my gear sets", default = true, cmd = "sets" },
    { key = "useCategory", type = "boolean", label = "Put padlocked items in their own \"Locked\" category",
      default = true, cmd = "category" },
    { key = "categorySets", type = "boolean", label = "Gear set items go to \"Locked\" too", default = true,
      cmd = "categorysets", disabled = function(def) return not def.db.useCategory end },
    { type = "info", text = function(def) return def:Summary() end },
    { type = "button", label = "Unlock everything", confirm = "Click again to unlock all", nocmd = true,
      desc = "removes every lock on this character",
      run = function(def) def:ClearLocks() end },
  },
}

local setItems = {} -- itemID -> name of the first gear set holding it
local categoryRegistered = false
local categoryRefreshPending = false
local slots = setmetatable({}, { __mode = "k" })  -- slot button -> { bag, slot, itemID }
local marks = setmetatable({}, { __mode = "k" })  -- slot button -> padlock texture
local hooked = setmetatable({}, { __mode = "k" })
local hovered
local merchantOpen = false
local blocker
local buybackSnapshot = {}
local overlayRegistered = false

local function Locks()
  F.char.items = type(F.char.items) == "table" and F.char.items or {}
  return F.char.items
end

local function IsLocked(itemID)
  return itemID ~= nil and Locks()[itemID] == true
end

local function SetName(itemID)
  return F.db.protectSets ~= false and itemID ~= nil and setItems[itemID] or nil
end

local function IsProtected(itemID)
  return F._active and (IsLocked(itemID) or SetName(itemID) ~= nil)
end

-- For other features: ARLE.modules.ItemLock:IsProtected(itemID).
function F:IsLocked(itemID)
  return self._active and IsLocked(itemID)
end
function F:IsProtected(itemID)
  return IsProtected(itemID)
end

local function ItemText(itemID, link)
  if link then
    return link
  end
  return Items.Link(itemID)
end

local function Reason(itemID)
  if IsLocked(itemID) then
    return "is locked"
  end
  return "is in your gear set " .. (SetName(itemID) or "?")
end

local function UnlockHint(itemID)
  if IsLocked(itemID) then
    return "Alt+Right-click it in your bags to unlock it."
  end
  return "Remove it from the set first."
end

-------------------------------------------------------------------------------
-- Gear sets
-------------------------------------------------------------------------------

-- True when the set contents changed.
local function RebuildSetItems()
  local fresh = {}
  local api = C_EquipmentSet
  if api and api.GetEquipmentSetIDs and api.GetItemIDs then
    local ok, setIDs = pcall(api.GetEquipmentSetIDs)
    for _, setID in ipairs(ok and setIDs or {}) do
      local name = api.GetEquipmentSetInfo and api.GetEquipmentSetInfo(setID)
      local okIDs, ids = pcall(api.GetItemIDs, setID)
      for _, itemID in pairs(okIDs and ids or {}) do
        if type(itemID) == "number" and itemID > 0 and not fresh[itemID] then
          fresh[itemID] = name or ("set " .. setID)
        end
      end
    end
  end
  local changed = false
  for id, name in pairs(fresh) do
    if setItems[id] ~= name then
      changed = true
      break
    end
  end
  if not changed then
    for id in pairs(setItems) do
      if not fresh[id] then
        changed = true
        break
      end
    end
  end
  setItems = fresh
  return changed
end

-------------------------------------------------------------------------------
-- Padlocks
-------------------------------------------------------------------------------

local function Mark(btn)
  local m = marks[btn]
  if m then
    return m
  end
  local host = btn._textOverlay or btn
  m = host:CreateTexture(nil, "OVERLAY", nil, 7)
  m:SetTexture(LOCK_TEXTURE)
  m:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 1, 1)
  marks[btn] = m
  return m
end

local function ShowMark(btn, itemID)
  if not IsProtected(itemID) then
    if marks[btn] then
      marks[btn]:Hide()
    end
    return
  end
  local m = Mark(btn)
  -- Gold padlock for a lock, blue for gear-set protection only.
  if IsLocked(itemID) then
    m:SetDesaturated(false)
    m:SetVertexColor(1, 1, 1)
  else
    m:SetDesaturated(true)
    m:SetVertexColor(0.55, 0.8, 1)
  end
  local host = btn._textOverlay or btn
  local width = host:GetWidth() or 0
  local size = width > 0 and math.max(10, math.min(16, math.floor(width * 0.4 + 0.5))) or 14
  m:SetSize(size, size)
  m:Show()
end

local function RepaintAll()
  for btn, s in pairs(slots) do
    ShowMark(btn, s.itemID)
  end
end

-------------------------------------------------------------------------------
-- The merchant blocker
-------------------------------------------------------------------------------

local Toggle -- defined below

local function HideBlocker()
  if blocker and blocker:IsShown() then
    if GameTooltip:IsOwned(blocker) then
      GameTooltip:Hide()
    end
    blocker:Hide()
  end
  if blocker then
    blocker.owner = nil
  end
end

local function BlockerSlot()
  return blocker and blocker.owner and slots[blocker.owner]
end

local function BlockerPickup()
  local s = BlockerSlot()
  if s and not InCombatLockdown() then
    C_Container.PickupContainerItem(s.bag, s.slot)
  end
end

local function BuildBlocker()
  blocker = CreateFrame("Button", nil, UIParent)
  blocker:SetFrameStrata("TOOLTIP")
  blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  blocker:RegisterForDrag("LeftButton")
  local tint = blocker:CreateTexture(nil, "OVERLAY")
  tint:SetAllPoints()
  tint:SetColorTexture(1, 0.25, 0.25, 0.15)
  blocker:SetScript("OnClick", function(_, button)
    local s = BlockerSlot()
    if not s then
      return
    end
    if button == "RightButton" then
      if IsAltKeyDown() then
        Toggle(s.bag, s.slot)
      else
        F:Print(ItemText(s.itemID, C_Container.GetContainerItemLink(s.bag, s.slot)) .. " " .. Reason(s.itemID)
          .. ", so right-click is off at merchants. " .. UnlockHint(s.itemID))
      end
    elseif IsModifiedClick() then
      local link = C_Container.GetContainerItemLink(s.bag, s.slot)
      if link then
        HandleModifiedItemClick(link)
      end
    else
      BlockerPickup()
    end
  end)
  blocker:SetScript("OnDragStart", BlockerPickup)
  blocker:SetScript("OnReceiveDrag", BlockerPickup)
  blocker:SetScript("OnEnter", function(self)
    local s = BlockerSlot()
    if not s then
      return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(s.bag, s.slot)
    GameTooltip:Show()
  end)
  blocker:SetScript("OnLeave", function()
    HideBlocker()
    if hovered and not hovered:IsMouseOver() then
      hovered = nil
    end
  end)
  blocker:Hide()
end

local function UpdateBlocker()
  local btn = hovered
  local s = btn and slots[btn]
  local want = merchantOpen and s and IsProtected(s.itemID) and not InCombatLockdown()
    and btn:IsVisible() and btn:IsMouseOver()
  if not want then
    HideBlocker()
    return
  end
  if not blocker then
    BuildBlocker()
  end
  local left, bottom, width, height = btn:GetLeft(), btn:GetBottom(), btn:GetWidth(), btn:GetHeight()
  if not (left and bottom and width and height) then
    HideBlocker()
    return
  end
  -- Placed by coordinates: anchoring to the secure slot would make the
  -- blocker part of its protected anchor family.
  local scale = btn:GetEffectiveScale() / blocker:GetEffectiveScale()
  blocker.owner = btn
  blocker:ClearAllPoints()
  blocker:SetSize(width * scale, height * scale)
  blocker:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * scale, bottom * scale)
  blocker:Show()
  if GameTooltip:IsOwned(btn) then
    blocker:GetScript("OnEnter")(blocker)
  end
end

-------------------------------------------------------------------------------
-- Hover tracking, from EllesmereUI Bags' overlay painter
-------------------------------------------------------------------------------

local function OnSlotEnter(btn)
  if F._active then
    hovered = btn
    UpdateBlocker()
  end
end

local function OnSlotLeave(btn)
  if hovered == btn and not (blocker and blocker:IsShown() and blocker.owner == btn) then
    hovered = nil
  end
end

local function Paint(btn, data)
  local info = data and data.info
  local itemID = info and info.itemID
  if itemID and data.bag and data.slot and data.slot > 0 then
    local s = slots[btn] or {}
    s.bag, s.slot, s.itemID = data.bag, data.slot, itemID
    slots[btn] = s
    if not hooked[btn] and not InCombatLockdown() then
      hooked[btn] = true
      btn:HookScript("OnEnter", OnSlotEnter)
      btn:HookScript("OnLeave", OnSlotLeave)
    end
  else
    slots[btn] = nil
  end
  ShowMark(btn, itemID)
  if blocker and blocker.owner == btn then
    UpdateBlocker()
  end
end

-------------------------------------------------------------------------------
-- Buyback safety net
-------------------------------------------------------------------------------

local function BuybackCounts()
  local counts = {}
  local total = GetNumBuybackItems and GetNumBuybackItems() or 0
  for i = 1, total do
    local id = Items.IDFromLink(GetBuybackItemLink(i))
    if id then
      counts[id] = (counts[id] or 0) + 1
    end
  end
  return counts
end

local function SnapshotBuyback()
  buybackSnapshot = BuybackCounts()
end

local function CheckBuyback()
  if not merchantOpen then
    return
  end
  local counts = BuybackCounts()
  for id, count in pairs(counts) do
    if IsProtected(id) and count > (buybackSnapshot[id] or 0) then
      for i = GetNumBuybackItems(), 1, -1 do
        local link = GetBuybackItemLink(i)
        if Items.IDFromLink(link) == id then
          BuybackItem(i)
          buybackSnapshot = counts
          buybackSnapshot[id] = count - 1
          F:Print(ItemText(id, link) .. " " .. Reason(id) .. ", so it was bought back.")
          return -- MERCHANT_UPDATE fires again for the next one
        end
      end
    end
  end
  buybackSnapshot = counts
end

-------------------------------------------------------------------------------
-- "Locked" category
-------------------------------------------------------------------------------

-- Runs inside Ellesmere's classify pass: reads only. Another character's
-- items (offline view, bag nil) are not claimed: locks are per character.
local function ClaimLocked(_, itemID, bag)
  if bag == nil or not F._active then
    return false
  end
  if F.db.categorySets ~= false then
    return IsProtected(itemID)
  end
  return IsLocked(itemID)
end

local function CategoryManager()
  local manager = EUI.CategoryManager()
  if manager and type(manager.RegisterVirtualCategory) == "function" then
    return manager
  end
end

-- Registers or unregisters the category to match the setting (and on/off).
local function ApplyCategory()
  local manager = CategoryManager()
  if not manager then
    return false
  end
  local want = F._active and F.db.useCategory ~= false
  if want and not categoryRegistered then
    categoryRegistered = manager:RegisterVirtualCategory(CATEGORY_ID, {
      name = "Locked",
      icon = LOCK_TEXTURE,
      order = 0,
      classify = ClaimLocked,
    }) and true or false
  elseif not want and categoryRegistered then
    if manager.UnregisterVirtualCategory then
      manager:UnregisterVirtualCategory(CATEGORY_ID)
    end
    categoryRegistered = false
  end
  return true
end

-------------------------------------------------------------------------------
-- Locking
-------------------------------------------------------------------------------

local function AfterLockChange()
  SnapshotBuyback()
  RepaintAll()
  UpdateBlocker()
  if InCombatLockdown() then
    categoryRefreshPending = true
    return
  end
  local manager = categoryRegistered and CategoryManager()
  local bags = EUI.Bags()
  if manager and manager.RefreshVirtualCategories then
    manager:RefreshVirtualCategories()
  elseif bags and bags.IsShown and bags:IsShown() and bags.RefreshInventory then
    bags:RefreshInventory()
  end
  ARLE:Changed()
end

local function SetLocked(itemID, lock, link)
  if not itemID then
    return
  end
  Locks()[itemID] = lock and true or nil
  local set = SetName(itemID)
  if lock then
    F:Print(ItemText(itemID, link) .. " locked: it can't be sold or destroyed.")
  elseif set then
    F:Print(ItemText(itemID, link) .. " unlocked, but it is still protected by your gear set " .. set .. ".")
  else
    F:Print(ItemText(itemID, link) .. " unlocked.")
  end
  AfterLockChange()
end

-- A gear-set item needs no lock: say so instead of locking it.
local function ToggleItem(itemID, link)
  if not IsLocked(itemID) and SetName(itemID) then
    F:Print(ItemText(itemID, link) .. " is in your gear set " .. SetName(itemID)
      .. ", so it is already protected. Remove it from the set to sell or destroy it.")
    return
  end
  SetLocked(itemID, not IsLocked(itemID), link)
end

function Toggle(bag, slot)
  local itemID = C_Container.GetContainerItemID(bag, slot)
  if itemID then
    ToggleItem(itemID, C_Container.GetContainerItemLink(bag, slot))
  end
end

function F:ToggleItem(itemID, link)
  ToggleItem(itemID, link)
end

function F:ClearLocks()
  wipe(Locks())
  self:Print("all locks on this character removed.")
  AfterLockChange()
end

function F:Summary()
  local n, sets = 0, 0
  for _ in pairs(Locks()) do
    n = n + 1
  end
  for _ in pairs(setItems) do
    sets = sets + 1
  end
  return n .. " locked item" .. (n == 1 and "" or "s") .. " on this character"
    .. (self.db.protectSets ~= false and (", plus " .. sets .. " in your gear sets.") or ".")
end

-------------------------------------------------------------------------------
-- Hooks
-------------------------------------------------------------------------------

local function MouseFocus()
  if GetMouseFoci then
    local foci = GetMouseFoci()
    return foci and foci[1]
  end
  return GetMouseFocus and GetMouseFocus()
end

local function OnAltRightClick()
  local btn = hovered
  local s = btn and slots[btn]
  if not s or not btn:IsVisible() or not btn:IsMouseOver() then
    return
  end
  -- Another frame over the slot took the click (the blocker handles its own;
  -- Ellesmere's Quick Actions cast button means that click was a cast).
  local focus = MouseFocus()
  if focus and focus ~= btn then
    return
  end
  Toggle(s.bag, s.slot)
end

local function OnDeletePopup(which)
  if not DELETE_POPUPS[which] then
    return
  end
  local kind, itemID, link = GetCursorInfo()
  if kind == "item" and IsProtected(itemID) then
    ClearCursor()
    F:Print(ItemText(itemID, link) .. " " .. Reason(itemID) .. " and can't be destroyed (nothing will be "
      .. "deleted). " .. UnlockHint(itemID))
  end
end

local function OnBagTooltip(tooltip, bag, slot)
  local itemID = C_Container.GetContainerItemID(bag, slot)
  if IsLocked(itemID) then
    tooltip:AddLine("Locked: can't be sold or destroyed (Alt+Right-click to unlock)", 1, 0.82, 0.25, true)
    tooltip:Show()
  elseif SetName(itemID) then
    tooltip:AddLine("In gear set " .. SetName(itemID) .. ": can't be sold or destroyed", 0.55, 0.8, 1, true)
    tooltip:Show()
  end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function F:OnEnable()
  Locks()
  RebuildSetItems()
  local bags = EUI.Bags()
  if not overlayRegistered then
    if bags and type(bags.RegisterItemOverlayIcon) == "function" then
      bags.RegisterItemOverlayIcon("ARLE_ItemLock", Paint)
      overlayRegistered = true
    else
      self:Print("EllesmereUI Bags' overlay API was not found (did it change?). Padlocks and Alt+Right-click are "
        .. "off; /arl lock <item> still locks items.")
    end
  end
  if not ApplyCategory() then
    self:Print("EllesmereUI Bags' category API was not found; locked items stay in their normal categories.")
  end
  local manager = EUI.CategoryManager()
  if not self:Wrap(manager, "IsJunk", function(orig, mgr, itemID, ...)
    if IsProtected(itemID) then
      return false
    end
    return orig(mgr, itemID, ...)
  end) then
    self:Print("EllesmereUI's junk check was not found: Sell Junk may sell locked junk (it is bought back).")
  end
  self:Hook("StaticPopup_Show", OnDeletePopup)
  self:Hook(GameTooltip, "SetBagItem", OnBagTooltip)

  self:On("MERCHANT_SHOW", function()
    merchantOpen = true
    SnapshotBuyback()
    UpdateBlocker()
  end)
  self:On("MERCHANT_CLOSED", function()
    merchantOpen = false
    HideBlocker()
  end)
  self:On("MERCHANT_UPDATE", CheckBuyback)
  self:On("PLAYER_REGEN_DISABLED", HideBlocker)
  self:On("PLAYER_REGEN_ENABLED", function()
    if categoryRefreshPending then
      categoryRefreshPending = false
      AfterLockChange()
    end
  end)
  local function SetsChanged()
    if RebuildSetItems() then
      AfterLockChange()
    end
  end
  self:On("PLAYER_ENTERING_WORLD", SetsChanged)
  pcall(self.On, self, "EQUIPMENT_SETS_CHANGED", SetsChanged)
  if not pcall(self.On, self, "GLOBAL_MOUSE_UP", function(_, _, button)
    if button == "RightButton" and IsAltKeyDown() then
      OnAltRightClick()
    end
  end) then
    self:Print("Alt+Right-click is unavailable on this client; use /arl lock <shift-click item>.")
  end
  AfterLockChange()
end

function F:OnDisable()
  HideBlocker()
  merchantOpen = false
  hovered = nil
  ApplyCategory()
  RepaintAll() -- hides the padlocks
  -- No painter left in EUI's slot updates while off (OnEnable registers it
  -- again). Without the unregister call the painter stays and does nothing.
  local bags = EUI.Bags()
  if overlayRegistered and bags and type(bags.UnregisterItemOverlayIcon) == "function" then
    bags.UnregisterItemOverlayIcon("ARLE_ItemLock")
    overlayRegistered = false
    wipe(slots)
  end
  AfterLockChange()
end

-- The standalone EllesmereUIBags_ItemLock's data (per character
-- EllesmereUIBags_ItemLockDB: items = { [itemID] = true }, protectSets,
-- useCategory, categorySets). Locks are merged into this character's (a lock
-- list is safest as a union); its settings replace ours. Each character's
-- locks come over the first time it logs in with the old addon still on.
function F:Import()
  local old = _G.EllesmereUIBags_ItemLockDB
  if type(old) ~= "table" then
    return
  end
  if type(old.items) == "table" then
    local locks = Locks()
    for itemID, value in pairs(old.items) do
      local id = tonumber(itemID)
      if id and id > 0 and value == true then
        locks[math.floor(id)] = true
      end
    end
  end
  for _, key in ipairs({ "protectSets", "useCategory", "categorySets" }) do
    if type(old[key]) == "boolean" then
      self.db[key] = old[key]
    end
  end
end

function F:OnOptionChanged(key)
  if key == "useCategory" then
    ApplyCategory()
  end
  AfterLockChange()
end

function F:GetStatus()
  return "Active · " .. self:Summary()
end

-- /arl lock <link or ID>: locks or unlocks it.
function F:main(rest, raw)
  local itemID = Items.IDFromLink(raw) or tonumber((rest or ""):match("^%s*(%d+)%s*$") or "")
  if itemID then
    ToggleItem(itemID, raw:match("|c.-|r"))
    return
  end
  if (rest or "") == "" then
    ARLE:PrintStatus(self)
    return
  end
  self:Print("shift-click an item into the command, or give its ID: /arl lock <item>.")
end

F.commands = {
  { name = "list", help = "locked items on this character", run = function(self)
    self:Print("locked items:")
    local any = false
    for itemID in pairs(Locks()) do
      any = true
      print("   " .. ItemText(itemID))
    end
    if not any then
      print("   none")
    end
    print("   " .. self:Summary())
  end },
  { name = "clear", help = "removes every lock on this character", run = function(self)
    self:ClearLocks()
  end },
}

ARLE:RegisterModule(F)
