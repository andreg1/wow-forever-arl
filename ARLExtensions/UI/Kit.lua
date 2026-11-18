-- ARLE.UI.Kit (also ARLE.UIKit): themed widgets for the panel and for every
-- feature window, so everything follows the theme picked in Settings (ARL,
-- EllesmereUI, ElvUI, Blizzard). Features build their frames from these and
-- from ARLE.UI.Window instead of raw templates.
local _, ns = ...
local ARLE = ns.ARLE
local Skin = ARLE.Skin

local Kit = {}
ARLE.UI.Kit = Kit
ARLE.UIKit = Kit

function Kit.Text(parent, template, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  Skin:Font(fs)
  return fs
end

function Kit.Check(parent, name)
  local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  Skin:Check(check)
  return check
end

function Kit.Button(parent, label, width)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetSize(width or 100, 22)
  button:SetText(label)
  Skin:Button(button)
  return button
end

function Kit.SmallButton(parent, label, width)
  local b = Kit.Button(parent, label, width)
  b:SetHeight(16)
  local fs = b:GetFontString()
  if fs and GameFontNormalSmall then
    fs:SetFontObject(GameFontNormalSmall)
  end
  return b
end

function Kit.EditBox(parent, width, name)
  local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  box:SetSize(width or 160, 22)
  box:SetAutoFocus(false)
  Skin:EditBox(box)
  box:SetScript("OnEscapePressed", box.ClearFocus)
  return box
end

-- A scroll area: returns the scroll frame and its child (sized to width).
function Kit.Scroll(parent, name)
  local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
  Skin:ScrollBar(scroll)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  return scroll, child
end

-- An item/spell icon button with a tooltip hook and an optional count.
function Kit.Icon(parent, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size or 20, size or 20)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.15)
  return b
end

-- Tooltips ----------------------------------------------------------------------

function Kit.TooltipSide(owner)
  local x = owner:GetCenter()
  if x and x * owner:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2 then
    return "ANCHOR_LEFT"
  end
  return "ANCHOR_RIGHT"
end

function Kit.SimpleTooltip(owner, title, text)
  GameTooltip:SetOwner(owner, Kit.TooltipSide(owner))
  GameTooltip:SetText(title, 1, 1, 1)
  if text then
    GameTooltip:AddLine(text, 0.8, 0.8, 0.8, true)
  end
  GameTooltip:Show()
end

-- Shows a simple tooltip on hover.
function Kit.Tip(frame, title, text)
  frame:SetScript("OnEnter", function(self)
    Kit.SimpleTooltip(self, type(title) == "function" and title() or title, type(text) == "function" and text() or text)
  end)
  frame:SetScript("OnLeave", GameTooltip_Hide)
end

