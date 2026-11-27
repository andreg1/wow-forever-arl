-- LFG Role Filter, messages: the Tanks / Healers / Groups buttons under the
-- filter panel's list message every player (or group leader) the filter
-- shows, and a Replies panel sorts their answers into positive, neutral and
-- negative, with an optional goodbye to the negative ones.
--
-- Sending: live Forever refuses chat lines an addon posts (Layer Bridge's
-- measurements, C_ChatInfo.AreOutgoingAddonChatMessagesRestricted), so each
-- message is opened in the player's chat box as a whisper (Blizzard's own
-- SendTell, the panel's W button) and goes out with the player's Enter. The
-- next one opens a few seconds after the game confirms the last
-- (CHAT_MSG_WHISPER_INFORM); Esc pauses. Where the game allows it and the
-- player turned "send by itself" on, SendChatMessage is tried, and the first
-- one not confirmed within 3 s turns that off for the session.
-- Not spam: at most askMax players per click and 40 an hour, nobody twice
-- within askAgain minutes (char.contacted, kept a day), never someone in your
-- group, nothing in combat or a chat lockdown.
--
-- Replies: a whisper from a player messaged in the last 2 hours is filed
-- (char.replies, kept 2 hours) by a word score (English and Portuguese: "sure",
-- "inv", "bora", "no thanks", "busy", "já tenho"...), a question with a weak
-- score staying neutral. A right-click moves a reply to the next list.
-- Part of LFGRoleFilter (same feature table, ns.LFGRoleFilter).
local _, ns = ...
local ARLE = _G.ARLExtensions
local L = ns.LFGRoleFilter
if not (ARLE and L) then
  return
end
local Skin, Kit, Lib = ARLE.Skin, ARLE.UI.Kit, ARLE.Lib
local F = L.F

local FOOT_H = 46 -- px under the filter panel's list
local REPLY_W = 260
local REPLY_ROW = 34
local HEAD_ROW = 18
local BOTTOM_H = 96 -- the goodbye block
local HOUR = 3600
local HOUR_CAP = 40 -- messages an hour, every click together
local KEEP_CONTACTED = 86400 -- s
local REPLY_FOR = 7200 -- s a whisper counts as a reply after ours
local INFORM_WAIT = 3 -- s for the game to confirm a message sent by itself
local CLOSED_WAIT = 2 -- s after the chat box closed without the message going out
local BUSY_RETRY = 1 -- s
local MSG_MAX = 255
local TEXT_MAX = 200
local TONES = { "pos", "neu", "neg" }
local TONE_LABEL = { pos = "Positive", neu = "Neutral", neg = "Negative" }
local TONE_COLOR = { pos = { 0.35, 0.9, 0.45 }, neu = { 0.8, 0.8, 0.8 }, neg = { 1, 0.4, 0.35 } }
local NEXT_TONE = { pos = "neu", neu = "neg", neg = "pos" }
local KIND_LABEL = { tank = "tanks", healer = "healers", group = "groups" }
local KIND_ONE = { tank = "tank", healer = "healer", group = "group" }
local KIND_KEY = { tank = "msgTank", healer = "msgHealer", group = "msgGroup" }

