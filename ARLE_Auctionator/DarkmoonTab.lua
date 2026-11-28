-- Darkmoon Faire: its panel in the ARL tab on the auction house (ARLTab.lua
-- holds the tab; DarkmoonTickets.lua has the data, the costs, the plans and
-- the Faire's dates; this file only draws them). Top: where and when the
-- Faire is (and a map pin); two views, Tickets and Reputation, each with its
-- standing / ticket goal and a plan to it.
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
  item = { 54, 230, "LEFT" },
  each = { 290, 110, "RIGHT" },
  turnin = { 404, 90, "RIGHT" },
  gain = { 498, 80, "RIGHT" },
  per = { 582, 100, "RIGHT" },
  have = { 686, 60, "RIGHT" },
}
local HEADERS = {
  tickets = {
    labels = { rank = "#", item = "Turn-in", each = "Each", turnin = "Per turn-in", gain = "Tickets",
      per = "Per ticket", have = "Have" },
    tips = {
      each = "One item at its cheapest: bought, from a vendor, or crafted from materials.",
      turnin = "What one turn-in costs.",
      gain = "Tickets one turn-in pays (a * means the guide's number: it's learned when you turn one in).",
      per = "Per turn-in over tickets. Green: the cheapest third.",
    },
  },
  rep = {
    labels = { rank = "#", item = "Way", each = "Each", turnin = "Per turn-in", gain = "Reputation",
      per = "Per rep", have = "Have" },
    tips = {
      each = "One item at its cheapest; a deck at the cheaper of the deck and its eight cards.",
      turnin = "What one turn-in (or deck) costs.",
      gain = "100 a turn-in until its tier's cut, 150 a deck with no cut.",
      per = "Per turn-in over reputation. Green: the cheapest third.",
    },
  },
}
local QUALITY_STAR = "|TInterface\\COMMON\\ReputationStar:12:12:0:0:32:32:0:16:0:16|t"
local TICKET_ICON = 134481

local T = {}
ns.DarkmoonTab = T
local D = ns.Darkmoon

local frame, rows = nil, {}
local list, plan = {}, nil

local function F()
  return D.F
end

local function View()
  return F().db.view == "rep" and "rep" or "tickets"
end

local function Money(c)
  return c and Lib.FormatMoney(math.floor(c + 0.5)) or "|cff707070--|r"
end

local function Colored(id, fallback)
  local name, _, quality = Items.GetInfo(id)
  if not name then
    Items.Name(id)
  end
  local r, g, b = Lib.QualityColor(quality or 1)
  return ("|c%s%s|r"):format(Lib.Hex(r, g, b), name or fallback or ("item " .. id))
end

-------------------------------------------------------------------------------
-- Tooltip
-------------------------------------------------------------------------------

local SRC_WORD = { buy = "auction", vendor = "vendor", craft = "craft" }

local function AddNode(node, count, depth)
  if not node then
    return
  end
  local pad = ("   "):rep(depth)
  local how = node.src and SRC_WORD[node.src] or "no price"
  if node.src == "craft" and not node.known then
    how = "craft, a recipe you don't know"
  end
  GameTooltip:AddDoubleLine(("%s%d x %s"):format(pad, count, Colored(node.id)),
    ("%s |cff909090(%s)|r"):format(node.cost and Money(node.cost * count) or "|cffff6060?|r", how), 1, 1, 1, 1, 1, 1)
  if node.src == "craft" and node.parts and depth < 3 then
    for _, part in ipairs(node.parts) do
      AddNode(part.node, part.count * count / (node.yield or 1), depth + 1)
    end
  end
end

