-- Theme adapters: the panel asks for a "window", "button", "check", ... and
-- this file paints it in the chosen theme.
--
--   arl        ARL's own flat look (the default): near-black panels with 1px
--              borders, flat buttons, on/off switches, a gold (or class
--              colour) accent and the UI addon's font. Modelled on the look
--              of Forever Leveling BiS's Modern theme; our own code, drawn
--              with the game's plain white texture only.
--   ellesmere  EllesmereUI's public Skinning API (EllesmereUI.RegisterSkin)
--   elvui      ElvUI's Skins module (S:HandleButton, frame:SetTemplate, ...)
--   blizzard   stock templates, no repaint
--
-- "auto" picks ElvUI, then EllesmereUI, then Blizzard. Settings and
-- /arl theme pick one. Every adapter call is protected: a theme API changing
-- shape degrades to the stock look instead of breaking the panel.
local _, ns = ...
local ARLE = ns.ARLE

local Skin = {}
ARLE.Skin = Skin

local euiS -- EllesmereUI skin primitives, handed to us at PLAYER_LOGIN

if EllesmereUI and EllesmereUI.RegisterSkin then
  EllesmereUI.RegisterSkin(ARLE.name, function(S)
    euiS = S
  end)
end

local function ElvUISkins()
  local engine = _G.ElvUI
  if type(engine) ~= "table" then
    return nil
  end
  local E = engine[1]
  local ok, S = pcall(E.GetModule, E, "Skins")
  if ok and S then
    return E, S
  end
end

-------------------------------------------------------------------------------
-- ARL palette
-------------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ARL = {
  window = { 0.06, 0.06, 0.08, 0.95 }, -- windows
  box = { 0.09, 0.09, 0.11, 1 },       -- panes inside a window
  surface = { 0.14, 0.14, 0.17, 1 },   -- buttons, switch tracks
  field = { 0.12, 0.12, 0.14, 1 },     -- text boxes, dropdowns
  border = { 0.25, 0.25, 0.25, 1 },
  dim = { 0.6, 0.6, 0.6 },
  gold = { 1, 0.82, 0 },
}
Skin.ARL = ARL
Skin.TITLE_H = 30 -- the ARL window's title band

-- The theme in use this session, latched on first ask (skins cannot be undone
-- without a reload anyway).
function Skin:Theme()
  if self.theme then
    return self.theme
  end
  local want = (ARLE.db and ARLE.db.theme) or "arl"
  self.requested = want
  local theme = "blizzard"
  if want == "arl" then
    theme = "arl"
  elseif want == "elvui" or (want == "auto" and ElvUISkins()) then
    theme = ElvUISkins() and "elvui" or "blizzard"
  end
  if theme == "blizzard" and (want == "ellesmere" or want == "auto") and euiS and type(euiS.IsEnabled) == "function" and euiS.IsEnabled() then
    theme = "ellesmere"
  end
  self.theme = theme
  return theme
end

function Skin:ThemeLabel()
  local names = { arl = "ARL", ellesmere = "EllesmereUI", elvui = "ElvUI", blizzard = "Blizzard" }
  return names[self:Theme()]
end

