-- Sharer Markers: on OpenMap's world map, guildmates and friends who share
-- their place (OpenMap users, and ARL's Share Location) show as class-coloured
-- diamonds with their name, so they can't be taken for your party and raid,
-- which stay OpenMap's round dots with a gold ring.
--
-- OpenMap (MIT, "OpenMap contributors") draws both as the same 12 px
-- class-coloured circle; only a thin gold ring tells group members apart
-- (OpenMap/Map/Nav.lua, Friends.lua). Public surfaces used, nothing of
-- OpenMap's edited:
--   _G.OpenMap (its namespace), :GetModule("worldmap")
--   OpenMap.MapStitch.AddPin(set, u, v, look, data): self:Wrap. A sharer's dot
--     is the only pin drawn with data = { full = "Name-Realm", p = { map, x,
--     y, class, ... }, roster }; for it, the look handed on is our diamond
--     (same class colour) instead of OpenMap's circle. Every other pin passes
--     through untouched.
--   mod.RefreshFriends(): redraws those dots at once on enable, disable and
--     an option change.
-- Names: a FontString of ours on the pin, kept in a weak-keyed table (no
-- fields written onto OpenMap's frames). OpenMap pools pins per set, and that
-- set only holds sharer dots, so each reuse comes through AddPin again and the
-- label is set or hidden there. Off: every label is hidden and the dots
-- redrawn as OpenMap's own.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local DIAMOND = "Interface\\AddOns\\" .. ADDON .. "\\Media\\SharerDiamond"
local SIZE = 14          -- OpenMap's dots are 12: the diamond's tip-to-tip reads about as big

local F = {
  id = "SharerMarkers",
  addon = ADDON,
  title = "Sharer Markers",
  extends = "OpenMap",
  group = "OpenMap",
  command = "markers",
  commandHelp = "diamonds and names for guildmates on OpenMap, apart from your group",
  description = "On OpenMap's world map, guildmates and friends who share where they are show as class-coloured "
    .. "diamonds with their name. Your party and raid stay round dots with a gold ring.",
  options = {
    { key = "names", type = "boolean", label = "Show their names", default = true,
      tooltip = "Their name beside each diamond." },
    { type = "info", text = function(def) return def:GetStatus() end },
  },
}

local labels = setmetatable({}, { __mode = "k" })   -- pin -> our FontString
local looks = {}                                    -- "r,g,b" -> our look
local drawn = 0                                     -- diamonds drawn in the last redraw

local function Module()
  local om = _G.OpenMap
  if type(om) ~= "table" or type(om.GetModule) ~= "function" then
    return
  end
  local ok, mod = pcall(om.GetModule, om, "worldmap")
  if ok and type(mod) == "table" then
    return om, mod
  end
end

local function Redraw()
  local _, mod = Module()
  if mod and type(mod.RefreshFriends) == "function" then
    pcall(mod.RefreshFriends)
  end
end

-- a sharer's dot, as OpenMap's Friends.lua draws it
local function IsSharer(data)
  return type(data) == "table" and type(data.full) == "string" and type(data.p) == "table" and data.p.map ~= nil
end

local function DiamondLook(look)
  local c = type(look) == "table" and type(look.color) == "table" and look.color or { 1, 1, 1, 1 }
  local key = ("%.3f,%.3f,%.3f"):format(c[1] or 1, c[2] or 1, c[3] or 1)
  local mine = looks[key]
  if not mine then
    -- (fallback: a plain square, still not a round dot, if the texture can't be read)
    mine = { texture = DIAMOND, fallback = "Interface\\Buttons\\WHITE8X8", size = SIZE,
      color = { c[1] or 1, c[2] or 1, c[3] or 1, 1 } }
    looks[key] = mine
  end
  return mine
end

local function Label(pin)
  local fs = labels[pin]
  if not fs then
    fs = pin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", pin, "RIGHT", 1, 0)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    labels[pin] = fs
  end
  return fs
end

function F:AddPin(orig, set, u, v, look, data)
  if not IsSharer(data) then
    return orig(set, u, v, look, data)
  end
  local pin = orig(set, u, v, DiamondLook(look), data)
  drawn = drawn + 1
  if type(pin) == "table" and pin.CreateFontString then
    local fs = Label(pin)
    if self.db.names then
      local name = data.full:match("^[^%-]+") or data.full
      local c = type(look) == "table" and look.color
      fs:SetText(name)
      if type(c) == "table" then
        fs:SetTextColor(c[1] or 1, c[2] or 1, c[3] or 1)
      end
      fs:Show()
    else
      fs:Hide()
    end
  end
  return pin
end

function F:OnEnable()
  local om = Module()
  local S = om and om.MapStitch
  if type(S) ~= "table" or type(S.AddPin) ~= "function" then
    self:Print("OpenMap's map drawing wasn't found (OpenMap may have changed); nothing to mark.")
    return
  end
  self:Wrap(S, "AddPin", function(orig, set, u, v, look, data)
    -- (counted per redraw: Friends.lua clears the set, then adds every dot)
    if IsSharer(data) and type(set) == "table" and type(set.pins) == "table" and #set.pins == 0 then
      drawn = 0
    end
    return self:AddPin(orig, set, u, v, look, data)
  end)
  Redraw()
end

function F:OnDisable()
  for _, fs in pairs(labels) do
    fs:Hide()
  end
  drawn = 0
  -- (the wrapper already passes straight through: the dots come back as OpenMap's own)
  Redraw()
end

function F:OnOptionChanged()
  Redraw()
end

function F:GetStatus()
  local _, mod = Module()
  if not mod then
    return "OpenMap isn't loaded"
  end
  local db = type(mod.db) == "table" and mod.db or {}
  if db.friends == false and db.guild == false then
    return "OpenMap shows no friends or guild members (its Friends / Guild members on the map are off)"
  end
  return ("Active · %d guildmate%s or friend%s marked on the map last time it drew"):format(drawn,
    drawn == 1 and "" or "s", drawn == 1 and "" or "s")
end

ARLE:RegisterModule(F)
