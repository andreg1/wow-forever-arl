-- ARLE.Secure: things the game only allows outside combat, or only from a
-- key the player presses.
--
-- Packs are LoadOnDemand and may load mid-combat, when secure frames can't be
-- made. So the host makes the few secure buttons features need here, at
-- login, and lists their key bindings in its own Bindings.xml (header "ARL
-- Extensions"); features only change their attributes, out of combat.
--
--   ARLE.Secure:Run(fn)            now, or as soon as combat ends (in order)
--   ARLE.Secure:Button(key)        one of the buttons below
--   ARLE.Secure:Binding(key)       its binding name ("CLICK ARLE_Secure...:LeftButton")
--   ARLE.Secure:BoundKey(key)      the key bound to it, readable, or nil
local _, ns = ...
local ARLE = ns.ARLE
local S = ARLE.Secure

local queue = {}

local function InCombat()
  return InCombatLockdown and InCombatLockdown()
end

function S:InCombat()
  return InCombat() and true or false
end

function S:Run(fn)
  if InCombat() then
    queue[#queue + 1] = fn
    return false
  end
  local ok, err = pcall(fn)
  if not ok then
    geterrorhandler()(err)
  end
  return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
  local list = queue
  queue = {}
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn)
    if not ok then
      geterrorhandler()(err)
    end
  end
end)

-- key -> { kind, label shown in the key bindings list }
local BUTTONS = {
  FishingSwap = { kind = "macro", label = "Fishing Pole Alert: put my weapons back on" },
  RareScan = { kind = "macro", label = "Rare Objectives: scan for rare quest mobs" },
  UseItem = { kind = "item" },
}
S.BUTTONS = BUTTONS

local made = {}

local function Name(key)
  return "ARLE_Secure" .. key
end

function S:Binding(key)
  return "CLICK " .. Name(key) .. ":LeftButton"
end

function S:Button(key)
  return made[key]
end

function S:BoundKey(key)
  local k = GetBindingKey and GetBindingKey(self:Binding(key))
  if k then
    return GetBindingText and GetBindingText(k) or k
  end
end

-- The binding list's labels (the game reads these names).
BINDING_HEADER_ARLEXTENSIONS = ARLE.shortTitle
for key, spec in pairs(BUTTONS) do
  if spec.label then
    _G["BINDING_NAME_" .. S:Binding(key)] = spec.label
  end
end

-- Made at load (login, never in combat). Hidden 1x1 buttons that answer key
-- presses on the down edge only, so a press acts once; UseItem is shown by
-- the feature that uses it (a clickable icon).
local function Make(key, spec)
  local ok, b = pcall(CreateFrame, "Button", Name(key), UIParent, "SecureActionButtonTemplate")
  if not ok or not b then
    return
  end
  b:SetAttribute("type", spec.kind)
  if spec.kind == "macro" then
    b:SetAttribute("useOnKeyDown", true)
    b:RegisterForClicks("AnyDown")
    b:SetSize(1, 1)
  else
    -- A clickable icon: act on the mouse release. Without useOnKeyDown=false
    -- the template follows the ActionButtonUseKeyDown CVar (on by default)
    -- and ignores an up-edge click.
    b:SetAttribute("useOnKeyDown", false)
    b:RegisterForClicks("AnyUp")
    b:SetSize(36, 36)
  end
  b:Hide()
  made[key] = b
end

for key, spec in pairs(BUTTONS) do
  Make(key, spec)
end

-- Sets attributes now or after combat; the last call for a key wins.
local pendingAttrs = {}
function S:SetAttributes(key, attrs)
  local b = made[key]
  if not b then
    return
  end
  pendingAttrs[key] = attrs
  self:Run(function()
    local a = pendingAttrs[key]
    if a then
      pendingAttrs[key] = nil
      for k, v in pairs(a) do
        b:SetAttribute(k, v)
      end
    end
  end)
end