local function Try(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and ARLE.debug then
    ARLE:Print("skin: " .. tostring(err))
  end
  return ok
end

-- The accent: gold, or the player's class colour (Settings: Accent colour).
local function ArlAccent()
  if ARLE.db and ARLE.db.accent == "class" then
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[select(2, UnitClass("player"))]
    if c then
      return c.r, c.g, c.b
    end
  end
  return ARL.gold[1], ARL.gold[2], ARL.gold[3]
end

-- A flat fill with a 1px border, drawn on the frame itself (no template
-- needed). Returns the fill; frame.arlEdges holds the four edges.
local function Flat(frame, color, layer)
  local bg = frame:CreateTexture(nil, layer or "BACKGROUND", nil, -7)
  bg:SetAllPoints()
  bg:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
  local edges = {}
  local function Edge(p1, p2, w, h)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND", nil, -6)
    t:SetPoint(p1)
    t:SetPoint(p2)
    if w then
      t:SetWidth(w)
    else
      t:SetHeight(h)
    end
    t:SetColorTexture(ARL.border[1], ARL.border[2], ARL.border[3], 1)
    edges[#edges + 1] = t
  end
  Edge("TOPLEFT", "TOPRIGHT", nil, 1)
  Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
  Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
  Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
  frame.arlBg, frame.arlEdges = bg, edges
  return bg
end
Skin.Flat = Flat

local function SetEdges(frame, r, g, b, a)
  for _, t in ipairs(frame.arlEdges or {}) do
    t:SetColorTexture(r, g, b, a or 1)
  end
end

-- Hides a template's own art (Blizzard buttons, input boxes, dropdowns):
-- alpha only, nothing is reparented.
local function StripArt(frame, keep)
  for _, region in ipairs({ frame:GetRegions() }) do
    if region.GetObjectType and region:GetObjectType() == "Texture" and region ~= keep
        and not (frame.arlBg == region) then
      region:SetAlpha(0)
    end
  end
  for _, key in ipairs({ "Left", "Middle", "Right", "Mid", "LeftDisabled", "MiddleDisabled", "RightDisabled" }) do
    local t = frame[key]
    if t and t.SetAlpha then
      t:SetAlpha(0)
    end
  end
end

local function Hover(frame)
  local hl = frame:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  return hl
end

-------------------------------------------------------------------------------
-- Windows and panes
-------------------------------------------------------------------------------

-- The Blizzard window template, or a plain backdrop frame for themes that
-- repaint it anyway.
function Skin:CreateWindow(name, parent)
  local theme = self:Theme()
  local frame
  if theme == "blizzard" then
    local ok, made = pcall(CreateFrame, "Frame", name, parent, "BasicFrameTemplateWithInset")
    if ok then
      frame = made
      frame.stock = true
    end
  end
  if not frame then
    local ok, made = pcall(CreateFrame, "Frame", name, parent, "BackdropTemplate")
    frame = ok and made or CreateFrame("Frame", name, parent)
  end

  if theme == "arl" then
    Flat(frame, ARL.window)
    -- Title band: a darker strip with a faint rule under it.
    local band = frame:CreateTexture(nil, "BORDER")
    band:SetPoint("TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", -1, -1)
    band:SetHeight(self.TITLE_H)
    band:SetColorTexture(0, 0, 0, 0.35)
    local rule = frame:CreateTexture(nil, "BORDER", nil, 1)
    rule:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
    rule:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
    rule:SetHeight(1)
    rule:SetColorTexture(1, 1, 1, 0.08)
    frame.arl = true
  elseif theme == "ellesmere" then
    Try(euiS.Shell, frame)
  elseif theme == "elvui" then
    Try(function()
      frame:SetTemplate("Transparent")
    end)
  elseif not frame.stock and frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true,
      tileSize = 32,
      edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end
  return frame
end

-- A floating, tooltip-like window (module overlays such as the BiS helper):
-- the theme's panel look, or the stock tooltip backdrop.
function Skin:CreateTooltipWindow(name, parent)
  local ok, frame = pcall(CreateFrame, "Frame", name, parent, "BackdropTemplate")
  if not ok then
    frame = CreateFrame("Frame", name, parent)
  end
  local theme = self:Theme()
  if theme == "arl" then
    Flat(frame, ARL.window)
  elseif theme == "ellesmere" then
    Try(euiS.Panel, frame)
  elseif theme == "elvui" then
    Try(function()
      frame:SetTemplate("Transparent")
    end)
  elseif frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.06, 0.06, 0.08, 0.94)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.65, 1)
  end
  return frame
end

-- A sub-panel (list pane, details pane).
function Skin:Panel(frame)
  local theme = self:Theme()
  if theme == "arl" then
    Flat(frame, ARL.box)
  elseif theme == "ellesmere" then
    Try(euiS.Panel, frame, { inset = true })
  elseif theme == "elvui" then
    Try(function()
      frame:SetTemplate("Default")
    end)
  else
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)
  end
end

-------------------------------------------------------------------------------
-- Widgets
-------------------------------------------------------------------------------

