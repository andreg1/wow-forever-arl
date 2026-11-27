-- Layer Bridge: the box (layer, status, Host, Swap), its minimized pill and
-- its three drawers (Network, History, Options). Built from Kit.Card so it
-- follows the ARL theme; laid out like Layer Anarchy's box for usability:
-- one big Swap button that turns into Stop / Ask more / Leave, a Host
-- toggle beside it, a coloured edge for the state, the drawers' icons on top.
-- The box holds no secure button (the Swap key binding is the host's own
-- button), so it can be moved, shown and hidden in combat.
local _, ns = ...
local LB = ns.LayerBridge
if not LB then
  return
end
local ARLE = _G.ARLExtensions
local F = LB.F
local Kit = ARLE.UI.Kit
local Skin = ARLE.Skin

local W, HUD_W, GLYPH, GLYPH_GAP, BTN_H, HOST_W = 252, 150, 16, 3, 22, 84
local ROW_H, COL_W, PILL_W = 15, 40, 34
local DEFAULT_Y = -200
local ICON = {
  layer = "Interface\\Icons\\Spell_Arcane_Blink",
  network = "Interface\\Icons\\INV_Misc_Spyglass_02",
  history = "Interface\\Icons\\INV_Misc_PocketWatch_01",
  options = "Interface\\Icons\\INV_Misc_Gear_01",
  -- (themed text buttons: Blizzard's plus / minus / stop art looked out of
  -- place in the ARL, EllesmereUI and ElvUI themes)
  minimize = "text:-",
  expand = "text:+",
  close = "text:x",
}
-- status text colours, and the edge colour per state
local TONE = {
  idle = { 0.73, 0.73, 0.71 }, swap = { 0.37, 0.85, 0.54 }, fail = { 0.94, 0.65, 0.29 },
  host = { 0.91, 0.80, 0.42 }, off = { 0.46, 0.47, 0.49 }, warn = { 0.94, 0.65, 0.29 },
}
local EDGE = { swap = { 0.25, 0.75, 0.42 }, fail = { 0.88, 0.57, 0.18 }, host = { 0.85, 0.72, 0.29 } }

local UI = {}
LB.UI = UI

local box, hud, open
local drawers = {}
local glyphs = {}

local function Scale()
  return math.max(0.5, (tonumber(F.db.scale) or 100) / 100)
end

local function Tip(frame, title, text)
  F:Script(frame, "OnEnter", function(self)
    Kit.SimpleTooltip(self, type(title) == "function" and title() or title,
      type(text) == "function" and text() or text)
  end)
  F:Script(frame, "OnLeave", GameTooltip_Hide)
end

local function Glyph(parent, file, title, text, onClick)
  local label = file:match("^text:(.+)$")
  if label then
    -- The theme's own small button, like every other ARL window's.
    local tb = Kit.SmallButton(parent, label, GLYPH + 2)
    tb:SetHeight(GLYPH)
    F:Script(tb, "OnClick", onClick)
    Tip(tb, title, text)
    return tb
  end
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(GLYPH, GLYPH)
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetAllPoints()
  b.tex:SetTexture(file)
  if file:find("Icons") then
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.2)
  F:Script(b, "OnClick", onClick)
  Tip(b, title, text)
  return b
end

local function SetDrag(f)
  if F.db.locked then
    f:RegisterForDrag()
  else
    f:RegisterForDrag("LeftButton")
  end
end

-------------------------------------------------------------------------------
-- Drawers
-------------------------------------------------------------------------------

local function PlaceDrawer(d)
  local anchor = box:IsShown() and box or hud
  d:SetScale(Scale())
  d:ClearAllPoints()
  local bottom = anchor:GetBottom() or 0
  if bottom * anchor:GetEffectiveScale() - d:GetHeight() * d:GetEffectiveScale() > 0 then
    d:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  else
    d:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
  end
end

local function CloseDrawer()
  if open then
    open:Hide()
    open = nil
  end
end

local function ToggleDrawer(key)
  local d = drawers[key]
  if open == d then
    return CloseDrawer()
  end
  CloseDrawer()
  open = d
  d.sync()
  d:Show()
  PlaceDrawer(d)
