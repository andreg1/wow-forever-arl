-- ARLE.Options: option presets shared by features, and turning text typed in
-- chat into a setting's value (for the generated "/arl <feature> set ...").
--
-- Option types (the panel draws each one; see UI/Panel.lua):
--   header    a small section title             { type="header", label }
--   boolean   on/off switch                     { key, label, tooltip }
--   select    dropdown                          { key, values = {{value,label}} }
--   number    text box with a number            { key, min, max }
--   range     number with - / + buttons         { key, min, max, step }
--   string    text box                          { key }
--   button    one-shot action                   { label, run = function(def) end, confirm }
--   keybind   a key binding of ours             { binding = "CLICK ...", label }
--   list      editable list of words/names      { key, label, add = "Add" } (db[key] is an array)
--   info      read-only line                    { text = function(def) return "..." end }
-- Any option may have: page (a child entry), tooltip, default, hidden(def),
-- disabled(def), get()/set(v) (keep the value elsewhere), cmd (the word used in
-- chat when it differs from key), nocmd (not settable from chat).
local _, ns = ...
local ARLE = ns.ARLE
local O = ARLE.Options
local L = ARLE.Lib

O.Preset = {}

-- Raid-warning text, sound and taskbar flash: the same three settings, with
-- the same labels, on every feature that alerts.
function O.Preset.Alert(spec)
  spec = spec or {}
  local page = spec.page
  return {
    { type = "header", label = spec.header or "Alert", page = page },
    { key = "alertWarning", type = "boolean", label = "Raid-warning message", default = true, page = page,
      cmd = "warning" },
    { key = "alertSound", type = "boolean", label = "Sound", default = true, page = page, cmd = "sound" },
    { key = "alertFlash", type = "boolean", label = "Flash the taskbar icon", default = true, page = page,
      cmd = "flash" },
  }
end

-- "Add a line to item tooltips".
function O.Preset.Tooltip(spec)
  spec = spec or {}
  return {
    { key = "tooltip", type = "boolean", label = spec.label or "Add a line to item tooltips", default = true,
      page = spec.page },
  }
end

-- A button that puts a movable frame back where it started.
function O.Preset.ResetPosition(spec)
  spec = spec or {}
  return {
    { type = "button", label = spec.label or "Reset position", page = spec.page, nocmd = true,
      run = function(def)
        def.char.position = nil
        def.char.alertPos = nil
        def.db.position = nil
        ARLE.UI.Alert:Place(def)
        if def.OnResetPosition then
          def:OnResetPosition()
        end
        def:Print("position reset.")
      end },
  }
end

-- Options may hold presets (nested lists): flattened in place, in order.
function O.Flatten(list)
  local out = {}
  local function add(entries)
    for _, o in ipairs(entries) do
      if o.type == nil and o.key == nil and o[1] ~= nil then
        add(o)
      else
        out[#out + 1] = o
      end
    end
  end
  add(list or {})
  return out
end

-- Settable from chat: has a key, and a type that holds a value.
local VALUE_TYPES = { boolean = true, select = true, number = true, range = true, string = true }
function O.IsValue(opt)
  return opt.key ~= nil and VALUE_TYPES[opt.type or ""] and not opt.nocmd
end

function O.CmdWord(opt)
  return (opt.cmd or opt.key):lower()
end

local TRUE = { on = true, ["true"] = true, yes = true, ["1"] = true, enable = true, enabled = true }
local FALSE = { off = true, ["false"] = true, no = true, ["0"] = true, disable = true, disabled = true }

-- The value text means for this option, or nil and why not.
-- A boolean with no text flips the current value.
function O.Parse(opt, text, current)
  text = L.Trim(text)
  local t = opt.type
  if t == "boolean" then
    local word = text:lower()
    if word == "" or word == "toggle" then
      return not current
    elseif TRUE[word] then
      return true
    elseif FALSE[word] then
      return false
    end
    return nil, "use on or off"
  elseif t == "number" or t == "range" then
    local n = tonumber(text)
    if not n then
      return nil, "needs a number" .. O.RangeText(opt)
    end
    if (opt.min and n < opt.min) or (opt.max and n > opt.max) then
      return nil, "must be" .. O.RangeText(opt)
    end
    return n
  elseif t == "select" then
    local k = L.Key(text)
    if k == "" then
      return nil, "one of: " .. O.ValuesText(opt)
    end
    for _, v in ipairs(opt.values) do
      if L.Key(v.value) == k then
        return v.value
      end
    end
    for _, v in ipairs(opt.values) do
      if L.Key(v.label):sub(1, #k) == k then
        return v.value
      end
    end
    return nil, "one of: " .. O.ValuesText(opt)
  elseif t == "string" then
    return text
  end
  return nil, "can't be set from chat"
end

function O.RangeText(opt)
  if opt.min and opt.max then
    return " from " .. opt.min .. " to " .. opt.max
  elseif opt.min then
    return " of at least " .. opt.min
  elseif opt.max then
    return " up to " .. opt.max
  end
  return ""
end

function O.ValuesText(opt)
  local list = {}
  for _, v in ipairs(opt.values or {}) do
    list[#list + 1] = tostring(v.value)
  end
  return table.concat(list, ", ")
end

-- How a value reads in chat.
function O.Describe(opt, value)
  local t = opt.type
  if t == "boolean" then
    return value and "|cff73e673on|r" or "|cff999999off|r"
  elseif t == "select" then
    for _, v in ipairs(opt.values or {}) do
      if v.value == value then
        return v.label
      end
    end
  elseif t == "list" then
    return (type(value) == "table" and #value or 0) .. " entries"
  end
  if value == nil or value == "" then
    return "|cff999999(none)|r"
  end
  return tostring(value)
end