function Skin:Button(button)
  local theme = self:Theme()
  if theme == "arl" then
    Try(function()
      StripArt(button)
      for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
        local t = button[getter] and button[getter](button)
        if t then
          t:SetAlpha(0)
        end
      end
      Flat(button, ARL.surface, "BACKGROUND")
      Hover(button)
      local fs = button:GetFontString()
      if fs and GameFontHighlightSmall then
        fs:SetFontObject(GameFontHighlightSmall)
        self:Font(fs)
      end
      -- Disabled: faded, like the rest of the look.
      local function State()
        button:SetAlpha(button:IsEnabled() and 1 or 0.45)
      end
      hooksecurefunc(button, "SetEnabled", State)
      hooksecurefunc(button, "Enable", State)
      hooksecurefunc(button, "Disable", State)
    end)
  elseif theme == "ellesmere" then
    Try(euiS.Button, button)
    Try(euiS.StateButtonLabel, button)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleButton, S, button)
  end
end

-- ARL: the check box becomes an on/off switch: a small flat track, a square
-- knob left (off) or right in the accent (on).
local function Switch(check)
  StripArt(check)
  for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture",
    "GetCheckedTexture", "GetDisabledCheckedTexture", "GetDisabledTexture" }) do
    local t = check[getter] and check[getter](check)
    if t then
      t:SetAlpha(0)
    end
  end
  check:SetSize(30, 16)
  local track = CreateFrame("Frame", nil, check)
  track:SetSize(26, 12)
  track:SetPoint("CENTER")
  track:EnableMouse(false)
  local fill = Flat(track, ARL.surface, "ARTWORK")
  local knob = track:CreateTexture(nil, "OVERLAY")
  knob:SetSize(8, 8)
  local function Update()
    local on = check:GetChecked() and true or false
    knob:ClearAllPoints()
    if on then
      local r, g, b = ArlAccent()
      fill:SetColorTexture(r * 0.35, g * 0.35, b * 0.35, 1)
      SetEdges(track, r, g, b, 0.9)
      knob:SetPoint("RIGHT", track, "RIGHT", -2, 0)
      knob:SetColorTexture(r, g, b, 1)
    else
      fill:SetColorTexture(ARL.surface[1], ARL.surface[2], ARL.surface[3], 1)
      SetEdges(track, ARL.border[1], ARL.border[2], ARL.border[3], 1)
      knob:SetPoint("LEFT", track, "LEFT", 2, 0)
      knob:SetColorTexture(0.45, 0.45, 0.48, 1)
    end
    track:SetAlpha(check:IsEnabled() and 1 or 0.45)
  end
  hooksecurefunc(check, "SetChecked", Update)
  hooksecurefunc(check, "SetEnabled", Update)
  check:HookScript("OnClick", Update)
  check.arlSwitch = Update
  Update()
end

function Skin:Check(check)
  local theme = self:Theme()
  if theme == "arl" then
    Try(Switch, check)
  elseif theme == "ellesmere" then
    Try(euiS.Checkbox, check)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleCheckBox, S, check)
  end
end

-- A close button for a window: ARL's flat square with a grey cross that takes
-- the accent on hover; otherwise the stock one, themed.
function Skin:CloseButton(parent, onClick)
  if self:Theme() ~= "arl" then
    local b = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
    b:SetPoint("TOPRIGHT", -4, -4)
    self:Close(b)
    if onClick then
      b:SetScript("OnClick", onClick)
    end
    return b
  end
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(20, 20)
  b:SetPoint("TOPRIGHT", -5, -5)
  Flat(b, ARL.surface)
  Hover(b)
  local lines = {}
  for i, angle in ipairs({ 45, -45 }) do
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetTexture(WHITE)
    t:SetSize(11, 1.5)
    t:SetPoint("CENTER")
    t:SetRotation(math.rad(angle))
    t:SetVertexColor(0.75, 0.75, 0.75)
    lines[i] = t
  end
  local function Tint(r, g, bl)
    for _, t in ipairs(lines) do
      t:SetVertexColor(r, g, bl)
    end
  end
  b:SetScript("OnEnter", function()
    Tint(ArlAccent())
  end)
  b:SetScript("OnLeave", function()
    Tint(0.75, 0.75, 0.75)
  end)
  b:SetScript("OnClick", onClick or function()
    parent:Hide()
  end)
  return b
end

function Skin:Close(button)
  local theme = self:Theme()
  if theme == "ellesmere" then
    Try(euiS.CloseButton, button)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleCloseButton, S, button)
  end
end

