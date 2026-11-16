-- The /arl window: an extension manager. Left, every feature grouped by
-- the addon it extends (a search box filters them); right, the selected
-- feature's status, notes and settings. Option types are listed in
-- Core/Options.lua; every widget comes from ARLE.UI.Kit, so the panel follows
-- the theme.
local _, ns = ...
local ARLE = ns.ARLE
local Skin = ARLE.Skin
local Kit = ARLE.UI.Kit
local L = ARLE.Lib

local WIDTH, HEIGHT = 680, 470
local LIST_W = 240
local DETAILS_W = WIDTH - LIST_W - 60 -- scroll child width until laid out
local PANE_H = 260                     -- custom panes (Officer Tools)
local GROUP_H, ROW_H, CHILD_H = 24, 26, 22

local STATE_COLOR = {
  active = { 0.45, 0.9, 0.5 },
  off = { 0.6, 0.6, 0.6 },
  missing = { 1, 0.45, 0.45 },
  waiting = { 1, 0.75, 0.3 },
  conflict = { 1, 0.6, 0.2 },
  error = { 1, 0.3, 0.3 },
  pending = { 1, 0.75, 0.3 },
  locked = { 0.85, 0.3, 0.3 },
}
local FIELD_H, ITEM_H = 30, 18

local main, list, listChild, details, emptyText, lock
local groupHeaders, moduleRows, fields = {}, {}, {}
local selected
local selectedPage -- a settings page of the selected module (child row), or nil
local childRows = {}
local panes = {} -- module def -> its custom pane frame
local Dropdown -- defined with the details pane
local search -- the list's search box
local capture -- key capture frame for keybind options

local function StateColor(state)
  local c = STATE_COLOR[state] or STATE_COLOR.off
  return c[1], c[2], c[3]
end

local Text, Check, Button = Kit.Text, Kit.Check, Kit.Button

local WARN_ICON = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
local NOTICE_H = 44

-- A small warning icon with a tooltip (a setting, row or page that needs an
-- outside addon). icon:Set(title, text) shows it; icon:Set() hides it.
local function WarnIcon(parent, size)
  local w = CreateFrame("Frame", nil, parent)
  w:SetSize(size or 14, size or 14)
  w.tex = w:CreateTexture(nil, "OVERLAY")
  w.tex:SetAllPoints()
  w.tex:SetTexture(WARN_ICON)
  w:EnableMouse(true)
  w:SetScript("OnEnter", function(self)
    if self.tipTitle then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.tipTitle, 1, 0.82, 0)
      if self.tipText then
        GameTooltip:AddLine(self.tipText, 1, 1, 1, true)
      end
      GameTooltip:Show()
    end
  end)
  w:SetScript("OnLeave", GameTooltip_Hide)
  function w:Set(title, text)
    self.tipTitle, self.tipText = title, text
    self:SetShown(title ~= nil)
  end
  w:Hide()
  return w
end

local function NeedsText(title, why)
  return "Needs " .. title, title .. " is " .. why .. "."
end

-------------------------------------------------------------------------------
-- List pane
-------------------------------------------------------------------------------

local function GroupHeader(index)
  local h = groupHeaders[index]
  if h then
    return h
  end
  h = CreateFrame("Frame", nil, listChild)
  h:SetHeight(GROUP_H)
  h.label = Text(h, "GameFontNormal")
  h.label:SetPoint("BOTTOMLEFT", 6, 4)
  h.note = Text(h, "GameFontDisableSmall")
  h.note:SetPoint("LEFT", h.label, "RIGHT", 6, 0)
  h.line = h:CreateTexture(nil, "ARTWORK")
  h.line:SetHeight(1)
  h.line:SetPoint("BOTTOMLEFT", 4, 0)
  h.line:SetPoint("BOTTOMRIGHT", -4, 0)
  groupHeaders[index] = h
  return h
end

local function ModuleRow(index)
  local row = moduleRows[index]
  if row then
    return row
  end
  row = CreateFrame("Button", nil, listChild)
  row:SetHeight(ROW_H)

  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  row.hl:SetColorTexture(1, 1, 1, 0.06)
  row.hl:Hide()
  row.selBar = row:CreateTexture(nil, "BACKGROUND", nil, 2)
  row.selBar:SetPoint("TOPLEFT")
  row.selBar:SetPoint("BOTTOMLEFT")
  row.selBar:SetWidth(2)
  row.selBar:Hide()
  row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  row.sel:SetAllPoints()
  row.sel:Hide()

  row.check = Check(row, "ARLEListCheck" .. index)
  row.check:SetPoint("LEFT", 8, 0)
  row.check:SetScript("OnClick", function(self)
    ARLE:SetModuleEnabled(self:GetParent().moduleId, self:GetChecked() and true or false)
  end)

  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(6, 6)
  row.dot:SetPoint("RIGHT", -8, 0)
  row.dot:SetColorTexture(1, 1, 1, 1)

  row.warn = WarnIcon(row, 14)
  row.warn:SetPoint("RIGHT", -4, 0)

  row.title = Text(row, "GameFontHighlight")
  row.title:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
  row.title:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
  row.title:SetWordWrap(false)

  row:SetScript("OnEnter", function(self)
    self.hl:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self.hl:Hide()
  end)
  row:SetScript("OnClick", function(self)
    selected, selectedPage = self.moduleId, nil
    ARLE:RefreshUI()
  end)
  moduleRows[index] = row
  return row
end

