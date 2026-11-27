-- Auto Mail: sends chosen bag items to chosen characters at a mailbox.
--
-- Our own code, against Blizzard's mail API only (no other addon needed).
-- Rules live in this character's settings (db.rules, a panel list), so
-- "Copy to all characters" gives every alt the same list; a rule naming the
-- character itself is skipped. A rule is "<item> = <character>" where <item>
-- is an item ID, an exact item name, or a name with * wildcards ("* Cloth").
--
-- Names: Forever's mail needs "First Surname" (EllesmereUI's mail alts note
-- this too). Every character that runs ARL records its full name in
-- shared.alts, so a rule may name just the first name of one of them.
--
-- Sending: on MAIL_SHOW (auto, Shift skips) or the card's Send button, the
-- bags are scanned; per recipient, up to ATTACHMENTS_MAX_SEND stacks go into
-- one mail (PickupContainerItem + ClickSendMailItemButton, SendMail), and the
-- next mail only after MAIL_SEND_SUCCESS. MAIL_FAILED, a mail error or a
-- timeout stops that recipient and clears what we attached. Never mailed:
-- soulbound items, items Item Lock protects (its padlocks and gear sets),
-- items the cursor holds. If the Send Mail tab already holds attachments the
-- player put there, nothing is touched. Nothing protected is called.
local ADDON = ...
local ARLE = _G.ARLExtensions
if not ARLE then
  return
end
local Lib = ARLE.Lib
local Items = Lib.Items
local Kit = ARLE.UI.Kit

local MAX_ATTACH = 12      -- stacks per mail when the client has no ATTACHMENTS_MAX_SEND
local SEND_GAP = 0.6       -- seconds between one mail's success and the next
local SEND_TIMEOUT = 15    -- seconds to wait for the server's answer
local AUTO_DELAY = 0.4     -- seconds after the mailbox opens before an auto run
local ALT_DAYS = 120       -- a character's name is forgotten after this many days unseen
local SUBJECT_MAX = 60

local F = {
  id = "AutoMail",
  addon = ADDON,
  title = "Auto Mail",
  group = "QualityOfLife",
  command = "mail",
  commandHelp = "mails chosen items to chosen characters at a mailbox",
  description = "Sends the items you pick to the characters you pick as soon as you open a mailbox "
    .. "(hold Shift to skip), or with the card's Send button. Soulbound and locked items stay.",
  options = {
    { type = "info", text = function(def) return def:GetStatus() end },
    { key = "rules", type = "list", label = "Rules: item = character", add = "Add", default = {},
      empty = "(none: add e.g. \"Linen Cloth = Bank Alt\", \"* Cloth = Bank Alt\" or an item ID)",
      format = function(v, def) return def:FormatRule(v) end },
    { key = "auto", type = "boolean", label = "Send as soon as I open a mailbox", default = true },
    { key = "card", type = "boolean", label = "Show a card at the mailbox with what goes where", default = true },
    { key = "chat", type = "boolean", label = "Say in chat what was sent", default = true },
  },
}

local mailOpen = false
local plan = {}         -- { { to = "First Surname", stacks = { { bag, slot, itemID, count } } } }
local run = nil         -- { queue = plan, i = recipient index, pending = { to, slots, at }, sent = {} }
local runGen = 0        -- bumped to drop the timers of a finished or stopped run
local closedCard = false
local card
local lastRun = {}      -- lines for /arl report
local MAIL_ERRORS = {}

local function MaxAttach()
  return tonumber(_G.ATTACHMENTS_MAX_SEND) or MAX_ATTACH
end

