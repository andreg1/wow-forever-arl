-- The addon's own settings, pinned at the top of the list under General.
-- A built-in entry: always on, no checkbox, no addon folder of its own.
local _, ns = ...
local ARLE = ns.ARLE
local Skin = ARLE.Skin

local THEMES = {
  { value = "arl", label = "ARL (default)" },
  { value = "auto", label = "Automatic (match my UI)" },
  { value = "ellesmere", label = "EllesmereUI" },
  { value = "elvui", label = "ElvUI" },
  { value = "blizzard", label = "Blizzard" },
}

local function Label(value)
  for _, t in ipairs(THEMES) do
    if t.value == value then
      return t.label
    end
  end
  return value
end

local settings = {
  id = "Settings",
  title = "Settings",
  group = "General",
  builtin = true,
  description = "How ARL Extensions looks.",
  defaults = {},
  options = {
    {
      key = "theme",
      type = "select",
      label = "Theme",
      tooltip = "How this window and the module windows look. ARL: flat and dark, in the style of Forever Leveling BiS. "
        .. "Automatic matches ElvUI or EllesmereUI when you run them. Applies after a reload.",
      values = THEMES,
      default = "arl",
      get = function()
        return ARLE.db.theme or "arl"
      end,
      set = function(value)
        ARLE.db.theme = value
      end,
    },
    {
      key = "accent",
      type = "select",
      label = "Accent colour (ARL theme)",
      tooltip = "The colour of selections, switches and headers in the ARL theme. Applies after a reload.",
      values = {
        { value = "gold", label = "Gold" },
        { value = "class", label = "My class colour" },
      },
      default = "gold",
      get = function()
        return ARLE.db.accent or "gold"
      end,
      set = function(value)
        ARLE.db.accent = value
      end,
    },
    {
      key = "loginMessage",
      type = "boolean",
      label = "Show a message in chat at login",
      default = true,
      get = function()
        return ARLE.db.loginMessage ~= false
      end,
      set = function(value)
        ARLE.db.loginMessage = value and true or false
      end,
    },
    { type = "header", label = "About" },
    {
      type = "info",
      text = function()
        return "v" .. tostring(ARLE.version or "?") .. "  ·  by aredpanda and andreg1  ·  MIT License\n"
          .. "|cff999999/arl help lists every command.|r"
      end,
    },
  },
}

function settings:GetStatus()
  local want = ARLE.db.theme or "arl"
  if Skin.requested and want ~= Skin.requested then
    return "|cffffb84dTheme changes to " .. Label(want) .. " after you reload the UI.|r"
  end
  return "Theme: " .. Label(want) .. (want == "auto" and (" (" .. Skin:ThemeLabel() .. ")") or "")
end

ARLE:RegisterModule(settings)