local function ShowTip(r)
  local e = r.entry
  if not e then
    return
  end
  GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
  GameTooltip:SetText(Colored(e.id, e.name))
  if e.kind == "deck" then
    GameTooltip:AddLine("Handed to Professor Thaddeus Paleo: 150 Darkmoon Faire reputation and a level 60 trinket. "
      .. "No cut: decks give reputation all the way.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("The deck", Money(e.node and e.node.cost) .. (e.via == "deck" and " |cff40ff40<|r" or ""),
      1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Its 8 cards", Money(e.cardsCost) .. (e.via == "cards" and " |cff40ff40<|r" or ""),
      1, 0.82, 0, 1, 1, 1)
    for _, c in ipairs(e.cards or {}) do
      GameTooltip:AddDoubleLine("   " .. Colored(c.id) .. (c.have > 0 and " |cff80ff80(have)|r" or ""),
        Money(c.node and c.node.cost), 1, 1, 1, 1, 1, 1)
    end
  else
    GameTooltip:AddLine(("Tier %d · %s · %d for %d ticket%s and 100 reputation"):format(e.t.tier, e.t.src, e.qty,
      e.tickets, e.tickets == 1 and "" or "s"), 0.6, 0.9, 1)
    GameTooltip:AddLine(e.learned and "Counts seen in the quest window." or "Counts from the guides (learned when "
      .. "you turn one in).", 0.6, 0.6, 0.6, true)
    if e.capped then
      GameTooltip:AddLine("Your reputation is past this tier's cut: it isn't offered any more.", 1, 0.4, 0.4, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("One turn-in:", 1, 0.82, 0)
    AddNode(e.node, e.qty, 1)
    if e.have > 0 then
      local n = math.floor(e.have / e.qty)
      GameTooltip:AddLine(("You have %d (%d turn-in%s)"):format(e.have, n, n == 1 and "" or "s"), 0.6, 1, 0.6)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine(e.kind == "deck" and "Per deck" or "Per turn-in", Money(e.perTurnIn), 1, 0.82, 0, 1, 1, 1)
  if e.perTicket then
    GameTooltip:AddDoubleLine("Per ticket", Money(e.perTicket), 1, 0.82, 0, 1, 1, 1)
  end
  if e.perRep then
    GameTooltip:AddDoubleLine("Per reputation", Money(e.perRep), 1, 0.82, 0, 1, 1, 1)
  end
  if e.plan then
    GameTooltip:AddLine(("%s In the plan: x%d"):format(QUALITY_STAR, e.planCount or 1), 1, 0.82, 0)
  end
  GameTooltip:AddLine("Click: look up what to buy in Auctionator · Shift-click: link", 0.5, 0.5, 0.5, true)
  GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Shopping through Auctionator
-------------------------------------------------------------------------------

local function ToBuy(node, into)
  if not node then
    return
  end
  if node.src == "buy" then
    into[node.id] = true
  elseif node.src == "craft" then
    for _, part in ipairs(node.parts or {}) do
      ToBuy(part.node, into)
    end
  end
end

local function Shop(entries)
  local ids, names, seen = {}, {}, {}
  for _, e in ipairs(entries) do
    if e.kind == "deck" then
      if e.via == "cards" then
        for _, c in ipairs(e.cards) do
          if c.have == 0 then
            ToBuy(c.node, ids)
          end
        end
      else
        ToBuy(e.node, ids)
      end
    else
      ToBuy(e.node, ids)
    end
  end
  for id in pairs(ids) do
    local name = Items.GetInfo(id)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  if #names == 0 then
    F():Print("nothing to buy there (or the names are still loading: try again).")
    return
  end
  table.sort(names)
  local ok, err = AH.SearchExact(names)
  if not ok then
    F():Print("Auctionator couldn't search: " .. tostring(err or "?"))
  end
end

-- The plan as a buy list (Buyer.lua): the items (less those you have), a craft's materials, or a deck's cards.
local function BuyPlan(entries)
  local B = ns.Buyer
  if not B then
    return
  end
  local into = {}
  for _, e in ipairs(entries) do
    local n = e.planCount or 1
    if e.kind == "deck" then
      if e.via == "cards" then
        for _, c in ipairs(e.cards) do
          B.Collect(c.node, n - (c.have or 0), into)
        end
      else
        B.Collect(e.node, n - (e.have or 0), into)
      end
    else
      B.Collect(e.node, (e.qty or 1) * n - (e.have or 0), into)
    end
  end
  local count, most = B.Load("Darkmoon", into)
  if count == 0 then
    F():Print("nothing to buy in that plan.")
  else
    F():Print(("buy list: %d items, %s at most. Press Buy next (top right) for each purchase."):format(count,
      Lib.FormatMoney(math.floor(most + 0.5))))
  end
end

-------------------------------------------------------------------------------
-- The ticket goal: a prize
-------------------------------------------------------------------------------

local function GoalMenu(owner)
  local current = tonumber(F().db.ticketGoalItem) or 0
  local function set(item, tickets)
    ARLE:SetOption(F().id, "ticketGoalItem", item)
    ARLE:SetOption(F().id, "ticketGoal", tickets)
  end
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    local nextIndex = 1
    for i, p in ipairs(D.PRIZES) do
      if p.id == current then
        nextIndex = i % #D.PRIZES + 1
      end
    end
    local p = D.PRIZES[nextIndex]
    set(p.id, p.tickets)
    return
  end
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle("Save Prize Tickets up for")
    root:CreateRadio("No goal", function()
      return current == 0
    end, function()
      set(0, 0)
    end)
    for _, p in ipairs(D.PRIZES) do
      root:CreateRadio(("%s  |cffffd100%d|r"):format(Colored(p.id, p.name), p.tickets), function()
        return current == p.id
      end, function()
        set(p.id, p.tickets)
      end)
    end
  end)
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