local function Log(fmt, ...)
  local line = string.format(fmt, ...)
  lastRun[#lastRun + 1] = date("%H:%M:%S ") .. line
  if #lastRun > 40 then
    table.remove(lastRun, 1)
  end
  F:Debug("%s", line)
end

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------

local function Alts()
  local t = F.shared.alts
  if type(t) ~= "table" then
    t = {}
    F.shared.alts = t
  end
  return t
end

local function NoteMe()
  local me = ARLE:MyName()
  if type(me) == "string" and me:find(" ") then
    local _, class = UnitClass("player")
    Alts()[me] = { class = class, seen = time() }
  end
  local cutoff = time() - ALT_DAYS * 86400
  for name, info in pairs(Alts()) do
    if type(info) ~= "table" or (tonumber(info.seen) or 0) < cutoff then
      Alts()[name] = nil
    end
  end
end

-- The full name mail needs: as typed when it has a surname, else the one
-- ARL character whose first name it is.
local function Resolve(name)
  name = Lib.Trim(name)
  if name == "" or name:find(" ") then
    return name, true
  end
  local want, found = name:lower(), nil
  for full in pairs(Alts()) do
    if (full:match("^(%S+)") or ""):lower() == want then
      if found then
        return name, false -- two alts share that first name
      end
      found = full
    end
  end
  if found then
    return found, true
  end
  return name, false
end

local function IsMe(name)
  return name:lower() == (ARLE:MyName() or ""):lower()
end

-------------------------------------------------------------------------------
-- Rules
-------------------------------------------------------------------------------

local function Pattern(text)
  local escaped = text:lower():gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  return "^" .. escaped:gsub("%*", ".*") .. "$"
end

-- "<item> = <character>" (also "->" or " to ") -> rule, or nil + why.
local function ParseRule(text)
  text = Lib.Trim(text)
  local item, to = text:match("^(.-)%s*=%s*(.+)$")
  if not item then
    item, to = text:match("^(.-)%s*%->%s*(.+)$")
  end
  if not item then
    item, to = text:match("^(.-)%s+[Tt][Oo]%s+(.+)$")
  end
  item, to = Lib.Trim(item), Lib.Trim(to)
  if item == "" or to == "" then
    return nil, "write it as item = character"
  end
  local rule = { text = text, typed = to }
  rule.to, rule.known = Resolve(to)
  local id = Items.IDFromLink(item) or tonumber(item:match("^item:(%d+)$") or item:match("^#?(%d+)$") or "")
  if id then
    rule.id = id
  elseif item:find("%*") then
    rule.pattern = Pattern(item)
    rule.label = item
  else
    rule.name = (item:match("%[(.-)%]") or item):lower()
    rule.label = item:match("%[(.-)%]") or item
  end
  return rule
end

local function Rules()
  local list = {}
  for _, text in ipairs(F.db.rules or {}) do
    local rule = ParseRule(text)
    if rule then
      list[#list + 1] = rule
    end
  end
  return list
end

local function Matches(rule, itemID, name)
  if rule.id then
    return rule.id == itemID
  end
  if not name then
    return false
  end
  name = name:lower()
  if rule.pattern then
    return name:match(rule.pattern) ~= nil
  end
  return rule.name == name
end

function F:FormatRule(text)
  local rule, why = ParseRule(text)
  if not rule then
    return "|cffff6060" .. tostring(text) .. "|r  |cff888888(" .. why .. ")|r"
  end
  local item = rule.id and Items.Link(rule.id) or ("|cffffffff" .. rule.label .. "|r")
  local to = rule.to
  if IsMe(to) then
    to = to .. " |cff888888(this character: skipped here)|r"
  elseif not rule.known then
    to = to .. " |cffffd100(add the surname: mail needs \"First Surname\")|r"
  end
  return item .. "  |cff888888->|r  " .. to
end

-------------------------------------------------------------------------------
-- Bags
-------------------------------------------------------------------------------

local function Protected(itemID)
  local lock = ARLE.modules and ARLE.modules.ItemLock
  return lock and lock.IsProtected and lock:IsProtected(itemID) or false
end

local function SlotInfo(bag, slot)
  local info = Lib.Call(C_Container.GetContainerItemInfo, bag, slot)
  if not Lib.Readable(info) then
    return nil
  end
  return info
end

-- Builds the plan from the bags: recipients in rule order, each with its stacks.
local function BuildPlan()
  plan = {}
  if not (C_Container and C_Container.GetContainerNumSlots) then
    return plan
  end
  local rules = Rules()
  if #rules == 0 then
    return plan
  end
  local byName = {}
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, Lib.Call(C_Container.GetContainerNumSlots, bag) or 0 do
      local info = SlotInfo(bag, slot)
      local itemID = info and Lib.Plain(info.itemID)
      if itemID and not info.isBound and not info.isLocked and not Protected(itemID) then
        local name = Items.GetInfo(itemID)
        for _, rule in ipairs(rules) do
          if Matches(rule, itemID, name) then
            if not IsMe(rule.to) then
              local key = rule.to:lower()
              local entry = byName[key]
              if not entry then
                entry = { to = rule.to, stacks = {} }
                byName[key] = entry
                plan[#plan + 1] = entry
              end
              entry.stacks[#entry.stacks + 1] = { bag = bag, slot = slot, itemID = itemID,
                count = Lib.Plain(info.stackCount) or 1 }
            end
            break -- the first rule that matches decides
          end
        end
      end
    end
  end
  return plan
end

local function PlanCounts(list)
  local stacks = 0
  for _, entry in ipairs(list) do
    stacks = stacks + #entry.stacks
  end
  return stacks, #list
end

-- "20x Linen Cloth, 3x Wool Cloth" for one recipient.
local function Summary(entry, limit)
  local totals, order = {}, {}
  for _, s in ipairs(entry.stacks) do
    if not totals[s.itemID] then
      order[#order + 1] = s.itemID
      totals[s.itemID] = 0
    end
    totals[s.itemID] = totals[s.itemID] + s.count
  end
  local parts = {}
  for i, id in ipairs(order) do
    if limit and i > limit then
      parts[#parts + 1] = "+" .. (#order - limit) .. " more"
      break
    end
    parts[#parts + 1] = totals[id] .. "x " .. Items.Name(id)
  end
  return table.concat(parts, ", ")
end

-------------------------------------------------------------------------------
-- The card
-------------------------------------------------------------------------------

local function Paint()
  if not card then
    return
  end
  if not (mailOpen and F.db.card and not closedCard) then
    card:Hide()
    return
  end
  local stacks, people = PlanCounts(plan)
  if run then
    local entry = run.queue[run.i]
    card:SetLines("Mailing...", entry and ("To " .. entry.to .. ": " .. Summary(entry, 3)) or nil,
      string.format("%d mail%s sent", #run.sent, #run.sent == 1 and "" or "s"))
    card.send:SetText("Stop")
  elseif stacks == 0 then
    if #lastRun == 0 or not F.sentHere then
      card:Hide()
      return
    end
    card:SetLines("Auto Mail: all sent", F.sentHere, nil)
    card.send:SetText("Send")
  else
    local lines = {}
    for i, entry in ipairs(plan) do
      if i > 3 then
        lines[#lines + 1] = "+" .. (#plan - 3) .. " more"
        break
      end
      lines[#lines + 1] = entry.to .. ": " .. Summary(entry, 2)
    end
    card:SetLines(string.format("%s for %s", Lib.Plural(stacks, "stack"), Lib.Plural(people, "character")),
      table.concat(lines, "\n"), F.db.auto and "Hold Shift at the mailbox to skip sending" or nil)
    card.send:SetText("Send")
  end
  local first = plan[1] and plan[1].stacks[1]
  card.icon:SetTexture(first and Items.GetIcon(first.itemID) or "Interface\\Icons\\INV_Letter_15")
  card.place()
  card:Show()
end

local function MakeCard()
  if card then
    return
  end
  card = Kit.Card(F, { icon = true, move = { y = 120 } })
  card:AddButton("Close", 48, function()
    closedCard = true
    Paint()
  end)
  card.send = card:AddButton("Send", 48, function()
    if run then
      F:Stop("stopped")
    else
      F:Start("button")
    end
  end)
  card:Hide()
end

-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------

local function HasAttachments()
  for i = 1, MaxAttach() do
    if Lib.Call(HasSendMailItem, i) then
      return true
    end
  end
  return false
end

local function ClearAttachments()
  for i = 1, MaxAttach() do
    if Lib.Call(HasSendMailItem, i) then
      Lib.Call(ClickSendMailItemButton, i, true)
    end
  end
end

local function ShowSendTab()
  local frame = _G.SendMailFrame
  if frame and not frame:IsVisible() and _G.MailFrameTab2 then
    _G.MailFrameTab2:Click()
  end
end

function F:Stop(why)
  if not run then
    return
  end
  runGen = runGen + 1
  if run.pending then
    ClearAttachments()
  end
  ClearCursor()
  local sent = run.sent
  run = nil
  Log("run ended: %s (%d mail(s))", why, #sent)
  if #sent > 0 then
    local per, order = {}, {}
    for _, s in ipairs(sent) do
      if not per[s.to] then
        per[s.to] = 0
        order[#order + 1] = s.to
      end
      per[s.to] = per[s.to] + s.stacks
    end
    local parts = {}
    for _, to in ipairs(order) do
      parts[#parts + 1] = to .. " (" .. Lib.Plural(per[to], "stack") .. ")"
    end
    self.sentHere = "Sent to " .. table.concat(parts, ", ")
    if self.db.chat then
      self:Print(self.sentHere .. ".")
    end
  end
  BuildPlan()
  Paint()
end

-- Sends the next mail of the run, or ends it.
function F:Next()
  if not run then
    return
  end
  if not mailOpen then
    self:Stop("the mailbox closed")
    return
  end
  local entry = run.queue[run.i]
  -- Stacks that are no longer where the plan saw them are left out.
  local batch = {}
  while entry do
    while #entry.stacks > 0 and #batch < MaxAttach() do
      local s = table.remove(entry.stacks, 1)
      local info = SlotInfo(s.bag, s.slot)
      if info and Lib.Plain(info.itemID) == s.itemID and not info.isLocked and not info.isBound then
        batch[#batch + 1] = s
      end
    end
    if #batch > 0 then
      break
    end
    run.i = run.i + 1
    entry = run.queue[run.i]
  end
  if not entry then
    self:Stop("done")
    return
  end
  if HasAttachments() then
    self:Print("the Send Mail tab already holds items: send or clear them, then press Send again.")
    self:Stop("attachments already there")
    return
  end
  ShowSendTab()
  ClearCursor()
  for i, s in ipairs(batch) do
    Lib.Call(C_Container.PickupContainerItem, s.bag, s.slot)
    Lib.Call(ClickSendMailItemButton, i)
    if CursorHasItem() then
      ClearCursor()
      Log("couldn't attach %s from bag %d slot %d", Items.Name(s.itemID), s.bag, s.slot)
      self:Print("couldn't attach " .. Items.Link(s.itemID) .. "; stopped.")
      ClearAttachments()
      self:Stop("attach failed")
      return
    end
  end
  local price = Lib.Call(GetSendMailPrice) or 0
  if price > (GetMoney() or 0) then
    ClearAttachments()
    self:Print("not enough money for the postage (" .. Lib.FormatMoney(price) .. ").")
    self:Stop("no money")
    return
  end
  Lib.Call(SetSendMailCOD, 0)
  Lib.Call(SetSendMailMoney, 0)
  local first = batch[1].itemID
  local one = true
  local total = 0
  for _, s in ipairs(batch) do
    one = one and s.itemID == first
    total = total + s.count
  end
  local subject = one and (Items.Name(first) .. " x" .. total) or ("Items (" .. #batch .. " stacks)")
  subject = subject:sub(1, SUBJECT_MAX)
  run.pending = { to = entry.to, stacks = #batch, subject = subject }
  Log("sending \"%s\" to %s (%d stack(s), %s postage)", subject, entry.to, #batch, Lib.FormatMoney(price))
  local gen = runGen
  local ok = pcall(SendMail, entry.to, subject, "")
  if not ok then
    self:OnSendFailed("SendMail refused")
    return
  end
  self:After(SEND_TIMEOUT, function()
    if run and runGen == gen and run.pending then
      self:Print("no answer from the mail server; stopped.")
      self:Stop("timeout")
    end
  end)
  Paint()
end

function F:Start(via)
  if run or not mailOpen then
    return
  end
  closedCard = false
  BuildPlan()
  if PlanCounts(plan) == 0 then
    self:Debug("%s: nothing to send", via)
    Paint()
    return
  end
  runGen = runGen + 1
  lastRun = {}
  self.sentHere = nil
  run = { queue = plan, i = 1, sent = {} }
  Log("run started (%s): %d stack(s) for %d character(s)", via, PlanCounts(plan))
  self:Next()
end

function F:OnSendSuccess()
  if not (run and run.pending) then
    return
  end
  local p = run.pending
  run.pending = nil
  run.sent[#run.sent + 1] = p
  Log("sent to %s", p.to)
  runGen = runGen + 1
  local gen = runGen
  self:After(SEND_GAP, function()
    if runGen == gen then
      self:Next()
    end
  end)
  Paint()
end

-- This recipient's remaining stacks are dropped; the next one goes on.
function F:OnSendFailed(why)
  if not (run and run.pending) then
    return
  end
  local p = run.pending
  run.pending = nil
  ClearAttachments()
  Log("failed to %s: %s", p.to, tostring(why))
  self:Print("couldn't mail " .. p.to .. ": " .. tostring(why))
  run.queue[run.i].stacks = {}
  run.i = run.i + 1
  runGen = runGen + 1
  local gen = runGen
  self:After(SEND_GAP, function()
    if runGen == gen then
      self:Next()
    end
  end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

function F:OnMailShow()
  mailOpen = true
  closedCard = false
  self.sentHere = nil
  BuildPlan()
  Paint()
  if self.db.auto then
    if IsShiftKeyDown() then
      self:Debug("auto: skipped (Shift held)")
      return
    end
    self:After(AUTO_DELAY, function()
      self:Start("auto")
    end)
  end
end

function F:OnMailClosed()
  mailOpen = false
  self:Stop("the mailbox closed")
  Paint()
end

function F:OnBags()
  if mailOpen and not run then
    BuildPlan()
    Paint()
  end
end

function F:OnUIError(_, _, message)
  if run and run.pending and MAIL_ERRORS[message] then
    self:OnSendFailed(message)
  end
end

function F:OnEnable()
  mailOpen = _G.MailFrame and _G.MailFrame:IsShown() or false
  run, closedCard, plan = nil, false, {}
  runGen = runGen + 1
  MAIL_ERRORS = {}
  for key, text in pairs(_G) do
    if type(key) == "string" and type(text) == "string" and key:find("^ERR_MAIL_") then
      MAIL_ERRORS[text] = true
    end
  end
  for _, key in ipairs({ "ERR_NOT_ENOUGH_MONEY", "ERR_PLAYER_WRONG_FACTION" }) do
    if type(_G[key]) == "string" then
      MAIL_ERRORS[_G[key]] = true
    end
  end
  NoteMe()
  MakeCard()
  self:On("MAIL_SHOW", self.OnMailShow)
  self:On("MAIL_CLOSED", self.OnMailClosed)
  self:On("MAIL_SEND_SUCCESS", self.OnSendSuccess)
  self:On("MAIL_FAILED", function()
    self:OnSendFailed("the mail failed")
  end)
  self:On("UI_ERROR_MESSAGE", self.OnUIError)
  self:On("BAG_UPDATE_DELAYED", self.OnBags)
  if mailOpen then
    BuildPlan()
    Paint()
  end
end

function F:OnDisable()
  if run then
    self:Stop("turned off")
  end
  mailOpen = false
  if card then
    card:Hide()
  end
end

function F:OnOptionChanged()
  if mailOpen and not run then
    BuildPlan()
  end
  Paint()
end

function F:GetStatus()
  local n = #(self.db.rules or {})
  if n == 0 then
    return "Active · no rules yet: add one below, or /arl mail add <item> = <character>"
  end
  if run then
    return "Active · mailing (" .. #run.sent .. " sent so far)"
  end
  local list = mailOpen and plan or {}
  if not mailOpen then
    local saved = plan
    list = BuildPlan()
    plan = saved
  end
  local stacks, people = PlanCounts(list)
  local mode = self.db.auto and "sends when you open a mailbox" or "press Send at a mailbox"
  if stacks == 0 then
    return "Active · " .. Lib.Plural(n, "rule") .. ", nothing in your bags to send · " .. mode
  end
  return string.format("Active · %s, %s for %s waiting · %s", Lib.Plural(n, "rule"),
    Lib.Plural(stacks, "stack"), Lib.Plural(people, "character"), mode)
end

function F:ReportDetails()
  local lines = { "Rules:" }
  for _, text in ipairs(self.db.rules or {}) do
    local rule, why = ParseRule(text)
    lines[#lines + 1] = "  " .. text .. (rule and (" -> " .. rule.to .. (rule.known and "" or " (no surname)"))
      or (" (bad: " .. why .. ")"))
  end
  lines[#lines + 1] = "Last run:"
  for _, line in ipairs(lastRun) do
    lines[#lines + 1] = "  " .. line
  end
  return lines
end

F.commands = {
  { name = "add", args = "<item> = <character>", help = "adds a rule (Shift-click an item into chat for its link)",
    run = function(self, _, raw)
      local rule, why = ParseRule(raw)
      if not rule then
        self:Print("usage: /arl mail add <item> = <character> (" .. why .. ")")
        return
      end
      -- A link is kept as its item ID, so the rule reads the same in any locale.
      local text = raw
      if rule.id then
        text = rule.id .. " = " .. rule.typed
      end
      local list = { unpack(self.db.rules or {}) }
      list[#list + 1] = text
      ARLE:SetOption(self.id, "rules", list)
      self:Print("rule added: " .. self:FormatRule(text))
    end },
  { name = "remove", args = "<number>", help = "removes rule number <n> (see /arl mail list)", run = function(self, rest)
    local n = tonumber(rest)
    local list = {}
    for i, v in ipairs(self.db.rules or {}) do
      if i ~= n then
        list[#list + 1] = v
      end
    end
    if not n or #list == #(self.db.rules or {}) then
      self:Print("usage: /arl mail remove <number> (see /arl mail list)")
      return
    end
    ARLE:SetOption(self.id, "rules", list)
    self:Print("rule " .. n .. " removed.")
  end },
  { name = "list", help = "your rules, and what in your bags would go to whom", run = function(self)
    self:Print("rules (the first that matches an item decides):")
    for i, text in ipairs(self.db.rules or {}) do
      print("   " .. i .. ". " .. self:FormatRule(text))
    end
    if #(self.db.rules or {}) == 0 then
      print("   (none)")
    end
    local saved = plan
    local list = BuildPlan()
    if not mailOpen then
      plan = saved
    end
    for _, entry in ipairs(list) do
      print("   -> " .. entry.to .. ": " .. Summary(entry))
    end
  end },
  { name = "send", help = "sends now (at an open mailbox)", run = function(self)
    if not mailOpen then
      self:Print("open a mailbox first.")
      return
    end
    self:Start("command")
  end },
  { name = "alts", help = "the characters' full names ARL knows (a rule may use just the first name)",
    run = function(self)
      self:Print("characters seen with ARL:")
      for name in pairs(Alts()) do
        print("   " .. name)
      end
    end },
}

ARLE:RegisterModule(F)