end
UI.ToggleDrawer = ToggleDrawer

-- A Kit.Card with a title, a close glyph and a body frame below the title.
local function Drawer(key, title)
  local C = Kit.CARD
  local d = Kit.Card(F, { width = W })
  d:SetFrameStrata("MEDIUM")
  d:EnableMouse(true)
  d:SetLines(title)
  d.close = Glyph(d, ICON.close, "Close", nil, CloseDrawer)
  d.close:SetPoint("TOPRIGHT", -C.pad, -C.pad + 1)
  d.text:SetPoint("RIGHT", d.close, "LEFT", -4, 0)
  d.body = CreateFrame("Frame", nil, d)
  d.body:SetPoint("TOPLEFT", d.text, "BOTTOMLEFT", 0, -6)
  d.body:SetPoint("RIGHT", -C.pad, 0)
  d.body:SetHeight(1)
  function d.SetBody(h)
    d.body:SetHeight(math.max(1, h))
    d.extra = h + 6
    d:Fit()
  end
  drawers[key] = d
  return d
end

local function Cell(parent, template, justify)
  local fs = Kit.Text(parent, template or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "RIGHT")
  fs:SetWordWrap(false)
  return fs
end

local function DrawCell(fs, n, text, color)
  fs:SetText(n and (text or tostring(n)) or "-")
  if not n or n == 0 then
    fs:SetTextColor(0.45, 0.45, 0.47)
  elseif color then
    fs:SetTextColor(color[1], color[2], color[3])
  else
    fs:SetTextColor(0.9, 0.9, 0.9)
  end
end

-- A row of right-aligned columns; returns the cells (first = leftmost).
local function Columns(row, n, template, rightInset)
  local cells = {}
  for j = 1, n do
    local fs = Cell(row, template)
    fs:SetWidth(COL_W)
    fs:SetPoint("RIGHT", -(rightInset or 0) - (n - j) * COL_W, 0)
    cells[j] = fs
  end
  return cells
end

local function Row(body, y)
  local r = CreateFrame("Frame", nil, body)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 0, -y)
  r:SetPoint("TOPRIGHT", 0, -y)
  return r
end

local function Left(r, text, template)
  local fs = Cell(r, template or "GameFontNormalSmall", "LEFT")
  fs:SetPoint("LEFT", 0, 0)
  fs:SetText(text)
  return fs
end