function Skin:EditBox(box)
  local theme = self:Theme()
  if theme == "arl" then
    Try(function()
      StripArt(box)
      Flat(box, ARL.field)
      if box.SetTextInsets then
        box:SetTextInsets(6, 6, 0, 0)
      end
      -- Its border takes the accent while typing.
      box:HookScript("OnEditFocusGained", function(self)
        local r, g, b = ArlAccent()
        SetEdges(self, r, g, b, 0.9)
      end)
      box:HookScript("OnEditFocusLost", function(self)
        SetEdges(self, ARL.border[1], ARL.border[2], ARL.border[3], 1)
      end)
      if GameFontHighlightSmall then
        box:SetFontObject(GameFontHighlightSmall)
      end
    end)
  elseif theme == "ellesmere" then
    Try(euiS.EditBox, box)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleEditBox, S, box)
  end
end

-- ARL: a slim scroll bar: no arrows or track art, a thin grey thumb.
local function SlimBar(bar)
  local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
  StripArt(bar, thumb)
  for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
    local name = bar.GetName and bar:GetName()
    local b = bar[key] or (name and _G[name .. key])
    if b then
      b:SetAlpha(0)
      b:EnableMouse(false)
    end
  end
  if thumb then
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(1, 1, 1, 0.25)
    thumb:SetWidth(4)
  end
end

function Skin:ScrollBar(scrollFrame)
  local bar = scrollFrame.ScrollBar or (scrollFrame.GetName and scrollFrame:GetName() and _G[scrollFrame:GetName() .. "ScrollBar"])
  if not bar then
    return
  end
  local theme = self:Theme()
  if theme == "arl" then
    Try(SlimBar, bar)
  elseif theme == "ellesmere" then
    Try(euiS.ScrollBar, bar)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleScrollBar, S, bar)
  end
end

function Skin:Dropdown(dropdown)
  local theme = self:Theme()
  if theme == "arl" then
    -- ARL dropdowns are flat buttons (UI.lua); their face is a field.
    if dropdown.arlBg then
      dropdown.arlBg:SetColorTexture(ARL.field[1], ARL.field[2], ARL.field[3], 1)
    end
  elseif theme == "ellesmere" then
    Try(euiS.Dropdown, dropdown)
  elseif theme == "elvui" then
    local _, S = ElvUISkins()
    Try(S.HandleDropDownBox, S, dropdown)
  end
end

-- The UI addon's font file (EllesmereUI's, else ElvUI's), or nil.
local function UIFontPath()
  if EllesmereUI and EllesmereUI.GetFontPath then
    local ok, path = pcall(EllesmereUI.GetFontPath)
    if ok and path then
      return path
    end
  end
  local E = ElvUISkins()
  return E and E.media and E.media.normFont
end

-- Re-fonts a FontString to the theme's UI font. ARL: the UI addon's font if
-- one is loaded, one point smaller than the game's (the rows are compact).
function Skin:Font(fs)
  local theme = self:Theme()
  if theme == "arl" then
    Try(function()
      if fs.arlFont then
        return
      end
      fs.arlFont = true
      local path, size, flags = fs:GetFont()
      if size then
        fs:SetFont(UIFontPath() or path, size - 1, flags or "")
      end
    end)
  elseif theme == "ellesmere" then
    Try(euiS.Font, fs)
  elseif theme == "elvui" then
    local E = ElvUISkins()
    Try(function()
      local _, size = fs:GetFont()
      fs:SetFont(E.media.normFont, size, "")
    end)
  end
end

-- Accent color for group headers and the selected row.
function Skin:Accent()
  local theme = self:Theme()
  if theme == "arl" then
    return ArlAccent()
  elseif theme == "ellesmere" then
    local ok, r, g, b = pcall(euiS.GetAccentColor)
    if ok and r then
      return r, g, b
    end
  elseif theme == "elvui" then
    local E = ElvUISkins()
    local c = E and E.media and E.media.rgbvaluecolor
    if c then
      return c.r or c[1], c.g or c[2], c.b or c[3]
    end
  end
  return 1, 0.82, 0
end

-- Text colour of a label that isn't selected: ARL's grey, else white.
function Skin:Dim()
  if self:Theme() == "arl" then
    return ARL.dim[1], ARL.dim[2], ARL.dim[3]
  end
  return 1, 1, 1
end