-- Word scores (lower case, matched as whole words; longer phrases first, and
-- a matched phrase is taken out so "no problem" isn't also "no").
local WORDS = {
  -- positive
  { "no problem", 2 }, { "no prob", 2 }, { "sem problema", 2 }, { "why not", 2 }, { "count me in", 2 },
  { "sounds good", 2 }, { "on my way", 2 }, { "of course", 2 }, { "let's go", 2 }, { "lets go", 2 },
  { "i'm in", 2 }, { "im in", 2 }, { "i am in", 2 }, { "inv me", 2 }, { "send inv", 2 }, { "pode mandar", 2 },
  { "pode ser", 2 }, { "manda inv", 2 }, { "to dentro", 2 }, { "tô dentro", 2 }, { "com certeza", 2 },
  { "yes", 1 }, { "yeah", 1 }, { "yea", 1 }, { "yep", 1 }, { "yup", 1 }, { "ya", 1 }, { "sure", 1 }, { "ok", 1 },
  { "okay", 1 }, { "k", 1 }, { "kk", 1 }, { "inv", 1.5 }, { "invite", 1.5 }, { "omw", 2 }, { "coming", 1 },
  { "down", 1 }, { "deal", 1 }, { "absolutely", 1.5 }, { "np", 1 }, { "ready", 1 }, { "y", 1 }, { "+1", 1 },
  { "+", 1 }, { "sim", 1.5 }, { "claro", 1.5 }, { "bora", 1.5 }, { "vamos", 1 }, { "manda", 1 }, { "beleza", 1 },
  { "blz", 1 }, { "fechou", 1.5 }, { "fechado", 1.5 }, { "partiu", 1.5 }, { "top", 0.5 }, { "dale", 1 },
  { "si", 1 }, { "ty", 0.5 }, { "thanks", 0.5 }, { "valeu", 0.5 },
  -- negative
  { "not interested", -3 }, { "no thanks", -2.5 }, { "no thank you", -2.5 }, { "no ty", -2.5 },
  { "already have", -2 }, { "already in", -2 }, { "already got", -2 }, { "found one", -2 }, { "we're full", -2 },
  { "we are full", -2 }, { "not now", -1.5 }, { "maybe later", -1.5 }, { "i'll pass", -2 }, { "go away", -3 },
  { "leave me", -3 }, { "not looking", -2 }, { "n obrigado", -2.5 }, { "não obrigado", -2.5 },
  { "nao obrigado", -2.5 }, { "sem tempo", -2 }, { "agora não", -1.5 }, { "agora nao", -1.5 },
  { "já tenho", -2 }, { "ja tenho", -2 }, { "já estou", -2 }, { "ja estou", -2 }, { "ja to", -2 },
  { "já tô", -2 }, { "foi mal", -1.5 }, { "valeu mas", -1.5 }, { "no", -1.5 }, { "nope", -2 }, { "nah", -2 },
  { "n", -1 }, { "busy", -2 }, { "already", -1.5 }, { "found", -1 }, { "full", -1.5 }, { "sorry", -0.5 },
  { "pass", -1.5 }, { "later", -0.5 }, { "stop", -3 }, { "spam", -3 }, { "don't", -1 }, { "dont", -1 },
  { "can't", -1 }, { "cant", -1 }, { "afk", -1 }, { "não", -1.5 }, { "nao", -1.5 }, { "nem", -1 }, { "nop", -2 },
  { "ocupado", -2 }, { "desculpa", -0.5 }, { "lotado", -1.5 }, { "cheio", -1.5 },
}
table.sort(WORDS, function(a, b)
  return #a[1] > #b[1]
end)

local O = {}
ns.LFGOutreach = O

local footer -- widgets under the filter panel's list
local prompt -- the message card
local replies -- the Replies panel
local queue = {} -- { name, text, kind, reply }
local current -- the item being sent (+ mode "auto" | "box", at, box, closedAt)
local nextAt = 0
local run -- { sent, total, skipped, offline } for the clicks since the queue was last empty
local paused, autoBroken, repliesWanted = false, false, false
local waitReason
local notFoundPattern

-------------------------------------------------------------------------------
-- Names, the contacted list and the replies list
-------------------------------------------------------------------------------

local function Key(name)
  name = Lib.StripRealm(name)
  return name and name:lower() or nil
end

local function FirstWord(s)
  return s and s:match("^(%S+)") or s
end

-- The same player, with or without the surname.
local function Same(a, b)
  local ka, kb = Key(a), Key(b)
  return ka ~= nil and kb ~= nil and (ka == kb or FirstWord(ka) == FirstWord(kb))
end

local function Contacted()
  if type(F.char.contacted) ~= "table" then
    F.char.contacted = {}
  end
  return F.char.contacted
end

local function Replies()
  if type(F.char.replies) ~= "table" then
    F.char.replies = {}
  end
  return F.char.replies
end

local function ContactOf(name)
  local list, k = Contacted(), Key(name)
  if not k then
    return nil
  end
  if list[k] then
    return list[k], k
  end
  local first = FirstWord(k)
  for key, c in pairs(list) do
    if FirstWord(key) == first then
      return c, key
    end
  end
end

local function Prune()
  local now = time()
  local list = Contacted()
  for k, c in pairs(list) do
    if type(c) ~= "table" or type(c.at) ~= "number" or now - c.at > KEEP_CONTACTED then
      list[k] = nil
    end
  end
  local r = Replies()
  for i = #r, 1, -1 do
    if type(r[i]) ~= "table" or type(r[i].at) ~= "number" or now - r[i].at > REPLY_FOR then
      table.remove(r, i)
    end
  end
end

local function SentLastHour()
  local n, now = 0, time()
  for _, c in pairs(Contacted()) do
    if now - c.at < HOUR then
      n = n + 1
    end
  end
  return n
end

-------------------------------------------------------------------------------
-- Tone
-------------------------------------------------------------------------------

local function Escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- "pos" | "neu" | "neg", and the score.
function O.Tone(text)
  local raw = (text or ""):lower()
  local score = 0
  for _, face in ipairs({ ":)", ":d", "<3", "=)", ";)", "xd" }) do
    if raw:find(face, 1, true) then
      score = score + 1
    end
  end
  for _, face in ipairs({ ":(", ":/", "=(" }) do
    if raw:find(face, 1, true) then
      score = score - 1
    end
  end
  local question = raw:find("?", 1, true) ~= nil
  local s = " " .. raw:gsub("[%.,!;:%(%)\"/%?=<>]", " "):gsub("%s+", " ") .. " "
  for _, w in ipairs(WORDS) do
    local pat = " " .. Escape(w[1]) .. " "
    local n
    s, n = s:gsub(pat, "  ")
    if n > 0 then
      score = score + w[2] * n
    end
  end
  if score >= 1 and not (question and score < 2) then
    return "pos", score
  elseif score <= -1 then
    return "neg", score
  end
  return "neu", score
end

-------------------------------------------------------------------------------
-- Messages
-------------------------------------------------------------------------------

local function Cut(s)
  if #s <= MSG_MAX then
    return s
  end
  s = s:sub(1, MSG_MAX)
  -- (not in the middle of a UTF-8 letter)
  while #s > 0 and s:byte(#s) >= 128 and s:byte(#s) < 192 do
    s = s:sub(1, -2)
  end
  if #s > 0 and s:byte(#s) >= 192 then
    s = s:sub(1, -2)
  end
  return s
end

local function Fill(text, e)
  local _, token = Lib.Call(UnitClass, "player")
  local act = e and e.activity and (e.activity:gsub("%s*%(%+%d+%)$", "")) or "a dungeon"
  local out = (text or ""):gsub("{(%a+)}", function(w)
    w = w:lower()
    if w == "name" then
      return FirstWord(Lib.StripRealm(e and e.leader) or "") or ""
    elseif w == "activity" then
      return act
    elseif w == "level" then
      return tostring(UnitLevel("player") or "")
    elseif w == "class" then
      return type(token) == "string" and L.ClassLabel(token) or ""
    end
  end)
  return Cut(Lib.Trim(out))
end

local function Queued(name)
  if current and Same(current.name, name) then
    return true
  end
  for _, q in ipairs(queue) do
    if Same(q.name, name) and q.kind ~= "bye" then
      return true
    end
  end
  return false
end

-- Who a button would message now, and how many it leaves out as messaged lately.
local function Candidates(kind)
  local out, seen, recent = {}, {}, 0
  local now = time()
  local again = (tonumber(F.db.askAgain) or 60) * 60
  local me = Key(ARLE:MyName())
  for _, e in ipairs(L.shown) do
    local fits
    if kind == "group" then
      fits = not e.solo
    else
      fits = e.solo and e.roles[kind]
    end
    local k = fits and Key(e.leader)
    if k and not seen[k] and k ~= me and not L.InGroupWith(e.leader) then
      seen[k] = true
      local c = ContactOf(e.leader)
      if (c and now - c.at < again) or Queued(e.leader) then
        recent = recent + 1
      else
        out[#out + 1] = e
      end
    end
  end
  return out, recent
end

local function Room()
  return math.max(0, HOUR_CAP - SentLastHour() - #queue - (current and 1 or 0))
end

local function AutoAllowed()
  if not F.db.autoSend or autoBroken then
    return false
  end
  local f = C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
  return not (type(f) == "function" and (Lib.Call(f)) == true)
end

local function Locked()
  local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
  return type(f) == "function" and (Lib.Call(f)) == true
end

-------------------------------------------------------------------------------
-- The sender: one message at a time
-------------------------------------------------------------------------------

local Redraw -- forward: footer + replies panel

-- Takes our text back out of the chat box when it's still there.
local function TakeBack(item)
  local box = item and item.box
  if not (box and box:IsShown() and box:GetText() == item.text) then
    return
  end
  box:SetText("")
  local util = rawget(_G, "ChatFrameUtil")
  local close = (type(util) == "table" and util.DeactivateChat) or rawget(_G, "ChatEdit_DeactivateChat")
  if type(close) == "function" then
    pcall(close, box)
  end
end

local function Finish()
  if not run then
    return
  end
  local r = run
  run = nil
  local extra = {}
  if r.skipped > 0 then
    extra[#extra + 1] = r.skipped .. " skipped"
  end
  if r.offline > 0 then
    extra[#extra + 1] = r.offline .. " offline"
  end
  if r.sent > 0 or #extra > 0 then
    F:Print(("messages done: %d sent%s. Replies are sorted in the Replies panel (/arl lfg replies)."):format(r.sent,
      #extra > 0 and (", " .. table.concat(extra, ", ")) or ""))
  end
end

function O.Stop(why)
  local n = #queue + (current and 1 or 0)
  for _, q in ipairs(queue) do
    if q.reply then
      q.reply.byeQueued = nil
    end
  end
  wipe(queue)
  if current then
    TakeBack(current)
    if current.reply then
      current.reply.byeQueued = nil
    end
    current = nil
  end
  paused = false
  if why and n > 0 then
    F:Print(("%s: %d message%s not sent."):format(why, n, n == 1 and "" or "s"))
  end
  Finish()
  Redraw()
end

local function Skip()
  local item = current
  if item then
    TakeBack(item)
    current = nil
  else
    item = table.remove(queue, 1)
  end
  if item and item.reply then
    item.reply.byeQueued = nil
  end
  if item and run and item.kind ~= "bye" then
    run.skipped = run.skipped + 1
  end
  paused = false
  nextAt = GetTime() + 0.5
  if #queue == 0 and not current then
    Finish()
  end
  Redraw()
end

local function Resume()
  paused = false
  nextAt = GetTime()
  Redraw()
end

local function Done(item, offline)
  current = nil
  nextAt = GetTime() + (tonumber(F.db.askGap) or 3)
  if item.kind == "bye" then
    if item.reply then
      item.reply.bye, item.reply.byeQueued = true, nil
    end
  else
    Contacted()[Key(item.name)] = { at = time(), name = item.name, kind = item.kind }
    if run then
      if offline then
        run.offline = run.offline + 1
      else
        run.sent = run.sent + 1
      end
    end
    if not offline then
      repliesWanted = true
    end
  end
  F:Debug("message %s to %s", offline and "not delivered (offline)" or "sent", item.name)
  if #queue == 0 then
    Finish()
  end
  Redraw()
end

local function Pump()
  if current or paused or #queue == 0 or GetTime() < nextAt then
    return
  end
  if InCombatLockdown() or Locked() then
    waitReason = "waiting for the fight to end"
    return
  end
  local item = queue[1]
  if item.kind ~= "bye" and L.InGroupWith(item.name) then
    table.remove(queue, 1)
    if run then
      run.skipped = run.skipped + 1
    end
    return
  end
  if AutoAllowed() then
    table.remove(queue, 1)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or rawget(_G, "SendChatMessage")
    item.mode, item.at = "auto", GetTime()
    current = item
    if type(send) ~= "function" or not pcall(send, item.text, "WHISPER", nil, item.name) then
      autoBroken = true
      current = nil
      table.insert(queue, 1, item)
      F:Debug("SendChatMessage refused: the chat box from now on")
    end
    waitReason = nil
    Redraw()
    return
  end
  local box = Lib.ActiveChatBox()
  if box and box:IsShown() and (box:GetText() or "") ~= "" then
    waitReason = "waiting: your chat box is in use"
    nextAt = GetTime() + BUSY_RETRY
    Redraw()
    return
  end
  table.remove(queue, 1)
  L.Whisper(item.name)
  box = Lib.ActiveChatBox()
  if not (box and box:IsShown()) then
    table.insert(queue, 1, item)
    paused = true
    F:Print("couldn't open the chat box for the next message: paused.")
    Redraw()
    return
  end
  box:Insert(item.text)
  item.mode, item.at, item.box, item.closedAt = "box", GetTime(), box, nil
  item.text = box:GetText() -- what Enter sends (and what TakeBack looks for)
  current = item
  waitReason = nil
  Redraw()
end

-- The message in flight: confirmed, refused, or the chat box closed without it.
local function Watch()
  local c = current
  if not c then
    return
  end
  local now = GetTime()
  if c.mode == "auto" then
    if now - c.at > INFORM_WAIT then
      autoBroken = true
      current = nil
      table.insert(queue, 1, c)
      F:Print("the game didn't send the message by itself: each one now waits for your Enter in the chat box.")
      Redraw()
    end
    return
  end
  local box = c.box
  if box and box:IsShown() and box:GetText() == c.text then
    c.closedAt = nil
    return
  end
  c.closedAt = c.closedAt or now
  if now - c.closedAt > CLOSED_WAIT then
    current = nil
    table.insert(queue, 1, c)
    paused = true
    F:Debug("chat box closed without sending to %s: paused", c.name)
    Redraw()
  end
end

local function Start(kind, list, text)
  if not run then
    run = { sent = 0, total = 0, skipped = 0, offline = 0 }
  end
  for _, e in ipairs(list) do
    queue[#queue + 1] = { name = e.leader, text = Fill(text, e), kind = kind }
  end
  run.total = run.total + #list
  paused = false
  nextAt = math.min(nextAt, GetTime())
  repliesWanted = true
  F:Print(("messaging %d %s%s."):format(#list, KIND_LABEL[kind], AutoAllowed() and ""
    or ": each one opens in your chat box, press Enter to send it (Esc pauses)"))
  Redraw()
end

local function QueueBye(r)
  local text = Lib.Trim(F.db.goodbye or "")
  if text == "" or r.bye or r.byeQueued then
    return false
  end
  queue[#queue + 1] = { name = r.name, text = Fill(text, { leader = r.name }), kind = "bye", reply = r }
  r.byeQueued = true
  return true
end

local function ByeCount()
  local n = 0
  for _, r in ipairs(Replies()) do
    if r.tone == "neg" and not r.bye and not r.byeQueued then
      n = n + 1
    end
  end
  return n
end

local function ByeAll()
  local n = 0
  for _, r in ipairs(Replies()) do
    if r.tone == "neg" and QueueBye(r) then
      n = n + 1
    end
  end
  if n > 0 then
    paused = false
    F:Print(("goodbye to %d negative repl%s%s."):format(n, n == 1 and "y" or "ies", AutoAllowed() and ""
      or ": press Enter for each one"))
  end
  Redraw()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function OnInform(_, _, _, target)
  if current and Same(Lib.Str(Lib.Plain(target)), current.name) then
    Done(current)
  end
end

local function OnSystem(_, _, text)
  text = Lib.Str(Lib.Plain(text))
  if not (text and current and notFoundPattern) then
    return
  end
  local who = text:match(notFoundPattern)
  if who and Same(who, current.name) then
    Done(current, true)
  end
end

local function OnWhisper(_, _, text, sender, _, _, _, _, _, _, _, _, _, guid)
  text, sender = Lib.Str(Lib.Plain(text)), Lib.Str(Lib.Plain(sender))
  if not (text and sender) then
    return
  end
  local c, key = ContactOf(sender)
  if not c or time() - c.at > REPLY_FOR then
    return
  end
  local list, r = Replies(), nil
  for _, x in ipairs(list) do
    if x.key == key then
      r = x
      break
    end
  end
  if not r then
    r = { key = key, name = sender, kind = c.kind }
    table.insert(list, 1, r)
  end
  r.text = r.text and (r.text .. " / " .. text) or text
  if #r.text > TEXT_MAX then
    r.text = r.text:sub(-TEXT_MAX)
  end
  r.at = time()
  guid = Lib.Plain(guid)
  if guid and not r.class then
    local _, token = Lib.Call(GetPlayerInfoByGUID, guid)
    r.class = type(token) == "string" and token or nil
  end
  local was = r.tone
  if not r.manual then
    r.tone = O.Tone(r.text)
  end
  F:Debug("reply from %s filed as %s: %s", sender, r.tone, text)
  if r.tone == "neg" and was ~= "neg" and F.db.goodbyeAuto and QueueBye(r) then
    F:Print(("%s said no: goodbye queued%s."):format(sender, AutoAllowed() and "" or " (press Enter for it)"))
  end
  repliesWanted = true
  Redraw()
end

-------------------------------------------------------------------------------
-- The message card
-------------------------------------------------------------------------------

local function CreatePrompt()
  prompt = Kit.Card(F, { strata = "DIALOG", width = 262 })
  prompt.edit = Kit.EditBox(prompt, 236)
  prompt.edit:SetMaxLetters(MSG_MAX)
  prompt.edit:SetPoint("TOPLEFT", prompt.note, "BOTTOMLEFT", 5, -6)
  prompt.extra = 32
  prompt.send = prompt:AddButton("Send", 70, function()
    prompt.Go()
  end)
  prompt:AddButton("Cancel", 60, function()
    prompt:Hide()
  end)
  F:Script(prompt.edit, "OnEnterPressed", function()
    prompt.Go()
  end)
  F:Script(prompt.edit, "OnEscapePressed", function()
    prompt:Hide()
  end)
  function prompt.Go()
    local kind = prompt.kind
    local text = Lib.Trim(prompt.edit:GetText() or "")
    prompt:Hide()
    if not kind or text == "" then
      return
    end
    if text ~= F.db[KIND_KEY[kind]] then
      ARLE:SetOption(F.id, KIND_KEY[kind], text)
    end
    local list = Candidates(kind)
    local n = math.min(#list, tonumber(F.db.askMax) or 10, Room())
    if n <= 0 then
      F:Print("nobody left to message (the filter changed, or the hourly limit is reached).")
      return
    end
    while #list > n do
      table.remove(list)
    end
    Start(kind, list, text)
  end
end

local function Ask(kind)
  if InCombatLockdown() then
    F:Print("not in combat.")
    return
  end
  local list, recent = Candidates(kind)
  local room = Room()
  if #list == 0 then
    F:Print(recent > 0 and ("every %s shown was messaged in the last %d minutes."):format(KIND_ONE[kind],
      tonumber(F.db.askAgain) or 60) or ("no %s in the list: change the filter or refresh the search."):format(
      KIND_ONE[kind]))
    return
  end
  if room <= 0 then
    F:Print(("you've messaged %d players this hour: that's the limit, so nobody reports you for spam."):format(
      HOUR_CAP))
    return
  end
  if not prompt then
    CreatePrompt()
  end
  local n = math.min(#list, tonumber(F.db.askMax) or 10, room)
  prompt.kind = kind
  prompt:SetLines(("Message %d %s"):format(n, n == 1 and KIND_ONE[kind] or KIND_LABEL[kind]),
    (n < #list and ("%d more next click. "):format(#list - n) or "")
      .. (recent > 0 and ("%d messaged lately left out. "):format(recent) or "")
      .. ("One every %ds."):format(tonumber(F.db.askGap) or 3),
    AutoAllowed() and "Sent by itself where the game allows it."
      or "Each one opens in your chat box: Enter sends it, Esc pauses.")
  prompt.edit:SetText(F.db[KIND_KEY[kind]] or "")
  prompt:ClearAllPoints()
  local panel = L.Panel()
  if panel and panel:IsShown() then
    prompt:SetPoint("BOTTOM", panel, "BOTTOM", 0, FOOT_H + 12)
  else
    prompt:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  end
  prompt:Show()
  prompt.edit:SetFocus()
  prompt.edit:HighlightText()
end

-------------------------------------------------------------------------------
-- The footer under the filter panel's list
-------------------------------------------------------------------------------

function O.CreateFooter(panel)
  footer = {}
  local rule = Kit.Rule(panel, 0.12)
  rule:SetPoint("BOTTOMLEFT", 8, FOOT_H + 4)
  rule:SetPoint("BOTTOMRIGHT", -8, FOOT_H + 4)
  local label = Kit.Text(panel, "GameFontNormalSmall")
  label:SetPoint("BOTTOMLEFT", 10, 30)
  label:SetText("Message all:")
  footer.ask = {}
  local prev
  for _, kind in ipairs({ "tank", "healer", "group" }) do
    local b = Kit.SmallButton(panel, "", 58)
    if prev then
      b:SetPoint("LEFT", prev, "RIGHT", 3, 0)
    else
      b:SetPoint("BOTTOMLEFT", 76, 28)
    end
    F:Script(b, "OnClick", function()
      Ask(kind)
    end)
    Kit.Tip(b, "Message " .. KIND_LABEL[kind], function()
      local list, recent = Candidates(kind)
      return (kind == "group" and "Every group leader the list shows" or ("Every solo %s the list shows"):format(
        KIND_ONE[kind])) .. " gets your message, one at a time (you write it first). " .. #list .. " now"
        .. (recent > 0 and (", " .. recent .. " messaged lately left out") or "") .. ". Their replies are sorted "
        .. "in the Replies panel."
    end)
    footer.ask[kind] = b
    prev = b
  end
  footer.status = Kit.Text(panel, "GameFontHighlightSmall")
  footer.status:SetPoint("BOTTOMLEFT", 10, 11)
  footer.status:SetPoint("RIGHT", panel, "RIGHT", -120, 0)
  footer.status:SetWordWrap(false)
  local function Btn(text, width, fn, tip)
    local b = Kit.SmallButton(panel, text, width)
    F:Script(b, "OnClick", fn)
    if tip then
      Kit.Tip(b, text, tip)
    end
    return b
  end
  footer.stop = Btn("Stop", 40, function()
    O.Stop("stopped")
  end, "Drop the messages still waiting.")
  footer.stop:SetPoint("BOTTOMRIGHT", -8, 9)
  footer.skip = Btn("Skip", 40, Skip, "Leave this player out and go on.")
  footer.skip:SetPoint("RIGHT", footer.stop, "LEFT", -3, 0)
  footer.resume = Btn("Go on", 46, Resume, "Open the next message again.")
  footer.resume:SetPoint("RIGHT", footer.skip, "LEFT", -3, 0)
  footer.replies = Btn("Replies", 70, function()
    O.ToggleReplies()
  end, "The answers to your messages, sorted into positive, neutral and negative.")
  footer.replies:SetPoint("BOTTOMRIGHT", -8, 9)
  return FOOT_H
end

local function PaintFooter()
  if not footer then
    return
  end
  for kind, b in pairs(footer.ask) do
    local n = #(Candidates(kind))
    b:SetText(("%s %d"):format(kind == "tank" and "Tanks" or kind == "healer" and "Healers" or "Groups", n))
    b:SetEnabled(n > 0)
  end
  local busy = current ~= nil or #queue > 0
  footer.stop:SetShown(busy)
  footer.skip:SetShown(busy)
  footer.resume:SetShown(busy and paused)
  footer.replies:SetShown(not busy)
  local nRep = #Replies()
  footer.replies:SetText(nRep > 0 and ("Replies " .. nRep) or "Replies")
  local text
  if busy then
    local done = run and (run.sent + run.skipped + run.offline) or 0
    local total = run and run.total or 0
    local who = current and current.name or (queue[1] and queue[1].name) or ""
    who = FirstWord(Lib.StripRealm(who) or "") or ""
    local kindBye = (current or queue[1] or {}).kind == "bye"
    if paused then
      text = "|cffffd100Paused|r · " .. who
    elseif current and current.mode == "box" then
      text = ("%s %s · press Enter"):format(kindBye and "Goodbye" or (math.min(done + 1, total) .. "/" .. total), who)
    elseif current then
      text = ("Sending to %s"):format(who)
    else
      text = waitReason or ((kindBye and "Goodbye" or (done .. "/" .. total)) .. " · next in a moment")
    end
  else
    local n = SentLastHour()
    text = n > 0 and ("%d messaged this hour"):format(n) or ""
  end
  footer.status:SetText(text)
end

-------------------------------------------------------------------------------
-- The Replies panel
-------------------------------------------------------------------------------

local rowPool, headPool = {}, {}

local function Ago(at)
  local s = time() - (at or 0)
  if s < 60 then
    return "now"
  end
  return math.floor(s / 60) .. "m"
end

local function ReplyTooltip(row)
  local r = row.reply
  if not r then
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(r.name, L.ClassColor(r.class))
  GameTooltip:AddLine(r.text or "", 1, 1, 1, true)
  local c = TONE_COLOR[r.tone]
  GameTooltip:AddLine(TONE_LABEL[r.tone] .. (r.manual and " (moved by you)" or ""), c[1], c[2], c[3])
  GameTooltip:AddLine(("Answer to your message to %s, %s ago."):format(KIND_LABEL[r.kind] or "players", Ago(r.at)),
    0.7, 0.7, 0.7)
  if r.bye then
    GameTooltip:AddLine("Goodbye sent.", 0.7, 0.7, 0.7)
  elseif r.byeQueued then
    GameTooltip:AddLine("Goodbye waiting to be sent.", 0.7, 0.7, 0.7)
  end
  GameTooltip:AddLine("Right-click: move it to " .. TONE_LABEL[NEXT_TONE[r.tone]] .. ".", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function ReplyRow(i)
  local row = rowPool[i]
  if row then
    return row
  end
  row = CreateFrame("Button", nil, replies.content)
  row:SetSize(REPLY_W - 20, REPLY_ROW)
  row:RegisterForClicks("RightButtonUp")
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(1, 1, 1, 0.04)
  row.mark = row:CreateTexture(nil, "ARTWORK")
  row.mark:SetPoint("TOPLEFT", 0, -2)
  row.mark:SetPoint("BOTTOMLEFT", 0, 2)
  row.mark:SetWidth(2)
  row.name = Kit.Text(row, "GameFontNormalSmall")
  row.name:SetPoint("TOPLEFT", 6, -3)
  row.name:SetPoint("RIGHT", row, "RIGHT", -52, 0)
  row.name:SetWordWrap(false)
  row.text = Kit.Text(row, "GameFontHighlightSmall")
  row.text:SetPoint("BOTTOMLEFT", 6, 4)
  row.text:SetPoint("RIGHT", row, "RIGHT", -52, 0)
  row.text:SetWordWrap(false)
  row.whisper = Kit.SmallButton(row, "W", 22)
  row.whisper:SetPoint("RIGHT", -2, 0)
  F:Script(row.whisper, "OnClick", function()
    L.Whisper(row.reply and row.reply.name)
  end)
  Kit.Tip(row.whisper, "Whisper")
  row.invite = Kit.SmallButton(row, "+", 22)
  row.invite:SetPoint("RIGHT", row.whisper, "LEFT", -2, 0)
  F:Script(row.invite, "OnClick", function()
    L.Invite(row.reply and row.reply.name)
  end)
  Kit.Tip(row.invite, "Invite to group")
  F:Script(row, "OnEnter", ReplyTooltip)
  F:Script(row, "OnLeave", GameTooltip_Hide)
  F:Script(row, "OnClick", function(self)
    local r = self.reply
    if not r then
      return
    end
    r.tone, r.manual = NEXT_TONE[r.tone] or "neu", true
    Redraw()
    if GameTooltip:GetOwner() == self then
      ReplyTooltip(self)
    end
  end)
  rowPool[i] = row
  return row
end

local function HeadRow(i)
  local h = headPool[i]
  if h then
    return h
  end
  h = Kit.Text(replies.content, "GameFontNormal")
  headPool[i] = h
  return h
end

local function PaintReplies()
  if not (replies and replies:IsShown()) then
    return
  end
  local groups = { pos = {}, neu = {}, neg = {} }
  local list = Replies()
  for _, r in ipairs(list) do
    local g = groups[r.tone] or groups.neu
    g[#g + 1] = r
  end
  local y, nRow, nHead = 0, 0, 0
  for _, tone in ipairs(TONES) do
    local g = groups[tone]
    table.sort(g, function(a, b)
      return (a.at or 0) > (b.at or 0)
    end)
    nHead = nHead + 1
    local h = HeadRow(nHead)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", 2, -y - 3)
    local c = TONE_COLOR[tone]
    h:SetText(("%s (%d)"):format(TONE_LABEL[tone], #g))
    h:SetTextColor(c[1], c[2], c[3])
    h:Show()
    y = y + HEAD_ROW
    for _, r in ipairs(g) do
      nRow = nRow + 1
      local row = ReplyRow(nRow)
      row.reply = r
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 0, -y)
      row.mark:SetColorTexture(c[1], c[2], c[3], 0.9)
      row.name:SetText(r.name .. "  |cff888888" .. Ago(r.at) .. (r.bye and " · bye sent" or "") .. "|r")
      row.name:SetTextColor(L.ClassColor(r.class))
      row.text:SetText(r.text or "")
      row.invite:SetShown(r.kind ~= "group")
      row:Show()
      y = y + REPLY_ROW + 2
    end
    y = y + 4
  end
  for i = nRow + 1, #rowPool do
    rowPool[i]:Hide()
    rowPool[i].reply = nil
  end
  for i = nHead + 1, #headPool do
    headPool[i]:Hide()
  end
  replies.content:SetHeight(math.max(1, y))
  replies.count:SetText(#list > 0 and tostring(#list) or "")
  replies.empty:SetShown(#list == 0)
  local n = ByeCount()
  replies.byeAll:SetText(n > 0 and ("Send to " .. n) or "Send")
  replies.byeAll:SetEnabled(n > 0)
  replies.auto:SetChecked(F.db.goodbyeAuto == true)
  if not replies.edit:HasFocus() then
    replies.edit:SetText(F.db.goodbye or "")
    replies.edit:SetCursorPosition(0)
  end
end

local function CreateReplies()
  replies = Skin:CreateTooltipWindow(nil, UIParent)
  replies:SetSize(REPLY_W, 420)
  replies:SetFrameStrata("HIGH")
  replies:SetClampedToScreen(true)
  replies:Hide()

  local title = Kit.Text(replies, "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Replies")
  title:SetTextColor(Skin:Accent())
  replies.count = Kit.Text(replies, "GameFontHighlightSmall")
  replies.count:SetPoint("LEFT", title, "RIGHT", 6, 0)
  local close = Kit.SmallButton(replies, "x", 18)
  close:SetPoint("TOPRIGHT", -8, -8)
  F:Script(close, "OnClick", function()
    repliesWanted = false
    replies:Hide()
  end)
  Kit.Tip(close, "Close", "Opens again with the next reply, or with the Replies button.")

  replies.empty = Kit.Text(replies, "GameFontDisableSmall")
  replies.empty:SetPoint("TOPLEFT", 10, -96)
  replies.empty:SetPoint("RIGHT", -10, 0)
  replies.empty:SetWordWrap(true)
  replies.empty:SetText("Answers to your messages land here, sorted by how they read. Right-click one to move it.")

  local scroll = CreateFrame("ScrollFrame", nil, replies)
  scroll:SetPoint("TOPLEFT", 8, -30)
  scroll:SetPoint("BOTTOMRIGHT", -8, BOTTOM_H + 4)
  scroll:EnableMouseWheel(true)
  replies.content = CreateFrame("Frame", nil, scroll)
  replies.content:SetSize(REPLY_W - 16, 1)
  scroll:SetScrollChild(replies.content)
  F:Script(scroll, "OnMouseWheel", function(self, delta)
    local max = math.max(0, replies.content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * REPLY_ROW * 2)))
  end)

  local rule = Kit.Rule(replies, 0.12)
  rule:SetPoint("BOTTOMLEFT", 8, BOTTOM_H)
  rule:SetPoint("BOTTOMRIGHT", -8, BOTTOM_H)
  local label = Kit.Text(replies, "GameFontNormalSmall")
  label:SetPoint("BOTTOMLEFT", 10, BOTTOM_H - 16)
  label:SetText("Goodbye to negative replies")
  replies.edit = Kit.EditBox(replies, REPLY_W - 28)
  replies.edit:SetMaxLetters(MSG_MAX)
  replies.edit:SetPoint("BOTTOMLEFT", 15, 46)
  local function Save()
    local text = Lib.Trim(replies.edit:GetText() or "")
    if text ~= (F.db.goodbye or "") then
      ARLE:SetOption(F.id, "goodbye", text)
    end
  end
  F:Script(replies.edit, "OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  F:Script(replies.edit, "OnEditFocusLost", Save)
  replies.auto = Kit.Check(replies)
  replies.auto:SetPoint("BOTTOMLEFT", 6, 22)
  local autoText = Kit.Text(replies, "GameFontHighlightSmall")
  autoText:SetPoint("LEFT", replies.auto, "RIGHT", 2, 1)
  autoText:SetText("Send it to new negative replies")
  F:Script(replies.auto, "OnClick", function(self)
    ARLE:SetOption(F.id, "goodbyeAuto", self:GetChecked() and true or false)
  end)
  Kit.Tip(replies.auto, "Goodbye by itself", "Each new negative reply gets the goodbye once (it opens in your chat "
    .. "box for your Enter on live Forever).")
  replies.byeAll = Kit.SmallButton(replies, "Send", 70)
  replies.byeAll:SetPoint("BOTTOMRIGHT", -8, 8)
  F:Script(replies.byeAll, "OnClick", function()
    Save()
    ByeAll()
  end)
  Kit.Tip(replies.byeAll, "Goodbye now", "Send the goodbye to every negative reply that hasn't had it.")
  replies.clear = Kit.SmallButton(replies, "Clear", 60)
  replies.clear:SetPoint("BOTTOMLEFT", 8, 8)
  F:Script(replies.clear, "OnClick", function(self)
    -- Two clicks (no Blizzard popup): the first arms it.
    if not self.armedAt or GetTime() - self.armedAt > 3 then
      self.armedAt = GetTime()
      self:SetText("Sure?")
      return
    end
    self.armedAt = nil
    self:SetText("Clear")
    wipe(Replies())
    Redraw()
  end)
  Kit.Tip(replies.clear, "Clear the list", "Click twice. The players stay on your messaged list, so they aren't "
    .. "messaged again within the set minutes.")
end

local function PlaceReplies()
  local panel = L.Panel()
  if panel and panel:IsShown() then
    local r, t = panel:GetRight(), panel:GetTop()
    if r and t then
      local s = panel:GetEffectiveScale() / replies:GetEffectiveScale()
      replies:ClearAllPoints()
      replies:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", r * s + 4, t * s)
      replies:SetHeight(math.max(260, panel:GetHeight() * s))
      replies.placed = true
    end
  elseif not replies.placed then
    replies:ClearAllPoints()
    replies:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    replies.placed = true
  end
end

function O.ToggleReplies()
  if replies and replies:IsShown() then
    repliesWanted = false
    replies:Hide()
  else
    repliesWanted = true
    O.Tick()
  end
end

Redraw = function()
  PaintFooter()
  PaintReplies()
end
O.Redraw = Redraw

-------------------------------------------------------------------------------
-- Called by LFGRoleFilter.lua
-------------------------------------------------------------------------------

-- Every 0.25 s while the feature is on.
function O.Tick()
  Watch()
  Pump()
  if repliesWanted and not InCombatLockdown() then
    if not replies then
      CreateReplies()
    end
    local wasShown = replies:IsShown()
    PlaceReplies()
    if not wasShown then
      replies:Show()
      PaintReplies()
    end
  end
  if footer and (current or #queue > 0) then
    PaintFooter()
  end
end

function O.Combat()
  if replies then
    replies:Hide() -- back after the fight (O.Tick) while wanted
  end
  if prompt then
    prompt:Hide()
  end
end

function O.Enable()
  wipe(queue)
  current, run, paused, autoBroken, waitReason = nil, nil, false, false, nil
  nextAt = 0
  Prune()
  for _, r in ipairs(Replies()) do
    r.byeQueued = nil
  end
  repliesWanted = #Replies() > 0
  local fmt = rawget(_G, "ERR_CHAT_PLAYER_NOT_FOUND_S")
  notFoundPattern = type(fmt) == "string" and ("^" .. Escape(fmt):gsub("%%%%s", "(.+)") .. "$") or nil
  F:On("CHAT_MSG_WHISPER", OnWhisper)
  F:On("CHAT_MSG_WHISPER_INFORM", OnInform)
  F:On("CHAT_MSG_SYSTEM", OnSystem)
end

function O.Disable()
  wipe(queue)
  if current then
    TakeBack(current)
  end
  current, run, paused = nil, nil, false
  if replies then
    replies:Hide()
  end
  if prompt then
    prompt:Hide()
  end
end

function O.Status()
  if current or #queue > 0 then
    return (" · messages: %d waiting%s"):format(#queue + (current and 1 or 0), paused and " (paused)" or "")
  end
  local n = F.char and type(F.char.replies) == "table" and #F.char.replies or 0
  return n > 0 and (" · %d repl%s"):format(n, n == 1 and "y" or "ies") or ""
end

function O.Report()
  local lines = {
    ("messages: %d waiting, current %s, paused %s, by itself %s (refused %s, restricted %s)"):format(#queue,
      current and (current.name .. " via " .. current.mode) or "none", tostring(paused), tostring(F.db.autoSend == true),
      tostring(autoBroken), tostring((F.db.autoSend and not autoBroken and not AutoAllowed()) or false)),
    ("messaged this hour: %d of %d; replies: %d"):format(SentLastHour(), HOUR_CAP, #Replies()),
  }
  for i, r in ipairs(Replies()) do
    if i > 10 then
      break
    end
    lines[#lines + 1] = ("  %s %s: %s"):format(r.tone or "?", r.name or "?", r.text or "")
  end
  return lines
end
