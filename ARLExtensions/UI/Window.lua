-- ARLE.UI.Window: floating, tooltip-style windows for features (Dungeon
-- Helper look): the theme's panel, a slim title bar with a close button,
-- dragging, and a remembered position.
--
--   local w = ARLE.UI.Window:New({
--     name = "ARLEQuestSearchFrame", title = "Quest Search", width = 420, height = 380,
--     store = def.char, key = "pos",                 -- where the position is kept
--     point = { "CENTER", UIParent, "CENTER", 0, 60 },
--     escClose = true,                                -- Escape closes it
--   })
--   w.content   frame under the title bar (fill it)
--   w:SetTitle(text), w.titleBar (add buttons there), w.close
local _, ns = ...
local ARLE = ns.ARLE
local Skin = ARLE.Skin
local Kit = ARLE.UI.Kit

local Window = {}
ARLE.UI.Window = Window
Window.HEADER_H = 22

function Window:New(spec)
  local f = Skin:CreateTooltipWindow(spec.name, spec.parent or UIParent)
  f:SetSize(spec.width or 300, spec.height or 300)
  f:SetFrameStrata(spec.strata or "MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  local store, key = spec.store, spec.key or "pos"
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if store then
      local point, _, rel, x, y = self:GetPoint()
      store[key] = { point, rel, x, y }
    end
  end)
  function f:RestorePosition()
    self:ClearAllPoints()
    local pos = store and store[key]
    if type(pos) == "table" and pos[1] then
      self:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
      local p = spec.point or { "CENTER", UIParent, "CENTER", 0, 0 }
      self:SetPoint(p[1], p[2] or UIParent, p[3] or p[1], p[4] or 0, p[5] or 0)
    end
  end
  f:RestorePosition()

  f.titleBar = CreateFrame("Frame", nil, f)
  f.titleBar:SetPoint("TOPLEFT", 4, -2)
  f.titleBar:SetPoint("TOPRIGHT", -4, -2)
  f.titleBar:SetHeight(self.HEADER_H - 2)
  f.close = Kit.SmallButton(f.titleBar, "x", 18)
  f.close:SetPoint("RIGHT", 0, 0)
  f.close:SetScript("OnClick", function()
    f:Hide()
  end)
  f.title = Kit.Text(f.titleBar, "GameFontNormalSmall")
  f.title:SetPoint("LEFT", 4, 0)
  f.title:SetPoint("RIGHT", f.close, "LEFT", -4, 0)
  f.title:SetWordWrap(false)
  f.title:SetText(spec.title or "")
  function f:SetTitle(text)
    self.title:SetText(text or "")
  end
  local rule = Kit.Rule(f, 0.08)
  rule:SetPoint("TOPLEFT", 1, -self.HEADER_H)
  rule:SetPoint("TOPRIGHT", -1, -self.HEADER_H)

  f.content = CreateFrame("Frame", nil, f)
  f.content:SetPoint("TOPLEFT", 6, -(self.HEADER_H + 4))
  f.content:SetPoint("BOTTOMRIGHT", -6, 6)

  if spec.escClose and spec.name then
    tinsert(UISpecialFrames, spec.name)
  end
  f:Hide()
  return f
end
