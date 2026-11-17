-- ARLE.Secure: things the game only allows outside combat, or only from a
-- key the player presses.
--
-- Packs are LoadOnDemand and may load mid-combat, when secure frames can't be
-- made. So the host makes the few secure buttons features need here, at
-- login, and lists their key bindings in its own Bindings.xml (header "ARL
-- Extensions"); features only change their attributes, out of combat.
--
--   ARLE.Secure:Run(fn[, key])     now, or as soon as combat ends (in order);
--                                  with a key, only the last fn queued under it
--   ARLE.Secure:Attach(key, holder, point, w, h)   lay a button on a feature's frame
--   ARLE.Secure:Detach(key, holder, attrs)         hand it back clean
--   ARLE.Secure:Button(key)        one of the buttons below
--   ARLE.Secure:Binding(key)       its binding name ("CLICK ARLE_Secure...:LeftButton")
--   ARLE.Secure:BoundKey(key)      the key bound to it, readable, or nil
local _, ns = ...
local ARLE = ns.ARLE
local S = ARLE.Secure

local queue = {}
local queuedAt = {} -- key -> index in queue

-- A frame that holds a secure button, or that one is anchored to, becomes
-- protected: in combat the game blocks its SetPoint, SetSize, SetScale,
-- Show/Hide, Enable/Disable and StartMoving ("ADDON_ACTION_BLOCKED"), even
-- while it's hidden. Such changes go through Run with a key (the frame, or a
-- name), so a change repeated in combat runs once, with its latest version.

local function InCombat()
  return InCombatLockdown and InCombatLockdown()
end

function S:InCombat()
  return InCombat() and true or false
end

function S:Run(fn, key)
  if InCombat() then
    local at = key ~= nil and queuedAt[key]
    if at then
      queue[at] = fn
    else
      queue[#queue + 1] = fn
      if key ~= nil then
        queuedAt[key] = #queue
      end
    end
    return false
  end
  -- Out of combat already (the queue not drained yet): this newer fn runs
  -- now, so an older one waiting under the same key mustn't run after it.
  local at = key ~= nil and queuedAt[key]
  if at then
    queue[at] = function() end
    queuedAt[key] = nil
  end
  local ok, err = pcall(fn)
  if not ok then
    ARLE.Debug:Record(nil, err)
  end
  return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
  local list = queue
  queue, queuedAt = {}, {}
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn)
    if not ok then
      ARLE.Debug:Record(nil, err)
    end
  end
end)

-- key -> { kind, label shown in the key bindings list }
local BUTTONS = {
  FishingSwap = { kind = "macro", label = "Fishing Pole Alert: put my weapons back on" },
  RareScan = { kind = "macro", label = "Rare Objectives: scan for rare quest mobs" },
  BuffBack = { kind = "macro", label = "Buff Back: buff the next person in the queue" },
  -- Layer Bridge's AutoLayer button (the key keeps its first name): a
  -- clickable macro, so its "inv layer" line is said by the player's click.
  LayerSwap = { kind = "macro", click = true, label = "Layer Bridge: ask AutoLayer hosts (inv layer)" },
  UseItem = { kind = "item" }, -- Sleeping Bag's bag icon
  UseFood = { kind = "item" }, -- XP Food's food icon (both alerts can be up at once)
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
  if spec.kind == "macro" and not spec.click then
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

-- Lays a host button on a feature's frame (holder), out of combat only:
-- parented to it and anchored to the holder itself (a protected frame can't
-- be anchored to a region such as an icon texture: "Cannot anchor protected
-- frames to regions"). point = { "LEFT", x, y }. Returns the button, or nil
-- in combat or when it's missing (game not restarted since it was added).
function S:Attach(key, holder, point, w, h)
  local b = made[key]
  if not b or not holder or InCombat() then
    return nil
  end
  b:SetParent(holder)
  b:ClearAllPoints()
  b:SetPoint(point[1], holder, point[1], point[2] or 0, point[3] or 0)
  b:SetSize(w, h or w)
  b:Show()
  return b
end

-- Hands a shared button back clean (hidden, under UIParent, the listed
-- attributes and its scripts cleared) so the next feature doesn't inherit
-- it. Only while it's still on holder (another feature may have taken it);
-- out of combat only (callers go through Run).
local SCRIPTS = { "OnEnter", "OnLeave", "PreClick", "PostClick" }
function S:Detach(key, holder, attrs)
  local b = made[key]
  if not b or not holder or b:GetParent() ~= holder or InCombat() then
    return
  end
  b:Hide()
  b:ClearAllPoints()
  b:SetParent(UIParent)
  for _, a in ipairs(attrs or {}) do
    b:SetAttribute(a, nil)
  end
  for _, script in ipairs(SCRIPTS) do
    b:SetScript(script, nil)
  end
end