-- A row of filter buttons; the selected one is drawn in the accent colour.
-- list = { {key, label, width, tip}, ... }; set(key) runs on click.
function Kit.FilterButtons(bar, list, get, set)
  local buttons, prev = {}, nil
  for _, f in ipairs(list) do
    local b = Kit.SmallButton(bar, f.label, f.width or 44)
    b.key = f.key
    if prev then
      b:SetPoint("LEFT", prev, "RIGHT", 2, 0)
    else
      b:SetPoint("LEFT", 0, 0)
    end
    b:SetScript("OnClick", function(self)
      set(self.key)
      buttons.Paint()
    end)
    b:SetScript("OnEnter", function(self)
      Kit.SimpleTooltip(self, f.label, f.tip)
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    buttons[#buttons + 1] = b
    prev = b
  end
  function buttons.Paint()
    local ar, ag, ab = Skin:Accent()
    local current = get()
    for _, b in ipairs(buttons) do
      local fs = b:GetFontString()
      if fs then
        if b.key == current then
          fs:SetTextColor(ar, ag, ab)
        else
          fs:SetTextColor(0.75, 0.75, 0.75)
        end
      end
    end
  end
  buttons.last = prev
  return buttons
end

-- A thin rule (separator line).
function Kit.Rule(parent, alpha)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetHeight(1)
  t:SetColorTexture(1, 1, 1, alpha or 0.1)
  return t
end

-- A feature's movable box, kept where the player drags it: the centre's
-- offset from UIParent's centre, in UIParent units, in def.char[spec.key or
-- "position"] (what the "Reset position" preset clears). Returns place(),
-- which puts the frame back there (call it after a reset or a SetScale).
--   spec.x, spec.y   default offset
--   spec.secure      the frame holds a secure button (it's protected): no
--                    drag in combat, and moves wait for combat to end
--   spec.onMoved     fn() after a drag (e.g. to move a sibling box along)
function Kit.Movable(f, def, spec)
  spec = spec or {}
  local key = spec.key or "position"
  local Secure = ARLE.Secure
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  local function Go()
    f:ClearAllPoints()
    local pos = def.char and def.char[key]
    local s = f:GetScale() -- offsets are in the frame's own (scaled) units
    f:SetPoint("CENTER", UIParent, "CENTER", (pos and pos[1] or spec.x or 0) / s, (pos and pos[2] or spec.y or 0) / s)
  end
  local function Place()
    if spec.secure then
      Secure:Run(Go, f)
    else
      Go()
    end
  end
  local moving
  local stopKey = {}
  def:Script(f, "OnDragStart", function(self)
    if spec.secure and Secure:InCombat() then
      return
    end
    moving = true
    self:StartMoving()
  end)
  def:Script(f, "OnDragStop", function(self)
    if not moving then
      return
    end
    moving = nil
    local function Stop()
      self:StopMovingOrSizing()
      local x, y = self:GetCenter()
      local cx, cy = UIParent:GetCenter()
      local s = self:GetScale()
      if x and cx then
        def.char[key] = { x * s - cx, y * s - cy }
      end
      Go()
      if spec.onMoved then
        spec.onMoved()
      end
    end
    if spec.secure then
      Secure:Run(Stop, stopKey) -- its own key: a Place queued after it must not replace it
    else
      Stop()
    end
  end)
  Place()
  return Place
end

-------------------------------------------------------------------------------
-- Kit.Card: the one look of every feature popup (reminders, alerts, status
-- boxes): a themed box with a thin accent edge on the left, an optional icon
-- top-left, up to three lines (text, sub, note) and a row of small buttons at
-- the bottom right, as tall as its text needs. Every popup is built from it,
-- so they share size, spacing, fonts and behaviour.
--
--   local card = Kit.Card(def, { icon = true, width = 280, strata = "MEDIUM",
--     move = { y = 120, secure = true, key = "position", onMoved = fn } })
--   card:SetLines(text, sub, note)     -- any may be nil (hidden)
--   card:AddButton("Dismiss", 52, fn)  -- right to left, in the order added
--   card:SetAccent(r, g, b)            -- the edge (and title) colour; default the theme's
--   card:Fit()                         -- height from the lines (SetLines calls it)
--   card.place()                       -- re-place it (Kit.Movable's), when move was given
-- A card holding a host secure button is protected: size and place it out of
-- combat (move.secure = true defers its moves; call Fit through Secure:Run).
-------------------------------------------------------------------------------

Kit.CARD = { width = 280, pad = 8, icon = 32, edge = 3, button = 16 }

function Kit.Card(def, spec)
  spec = spec or {}
  local C = Kit.CARD
  local f = Skin:CreateTooltipWindow(nil, UIParent)
  f:SetFrameStrata(spec.strata or "MEDIUM")
  f:SetWidth(spec.width or C.width)
  f:SetHeight(C.icon + 2 * C.pad)

  f.edge = f:CreateTexture(nil, "OVERLAY")
  f.edge:SetPoint("TOPLEFT", 1, -1)
  f.edge:SetPoint("BOTTOMLEFT", 1, 1)
  f.edge:SetWidth(C.edge)

  local left = C.pad + C.edge
  if spec.icon then
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(C.icon, C.icon)
    f.icon:SetPoint("TOPLEFT", left, -C.pad)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  end

  f.text = Kit.Text(f, spec.titleFont or "GameFontHighlight")
  if f.icon then
    f.text:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", C.pad, 0)
  else
    f.text:SetPoint("TOPLEFT", left, -C.pad)
  end
  f.text:SetPoint("RIGHT", -C.pad, 0)
  f.text:SetWordWrap(true)

  f.sub = Kit.Text(f, "GameFontNormalSmall")
  f.sub:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -3)
  f.sub:SetPoint("RIGHT", -C.pad, 0)
  f.sub:SetWordWrap(true)

  f.note = Kit.Text(f, "GameFontDisableSmall")
  f.note:SetPoint("TOPLEFT", f.sub, "BOTTOMLEFT", 0, -2)
  f.note:SetPoint("RIGHT", -C.pad, 0)
  f.note:SetWordWrap(true)

  f.buttons = {}
  -- extra: px a feature's own content needs below the lines (a bar)
  f.extra = 0

  function f:SetAccent(r, g, b)
    if not r then
      r, g, b = Skin:Accent()
    end
    self.edge:SetColorTexture(r, g, b, 0.9)
  end

  function f:AddButton(label, width, fn)
    local b = Kit.SmallButton(self, label, width)
    local prev = self.buttons[#self.buttons]
    if prev then
      b:SetPoint("RIGHT", prev, "LEFT", -4, 0)
    else
      b:SetPoint("BOTTOMRIGHT", -C.pad, C.pad)
    end
    if fn then
      def:Script(b, "OnClick", fn)
    end
    self.buttons[#self.buttons + 1] = b
    return b
  end

  local function H(fs)
    return fs:IsShown() and (fs:GetText() or "") ~= "" and fs:GetStringHeight() or 0
  end

  function f:Fit()
    local h = C.pad + H(self.text)
    local sub, note = H(self.sub), H(self.note)
    if sub > 0 then
      h = h + 3 + sub
    end
    if note > 0 then
      h = h + 2 + note
    end
    h = h + self.extra
    local anyButton = false
    for _, b in ipairs(self.buttons) do
      anyButton = anyButton or b:IsShown()
    end
    if anyButton then
      h = h + 6 + C.button
    end
    h = h + C.pad
    if self.icon and self.icon:IsShown() then
      h = math.max(h, C.icon + 2 * C.pad)
    end
    self:SetHeight(math.ceil(h))
  end

  function f:SetLines(text, sub, note)
    self.text:SetText(text or "")
    self.sub:SetText(sub or "")
    self.note:SetText(note or "")
    self.sub:SetShown(sub ~= nil and sub ~= "")
    self.note:SetShown(note ~= nil and note ~= "")
    self:Fit()
  end

  f:SetAccent()
  if spec.move then
    f.place = Kit.Movable(f, def, spec.move)
  end
  f:Hide()
  return f
end