local function Text(parent, col, font)
  local c = COLS[col]
  local fs = Kit.Text(parent, font or "GameFontHighlightSmall")
  fs:SetPoint("LEFT", parent, "LEFT", c[1], 0)
  fs:SetWidth(c[2])
  fs:SetJustifyH(c[3])
  fs:SetWordWrap(false)
  return fs
end

local function MakeRow(parent, i)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  r:SetPoint("RIGHT", parent, "RIGHT")
  r.bg = r:CreateTexture(nil, "BACKGROUND")
  r.bg:SetAllPoints()
  r.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.08)
  r.mark = r:CreateTexture(nil, "ARTWORK")
  r.mark:SetPoint("TOPLEFT")
  r.mark:SetPoint("BOTTOMLEFT")
  r.mark:SetWidth(3)
  r.mark:SetColorTexture(1, 0.82, 0, 0.9)
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
  r.each = Text(r, "each")
  r.each:ClearAllPoints()
  r.each:SetPoint("TOPRIGHT", r, "TOPLEFT", COLS.each[1] + COLS.each[2], -4)
  r.how = Text(r, "each", "GameFontDisableSmall")
  r.how:ClearAllPoints()
  r.how:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", COLS.each[1] + COLS.each[2], 4)
  r.turnin, r.gain = Text(r, "turnin"), Text(r, "gain")
  r.per = Text(r, "per", "GameFontNormal")
  r.have = Text(r, "have")
  F():Script(r, "OnEnter", ShowTip)
  F():Script(r, "OnLeave", GameTooltip_Hide)
  F():Script(r, "OnClick", function(self)
    local e = self.entry
    if not e then
      return
    end
    if IsModifiedClick("CHATLINK") then
      local _, link = Items.GetInfo(e.id)
      if link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(link)
      end
    else
      Shop({ e })
    end
  end)
  return r
end

local function HowWord(e)
  if e.kind == "deck" then
    return e.via == "cards" and "|cff80c0ffits 8 cards|r" or e.via and "auction" or "|cffff6060no price|r"
  end
  local n = e.node
  if not (n and n.src) then
    return "|cffff6060no price|r"
  elseif n.src == "craft" then
    return n.known and "|cff80c0ffcraft|r" or "|cffc080ffcraft (someone else)|r"
  elseif n.src == "vendor" then
    return "vendor"
  end
  return "auction"
end

local function Paint(r, e, i, band, view)
  r.entry = e
  r.mark:SetShown(e.plan == true)
  r.rank:SetText(e.plan and ("|cffffd100" .. i .. "|r") or tostring(i))
  r.icon:SetTexture(e.icon or 134400)
  local dim = view == "tickets" and e.capped
  r.icon:SetDesaturated(dim)
  r.item:SetText(dim and ("|cff808080" .. (e.name or "?") .. "|r") or Colored(e.id, e.name))
  local sub
  if e.kind == "deck" then
    sub = "Card deck · Professor Thaddeus Paleo"
  else
    sub = ("Tier %d · %s%s"):format(e.t.tier, e.t.src, e.capped and " · |cffff6060past your reputation|r" or "")
  end
  if e.planCount and e.planCount > 1 then
    sub = sub .. " · |cffffd100x" .. e.planCount .. "|r"
  end
  r.sub:SetText(sub)
  r.each:SetText(e.kind == "deck" and Money(e.cost) or Money(e.unit))
  r.how:SetText(HowWord(e))
  r.turnin:SetText((e.kind == "turnin" and (e.qty .. " x  ") or "") .. Money(e.perTurnIn))
  if view == "rep" then
    r.gain:SetText(e.kind == "deck" and "150" or (e.capped and "|cff8080800|r" or "100"))
  else
    r.gain:SetText(e.tickets .. (e.learned and "" or "*"))
  end
  local value = view == "rep" and e.perRep or e.perTicket
  local color = band == 1 and "|cff40ff40" or band == 2 and "|cffffff40" or band == 3 and "|cffff9040" or "|cffb0b0b0"
  r.per:SetText(value and (color .. Lib.FormatMoney(math.floor(value + 0.5)):gsub("|r", "|r" .. color) .. "|r")
    or Money(nil))
  local qty = e.qty or 1
  r.have:SetText(e.have > 0 and (e.have >= qty and ("|cff40ff40" .. e.have .. "|r") or tostring(e.have)) or "-")
  r:SetAlpha(dim and 0.6 or 1)
  r:Show()