-- Modules can split their settings into pages (def.pages): each page is a
-- child row under the module, shown while the module is selected.
local function ChildRow(index)
  local row = childRows[index]
  if row then
    return row
  end
  row = CreateFrame("Button", nil, listChild)
  row:SetHeight(CHILD_H)
  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  row.hl:SetColorTexture(1, 1, 1, 0.06)
  row.hl:Hide()
  row.selBar = row:CreateTexture(nil, "BACKGROUND", nil, 2)
  row.selBar:SetPoint("TOPLEFT")
  row.selBar:SetPoint("BOTTOMLEFT")
  row.selBar:SetWidth(2)
  row.selBar:Hide()
  row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  row.sel:SetAllPoints()
  row.sel:Hide()
  row.branch = row:CreateTexture(nil, "ARTWORK") -- the tree line
  row.branch:SetWidth(1)
  row.branch:SetPoint("TOPLEFT", 20, 0)
  row.branch:SetPoint("BOTTOMLEFT", 20, 0)
  row.tick = row:CreateTexture(nil, "ARTWORK")
  row.tick:SetSize(8, 1)
  row.tick:SetPoint("LEFT", 20, 0)
  row.title = Text(row, "GameFontHighlightSmall")
  row.title:SetPoint("LEFT", 34, 0)
  row.title:SetPoint("RIGHT", -22, 0)
  row.title:SetWordWrap(false)
  row.warn = WarnIcon(row, 12)
  row.warn:SetPoint("RIGHT", -6, 0)
  row:SetScript("OnEnter", function(self)
    self.hl:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self.hl:Hide()
  end)
  row:SetScript("OnClick", function(self)
    selected, selectedPage = self.owner, self.page
    ARLE:RefreshUI()
  end)
  childRows[index] = row
  return row
end

-- Does a feature match the search text: title, notes, command word, the
-- labels of its settings and of its pages.
local function Matches(info, q)
  if q == "" then
    return true
  end
  local function has(text)
    return text and L.Key(text):find(q, 1, true) ~= nil
  end
  if has(info.title) or has(info.notes) or has(info.command) or has(info.groupLabel) then
    return true
  end
  local def = ARLE.modules[info.id]
  for _, opt in ipairs(def and def.options or {}) do
    if has(opt.label) or has(opt.key) then
      return true
    end
  end
  for _, page in ipairs(def and def.pages or {}) do
    if has(page.label) then
      return true
    end
  end
  return false
end