local function Header(body, y, names, title, inset)
  local r = Row(body, y)
  if title then
    Left(r, title, "GameFontDisableSmall")
  end
  for j, fs in ipairs(Columns(r, #names, "GameFontDisableSmall", inset)) do
    fs:SetText(names[j])
  end
  return y + ROW_H
end

local function Section(body, y, title)
  local r = Row(body, y + 4)
  local fs = Left(r, title, "GameFontNormalSmall")
  local ar, ag, ab = Skin:Accent()
  fs:SetTextColor(ar, ag, ab)
  return y + ROW_H + 4
end

local netRows, grid = {}, {}

local function BuildNetwork()
  local d = Drawer("network", "Networks")
  local seg = CreateFrame("Frame", nil, d)
  seg:SetSize(90, 16)
  seg:SetPoint("RIGHT", d.close, "LEFT", -6, 0)
  d.seg = Kit.FilterButtons(seg, {
    { key = "hour", label = "1h", width = 30, tip = "The last hour" },
    { key = "session", label = "Session", width = 56, tip = "Since you logged in" },
  }, function()
    return F.char.statsWindow == "session" and "session" or "hour"
  end, function(key)
    F.char.statsWindow = key
    d.sync()
  end)
  d.text:SetPoint("RIGHT", seg, "LEFT", -4, 0)
  local body = d.body
  local y = Header(body, 0, { "Seen", "Talking", "Hosts" }, "Network", PILL_W + 4)
  for _, net in ipairs(LB.nets) do
    local r = Row(body, y)
    r:SetHeight(ROW_H + 2)
    r.net = net
    r.name = Left(r, net.name, "GameFontHighlightSmall")
    r.pill = Kit.SmallButton(r, "On", PILL_W)
    r.pill:SetHeight(ROW_H)
    r.pill:SetPoint("RIGHT", 0, 0)
    F:Script(r.pill, "OnClick", function()
      ARLE:SetOption(F.id, net.key, F.db[net.key] == false)
      d.sync()
    end)
    Tip(r.pill, net.name, function()
      local native = LB.Native(net)
      if native then
        return (net.desc or "") .. "\n\n" .. native .. " is loaded: its users are answered by it, not by ARL."
      end
      return (net.desc or "") .. "\n\nClick to turn it " .. (F.db[net.key] == false and "on." or "off.")
    end)
    r.cells = Columns(r, 3, "GameFontHighlightSmall", PILL_W + 4)
    netRows[#netRows + 1] = r
    y = y + ROW_H + 2
  end
  y = Section(body, y, "Your swaps")
  y = Header(body, y, { "Count", "Avg", "Best", "Hour" })
  local r = Row(body, y)
  Left(r, "Swaps", "GameFontHighlightSmall")
  grid.swaps = Columns(r, 4)
  y = y + ROW_H
  y = Header(body, y, { "Taken", "Same", "Late" }, nil, COL_W)
  r = Row(body, y)
  Left(r, "Invites", "GameFontHighlightSmall")
  Tip(r, "Invites", "Taken: invites accepted. Same: declined, the host was on your layer. Late: declined, they "
    .. "came after the swap ended.")
  r:EnableMouse(true)
  grid.invites = Columns(r, 3, nil, COL_W)
  y = y + ROW_H
  y = Section(body, y, "Hosting")
  y = Header(body, y, { "Asked", "Invited", "Moved", "Failed" })
  r = Row(body, y)
  Left(r, "Ground", "GameFontHighlightSmall")
  grid.ground = Columns(r, 4)
  y = y + ROW_H
  r = Row(body, y)
  Left(r, "Flying", "GameFontHighlightSmall")
  grid.flying = Columns(r, 4)
  y = y + ROW_H
  d.SetBody(y)
  d.sync = function()
    d.seg.Paint()
    for _, row in ipairs(netRows) do
      local net = row.net
      local native = LB.Native(net)
      local on = F.db[net.key] ~= false and not native
      local seen, talking, hosts = LB.Stats.Net(net)
      DrawCell(row.cells[1], seen)
      DrawCell(row.cells[2], talking)
      DrawCell(row.cells[3], hosts, nil, TONE.host)
      row.pill:SetText(native and "Own" or (on and "On" or "Off"))
      row.pill:SetEnabled(not native)
      if on then
        row.name:SetTextColor(0.9, 0.9, 0.9)
      else
        row.name:SetTextColor(0.5, 0.5, 0.52)
      end
    end
    local v = LB.Stats.View()
    DrawCell(grid.swaps[1], v.swaps)
    DrawCell(grid.swaps[2], v.avg, v.avg and string.format("%.1fs", v.avg))
    DrawCell(grid.swaps[3], v.best, v.best and string.format("%.1fs", v.best), TONE.host)
    DrawCell(grid.swaps[4], v.thisHour, v.thisHour .. "/" .. v.limit)
    DrawCell(grid.invites[1], v.taken)
    DrawCell(grid.invites[2], v.same)
    DrawCell(grid.invites[3], v.late)
    for _, k in ipairs({ "ground", "flying" }) do
      local h, cells = v[k], grid[k]
      DrawCell(cells[1], h.asked)
      DrawCell(cells[2], h.invited)
      DrawCell(cells[3], h.moved, nil, TONE.swap)
      DrawCell(cells[4], h.failed)
    end
  end
end

local histRows = {}

local function BuildHistory()
  local d = Drawer("history", "Layers you've been on")
  d.clear = Kit.SmallButton(d, "Clear", 48)
  d.clear:SetPoint("RIGHT", d.close, "LEFT", -6, 0)
  d.text:SetPoint("RIGHT", d.clear, "LEFT", -4, 0)
  F:Script(d.clear, "OnClick", function(self)
    if self.armedAt and GetTime() - self.armedAt < 4 then
      self.armedAt = nil
      LB.History.Clear()
      d.sync()
      return
    end
    self.armedAt = GetTime()
    self:SetText("Sure?")
    F:After(4, function()
      if not self.armedAt or GetTime() - self.armedAt >= 4 then
        self.armedAt = nil
        self:SetText("Clear")
      end
    end)
  end)
  Tip(d.clear, "Clear", "Forget these layers (click twice).")
  d.empty = Kit.Text(d.body, "GameFontDisableSmall")
  d.empty:SetPoint("TOPLEFT", 0, 0)
  d.empty:SetPoint("RIGHT", 0, 0)
  d.empty:SetWordWrap(true)
  d.sync = function()
    local list = LB.History.List()
    local epoch = LB.Epoch()
    local y = 0
    for i, e in ipairs(list) do
      local r = histRows[i]
      if not r then
        r = Kit.SmallButton(d.body, "", W - 2 * Kit.CARD.pad - Kit.CARD.edge)
        r:SetHeight(18)
        local fs = r:GetFontString()
        if fs then
          fs:SetJustifyH("LEFT")
          fs:ClearAllPoints()
          fs:SetPoint("LEFT", 6, 0)
          fs:SetPoint("RIGHT", -6, 0)
        end
        F:Script(r, "OnClick", function(self)
          local entry = self.entry
          if entry and entry.id and entry.epoch ~= LB.Epoch() then
            LB.Swap.Click("history", { id = entry.id, host = entry.host })
            CloseDrawer()
          end
        end)
        Tip(r, function()
          local entry = r.entry
          return entry and LB.Label(entry.epoch) or ""
        end, function()
          local entry = r.entry
          if not entry then
            return nil
          end
          if entry.epoch == LB.Epoch() then
            return "You're on this layer."
          end
          if not entry.id then
            return "ARL never learned this layer's id (you weren't moved here by a LayerSwap host), so it can't be "
              .. "asked for."
          end
          return "Click to ask LayerSwap hosts on this layer (id " .. entry.id .. ")"
            .. (entry.host and (", " .. entry.host .. " first") or "") .. "."
        end)
        histRows[i] = r
      end
      r.entry = e
      local here = e.epoch == epoch
      r:SetText(string.format("%s%s · %s%s · %s", here and "|cff5fd88a" or "", LB.Label(e.epoch),
        LB.ZoneName(e.zone) or "?", e.host and (" · " .. e.host) or "", here and "here|r" or LB.Ago(e.at)))
      r:SetEnabled(here or e.id ~= nil)
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, -y)
      r:Show()
      y = y + 20
    end
    for i = #list + 1, #histRows do
      histRows[i]:Hide()
    end
    if #list == 0 then
      d.empty:SetText("Nothing yet: layers show up here as you move between them.")
      d.empty:Show()
      y = d.empty:GetStringHeight()
    else
      d.empty:Hide()
    end
    d.SetBody(y)
    if open == d then
      PlaceDrawer(d)
    end
  end
end

local checks = {}
local OPTIONS = {
  { "host", "Host for others" },
  { "hostWhileFlying", "Host while flying" },
  { "auto", "Accept and leave automatically" },
  { "askAutoLayer", "Ask AutoLayer hosts too" },
  { "avoidVisited", "Don't go back to visited layers" },
  { "sound", "Sound when moved" },
  { "forceTriple", "Triple-click: swap anyway on cooldown" },
  { "locked", "Lock position" },
}

local function Option(key)
  for _, o in ipairs(F.options) do
    if type(o) == "table" and o.key == key then
      return o
    end
  end
end

local function Stepper(body, y, key, label, fmt)
  local o = Option(key) or {}
  local r = Row(body, y)
  r:SetHeight(20)
  Left(r, label, "GameFontHighlightSmall")
  local plus = Kit.SmallButton(r, "+", 20)
  plus:SetPoint("RIGHT", 0, 0)
  local value = Cell(r, "GameFontHighlightSmall", "CENTER")
  value:SetWidth(56)
  value:SetPoint("RIGHT", plus, "LEFT", -2, 0)
  local minus = Kit.SmallButton(r, "-", 20)
  minus:SetPoint("RIGHT", value, "LEFT", -2, 0)
  local function Step(dir)
    local v = (tonumber(F.db[key]) or o.default or 0) + dir * (o.step or 1)
    v = math.max(o.min or v, math.min(o.max or v, v))
    ARLE:SetOption(F.id, key, v)
  end
  F:Script(plus, "OnClick", function()
    Step(1)
  end)
  F:Script(minus, "OnClick", function()
    Step(-1)
  end)
  if o.desc then
    r:EnableMouse(true)
    Tip(r, label, o.desc)
  end
  checks[#checks + 1] = { sync = function()
    value:SetText(fmt(tonumber(F.db[key]) or o.default or 0))
  end }
  return y + 22
end

local function BuildOptions()
  local d = Drawer("options", "Options")
  local body, y = d.body, 0
  for _, o in ipairs(OPTIONS) do
    local key, label = o[1], o[2]
    local r = CreateFrame("Button", nil, body)
    r:SetHeight(20)
    r:SetPoint("TOPLEFT", 0, -y)
    r:SetPoint("TOPRIGHT", 0, -y)
    local c = Kit.Check(r)
    c:SetSize(20, 20)
    c:SetPoint("LEFT", -2, 0)
    local fs = Kit.Text(r, "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
    fs:SetText(label)
    local function Flip()
      ARLE:SetOption(F.id, key, not F.db[key])
    end
    F:Script(c, "OnClick", Flip)
    F:Script(r, "OnClick", Flip)
    local desc = (Option(key) or {}).desc
    if desc then
      Tip(r, label, desc)
    end
    checks[#checks + 1] = { sync = function()
      c:SetChecked(F.db[key] and true or false)
    end }
    y = y + 21
  end
  y = Stepper(body, y + 2, "invitesPerHour", "Invites per hour", function(v)
    return v == 0 and "No limit" or tostring(v)
  end)
  y = Stepper(body, y, "scale", "Size", function(v)
    return v .. "%"
  end)
  local all = Kit.SmallButton(body, "All settings", 96)
  all:SetPoint("TOPLEFT", 0, -(y + 4))
  F:Script(all, "OnClick", function()
    CloseDrawer()
    ARLE:Open(F.id)
  end)
  d.SetBody(y + 24)
  d.sync = function()
    for _, c in ipairs(checks) do
      c.sync()
    end
  end
end

-------------------------------------------------------------------------------
-- The box and the minimized pill
-------------------------------------------------------------------------------

local function PlaceAll()
  if open then
    PlaceDrawer(open)
  end
end

-- Quick clicks in a row on Swap or the pill: the third one while the swap
-- limit's wait runs asks anyway (forceTriple). Returns true when it forced.
local TRIPLE_GAP = 0.5 -- s between two clicks of one triple-click
local clicks = { n = 0, at = 0 }

local function SwapClick()
  local now = GetTime()
  clicks.n = (now - clicks.at <= TRIPLE_GAP) and clicks.n + 1 or 1
  clicks.at = now
  if clicks.n >= 3 and F.db.forceTriple ~= false and LB.Limit.Left() and not LB.Swap.Busy() then
    clicks.n = 0
    LB.Swap.Click("button", nil, true)
    return
  end
  LB.Swap.Click("button")
end

local function SwapTip()
  local lines = {}
  local key = ARLE.Secure:BoundKey("LayerSwap")
  lines[#lines + 1] = "Asks every network that's on at once; the first host on another layer to invite moves you."
  lines[#lines + 1] = "While asking, click again to ask more players (when there are more) or to stop."
  lines[#lines + 1] = "\nNetworks: " .. LB.Swap.NetList()
  local n, limit = LB.Limit.ThisHour()
  lines[#lines + 1] = string.format("Swaps this hour: %d of %d", n, limit)
  if LB.Limit.Left() and F.db.forceTriple ~= false then
    lines[#lines + 1] = "On cooldown: triple-click to try anyway."
  end
  lines[#lines + 1] = key and ("Key: " .. key) or "Bind a key: Key Bindings > ARL Extensions > Layer Bridge: swap layer"
  return table.concat(lines, "\n")
end

local function BuildBox()
  local C = Kit.CARD
  box = Kit.Card(F, { width = W, icon = true, titleFont = "GameFontNormalLarge",
    move = { y = DEFAULT_Y, onMoved = PlaceAll } })
  box.icon:SetTexture(ICON.layer)
  -- the drawers' icons, top right
  local x = -C.pad
  local list = {
    { "minimize", ICON.minimize, "Minimize", "Shrink to a small pill (click it to come back).", function()
      ARLE:SetOption(F.id, "minimized", true)
    end },
    { "options", ICON.options, "Options", nil, function() ToggleDrawer("options") end },
    { "history", ICON.history, "History", "The layers you've been on in the last 6 hours; click one to go back.",
      function() ToggleDrawer("history") end },
    { "network", ICON.network, "Networks", "Who's on each network, your swaps and your hosting.",
      function() ToggleDrawer("network") end },
  }
  for _, g in ipairs(list) do
    local b = Glyph(box, g[2], g[3], g[4], g[5])
    b:SetPoint("TOPRIGHT", x, -C.pad + 1)
    x = x - GLYPH - GLYPH_GAP
    glyphs[#glyphs + 1] = b
  end
  box.text:SetPoint("RIGHT", glyphs[#glyphs], "LEFT", -4, 0)
  box.text:SetWordWrap(false)
  box.sub:SetWordWrap(false)
  box.sub:SetPoint("RIGHT", -C.pad, 0)

  box.hostBtn = Kit.Button(box, "Host: Off", HOST_W)
  box.hostBtn:SetHeight(BTN_H)
  box.hostBtn:SetPoint("BOTTOMLEFT", C.pad + C.edge, C.pad)
  F:Script(box.hostBtn, "OnClick", function()
    ARLE:SetOption(F.id, "host", not F.db.host)
  end)
  Tip(box.hostBtn, "Host for others", function()
    local why = LB.Host.Blocked()
    return "Invite players of every network who ask for another layer. Only while you're solo or leading a group "
      .. "of your guests; you leave it 30 s after they've all moved."
      .. (F.db.host and why and why ~= "off" and ("\n\nPaused now: " .. why) or "")
  end)

  box.swapBtn = Kit.Button(box, "Swap", 100)
  box.swapBtn:SetHeight(BTN_H)
  box.swapBtn:SetPoint("BOTTOMLEFT", box.hostBtn, "BOTTOMRIGHT", 4, 0)
  box.swapBtn:SetPoint("RIGHT", -C.pad, 0)
  F:Script(box.swapBtn, "OnClick", SwapClick)
  Tip(box.swapBtn, "Swap layer", SwapTip)

  box.noticeBtn = Kit.Button(box, "", 100)
  box.noticeBtn:SetHeight(BTN_H)
  box.noticeBtn:SetPoint("BOTTOMLEFT", box.hostBtn, "TOPLEFT", 0, 4)
  box.noticeBtn:SetPoint("RIGHT", -C.pad, 0)
  box.noticeBtn:Hide()
  F:Script(box.noticeBtn, "OnClick", function(self)
    if self.onClick then
      self.onClick()
    end
  end)
  box.extra = 6 + BTN_H
end

local function BuildHud()
  local C = Kit.CARD
  hud = Kit.Card(F, { width = HUD_W, icon = true, move = { y = DEFAULT_Y, onMoved = PlaceAll } })
  hud.icon:SetTexture(ICON.layer)
  hud.icon:SetSize(24, 24)
  hud.expand = Glyph(hud, ICON.expand, "Expand", "Show the whole box.", function()
    ARLE:SetOption(F.id, "minimized", false)
  end)
  hud.expand:SetPoint("TOPRIGHT", -C.pad, -C.pad + 1)
  hud.text:SetPoint("RIGHT", hud.expand, "LEFT", -2, 0)
  hud.text:SetWordWrap(false)
  hud.sub:SetWordWrap(false)
  -- A click that isn't a drag swaps (like the big button).
  F:Script(hud, "OnMouseDown", function(self)
    self.downAt = { self:GetCenter() }
  end)
  F:Script(hud, "OnMouseUp", function(self, button)
    local x, y = self:GetCenter()
    local d = self.downAt
    self.downAt = nil
    if button == "LeftButton" and d and d[1] == x and d[2] == y and self:IsMouseOver() then
      SwapClick()
    end
  end)
  Tip(hud, "Layer Bridge", function()
    return "Click: " .. (LB.Swap.Busy() and "stop / ask more" or "swap layer") .. ". Drag to move. + shows the box."
      .. ((LB.Limit.Left() and F.db.forceTriple ~= false and not LB.Swap.Busy())
        and "\nOn cooldown: triple-click to try anyway." or "")
  end)
end

local function Paint(card, v)
  local edge = EDGE[v.border]
  if edge then
    card:SetAccent(edge[1], edge[2], edge[3])
  else
    card:SetAccent()
  end
  local tone = TONE[v.tone] or TONE.idle
  local note = v.notice and v.notice.text ~= "" and v.notice.text or nil
  card:SetLines(v.label, v.status or "", card == box and note or nil)
  local ar, ag, ab = Skin:Accent()
  card.text:SetTextColor(ar, ag, ab)
  card.sub:SetTextColor(tone[1], tone[2], tone[3])
  if card.icon then
    card.icon:SetDesaturated(v.tone == "off")
  end
end

local function DrawBox(v)
  local btn = v.notice and v.notice.button
  box.noticeBtn.onClick = btn and btn.onClick or nil
  box.noticeBtn:SetText(btn and btn.text or "")
  box.noticeBtn:SetShown(btn ~= nil)
  box.extra = 6 + BTN_H + (btn and BTN_H + 4 or 0)
  Paint(box, v)
  box.hostBtn:SetText(v.host and "Host: On" or "Host: Off")
  local hfs = box.hostBtn:GetFontString()
  if hfs then
    if v.host then
      hfs:SetTextColor(TONE.host[1], TONE.host[2], TONE.host[3])
    else
      hfs:SetTextColor(0.8, 0.8, 0.8)
    end
  end
  box.swapBtn:SetText(v.swapText or "Swap")
  box.swapBtn:SetEnabled(v.swapEnabled ~= false)
end

function UI.Refresh()
  if not box then
    return
  end
  local s = Scale()
  for _, f in ipairs({ box, hud }) do
    if f:GetScale() ~= s then
      f:SetScale(s)
      f.place()
    end
    SetDrag(f)
  end
  if not F._active or F.db.button == false or LB.InInstance() then
    box:Hide()
    hud:Hide()
    CloseDrawer()
    return
  end
  local v = LB.View()
  if F.db.minimized then
    box:Hide()
    Paint(hud, v)
    hud:Show()
  else
    hud:Hide()
    DrawBox(v)
    box:Show()
  end
  if open then
    open.sync()
    PlaceDrawer(open)
  end
end

-- Fades the drawers' icons in while the mouse is on the box.
function UI.Hover()
  if not box or not box:IsShown() then
    return
  end
  local hot = box:IsMouseOver() or open ~= nil
  for _, g in ipairs(glyphs) do
    g:SetAlpha(hot and 1 or 0.35)
  end
end

function UI.Init()
  if not box then
    BuildBox()
    BuildHud()
    BuildNetwork()
    BuildHistory()
    BuildOptions()
  end
  box.place()
  hud.place()
  UI.Refresh()
end

function UI.Placed()
  if box then
    box.place()
    hud.place()
    PlaceAll()
  end
end

function UI.Hide()
  if box then
    box:Hide()
    hud:Hide()
  end
  CloseDrawer()
end

function UI.Shown()
  return box ~= nil and (box:IsShown() or hud:IsShown()), box
end