end

local function Cuts(entries, key, view)
  local priced = {}
  for _, e in ipairs(entries) do
    if e[key] and not (view == "tickets" and e.capped) then
      priced[#priced + 1] = e[key]
    end
  end
  table.sort(priced)
  return priced[math.max(1, math.floor(#priced / 3))], priced[math.max(1, math.floor(#priced * 2 / 3))]
end

local function RealRefresh()
  if not (frame and frame:IsVisible()) then
    return
  end
  local db = F().db
  local view = View()
  frame.views.Paint()
  frame.cappedCB:SetChecked(db.hideCapped == true)
  frame.bankCB:SetChecked(db.includeBank ~= false)
  local h = HEADERS[view]
  for col, fs in pairs(frame.headers) do
    fs:SetText(h.labels[col] or "")
  end

  local fair = D.Faire()
  frame.faire:SetText(D.FaireText(fair))

  local all, st = D.Evaluate()
  local tickets, ticketIcon = D.Tickets()
  frame.tickets:SetText(("|T%d:14:14:0:0|t %s Prize Tickets"):format(ticketIcon or TICKET_ICON,
    tickets and tostring(tickets) or "?"))
  local need, rep = nil, st and st.value
  if view == "rep" then
    frame.goalBtn:Hide()
    frame.bar:ClearAllPoints()
    frame.bar:SetPoint("TOPLEFT", 10, -54)
    if st and st.reaction then
      frame.camp:SetText(("%s · |cffffffff%s|r"):format(st.name or "Darkmoon Faire", st.label or "?"))
      if st.into and st.size and st.size > 0 then
        frame.bar:SetMinMaxValues(0, st.size)
        frame.bar:SetValue(st.into)
        frame.bar:SetStatusBarColor(0.6, 0.3, 0.9)
        frame.bar:Show()
        frame.barText:SetText(st.toNext and ("%d / %d · %d to %s"):format(st.into, st.size, st.toNext,
          st.nextLabel or "the next standing") or ("%d / %d"):format(st.into, st.size))
      else
        frame.bar:Hide()
        frame.barText:SetText("")
      end
      need = st.toNext
    else
      frame.camp:SetText("Darkmoon Faire: no standing read yet")
      frame.bar:Hide()
      frame.barText:SetText("")
    end
  else
    frame.camp:SetText("")
    frame.goalBtn:Show()
    local goal = tonumber(db.ticketGoal) or 0
    if goal > 0 then
      frame.goalBtn:SetText("Goal: " .. ((Items.GetInfo(db.ticketGoalItem)) or (goal .. " tickets")))
      frame.bar:ClearAllPoints()
      frame.bar:SetPoint("LEFT", frame.goalBtn, "RIGHT", 8, 0)
      frame.bar:SetMinMaxValues(0, goal)
      frame.bar:SetValue(math.min(goal, tickets or 0))
      frame.bar:SetStatusBarColor(0.9, 0.7, 0.1)
      frame.bar:Show()
      need = math.max(0, goal - (tickets or 0))
      frame.barText:SetText(need > 0 and ("%d / %d · %d to go"):format(tickets or 0, goal, need)
        or "|cff80ff80You have enough|r")
    else
      frame.goalBtn:SetText("Save up for...")
      frame.bar:Hide()
      frame.barText:SetText("")
    end
  end

  local sorted, key = D.Sorted(all, view)
  plan = D.Plan(sorted, view, need, rep)
  wipe(list)
  for _, e in ipairs(sorted) do
    list[#list + 1] = e
  end
  local cut1, cut2 = Cuts(list, key, view)
  local child = frame.child
  child:SetWidth(frame.scroll:GetWidth())
  for i, e in ipairs(list) do
    local r = rows[i] or MakeRow(child, i)
    rows[i] = r
    local band
    if e[key] and not (view == "tickets" and e.capped) then
      band = (cut1 and e[key] <= cut1) and 1 or (cut2 and e[key] <= cut2) and 2 or 3
    end
    Paint(r, e, i, band, view)
  end
  for i = #list + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  child:SetHeight(math.max(1, #list * ROW_H))

  local priced = false
  for _, e in ipairs(list) do
    priced = priced or e[key] ~= nil
  end
  if not priced then
    frame.empty:SetText("No prices yet: run a full scan (Auctionator's, or Scan on the Snipes panel) and these "
      .. "fill in.")
    frame.empty:Show()
  else
    frame.empty:Hide()
  end
  if plan.count > 0 then
    local what = view == "rep" and ("to %s (%d rep)"):format(st and st.nextLabel or "the next standing", need)
      or ("to %d more tickets"):format(need)
    frame.plan:SetText(("%s Plan %s: |cffffffff%d %s|r for |cffffffff%s|r%s"):format(QUALITY_STAR, what, plan.count,
      plan.count == 1 and "turn-in" or (view == "rep" and "turn-ins and decks" or "turn-ins"),
      Lib.FormatMoney(math.floor(plan.cost)),
      plan.short and " |cffff9040(not enough priced)|r" or ""))
    frame.shopBtn:Show()
  else
    frame.plan:SetText(view == "tickets" and (tonumber(db.ticketGoal) or 0) == 0
      and "|cff909090Pick a prize to save up for and the plan counts the cheapest turn-ins to it.|r" or "")
    frame.shopBtn:Hide()
  end
end

function T.Refresh()
  if frame and frame:IsVisible() then
    F():Debounce("dmf.refresh", 0.15, RealRefresh)
  end
end

local function Check(parent, key, label, tip)
  local cb = Kit.Check(parent)
  local text = Kit.Text(parent, "GameFontHighlightSmall")
  text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  text:SetText(label)
  F():Script(cb, "OnClick", function(self)
    ARLE:SetOption(F().id, key, self:GetChecked() and true or false)
  end)
  F():Script(cb, "OnEnter", function(self)
    Kit.SimpleTooltip(self, label, tip)
  end)
  F():Script(cb, "OnLeave", GameTooltip_Hide)
  return cb, text
end

local function Tip(widget, title, text)
  F():Script(widget, "OnEnter", function(self)
    Kit.SimpleTooltip(self, title, text)
  end)
  F():Script(widget, "OnLeave", GameTooltip_Hide)
end

local function Create(parent)
  local f = CreateFrame("Frame", "ARLEDarkmoonPanel", parent)
  frame = f

  -- where and when
  f.faire = Kit.Text(f, "GameFontNormal")
  f.faire:SetPoint("TOPLEFT", 10, -8)
  f.pinBtn = Kit.Button(f, "Map pin", 80)
  f.pinBtn:SetPoint("TOPRIGHT", -10, -4)
  F():Script(f.pinBtn, "OnClick", function()
    D.Pin()
  end)
  Tip(f.pinBtn, "Map pin", "Puts a pin on your map where the Faire stands (or will).")
  f.faire:SetPoint("RIGHT", f.pinBtn, "LEFT", -8, 0)
  f.faire:SetWordWrap(false)

  -- the views, the tickets held, the standing or the goal
  local bar = CreateFrame("Frame", nil, f)
  bar:SetPoint("TOPLEFT", 10, -30)
  bar:SetSize(220, 18)
  f.views = Kit.FilterButtons(bar, {
    { key = "tickets", label = "Prize Tickets", width = 100,
      tip = "Turn-ins by gold per Prize Ticket, and a plan to a prize." },
    { key = "rep", label = "Reputation", width = 90,
      tip = "Turn-ins and card decks by gold per Darkmoon Faire reputation, and a plan to your next standing." },
  }, View, function(key)
    ARLE:SetOption(F().id, "view", key)
    RealRefresh()
  end)
  f.camp = Kit.Text(f, "GameFontNormal")
  f.camp:SetPoint("LEFT", bar, "LEFT", 200, 0)
  f.tickets = Kit.Text(f, "GameFontHighlight")
  f.tickets:SetPoint("TOPRIGHT", -12, -32)

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetSize(260, 10)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  local barBg = f.bar:CreateTexture(nil, "BACKGROUND")
  barBg:SetAllPoints()
  barBg:SetColorTexture(0, 0, 0, 0.5)
  f.barText = Kit.Text(f, "GameFontHighlightSmall")
  f.barText:SetPoint("LEFT", f.bar, "RIGHT", 8, 0)
  f.goalBtn = Kit.Button(f, "Save up for...", 170)
  f.goalBtn:SetPoint("TOPLEFT", 10, -50)
  F():Script(f.goalBtn, "OnClick", function(self)
    GoalMenu(self)
  end)
  Tip(f.goalBtn, "Ticket goal", "Pick a prize from Gelvas Grimegate: the plan counts the cheapest turn-ins to it.")

  -- the plan
  f.shopBtn = Kit.Button(f, "Shopping List", 110)
  f.shopBtn:SetPoint("TOPRIGHT", -10, -72)
  F():Script(f.shopBtn, "OnClick", function()
    local picked = {}
    for _, e in ipairs(list) do
      if e.plan then
        picked[#picked + 1] = e
      end
    end
    Shop(picked)
  end)
  Tip(f.shopBtn, "Shopping List", "Searches Auctionator's Shopping tab for what the plan buys (the items, the "
    .. "materials of the ones you craft, or a deck's cards).")
  f.buyBtn = Kit.Button(f, "Buy the plan", 100)
  f.buyBtn:SetPoint("RIGHT", f.shopBtn, "LEFT", -6, 0)
  F():Script(f.buyBtn, "OnClick", function()
    local picked = {}
    for _, e in ipairs(list) do
      if e.plan then
        picked[#picked + 1] = e
      end
    end
    BuyPlan(picked)
  end)
  Tip(f.buyBtn, "Buy the plan", "Puts what the plan buys in the buy list, in the quantities it needs; then each "
    .. "press of Buy next (top right, or its key) buys the next one, never over the plan's price plus the margin "
    .. "set under Settings > Buying.")
  f.plan = Kit.Text(f, "GameFontNormal")
  f.plan:SetPoint("TOPLEFT", 10, -78)
  f.plan:SetPoint("RIGHT", f.buyBtn, "LEFT", -8, 0)
  f.plan:SetWordWrap(false)

  -- column headers
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", 6, -98)
  header:SetPoint("RIGHT", -28, 0)
  header:SetHeight(16)
  f.headers = {}
  local ar, ag, ab = Skin:Accent()
  for col in pairs(COLS) do
    local fs = Text(header, col, "GameFontNormalSmall")
    fs:SetTextColor(ar, ag, ab)
    f.headers[col] = fs
    local hit = CreateFrame("Frame", nil, header)
    hit:SetAllPoints(fs)
    F():Script(hit, "OnEnter", function(self)
      local hd = HEADERS[View()]
      if hd.tips[col] then
        Kit.SimpleTooltip(self, hd.labels[col], hd.tips[col])
      end
    end)
    F():Script(hit, "OnLeave", GameTooltip_Hide)
  end
  local rule = Kit.Rule(f, 0.15)
  rule:SetPoint("TOPLEFT", 6, -115)
  rule:SetPoint("TOPRIGHT", -6, -115)

  f.scroll, f.child = Kit.Scroll(f)
  f.scroll:SetPoint("TOPLEFT", 6, -118)
  f.scroll:SetPoint("BOTTOMRIGHT", -28, 30)
  f.empty = Kit.Text(f, "GameFontDisable")
  f.empty:SetPoint("CENTER", f.scroll, "CENTER")
  f.empty:SetWidth(420)
  f.empty:SetJustifyH("CENTER")

  local cb1, t1 = Check(f, "hideCapped", "Hide past my reputation",
    "Hide the turn-ins whose tier your reputation is past (they aren't offered any more).")
  cb1:SetPoint("BOTTOMLEFT", 6, 2)
  local cb2 = Check(f, "includeBank", "Count bank items", "What you have counts your bank too.")
  cb2:SetPoint("LEFT", t1, "RIGHT", 16, 0)
  f.cappedCB, f.bankCB = cb1, cb2

  F():Script(f, "OnShow", RealRefresh)
  return f
end

ns.ARLTab.Register({ id = "darkmoon", title = "Darkmoon", order = 3, width = 80, feature = D.F, settings = "darkmoon",
  tip = "The Darkmoon Faire: where and when, and the cheapest Prize Tickets and reputation.", build = Create })

function T.Attach()
  ns.ARLTab.Attach()
end

function T.Enable()
  ns.ARLTab.Update()
end

function T.Disable()
  ns.ARLTab.Update(D.F)
end
