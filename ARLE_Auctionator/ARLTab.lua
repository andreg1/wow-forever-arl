-- The ARL tab on the auction house: one tab that holds the pack's panels
-- (Logistics, Snipes), switched with a strip at its top. Each feature
-- registers its panel (ns.ARLTab.Register); a panel's button shows only while
-- its feature is on, and the tab's button only while one of them is.
--
-- The tab is added through LibAHTab-1-0 (the LibStub library Auctionator ships
-- for other addons' tabs: CreateTab / GetButton). LibAHTab lays tabs out in
-- the order they're made, so ours waits until Auctionator has made its own
-- (`AuctionatorAHTabsContainer.Tabs`, made when the auctioneer window opens)
-- and comes after them; no tab button is moved by us. A tab can't be taken out
-- again, so with every panel off its button and frame are hidden. Our frame
-- sits on AuctionHouseFrame by its own anchors; nothing is written on
-- Blizzard's or Auctionator's frames.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Kit, Skin = ARLE.UI.Kit, ARLE.Skin

local TAB_ID = "ARLExtensions"
local STRIP_H = 24 -- the panel switch strip
local WAIT_STEP, WAIT_MAX = 0.1, 50 -- waiting for Auctionator's tabs: 0.1 s, 5 s at most

local H = { panels = {} }
ns.ARLTab = H

local host, content, strip, buttons = nil, nil, nil, nil
local current -- the panel id shown (this session)
local waiting = false

-- panel = { id, title, order, width, feature, tip, settings (its page in the Auction House entry), build(parent) }
function H.Register(panel)
  H.panels[#H.panels + 1] = panel
  table.sort(H.panels, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
end

local leaving -- a feature turning off (its switch may still say on while OnDisable runs)

local function Active()
  local out = {}
  for _, p in ipairs(H.panels) do
    if p.feature and p.feature._active and p.feature ~= leaving then
      out[#out + 1] = p
    end
  end
  return out
end

local function Lib()
  return LibStub and LibStub("LibAHTab-1-0", true)
end

local function Button()
  local lib = Lib()
  if lib and lib.DoesIDExist and lib:DoesIDExist(TAB_ID) then
    return lib:GetButton(TAB_ID)
  end
end

-- Which feature traces go to: the first active panel's.
local function Owner()
  local a = Active()
  return a[1] and a[1].feature
end

local function Show(id)
  local active = Active()
  local pick
  for _, p in ipairs(active) do
    if p.id == id then
      pick = p
    end
  end
  pick = pick or active[1]
  current = pick and pick.id
  for _, p in ipairs(H.panels) do
    if p.frame then
      p.frame:SetShown(p == pick)
    end
  end
  if pick and not pick.frame then
    pick.frame = pick.build(content)
    pick.frame:SetAllPoints(content)
    pick.frame:Hide()
    pick.frame:Show() -- (so its OnShow paints it the first time too)
  end
end

-- The strip: one button per active panel, the shown one in the accent colour.
local stripKey
local function BuildStrip()
  local list, ids = {}, {}
  for _, p in ipairs(Active()) do
    list[#list + 1] = { key = p.id, label = p.title, width = p.width or 90, tip = p.tip }
    ids[#ids + 1] = p.id
  end
  local key = table.concat(ids, ",")
  if buttons and key == stripKey then
    buttons.Paint()
    return
  end
  stripKey = key
  if buttons then
    for _, b in ipairs(buttons) do
      b:Hide()
    end
  end
  buttons = Kit.FilterButtons(strip, list, function()
    return current
  end, function(key)
    Show(key)
    buttons.Paint()
  end)
  buttons.Paint()
end

local function Create()
  local f = CreateFrame("Frame", "ARLEAuctionTab", AuctionHouseFrame)
  f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -62)
  f:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 27)
  f:Hide() -- (LibAHTab shows it when the tab is picked)
  Skin:Panel(f)
  strip = CreateFrame("Frame", nil, f)
  strip:SetPoint("TOPLEFT", 10, -6)
  strip:SetPoint("RIGHT", -100, 0)
  strip:SetHeight(16)
  -- the settings: a shortcut to the Auction House entry in /arl, on the shown panel's page
  local cog = Kit.SmallButton(f, "Settings", 80)
  cog:SetPoint("TOPRIGHT", -10, -6)
  local scriptOwner = Owner()
  scriptOwner:Script(cog, "OnClick", function()
    local page
    for _, p in ipairs(H.panels) do
      if p.id == current then
        page = p.settings
      end
    end
    ARLE:Open(ns.AuctionHouse and ns.AuctionHouse.id or nil, page)
  end)
  scriptOwner:Script(cog, "OnEnter", function(self)
    Kit.SimpleTooltip(self, "Settings", "Opens the Auction House settings in /arl, on this panel's page.")
  end)
  scriptOwner:Script(cog, "OnLeave", GameTooltip_Hide)
  local rule = Kit.Rule(f, 0.15)
  rule:SetPoint("TOPLEFT", 6, -STRIP_H - 1)
  rule:SetPoint("TOPRIGHT", -6, -STRIP_H - 1)
  content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", 0, -STRIP_H - 2)
  content:SetPoint("BOTTOMRIGHT")
  host = f
  local owner = Owner()
  if owner then
    owner:Script(f, "OnShow", function()
      BuildStrip()
      Show(current)
    end)
  end
  return f
end

local function AuctionatorReady()
  local c = rawget(_G, "AuctionatorAHTabsContainer")
  return type(c) == "table" and type(c.Tabs) == "table" and #c.Tabs > 0
end

local function Make(tries)
  waiting = false
  local owner = Owner()
  if host or not owner or not AuctionHouseFrame then
    return
  end
  local lib = Lib()
  if not lib then
    owner:Debug("no LibAHTab-1-0 (Auctionator's): no ARL tab")
    return
  end
  if not AuctionatorReady() and tries < WAIT_MAX and AuctionHouseFrame:IsShown() then
    -- (after Auctionator's tabs, so ours is the last)
    waiting = true
    owner:After(WAIT_STEP, function()
      Make(tries + 1)
    end)
    return
  end
  local f = Create()
  local ok, err = pcall(lib.CreateTab, lib, TAB_ID, f, "ARL", "ARL Extensions")
  if not ok then
    owner:Debug("LibAHTab CreateTab failed: %s", tostring(err))
    return
  end
  owner:Debug("ARL tab added%s", AuctionatorReady() and " after Auctionator's" or "")
end

-- From a feature's AUCTION_HOUSE_SHOW, and when one is turned on with the AH open.
function H.Attach()
  if not host and not waiting then
    Make(0)
  end
  H.Update()
end

-- A feature went on or off (`gone`: the one turning off): the tab's button, the strip, the panel shown.
function H.Update(gone)
  leaving = gone
  local b = Button()
  local any = #Active() > 0
  if b then
    b:SetShown(any)
  end
  if not host then
    if any and AuctionHouseFrame and AuctionHouseFrame:IsShown() and not waiting then
      Make(0)
    end
    leaving = nil
    return
  end
  if not any then
    host:Hide()
    leaving = nil
    return
  end
  BuildStrip()
  if host:IsShown() then
    Show(current)
  end
  leaving = nil
end

-- Is this panel the one on screen?
function H.IsShown(id)
  return host ~= nil and host:IsVisible() and current == id
end
