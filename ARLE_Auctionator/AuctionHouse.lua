-- Auction House: one entry in /arl for the pack's auction house features, the
-- user's request (2026-11-28): one settings page for Darkmoon, Logistics and
-- Snipes, which the ARL tab's cog opens too.
--
-- The parts stay features of their own (their ids, saved data, commands and
-- error reports unchanged) but are hidden from the /arl list (toc hidden=1,
-- Core/Modules.lua). This entry shows them as pages: each page starts with
-- the part's on/off switch, then the part's own options, passed through with
-- get / set (ARLE:GetOption / ARLE:SetOption on the part, so its
-- OnOptionChanged runs as if set on its own page). Built from the parts'
-- options when this file loads (it's the pack's last), so a new part option
-- shows up here by itself.
--
-- This entry's own switch is the master: off turns its parts off (and keeps
-- which were on), on turns those back on, or all three the first time. A
-- part turned on from its page turns this on too. Characters that had parts
-- on before this entry existed get it turned on once (OnBind).
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end

local PARTS = {
  { id = "DarkmoonTickets", page = "darkmoon", label = "Darkmoon",
    notes = "The Darkmoon Faire: where and when, and the cheapest Prize Tickets and reputation." },
  { id = "Logistics", page = "logistics", label = "Logistics",
    notes = "Your supply camp: Craftsman's Writs by gold per reputation, Waylaid Crates by gold per Merchant's Favor." },
  { id = "Snipes", page = "snipes", label = "Snipes",
    notes = "Auctions selling for less than a vendor pays, from a full scan." },
}

local F = {
  id = "AuctionHouse",
  addon = ADDON,
  title = "Auction House",
  group = "Auctionator",
  extends = "Auctionator",
  command = "ah",
  commandHelp = "opens the Auction House settings",
  description = "The ARL tab on the auction house: Darkmoon (the Faire's tickets and reputation), Logistics (your "
    .. "supply camp's reputation and Merchant's Favor) and Snipes (auctions below vendor price). Each has its own "
    .. "page below, with its switch and settings; this switch turns them all off or back on.",
  pages = {},
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
  },
}

local function On(id)
  local info = ARLE:GetInfo(id)
  return info and info.enabled and true or false
end

local function SetPart(id, value)
  ARLE:SetModuleEnabled(id, value)
  if value and not On(F.id) then
    ARLE:SetModuleEnabled(F.id, true)
  end
end

-- One of a part's options, shown on this entry's page and passed through to the part.
local function Proxy(part, def, opt)
  local o = {}
  for k, v in pairs(opt) do
    if type(v) == "function" and k ~= "get" and k ~= "set" then
      o[k] = function(_, ...)
        return v(def, ...)
      end
    else
      o[k] = v
    end
  end
  o.page = part.page
  o.default = nil
  if opt.key then
    o.key = part.id .. ":" .. opt.key
    o.get = function()
      return ARLE:GetOption(part.id, opt)
    end
    o.set = function(value)
      ARLE:SetOption(part.id, opt.key, value)
    end
  end
  return o
end

for _, part in ipairs(PARTS) do
  local def = ARLE.modules[part.id]
  F.pages[#F.pages + 1] = { key = part.page, label = part.label, notes = part.notes }
  F.options[#F.options + 1] = { key = part.id .. ":on", type = "boolean", label = "Turn " .. part.label .. " on",
    page = part.page, cmd = part.page, get = function()
      return On(part.id)
    end, set = function(value)
      SetPart(part.id, value)
    end }
  for _, opt in ipairs(def and def.options or {}) do
    F.options[#F.options + 1] = Proxy(part, def, opt)
  end
end

-- The buy list (Buyer.lua): its own page.
local marginValues = {
  { value = 0, label = "Not a copper more than planned" },
  { value = 5, label = "Up to 5% more" },
  { value = 10, label = "Up to 10% more" },
  { value = 25, label = "Up to 25% more" },
  { value = 50, label = "Up to 50% more" },
}
F.pages[#F.pages + 1] = { key = "buying", label = "Buying",
  notes = "Buy the plan / Buy all fill a buy list; the Buy next button (or its key) buys it one press at a time." }
F.options[#F.options + 1] = { key = "buyMargin", type = "select", page = "buying", cmd = "margin",
  label = "Pay at most this much over the plan's price", values = marginValues, default = 10 }

-- Characters that had parts on before this entry existed: on, once.
function F:OnBind()
  if self.db.seen then
    return
  end
  self.db.seen = true
  for _, part in ipairs(PARTS) do
    if On(part.id) then
      self.db.enabled = true
      return
    end
  end
end

function F:OnEnable()
  if ns.Buyer then
    ns.Buyer.Enable(self)
  end
  local was = self.db.parts
  self.db.parts = nil
  local any = false
  for _, part in ipairs(PARTS) do
    any = any or On(part.id)
  end
  if any and not was then
    return -- (parts already on: nothing to put back)
  end
  self:After(0, function()
    for _, part in ipairs(PARTS) do
      if (was == nil or was[part.id]) and not On(part.id) then
        ARLE:SetModuleEnabled(part.id, true)
      end
    end
  end)
end

function F:OnDisable()
  if ns.Buyer then
    ns.Buyer.Disable()
  end
  local was = {}
  for _, part in ipairs(PARTS) do
    if On(part.id) then
      was[part.id] = true
      ARLE:SetModuleEnabled(part.id, false)
    end
  end
  self.db.parts = was
end

function F:main()
  ARLE:Open(F.id)
end

function F:GetStatus()
  local words = {}
  for _, part in ipairs(PARTS) do
    words[#words + 1] = part.label .. (On(part.id) and " on" or " |cff999999off|r")
  end
  local buy = ""
  local B = ns.Buyer
  if B and B.Active() then
    buy = " · buy list: " .. (B.NextText())
  end
  return "Active · " .. table.concat(words, ", ") .. buy
end

function F:ReportDetails()
  return ns.Buyer and ns.Buyer.Report() or {}
end

-- The page for an ARL tab panel (its `settings` key).
ns.AuctionHouse = { id = F.id }

ARLE:RegisterModule(F)
