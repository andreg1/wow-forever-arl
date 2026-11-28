-- Snipes: its panel in the ARL tab on the auction house (ARLTab.lua holds the
-- tab; Snipes.lua scans and reads Auctionator's scans; this file only draws the result). One
-- row per item selling below vendor price: the cheapest each, the vendor's
-- price, what buying them all costs and what vendoring them pays. A click
-- searches Auctionator's Shopping tab, right-click hides an item.
local ADDON, ns = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib, Items, Kit, Skin = ARLE.Lib, ARLE.Lib.Items, ARLE.UI.Kit, ARLE.Skin
local AH = ARLE.Bridge.Auctionator

local ROW_H = 32
local COLS = { -- x, width, justify
  rank = { 2, 20, "RIGHT" },
  item = { 54, 250, "LEFT" },
  best = { 310, 90, "RIGHT" },
  vendor = { 404, 90, "RIGHT" },
  cost = { 498, 90, "RIGHT" },
  profit = { 592, 100, "RIGHT" },
  pct = { 696, 60, "RIGHT" },
}
local LABELS = { rank = "#", item = "Item", best = "Cheapest each", vendor = "Vendor each", cost = "Buy all",
  profit = "Profit", pct = "Return" }
local TIPS = { -- (a row not checked yet says "up to": as if all listed were at the cheapest price)
  best = "The lowest buyout per item among the auctions below vendor price.",
  vendor = "What a vendor pays for one.",
  cost = "What buying every auction listed here costs.",
  profit = "What a vendor pays for them all, minus what they cost.",
  pct = "Profit over cost.",
}

local T = {}
ns.SnipesTab = T
local S = ns.Snipes

local frame, rows = nil, {}
local shown = {}

local function F()
  return S.F
end

local function Money(c)
  return c and Lib.FormatMoney(math.floor(c + 0.5)) or "|cff707070--|r"
end

local function Name(row)
  local name, link, quality = Items.GetInfo(row.id)
  if not name then
    Items.Name(row.id)
    local fromLink = type(row.link) == "string" and row.link:match("%[(.-)%]")
    return fromLink or ("item " .. row.id), 1
  end
  return name, quality or 1, link
end

local function Colored(row)
  local name, quality = Name(row)
  local r, g, b = Lib.QualityColor(quality)
  return ("|c%s%s|r"):format(Lib.Hex(r, g, b), name)
end

local function Shop(list)
  local names, seen = {}, {}
  for _, row in ipairs(list) do
    local name = Name(row)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  if #names == 0 then
    F():Print("nothing to buy there.")
    return
  end
  local ok, err = AH.SearchExact(names)
  if not ok then
    F():Print("Auctionator couldn't search: " .. tostring(err or "?"))
  end
end

local function ShowTip(r)
  local row = r.entry
  if not row then
    return
  end
  GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
  if row.link and GameTooltip.SetHyperlink then
    pcall(GameTooltip.SetHyperlink, GameTooltip, row.link)
  else
    GameTooltip:SetText(Colored(row))
  end
  GameTooltip:AddLine(" ")
  if row.exact then
    GameTooltip:AddLine(("%d auction%s below vendor price (%s each at a vendor):"):format(row.n,
      row.n == 1 and "" or "s", Money(row.vendor)), 1, 0.82, 0)
    for _, a in ipairs(row.auctions) do
      GameTooltip:AddDoubleLine(("   %d x  %s each"):format(a.count, Money(a.unit)),
        ("|cff40ff40+%s|r"):format(Money(a.profit)), 1, 1, 1, 1, 1, 1)
    end
    if row.n > #row.auctions then
      GameTooltip:AddLine(("   and %d more"):format(row.n - #row.auctions), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Buy them all", Money(row.cost), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("A vendor pays", Money(row.vendor * row.count), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit", Money(row.profit), 1, 0.82, 0, 0.25, 1, 0.25)
  else
    GameTooltip:AddDoubleLine("Cheapest", Money(row.best) .. " each", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("A vendor pays", Money(row.vendor) .. " each", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Profit", Money(row.each) .. " each", 1, 0.82, 0, 0.25, 1, 0.25)
    GameTooltip:AddDoubleLine("Listed", tostring(row.count), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(("Up to %s if all %d are at the cheapest price: the scan only gives the cheapest. Click "
      .. "to see each auction in Auctionator, or Check top %d."):format(Money(row.profit), row.count,
      S.CHECK_TOP or 20), 1, 0.6, 0.25, true)
  end
  if row.own then
    GameTooltip:AddLine("You have auctions of this too.", 0.6, 0.8, 1, true)
  end
  GameTooltip:AddLine("From the last scan: some may be sold already.", 0.6, 0.6, 0.6, true)
  GameTooltip:AddLine("Click: look it up in Auctionator · Shift-click: link · Right-click: hide this item", 0.5, 0.5,
    0.5, true)
  GameTooltip:Show()
end

local function Text(parent, col, font)
  local c = COLS[col]
  local fs = Kit.Text(parent, font or "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", c[1], 0)
  fs:SetWidth(c[2])
  fs:SetJustifyH(c[3])
  fs:SetWordWrap(false)
  return fs
end

local RealRefresh

local function MakeRow(parent, i)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("RIGHT", parent, "RIGHT")
  r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.08)
  r.rank = Text(r, "rank")
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(26, 26)
  r.icon:SetPoint("LEFT", 26, 0)
  r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  r.item = Text(r, "item", "GameFontHighlight")
  r.item:ClearAllPoints()
  r.item:SetPoint("TOPLEFT", COLS.item[1], -3)
  r.sub = Text(r, "item", "GameFontDisableSmall")
  r.sub:ClearAllPoints()
  r.sub:SetPoint("BOTTOMLEFT", COLS.item[1], 4)
  r.best, r.vendor, r.cost = Text(r, "best"), Text(r, "vendor"), Text(r, "cost")
  r.profit = Text(r, "profit", "GameFontNormal")
  r.pct = Text(r, "pct")
  F():Script(r, "OnEnter", ShowTip)
  F():Script(r, "OnLeave", GameTooltip_Hide)
  F():Script(r, "OnClick", function(self, button)
    local row = self.entry
    if not row then
      return
    end
    if button == "RightButton" then
      S.Hidden()[row.id] = true
      GameTooltip_Hide()
      RealRefresh()
    elseif IsModifiedClick("CHATLINK") then
      local _, _, link = Name(row)
      link = row.link or link
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
    else
      Shop({ row })
    end
  end)
  return r
end

local function Paint(r, row, i)
  r.entry = row
  r.rank:SetText(tostring(i))
  r.icon:SetTexture(Items.GetIcon and Items.GetIcon(row.id) or 134400)
  r.item:SetText(Colored(row))
  if row.exact then
    r.sub:SetText(("|cff80ff80checked|r · %d auction%s · %d item%s"):format(row.n, row.n == 1 and "" or "s",
      row.count, row.count == 1 and "" or "s"))
  else
    r.sub:SetText(("%d listed · %s profit each"):format(row.count, Money(row.each)))
  end
  local upTo = row.exact and "" or "|cff909090up to|r "
  r.best:SetText(Money(row.best))
  r.vendor:SetText(Money(row.vendor))
  r.cost:SetText(upTo .. Money(row.cost))
  r.profit:SetText(upTo .. "|cff40ff40" .. Money(row.profit):gsub("|r", "|r|cff40ff40") .. "|r")
  r.pct:SetText(row.best > 0 and ("%d%%"):format(math.floor(row.each / row.best * 100 + 0.5)) or "")
  r:Show()
end

RealRefresh = function()
  if not (frame and frame:IsVisible()) then
    return
  end
  local s = S.Store()
  local hidden = S.Hidden()
  local nHidden = 0
  for _ in pairs(hidden) do
    nHidden = nHidden + 1
  end
  wipe(shown)
  local profit, cost, upTo = 0, 0, false
  for _, row in ipairs(s.rows) do
    if not hidden[row.id] then
      shown[#shown + 1] = row
      profit, cost = profit + row.profit, cost + row.cost
      upTo = upTo or not row.exact
    end
  end
  local doing = S.Doing()
  if doing then
    frame.status:SetText(doing)
  elseif s.at and s.at > 0 then
    frame.status:SetText(("Last scan %s ago · %d items checked%s"):format(Lib.FormatDuration(time() - s.at),
      s.total or 0, s.partial and " |cffff9040(partial)|r" or ""))
  else
    frame.status:SetText("|cffff9040Not scanned yet|r")
  end
  frame.summary:SetText(#shown > 0 and ("|cffffffff%d item%s|r · buy all for %s|cffffffff%s|r · vendor profit "
    .. "%s|cff40ff40%s|r"):format(#shown, #shown == 1 and "" or "s", upTo and "up to " or "",
    Lib.FormatMoney(math.floor(cost)), upTo and "up to " or "", Lib.FormatMoney(math.floor(profit))) or "")
  frame.shopBtn:SetShown(#shown > 0)
  local unchecked = 0
  for _, row in ipairs(shown) do
    if not row.exact and row.key then
      unchecked = unchecked + 1
    end
  end
  frame.checkBtn:SetShown(unchecked > 0 and not S.Busy())
  frame.unhide:SetShown(nHidden > 0)
  frame.unhide:SetText(("Unhide %d"):format(nHidden))
  frame.scanBtn:SetText(S.Busy() and "Stop" or "Scan")

  local child = frame.child
  child:SetWidth(frame.scroll:GetWidth())
  for i, row in ipairs(shown) do
    local r = rows[i] or MakeRow(child, i)
    rows[i] = r
    Paint(r, row, i)
  end
  for i = #shown + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  child:SetHeight(math.max(1, #shown * ROW_H))
  if #shown == 0 then
    frame.empty:SetText((s.at and s.at > 0) and "Nothing below vendor price in the last scan."
      or "Click Scan (or run Auctionator's full scan): every auction selling for less than a vendor pays shows up "
      .. "here.")
    frame.empty:Show()
  else
    frame.empty:Hide()
  end
end

function T.Refresh()
  if frame and frame:IsVisible() then
    F():Debounce("snipes.refresh", 0.15, RealRefresh)
  end
end

local function Tip(widget, title, text)
  F():Script(widget, "OnEnter", function(self)
    Kit.SimpleTooltip(self, title, text)
  end)
  F():Script(widget, "OnLeave", GameTooltip_Hide)
end

local function Create(parent)
  local f = CreateFrame("Frame", "ARLESnipesPanel", parent)
  frame = f

  f.status = Kit.Text(f, "GameFontNormal")
  f.status:SetPoint("TOPLEFT", 10, -8)
  f.summary = Kit.Text(f, "GameFontHighlightSmall")
  f.summary:SetPoint("TOPLEFT", 10, -28)

  f.scanBtn = Kit.Button(f, "Scan", 90)
  f.scanBtn:SetPoint("TOPRIGHT", -10, -6)
  F():Script(f.scanBtn, "OnClick", function()
    if S.Busy() then
      S.Stop("stopped")
    else
      local ok, err = S.Scan()
      if not ok then
        F():Print("can't scan: " .. tostring(err) .. ".")
      end
    end
    RealRefresh()
  end)
  Tip(f.scanBtn, "Scan", "Searches the whole auction house, then looks up every item selling below its vendor "
    .. "price to find each cheap auction. Auctionator's own full scan fills this list too.")
  f.shopBtn = Kit.Button(f, "Shop all", 90)
  f.shopBtn:SetPoint("RIGHT", f.scanBtn, "LEFT", -6, 0)
  F():Script(f.shopBtn, "OnClick", function()
    Shop(shown)
  end)
  f.checkBtn = Kit.Button(f, ("Check top %d"):format(S.CHECK_TOP or 20), 100)
  f.checkBtn:SetPoint("RIGHT", f.shopBtn, "LEFT", -6, 0)
  F():Script(f.checkBtn, "OnClick", function()
    local ok, err = S.CheckTop()
    if not ok then
      F():Print("can't: " .. tostring(err) .. ".")
    end
    RealRefresh()
  end)
  Tip(f.checkBtn, "Check top", "Looks the top rows up one by one to see each auction under vendor price (and leave "
    .. "yours out). The scan alone only knows each item's cheapest price; this takes a second or two per item.")
  Tip(f.shopBtn, "Shop all", "Searches Auctionator's Shopping tab for every item listed here; buy the auctions "
    .. "under the vendor price shown.")

  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", 6, -48)
  header:SetPoint("RIGHT", -28, 0)
  header:SetHeight(16)
  local ar, ag, ab = Skin:Accent()
  for col, label in pairs(LABELS) do
    local fs = Text(header, col, "GameFontNormalSmall")
    fs:SetText(label)
    fs:SetTextColor(ar, ag, ab)
    if TIPS[col] then
      local hit = CreateFrame("Frame", nil, header)
      hit:SetAllPoints(fs)
      Tip(hit, label, TIPS[col])
    end
  end
  local rule = Kit.Rule(f, 0.15)
  rule:SetPoint("TOPLEFT", 6, -65)
  rule:SetPoint("TOPRIGHT", -6, -65)

  f.scroll, f.child = Kit.Scroll(f)
  f.scroll:SetPoint("TOPLEFT", 6, -68)
  f.scroll:SetPoint("BOTTOMRIGHT", -28, 30)
  f.empty = Kit.Text(f, "GameFontDisable")
  f.empty:SetPoint("CENTER", f.scroll, "CENTER")
  f.empty:SetWidth(420)
  f.empty:SetJustifyH("CENTER")

  f.note = Kit.Text(f, "GameFontDisableSmall")
  f.note:SetPoint("BOTTOMLEFT", 10, 10)
  f.note:SetText("Buying has no fee and a vendor's price never changes: what's listed here is a sure profit, "
    .. "if it's still for sale.")
  f.unhide = Kit.Button(f, "Unhide", 90)
  f.unhide:SetPoint("BOTTOMRIGHT", -10, 4)
  F():Script(f.unhide, "OnClick", function()
    wipe(S.Hidden())
    RealRefresh()
  end)
  Tip(f.unhide, "Unhide", "Shows the items you hid with a right-click again.")

  F():Script(f, "OnShow", RealRefresh)
  return f
end

ns.ARLTab.Register({ id = "snipes", title = "Snipes", order = 2, width = 70, feature = S.F, settings = "snipes",
  tip = "Auctions selling below vendor price, from Auctionator's last full scan.", build = Create })

function T.Attach()
  ns.ARLTab.Attach()
end

function T.Enable()
  ns.ARLTab.Update()
end

function T.Disable()
  ns.ARLTab.Update(S.F)
end