local function RefreshList(groups)
  local q = L.Key(search and search:GetText() or "")
  if q ~= "" then
    local filtered = {}
    for _, group in ipairs(groups) do
      local mods = {}
      for _, info in ipairs(group.modules) do
        if Matches(info, q) then
          mods[#mods + 1] = info
        end
      end
      if #mods > 0 then
        local copy = {}
        for k, v in pairs(group) do
          copy[k] = v
        end
        copy.modules = mods
        filtered[#filtered + 1] = copy
      end
    end
    groups = filtered
  end
  local ar, ag, ab = Skin:Accent()
  local y, nh, nr, nc = 0, 0, 0, 0
  local arl = Skin:Theme() == "arl"
  for _, group in ipairs(groups) do
    nh = nh + 1
    local h = GroupHeader(nh)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 0, -y)
    h:SetPoint("RIGHT")
    h.label:SetText(group.label)
    h.label:SetTextColor(ar, ag, ab)
    h.line:SetColorTexture(ar, ag, ab, 0.35)
    if not group.installed then
      h.note:SetText("not installed")
    elseif not group.loaded then
      h.note:SetText("not loaded")
    else
      h.note:SetText("")
    end
    h:Show()
    y = y + GROUP_H + 2

    for _, info in ipairs(group.modules) do
      nr = nr + 1
      local row = ModuleRow(nr)
      row.moduleId = info.id
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 0, -y)
      row:SetPoint("RIGHT")
      row.check:SetShown(not info.builtin) -- Settings is always on
      row.title:SetText(info.title)
      -- A feature whose outside addon is missing can't be turned on: its
      -- switch is off and greyed, and a warning icon says why.
      local blocked = info.missing ~= nil
      row.check:SetChecked(info.enabled and not blocked)
      row.check:SetEnabled(not blocked)
      row.blocked = blocked
      if blocked then
        row.warn:Set(NeedsText(info.missing, info.missingWhy))
      else
        row.warn:Set()
      end
      row.dot:SetShown(not blocked)
      if info.enabled and not blocked then
        row.title:SetTextColor(1, 1, 1)
      else
        row.title:SetTextColor(0.55, 0.55, 0.55)
      end
      row.dot:SetVertexColor(StateColor(info.state))
      local isSel = info.id == selected and not selectedPage
      row.sel:SetColorTexture(ar, ag, ab, 0.18)
      row.sel:SetShown(isSel)
      if arl then
        -- ARL: a faint accent fill and a 2px accent bar; the selected title
        -- in the accent.
        row.sel:SetColorTexture(ar, ag, ab, 0.1)
        row.selBar:SetColorTexture(ar, ag, ab, 1)
        row.selBar:SetShown(isSel)
        if info.id == selected and info.enabled then
          row.title:SetTextColor(ar, ag, ab)
        end
      end
      row:Show()
      y = y + ROW_H

      local def = ARLE.modules[info.id]
      local pages = info.id == selected and def and def.pages or {}
      for i, page in ipairs(pages) do
        nc = nc + 1
        local child = ChildRow(nc)
        child.owner, child.page = info.id, page.key
        child:ClearAllPoints()
        child:SetPoint("TOPLEFT", 0, -y)
        child:SetPoint("RIGHT")
        child.title:SetText(page.label)
        local needs, why = ARLE:RequirementProblem(page.requires)
        if needs then
          child.warn:Set(NeedsText(needs, why))
        else
          child.warn:Set()
        end
        local on = selectedPage == page.key
        if not info.enabled then
          child.title:SetTextColor(0.55, 0.55, 0.55)
        elseif on and arl then
          child.title:SetTextColor(ar, ag, ab)
        else
          child.title:SetTextColor(0.85, 0.85, 0.85)
        end
        child.branch:SetColorTexture(1, 1, 1, 0.18)
        child.branch:ClearAllPoints()
        child.branch:SetPoint("TOPLEFT", 20, 0)
        child.branch:SetPoint(i == #pages and "LEFT" or "BOTTOMLEFT", 20, 0) -- the last one ends in an L
        child.tick:SetColorTexture(1, 1, 1, 0.18)
        child.sel:SetColorTexture(ar, ag, ab, arl and 0.1 or 0.18)
        child.sel:SetShown(on)
        child.selBar:SetColorTexture(ar, ag, ab, 1)
        child.selBar:SetShown(on and arl)
        child:Show()
        y = y + CHILD_H
      end
    end
    y = y + 6
  end
  for i = nh + 1, #groupHeaders do
    groupHeaders[i]:Hide()
  end
  for i = nr + 1, #moduleRows do
    moduleRows[i]:Hide()
  end
  for i = nc + 1, #childRows do
    childRows[i]:Hide()
  end
  listChild:SetWidth(math.max(list:GetWidth(), 10))
  listChild:SetHeight(math.max(y, 1))
  emptyText:SetText(q ~= "" and "Nothing matches the search." or "No features installed. Run ./bin/arle publish, then /reload.")
  emptyText:SetShown(nr == 0)
end

-------------------------------------------------------------------------------
-- Details pane
-------------------------------------------------------------------------------

local function Field(index)
  local f = fields[index]
  if f then
    return f
  end
  f = CreateFrame("Frame", nil, details.body)
  f:SetHeight(FIELD_H)

  f.check = Check(f, "ARLEFieldCheck" .. index)
  f.check:SetPoint("LEFT", -2, 0)
  f.check:SetScript("OnClick", function(self)
    ARLE:SetOption(selected, f.key, self:GetChecked() and true or false)
  end)

  f.label = Text(f, "GameFontHighlight")

  f.edit = CreateFrame("EditBox", "ARLEFieldEdit" .. index, f, "InputBoxTemplate")
  f.edit:SetSize(160, 22)
  f.edit:SetPoint("RIGHT", -6, 0)
  f.edit:SetAutoFocus(false)
  Skin:EditBox(f.edit)
  f.edit:SetScript("OnEnterPressed", f.edit.ClearFocus)
  f.edit:SetScript("OnEscapePressed", function(self)
    self.cancel = true
    self:ClearFocus()
  end)
  f.edit:SetScript("OnEditFocusLost", function(self)
    if self.cancel then
      self.cancel = nil
      ARLE:RefreshUI()
      return
    end
    local opt = f.opt
    local value = self:GetText() or ""
    if opt.type == "list" then
      value = L.Trim(value)
      self:SetText("")
      if value ~= "" then
        f.AddItem(value)
      end
      return
    end
    if opt.type == "number" or opt.type == "range" then
      value = tonumber(value)
      if not value then
        ARLE:RefreshUI()
        return
      end
      if opt.min then
        value = math.max(opt.min, value)
      end
      if opt.max then
        value = math.min(opt.max, value)
      end
    end
    ARLE:SetOption(selected, f.key, value)
  end)

  -- range: [-] [value] [+]
  local function Step(dir)
    local opt = f.opt
    local cur = tonumber(ARLE:GetOption(selected, opt)) or opt.min or 0
    local v = cur + dir * (opt.step or 1)
    if opt.min then
      v = math.max(opt.min, v)
    end
    if opt.max then
      v = math.min(opt.max, v)
    end
    ARLE:SetOption(selected, f.key, v)
  end
  f.plus = Kit.SmallButton(f, "+", 20)
  f.plus:SetPoint("RIGHT", -6, 0)
  f.plus:SetScript("OnClick", function()
    Step(1)
  end)
  f.minus = Kit.SmallButton(f, "-", 20)
  f.minus:SetScript("OnClick", function()
    Step(-1)
  end)

  -- button / keybind / list "Add"
  f.action = Button(f, "", 150)
  f.action:SetScript("OnClick", function(self)
    local opt, def = f.opt, ARLE.modules[selected]
    if not opt or not def then
      return
    end
    if opt.type == "keybind" then
      f.StartCapture()
    elseif opt.type == "list" then
      local value = L.Trim(f.edit:GetText() or "")
      f.edit:SetText("")
      f.edit:ClearFocus()
      if value ~= "" then
        f.AddItem(value)
      end
    elseif opt.type == "button" then
      if not ARLE:Allowed() then
        return
      end
      -- A confirm button needs a second click within 3 seconds.
      if opt.confirm and not self.armed then
        self.armed = true
        self:SetText(opt.confirm)
        C_Timer.After(3, function()
          if self.armed then
            self.armed = nil
            ARLE:RefreshUI()
          end
        end)
        return
      end
      self.armed = nil
      local ok, err = pcall(opt.run, def)
      if not ok then
        ARLE.Debug:Record(def, err)
      end
      ARLE:RefreshUI()
    end
  end)
  f.action2 = Button(f, "Clear", 60)
  f.action2:SetScript("OnClick", function()
    local opt = f.opt
    if opt and opt.type == "keybind" and ARLE:Allowed() then
      if InCombatLockdown() then
        ARLE:Print("Key bindings can't change in combat.")
        return
      end
      local keys = { GetBindingKey(opt.binding) }
      for _, key in ipairs(keys) do
        SetBinding(key, nil)
      end
      if SaveBindings and GetCurrentBindingSet then
        SaveBindings(GetCurrentBindingSet())
      end
      ARLE:RefreshUI()
    end
  end)
  f.value = Text(f, "GameFontHighlightSmall")
  f.value:SetJustifyH("RIGHT")
  f.warn = WarnIcon(f, 14)
  f.items = {}

  function f.AddItem(value)
    local list = {}
    for _, v in ipairs(ARLE:GetOption(selected, f.opt) or {}) do
      if L.Key(v) == L.Key(value) then
        return
      end
      list[#list + 1] = v
    end
    list[#list + 1] = value
    ARLE:SetOption(selected, f.key, list)
  end
  function f.RemoveItem(index)
    local list = {}
    for i, v in ipairs(ARLE:GetOption(selected, f.opt) or {}) do
      if i ~= index then
        list[#list + 1] = v
      end
    end
    ARLE:SetOption(selected, f.key, list)
  end
  function f.Item(i)
    local row = f.items[i]
    if row then
      return row
    end
    row = CreateFrame("Frame", nil, f)
    row:SetHeight(ITEM_H)
    row.text = Text(row, "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 8, 0)
    row.remove = Kit.SmallButton(row, "x", 18)
    row.remove:SetPoint("RIGHT", -6, 0)
    row.remove:SetScript("OnClick", function(self)
      if ARLE:Allowed() then
        f.RemoveItem(self.index)
      end
    end)
    row.text:SetPoint("RIGHT", row.remove, "LEFT", -6, 0)
    f.items[i] = row
    return row
  end
  function f.StartCapture()
    if not ARLE:Allowed() then
      return
    end
    if InCombatLockdown() then
      ARLE:Print("Key bindings can't change in combat.")
      return
    end
    capture.field = f
    capture:EnableKeyboard(true)
    if capture.SetPropagateKeyboardInput then
      capture:SetPropagateKeyboardInput(false)
    end
    capture:Show()
    f.action:SetText("Press a key (Esc cancels)")
  end

  f:SetScript("OnEnter", function(self)
    if self.opt and self.opt.tooltip then
      GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:SetText(self.opt.label or self.key, 1, 1, 1)
      GameTooltip:AddLine(self.opt.tooltip, nil, nil, nil, true)
      GameTooltip:Show()
    end
  end)
  f:SetScript("OnLeave", GameTooltip_Hide)
  fields[index] = f
  return f
end

-- Key capture for keybind options: one hidden frame that takes the next key
-- press while a "Press a key" button is armed, and nothing at any other time.
local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
  LMETA = true, RMETA = true }
local function CreateCapture()
  capture = CreateFrame("Frame", nil, UIParent)
  capture:Hide()
  capture:SetScript("OnKeyDown", function(self, key)
    local f = self.field
    if MODIFIER_KEYS[key] then
      return
    end
    self.field = nil
    self:EnableKeyboard(false)
    self:Hide()
    if key ~= "ESCAPE" and f and f.opt and not InCombatLockdown() then
      local combo = key
      if IsShiftKeyDown() then
        combo = "SHIFT-" .. combo
      end
      if IsControlKeyDown() then
        combo = "CTRL-" .. combo
      end
      if IsAltKeyDown() then
        combo = "ALT-" .. combo
      end
      SetBinding(combo, f.opt.binding)
      if SaveBindings and GetCurrentBindingSet then
        SaveBindings(GetCurrentBindingSet())
      end
    end
    ARLE:RefreshUI()
  end)
end

-- Hides every widget of a field before it's drawn as one option type.
local function ResetField(f)
  f.check:Hide()
  f.edit:Hide()
  f.plus:Hide()
  f.minus:Hide()
  f.action:Hide()
  f.action2:Hide()
  f.value:SetText("")
  f.value:Hide()
  if f.dropdown then
    f.dropdown:Hide()
  end
  for _, row in ipairs(f.items) do
    row:Hide()
  end
  f.label:ClearAllPoints()
  f.label:SetTextColor(1, 1, 1)
  f.label:SetAlpha(1)
  f.label:SetWordWrap(false)
  f.warn:Set()
  f.check:SetEnabled(true)
  f.plus:SetEnabled(true)
  f.minus:SetEnabled(true)
  f.edit:EnableMouse(true)
  if f.dropdown then
    f.dropdown:SetEnabled(true)
  end
  f.edit:ClearAllPoints()
  f.edit:SetSize(160, 22)
  f.edit:SetPoint("RIGHT", -6, 0)
  f.action:ClearAllPoints()
  f.action:SetWidth(150)
end

local function Call(fn, def)
  if type(fn) ~= "function" then
    return fn
  end
  local ok, v = pcall(fn, def)
  if ok then
    return v
  end
end

-- Draws one option into a field; returns the field's height.
local function DrawField(f, opt, info, def)
  ResetField(f)
  f.key, f.opt = opt.key, opt
  local t = opt.type
  local value = opt.key and ARLE:GetOption(info.id, opt)
  local needs, why
  if def then
    needs, why = ARLE:OptionProblem(def, opt)
  end
  local enabled = not Call(opt.disabled, def) and not needs
  local height = FIELD_H
  f.label:SetText(opt.label or opt.key or "")
  if t == "header" then
    f.label:SetPoint("BOTTOMLEFT", 0, 4)
    f.label:SetTextColor(Skin:Accent())
  elseif t == "select" then
    local dd = Dropdown(f)
    dd:Show()
    dd:Refresh(opt, value)
    f.label:SetPoint("LEFT", 2, 0)
    f.label:SetPoint("RIGHT", dd, "LEFT", -8, 0)
  elseif t == "boolean" then
    f.check:Show()
    f.check:SetChecked(value and true or false)
    if Skin:Theme() == "arl" then
      -- ARL: label left, switch right; the label dims while it's off.
      f.check:ClearAllPoints()
      f.check:SetPoint("RIGHT", -6, 0)
      f.label:SetPoint("LEFT", 2, 0)
      f.label:SetPoint("RIGHT", f.check, "LEFT", -8, 0)
      f.label:SetAlpha(value and 1 or 0.55)
    else
      f.check:ClearAllPoints()
      f.check:SetPoint("LEFT", -2, 0)
      f.label:SetPoint("LEFT", f.check, "RIGHT", 2, 0)
    end
  elseif t == "range" then
    f.plus:Show()
    f.minus:Show()
    f.edit:Show()
    f.edit:SetSize(56, 22)
    f.edit:ClearAllPoints()
    f.edit:SetPoint("RIGHT", f.plus, "LEFT", -4, 0)
    f.minus:ClearAllPoints()
    f.minus:SetPoint("RIGHT", f.edit, "LEFT", -4, 0)
    if not f.edit:HasFocus() then
      f.edit:SetText(tostring(value == nil and "" or value))
      f.edit:SetCursorPosition(0)
    end
    f.label:SetPoint("LEFT", 2, 0)
    f.label:SetPoint("RIGHT", f.minus, "LEFT", -8, 0)
  elseif t == "button" then
    f.action:Show()
    if not f.action.armed then
      f.action:SetText(opt.label or "")
    end
    f.action:SetWidth(math.max(150, (f.action:GetFontString() and f.action:GetFontString():GetStringWidth() or 0) + 24))
    f.action:SetPoint("LEFT", 0, 0)
    f.label:SetText(Call(opt.desc, def) or "")
    f.label:SetTextColor(Skin:Dim())
    f.label:SetPoint("LEFT", f.action, "RIGHT", 8, 0)
    f.label:SetPoint("RIGHT", -6, 0)
  elseif t == "keybind" then
    f.action:Show()
    f.action2:Show()
    f.action2:SetPoint("RIGHT", -6, 0)
    f.action:SetPoint("RIGHT", f.action2, "LEFT", -4, 0)
    f.action:SetWidth(170)
    local key = GetBindingKey and GetBindingKey(opt.binding)
    if capture and capture.field == f then
      f.action:SetText("Press a key (Esc cancels)")
    else
      f.action:SetText(key and ("Key: " .. (GetBindingText and GetBindingText(key) or key)) or "Set a key")
    end
    f.action2:SetEnabled(key ~= nil)
    f.label:SetPoint("LEFT", 2, 0)
    f.label:SetPoint("RIGHT", f.action, "LEFT", -8, 0)
  elseif t == "list" then
    f.label:SetPoint("TOPLEFT", 2, -8)
    f.edit:Show()
    f.action:Show()
    f.action:SetText(opt.add or "Add")
    f.action:SetWidth(60)
    f.action:SetPoint("TOPRIGHT", -6, -4)
    f.edit:ClearAllPoints()
    f.edit:SetPoint("RIGHT", f.action, "LEFT", -4, 0)
    f.edit:SetSize(140, 22)
    if not f.edit:HasFocus() then
      f.edit:SetText("")
    end
    f.label:SetPoint("RIGHT", f.edit, "LEFT", -8, 0)
    local items = type(value) == "table" and value or {}
    for i, v in ipairs(items) do
      local row = f.Item(i)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 0, -(FIELD_H + (i - 1) * ITEM_H))
      row:SetPoint("RIGHT")
      row.text:SetText(opt.format and Call(function() return opt.format(v, def) end) or tostring(v))
      row.remove.index = i
      row:Show()
    end
    if #items == 0 then
      local row = f.Item(1)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 0, -FIELD_H)
      row:SetPoint("RIGHT")
      row.text:SetText("|cff888888" .. (opt.empty or "(none)") .. "|r")
      row.remove:Hide()
      row:Show()
      height = FIELD_H + ITEM_H
    else
      if f.items[1] then
        f.items[1].remove:Show()
      end
      height = FIELD_H + #items * ITEM_H
    end
    for i = #items + 1, #f.items do
      if not (#items == 0 and i == 1) then
        f.items[i]:Hide()
      end
    end
  elseif t == "info" then
    f.label:SetWordWrap(true)
    f.label:SetText(Call(opt.text, def) or opt.label or "")
    f.label:SetTextColor(0.82, 0.82, 0.82)
    f.label:SetPoint("TOPLEFT", 2, -6)
    f.label:SetPoint("RIGHT", -6, 0)
    height = math.max(FIELD_H - 8, f.label:GetStringHeight() + 12)
  else -- number, string
    f.edit:Show()
    f.edit:SetNumeric(false)
    if not f.edit:HasFocus() then
      f.edit:SetText(tostring(value == nil and "" or value))
      f.edit:SetCursorPosition(0)
    end
    f.label:SetPoint("LEFT", 2, 0)
    f.label:SetPoint("RIGHT", f.edit, "LEFT", -8, 0)
  end
  f.locked = not enabled
  if not enabled then
    f.check:SetEnabled(false)
    f.action:SetEnabled(false)
    f.plus:SetEnabled(false)
    f.minus:SetEnabled(false)
    f.edit:EnableMouse(false)
    if f.dropdown then
      f.dropdown:SetEnabled(false)
    end
  else
    f.action:SetEnabled(true)
  end
  -- Needs an outside addon: a warning icon after the label says which.
  if needs and t ~= "header" and t ~= "info" then
    f.warn:Set(NeedsText(needs, why))
    f.warn:ClearAllPoints()
    local w = math.min(f.label:GetStringWidth() or 0, 220)
    f.warn:SetPoint("LEFT", f.label, "LEFT", w + 4, 0)
  end
  f:SetHeight(height)
  f:SetAlpha((info.enabled and enabled) and 1 or 0.5)
  f:Show()
  return height
end

-- A dropdown for "select" options: the client's own menu dropdown where it
-- exists (WowStyle1DropdownTemplate, 11.0+), else a button that cycles.
local function ValueLabel(opt, value)
  for _, v in ipairs(opt.values) do
    if v.value == value then
      return v.label
    end
  end
  return tostring(value)
end

Dropdown = function(f)
  if f.dropdown then
    return f.dropdown
  end
  local ok, dd
  if Skin:Theme() ~= "arl" then
    ok, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
  end
  if ok and dd and dd.SetupMenu then
    dd:SetWidth(190)
    dd:SetPoint("RIGHT", -6, 0)
    function dd:Refresh(opt)
      self:SetupMenu(function(_, root)
        for _, v in ipairs(opt.values) do
          root:CreateRadio(v.label, function()
            return ARLE:GetOption(selected, opt) == v.value
          end, function()
            ARLE:SetOption(selected, opt.key, v.value)
          end)
        end
      end)
    end
  else
    -- A flat button showing the value; a click opens the game's menu of
    -- choices (or steps through them on clients without one).
    dd = Button(f, "", 190)
    dd:SetPoint("RIGHT", -6, 0)
    local fs = dd:GetFontString()
    if fs then
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", 8, 0)
      fs:SetPoint("RIGHT", -18, 0)
      fs:SetJustifyH("LEFT")
    end
    local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    function dd:Refresh(opt, value)
      self.opt = opt
      self:SetText(ValueLabel(opt, value))
    end
    dd:SetScript("OnClick", function(self)
      if MenuUtil and MenuUtil.CreateContextMenu then
        local opt = self.opt
        MenuUtil.CreateContextMenu(self, function(_, root)
          for _, v in ipairs(opt.values) do
            root:CreateRadio(v.label, function()
              return ARLE:GetOption(selected, opt) == v.value
            end, function()
              ARLE:SetOption(selected, opt.key, v.value)
            end)
          end
        end)
        return
      end
      local values, current = self.opt.values, ARLE:GetOption(selected, self.opt)
      local nextIndex = 1
      for i, v in ipairs(values) do
        if v.value == current then
          nextIndex = i % #values + 1
        end
      end
      ARLE:SetOption(selected, self.opt.key, values[nextIndex].value)
    end)
  end
  Skin:Dropdown(dd)
  f.dropdown = dd
  return dd
end

local shownId -- entry the details pane last showed (scroll resets on change)

local function RefreshDetails(info)
  local content = details.content
  local width = details.scroll:GetWidth()
  content:SetWidth((width and width > 50) and width or DETAILS_W)
  local showing = info and (info.id .. "/" .. (selectedPage or ""))
  if showing ~= shownId then
    shownId = showing
    details.scroll:SetVerticalScroll(0)
  end
  if not info then
    details.title:SetText("Nothing selected")
    details.status:SetText("")
    details.notes:SetText("Pick a feature on the left.")
    details.notice:Hide()
    details.reset:Hide()
    details.toggle:Hide()
    for _, pane in pairs(panes) do
      pane:Hide()
    end
    for _, f in ipairs(fields) do
      f:Hide()
    end
    return
  end

  -- A child row shows one settings page; the module row shows the rest.
  local def = ARLE.modules[info.id]
  local allOptions = def and def.options or {}
  local page
  for _, p in ipairs(def and def.pages or {}) do
    if p.key == selectedPage then
      page = p
    end
  end
  if not page then
    selectedPage = nil
  end

  details.title:SetText(page and (info.title .. "  |cff888888›|r  " .. page.label) or info.title)
  details.status:SetText(info.status)
  details.status:SetTextColor(StateColor(info.state))
  details.notes:SetText(page and (page.notes or "") or info.notes)
  details.toggle:SetShown(not info.builtin)
  details.toggle:SetText(info.enabled and not info.missing and "Disable" or "Enable")
  details.toggle:SetEnabled(not info.missing)
  details.toggle.blocked = info.missing ~= nil

  -- A whole feature (or page) that can't run without an outside addon: a
  -- notice saying why, in place of its settings.
  local needs, why = info.missing, info.missingWhy
  local pageNeeds, pageWhy
  if not needs and page then
    pageNeeds, pageWhy = ARLE:RequirementProblem(page.requires)
  end
  local notice = details.notice
  if needs or pageNeeds then
    local what = needs and info.title or page.label
    notice.title:SetText(what .. " needs " .. (needs or pageNeeds))
    notice.text:SetText((needs or pageNeeds) .. " is " .. (why or pageWhy) .. ". "
      .. (needs and "It can't be turned on until it is." or "These settings do nothing until it is."))
    notice:Show()
  else
    notice:Hide()
  end
  details.reset:ClearAllPoints()
  if info.builtin then
    details.reset:SetPoint("TOPLEFT", 10, -8) -- no Enable/Disable on built-ins
  else
    details.reset:SetPoint("LEFT", details.toggle, "RIGHT", 6, 0)
  end

  local options = {}
  if not needs then
    for _, opt in ipairs(allOptions) do
      if opt.page == selectedPage and not Call(opt.hidden, def) then
        options[#options + 1] = opt
      end
    end
  end
  details.reset:SetShown(#allOptions > 0 and not needs)

  -- Entries with their own pane (Officer Tools) draw it below the notes.
  for owner, pane in pairs(panes) do
    if owner ~= def then
      pane:Hide()
    end
  end
  -- A pane tied to a page (def.panePage) sits under that page's options;
  -- any other pane sits between the module's notes and its settings.
  local shownPane, pagePane
  if def and def.CreatePane and info.active and def.panePage == selectedPage then
    local pane = panes[def]
    if not pane then
      pane = CreateFrame("Frame", nil, content)
      pane:SetHeight(PANE_H)
      def:CreatePane(pane)
      panes[def] = pane
    end
    pane:ClearAllPoints()
    if def.panePage then
      pagePane = pane
    else
      pane:SetPoint("TOPLEFT", notice:IsShown() and notice or details.notes, "BOTTOMLEFT", 0, -12)
      pane:SetPoint("RIGHT", content, "RIGHT", -10, 0)
      shownPane = pane
    end
    pane:Show()
    if def.RefreshPane then
      def:RefreshPane(pane)
    end
  elseif def and panes[def] then
    panes[def]:Hide()
  end
  if #allOptions == 0 and not def and not needs then
    details.notes:SetText(info.notes .. "\n\n|cff999999Its settings show once it's turned on.|r")
  end

  local y = 0
  for i, opt in ipairs(options) do
    local f = Field(i)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", 0, -y)
    f:SetPoint("RIGHT")
    y = y + DrawField(f, opt, info, def)
  end
  for i = #options + 1, #fields do
    fields[i]:Hide()
  end
  if pagePane then
    if #options > 0 then
      pagePane:SetPoint("TOPLEFT", details.body, "TOPLEFT", 0, -(y + 8))
      y = y + 8 + PANE_H
    else
      pagePane:SetPoint("TOPLEFT", notice:IsShown() and notice or details.notes, "BOTTOMLEFT", 0, -12)
      shownPane = pagePane
    end
    pagePane:SetPoint("RIGHT", content, "RIGHT", -10, 0)
  end

  -- Settings go under the pane, the notice or the notes, in that order; then
  -- the scroll child is sized to everything in it.
  local above = shownPane or (notice:IsShown() and notice) or details.notes
  details.body:ClearAllPoints()
  details.body:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -12)
  details.body:SetPoint("RIGHT", content, "RIGHT", -10, 0)
  details.body:SetHeight(math.max(y, 1))
  local h = 10 + details.title:GetStringHeight() + 4 + details.status:GetStringHeight() + 8
    + details.notes:GetStringHeight()
  if notice:IsShown() then
    h = h + 10 + NOTICE_H
  end
  if shownPane then
    h = h + 12 + PANE_H
  end
  if #options > 0 then
    h = h + 12 + y
  end
  content:SetHeight(h + 16)
end

-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

function ARLE:RefreshUI()
  if not main or not main:IsShown() then
    return
  end
  -- The installed packs rarely change mid-session; rescanning every addon's
  -- metadata on each state change (every version reply) is wasted work.
  local now = GetTime()
  if not self._scannedAt or now - self._scannedAt > 10 then
    self._scannedAt = now
    self:Scan()
  end
  local groups = self:GetGroups()
  local current
  for _, group in ipairs(groups) do
    for _, info in ipairs(group.modules) do
      if not selected then
        selected = info.id
      end
      if info.id == selected then
        current = info
      end
    end
  end
  -- The selected entry may have gone (Officer Tools after losing the rank).
  if not current and groups[1] and groups[1].modules[1] then
    current = groups[1].modules[1]
    selected, selectedPage = current.id, nil
  end
  RefreshList(groups)
  RefreshDetails(current)
  self:RefreshLock()
end

function ARLE:RefreshLock()
  local state = self:GuildState()
  local locked = state ~= "member"
  if locked then
    lock.title:SetText(state == "checking" and "Checking your guild..." or "Guild members only")
    if state == "checking" then
      lock.text:SetText("Waiting for the server to confirm your guild. This only takes a moment.")
    else
      lock.text:SetText(self.title .. " can only be used by members of |cffffd100"
        .. self.guildName .. "|r.\n\nJoin us on Discord to get an invite.")
    end
  end
  lock:SetShown(locked)
  -- Belt and braces under the overlay: nothing on the panes reacts either.
  local enabled = not locked
  details.toggle:SetEnabled(enabled and not details.toggle.blocked)
  details.reset:SetEnabled(enabled)
  for _, row in ipairs(moduleRows) do
    row:SetEnabled(enabled)
    row.check:SetEnabled(enabled and not row.blocked)
  end
  for _, row in ipairs(childRows) do
    row:SetEnabled(enabled)
  end
  search:EnableMouse(enabled)
  for _, f in ipairs(fields) do
    local on = enabled and not f.locked
    f.check:SetEnabled(on)
    f.plus:SetEnabled(on)
    f.minus:SetEnabled(on)
    f.action:SetEnabled(enabled and f.action:IsEnabled())
    f.action2:SetEnabled(enabled and f.action2:IsEnabled())
    for _, row in ipairs(f.items) do
      row.remove:SetEnabled(enabled)
    end
    f.edit:EnableMouse(on)
    if f.dropdown then
      f.dropdown:SetEnabled(on)
    end
    if not enabled then
      f.edit:ClearFocus()
    end
  end
end

ARLE:OnChange(function()
  ARLE:RefreshUI()
end)

function ARLE:CreatePanel()
  main = Skin:CreateWindow("ARLExtensionsFrame", UIParent)
  main:SetSize(WIDTH, HEIGHT)
  main:SetPoint("CENTER")
  main:SetFrameStrata("DIALOG")
  main:SetToplevel(true)
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForDrag("LeftButton")
  main:SetScript("OnDragStart", main.StartMoving)
  main:SetScript("OnDragStop", main.StopMovingOrSizing)
  main:SetClampedToScreen(true)
  main:SetScript("OnShow", function()
    ARLE:RefreshUI()
  end)

  local title = Text(main, main.arl and "GameFontNormal" or "GameFontNormalLarge")
  if main.arl then
    title:SetPoint("LEFT", main, "TOPLEFT", 12, -Skin.TITLE_H / 2 - 1) -- in the title band
  else
    title:SetPoint("TOPLEFT", 16, main.stock and -6 or -14)
  end
  title:SetText(self.title .. (self.version and ("  |cff888888v" .. self.version .. "|r") or ""))
  if main.stock and main.TitleText then
    main.TitleText:SetText("")
  end

  if not main.CloseButton then
    Skin:CloseButton(main)
  end

  local top = main.stock and -32 or (main.arl and -(Skin.TITLE_H + 8)) or -42
  local listPane = CreateFrame("Frame", nil, main)
  listPane:SetPoint("TOPLEFT", 12, top)
  listPane:SetPoint("BOTTOMLEFT", 12, 42)
  listPane:SetWidth(LIST_W)
  Skin:Panel(listPane)

  -- Search: filters the list by title, notes, setting names and commands.
  search = Kit.EditBox(listPane, LIST_W - 12, "ARLExtensionsSearch")
  search:SetPoint("TOPLEFT", 6, -5)
  search:SetPoint("TOPRIGHT", -6, -5)
  search.hint = Text(search, "GameFontDisableSmall")
  search.hint:SetPoint("LEFT", 8, 0)
  search.hint:SetText("Search features and settings")
  search:SetScript("OnTextChanged", function(self)
    self.hint:SetShown((self:GetText() or "") == "")
    ARLE:RefreshUI()
  end)
  search:SetScript("OnEnterPressed", search.ClearFocus)
  search:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  main.search = search

  list = CreateFrame("ScrollFrame", "ARLExtensionsList", listPane, "UIPanelScrollFrameTemplate")
  list:SetPoint("TOPLEFT", 4, -32)
  list:SetPoint("BOTTOMRIGHT", -26, 4)
  Skin:ScrollBar(list)
  listChild = CreateFrame("Frame", nil, list)
  listChild:SetSize(LIST_W - 30, 1)
  list:SetScrollChild(listChild)

  emptyText = Text(listChild, "GameFontDisable")
  emptyText:SetPoint("TOPLEFT", 8, -8)
  emptyText:SetWidth(LIST_W - 46)
  emptyText:SetText("No features installed. Run ./bin/arle publish, then /reload.")
  CreateCapture()

  details = CreateFrame("Frame", nil, main)
  main.details = details
  details:SetPoint("TOPLEFT", listPane, "TOPRIGHT", 10, 0)
  details:SetPoint("BOTTOMRIGHT", -12, 42)
  Skin:Panel(details)

  details.toggle = Button(details, "Disable", 90)
  -- Action row above the description: [Disable] [Reset to defaults].
  details.toggle:SetPoint("TOPLEFT", 10, -8)
  details.toggle:SetScript("OnClick", function()
    local info = selected and ARLE:GetInfo(selected)
    if info then
      ARLE:SetModuleEnabled(info.id, not info.enabled)
    end
  end)

  -- Everything between the Enable/Disable button and Reset scrolls, so a
  -- long description never runs into the settings below it.
  details.scroll = CreateFrame("ScrollFrame", "ARLEDetailsScroll", details, "UIPanelScrollFrameTemplate")
  details.scroll:SetPoint("TOPLEFT", 0, -38)
  details.scroll:SetPoint("BOTTOMRIGHT", -26, 6)
  Skin:ScrollBar(details.scroll)
  local content = CreateFrame("Frame", nil, details.scroll)
  content:SetSize(DETAILS_W, 1)
  details.scroll:SetScrollChild(content)
  details.content = content

  details.title = Text(content, "GameFontNormalLarge")
  details.title:SetPoint("TOPLEFT", 14, -10)
  details.title:SetPoint("RIGHT", content, "RIGHT", -14, 0)
  details.status = Text(content, "GameFontHighlightSmall")
  details.status:SetPoint("TOPLEFT", details.title, "BOTTOMLEFT", 0, -4)
  details.status:SetPoint("RIGHT", content, "RIGHT", -14, 0)
  details.notes = Text(content, "GameFontHighlightSmall")
  details.notes:SetPoint("TOPLEFT", details.status, "BOTTOMLEFT", 0, -8)
  details.notes:SetPoint("RIGHT", content, "RIGHT", -14, 0)
  details.notes:SetTextColor(0.8, 0.8, 0.8)
  details.notes:SetSpacing(2)

  -- "Needs <addon>": shown instead of the settings of a feature (or page)
  -- whose outside addon is missing.
  local notice = CreateFrame("Frame", nil, content)
  notice:SetPoint("TOPLEFT", details.notes, "BOTTOMLEFT", 0, -10)
  notice:SetPoint("RIGHT", content, "RIGHT", -14, 0)
  notice:SetHeight(NOTICE_H)
  Skin:Panel(notice)
  notice.icon = notice:CreateTexture(nil, "ARTWORK")
  notice.icon:SetSize(24, 24)
  notice.icon:SetPoint("LEFT", 10, 0)
  notice.icon:SetTexture(WARN_ICON)
  notice.title = Text(notice, "GameFontNormal")
  notice.title:SetPoint("TOPLEFT", notice.icon, "TOPRIGHT", 8, 2)
  notice.title:SetPoint("RIGHT", -8, 0)
  notice.text = Text(notice, "GameFontHighlightSmall")
  notice.text:SetPoint("TOPLEFT", notice.title, "BOTTOMLEFT", 0, -3)
  notice.text:SetPoint("RIGHT", -8, 0)
  notice:Hide()
  details.notice = notice

  details.body = CreateFrame("Frame", nil, content)
  details.body:SetPoint("TOPLEFT", details.notes, "BOTTOMLEFT", 0, -12)
  details.body:SetPoint("RIGHT", content, "RIGHT", -10, 0)
  details.body:SetHeight(1)

  details.reset = Button(details, "Reset to defaults", 130)
  details.reset:SetPoint("LEFT", details.toggle, "RIGHT", 6, 0)
  local rule = details:CreateTexture(nil, "ARTWORK")
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 8, -34)
  rule:SetPoint("TOPRIGHT", -8, -34)
  rule:SetColorTexture(1, 1, 1, 0.12)
  details.reset:SetScript("OnClick", function()
    if selected then
      ARLE:ResetOptions(selected)
    end
  end)

  -- Guild lock: covers both panes and swallows every click on them.
  lock = CreateFrame("Frame", nil, main)
  lock:SetPoint("TOPLEFT", listPane, "TOPLEFT", 0, 0)
  lock:SetPoint("BOTTOMRIGHT", details, "BOTTOMRIGHT", 0, 0)
  lock:SetFrameLevel(details:GetFrameLevel() + 50)
  lock:EnableMouse(true)
  lock:EnableMouseWheel(true)
  lock:SetScript("OnMouseWheel", function() end)
  local shade = lock:CreateTexture(nil, "BACKGROUND")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.82)
  lock.icon = lock:CreateTexture(nil, "ARTWORK")
  lock.icon:SetSize(48, 48)
  lock.icon:SetPoint("CENTER", 0, 50)
  lock.icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
  lock.title = Text(lock, "GameFontNormalLarge")
  lock.title:SetPoint("TOP", lock.icon, "BOTTOM", 0, -10)
  lock.title:SetJustifyH("CENTER")
  lock.text = Text(lock, "GameFontHighlight")
  lock.text:SetPoint("TOP", lock.title, "BOTTOM", 0, -8)
  lock.text:SetWidth(WIDTH - 140)
  lock.text:SetJustifyH("CENTER")
  lock.text:SetSpacing(2)
  lock:Hide()
  main.lock = lock

  local reload = Button(main, "Reload UI", 100)
  reload:SetPoint("BOTTOMRIGHT", -14, 12)
  reload:SetScript("OnClick", ReloadUI)

  local hint = Text(main, "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 18)
  hint:SetPoint("RIGHT", reload, "LEFT", -8, 0)
  hint:SetText("Theme: " .. Skin:ThemeLabel() .. "  ·  /arl help")

  tinsert(UISpecialFrames, "ARLExtensionsFrame")
  main:Hide()
end

function ARLE:Toggle()
  if not self.ready then
    self:Print("Still loading.")
    return
  end
  if InCombatLockdown() then
    self:Print("Not in combat.")
    return
  end
  if not main then
    self:CreatePanel()
  end
  main:SetShown(not main:IsShown())
end

-- Opens the panel on one module (used by the EllesmereUI options page).
function ARLE:Open(id, page)
  if id then
    selected, selectedPage = id, page
  end
  if not main then
    self:CreatePanel()
  end
  main:Show()
  self:RefreshUI()
end
