-- Officer Tools: built in, listed under General after Settings, and only for
-- officers and the Guild Master (hidden from everyone else). Shows which
-- online guild members run this addon and which version, with a Warn button
-- that names the ones who don't (or run an older one) in guild chat.
--
-- Protocol (addon messages, see Core.lua). Every member takes part, so that
-- officers can see them:
--   H <version>  "hello": sent to GUILD at login, and whispered back to
--                whoever asked
--   Q <version>  "who runs it?": sent to GUILD by an officer's client at
--                login, when Officer Tools opens with stale answers, and by
--                Refresh; every member running the addon whispers an H back
local _, ns = ...
local ARLE = ns.ARLE

local HELLO_DELAY = 6     -- after login, so the guild roster has arrived
local ANSWER_WAIT = 6     -- seconds before silence means "not running"
local REFRESH_COOLDOWN = 10
local STALE_AFTER = 60    -- re-ask when Officer Tools opens after this long
local WARN_COOLDOWN = 60
local LINE_GAP = 1.2     -- seconds between guild chat lines when warning (the game drops quicker ones)
local LINE_MAX = 240     -- characters per guild chat line (the game's limit is 255)

local versions = {} -- short name -> version string
local queriedAt     -- GetTime() of the last query
local lastRefresh, lastWarn = -math.huge, -math.huge
local toldNewer

-------------------------------------------------------------------------------
-- Versions
-------------------------------------------------------------------------------

local function Parse(v)
  local parts = {}
  for n in tostring(v or ""):gmatch("%d+") do
    parts[#parts + 1] = tonumber(n)
  end
  return parts
end

-- -1, 0 or 1, like a <=> b. "0.10.0" is newer than "0.9.2".
local function Compare(a, b)
  local pa, pb = Parse(a), Parse(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  return 0
end
ARLE.CompareVersions = Compare

local function Mine()
  return ARLE.version or "0"
end

-- The newest version anyone online reported, ours included.
local function Latest()
  local latest = Mine()
  for _, v in pairs(versions) do
    if Compare(v, latest) > 0 then
      latest = v
    end
  end
  return latest
end

local function Heard(name, version)
  versions[name] = version
  if not toldNewer and Compare(version, Mine()) > 0 then
    toldNewer = true
    ARLE:Print("A newer version (v" .. version .. ") is out; you have v" .. Mine()
      .. ". Ask an officer for the update.")
  end
  ARLE:Changed()
end

-- Only guildmates count (the GUILD channel is members only; a whisper is
-- checked against the roster), and only a plain version number: a stranger's
-- "v99" must not tell the guild to update, and nothing odd reaches guild chat.
local function Trusted(sender, payload, channel)
  if type(payload) ~= "string" or #payload > 16 or not payload:match("^%d+[%.%d]*$") then
    return false
  end
  return channel == "GUILD" or ARLE:IsGuildmate(sender)
end

local REPLY_GAP = 30 -- seconds between whispered answers to one asker
local repliedAt = {}

ARLE:RegisterComm("H", function(sender, payload, channel)
  if Trusted(sender, payload, channel) then
    Heard(sender, payload)
  end
end)

ARLE:RegisterComm("Q", function(sender, payload, channel)
  if not Trusted(sender, payload, channel) then
    return
  end
  Heard(sender, payload)
  local now = GetTime()
  if repliedAt[sender] and now - repliedAt[sender] < REPLY_GAP then
    return
  end
  repliedAt[sender] = now
  ARLE:Send("H", Mine(), "WHISPER", sender)
end)

-------------------------------------------------------------------------------
-- Guild roster
-------------------------------------------------------------------------------

local function IsOfficer()
  if IsGuildLeader and IsGuildLeader() then
    return true
  end
  if C_GuildInfo and C_GuildInfo.IsGuildOfficer then
    return C_GuildInfo.IsGuildOfficer() and true or false
  end
  return CanEditOfficerNote and CanEditOfficerNote() and true or false
end
ARLE.IsGuildOfficer = IsOfficer

-- Online members with their state: "you", "current", "outdated",
-- "missing" (no answer) or "checking" (in the few seconds after a query).
-- Before any query nobody has been asked, which also reads as "missing";
-- in practice an officer's client asks at login and when the pane opens.
local function Members()
  local list = {}
  local me = ARLE:ShortName(UnitName("player"))
  local latest = Latest()
  local waiting = queriedAt and (GetTime() - queriedAt) < ANSWER_WAIT
  local total = GetNumGuildMembers and GetNumGuildMembers() or 0
  for i = 1, total do
    local name, rank, rankIndex, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
    if name and online then
      local short = ARLE:ShortName(name)
      local m = { name = short, rank = rank, rankIndex = rankIndex, class = classFile }
      if short == me then
        m.version, m.state = Mine(), "you"
      elseif versions[short] then
        m.version = versions[short]
        m.state = Compare(m.version, latest) < 0 and "outdated" or "current"
      else
        m.state = waiting and "checking" or "missing"
      end
      list[#list + 1] = m
    end
  end
  local order = { outdated = 1, missing = 2, checking = 3, current = 4, you = 5 }
  table.sort(list, function(a, b)
    if order[a.state] ~= order[b.state] then
      return order[a.state] < order[b.state]
    end
    return a.name:lower() < b.name:lower()
  end)
  return list, latest
end

local function Refresh(force)
  if force ~= true and GetTime() - lastRefresh < REFRESH_COOLDOWN then
    return
  end
  lastRefresh = GetTime()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  end
  queriedAt = GetTime()
  ARLE:Send("Q", Mine(), "GUILD")
  ARLE:Changed()
  -- Redraw once the wait is over, so silent members show as missing.
  C_Timer.After(ANSWER_WAIT + 0.1, function()
    ARLE:Changed()
  end)
end

-------------------------------------------------------------------------------
-- Warn in guild chat (officers and the Guild Master)
-------------------------------------------------------------------------------

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or _G.SendChatMessage

-- One header line, then the members who aren't up to date, as many to a
-- line as fit (few lines: the game drops guild chat sent in a quick burst):
--   [ARL Extensions] Version check (v0.2.3)
--   Old (has v0.2.0); Jaina (not installed)
local function WarnLines(list, latest)
  local entries = {}
  for _, m in ipairs(list) do
    if m.state == "outdated" then
      entries[#entries + 1] = m.name .. " (has v" .. m.version .. ")"
    elseif m.state == "missing" then
      entries[#entries + 1] = m.name .. " (not installed)"
    end
  end
  local count = #entries
  if count == 0 then
    return {}, 0
  end
  local lines, line = { "[ARL Extensions] Version check (v" .. latest .. ")" }, ""
  for _, e in ipairs(entries) do
    if line ~= "" and #line + 2 + #e > LINE_MAX then
      lines[#lines + 1] = line
      line = ""
    end
    line = line == "" and e or (line .. "; " .. e)
  end
  lines[#lines + 1] = line
  return lines, count
end
ARLE.GuildWarnLines = WarnLines

-- The first call arms it (the button reads "Post N lines?"), a second one
-- within ARM_TIME posts. No StaticPopupDialogs entry: writing into that
-- Blizzard table taints the shared popups.
local ARM_TIME = 5
local armedUntil = 0

local function WarnArmed()
  return GetTime() < armedUntil
end

local function Warn()
  if not IsOfficer() then
    ARLE:Print("Only officers and the Guild Master can warn the guild.")
    return
  end
  local list, latest = Members()
  local lines, count = WarnLines(list, latest)
  if count == 0 then
    ARLE:Print("Everyone online is up to date.")
    return
  end
  if not WarnArmed() then
    armedUntil = GetTime() + ARM_TIME
    ARLE:Print("Click Warn again within " .. ARM_TIME .. " seconds to post " .. count
      .. " name(s) in guild chat.")
    ARLE:Changed()
    C_Timer.After(ARM_TIME + 0.1, function()
      ARLE:Changed()
    end)
    return
  end
  armedUntil = 0
  lastWarn = GetTime()
  -- Spaced out: the game throttles chat sent in quick bursts.
  SendChat(lines[1], "GUILD")
  for i = 2, #lines do
    C_Timer.After((i - 1) * LINE_GAP, function()
      SendChat(lines[i], "GUILD")
    end)
  end
  ARLE:Changed()
end

-------------------------------------------------------------------------------
-- Pane in the /arl window
-------------------------------------------------------------------------------

local STATE_TEXT = {
  you = { "you", 0.6, 0.8, 1 },
  current = { "up to date", 0.45, 0.9, 0.5 },
  outdated = { "outdated", 1, 0.6, 0.25 },
  missing = { "not running", 1, 0.35, 0.35 },
  checking = { "checking...", 0.7, 0.7, 0.7 },
}
local ROW_H = 20

local entry = {
  id = "OfficerTools",
  title = "Officer Tools",
  group = "General",
  builtin = true,
  order = 2,
  description = "Which online guild members run this addon, and which version. Warn names the ones who don't in guild chat.",
  defaults = {},
  -- Only officers and the Guild Master see this entry at all.
  visible = IsOfficer,
}

function entry:CreatePane(pane)
  local kit = ARLE.UIKit
  pane.summary = kit.Text(pane, "GameFontHighlightSmall")
  pane.summary:SetPoint("TOPLEFT", 0, 0)
  pane.summary:SetPoint("RIGHT", 0, 0)

  pane.refresh = kit.Button(pane, "Refresh", 90)
  pane.refresh:SetPoint("BOTTOMLEFT", 0, 0)
  pane.refresh:SetScript("OnClick", function()
    Refresh()
  end)

  pane.warn = kit.Button(pane, "Warn in guild chat", 150)
  pane.warn:SetPoint("LEFT", pane.refresh, "RIGHT", 8, 0)
  pane.warn:SetScript("OnClick", Warn)

  pane.list = CreateFrame("ScrollFrame", "ARLEOfficerToolsList", pane, "UIPanelScrollFrameTemplate")
  pane.list:SetPoint("TOPLEFT", pane.summary, "BOTTOMLEFT", 0, -8)
  pane.list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -24, 30)
  ARLE.Skin:ScrollBar(pane.list)
  pane.child = CreateFrame("Frame", nil, pane.list)
  pane.child:SetSize(300, 1)
  pane.list:SetScrollChild(pane.child)
  pane.rows = {}
end

function entry:RefreshPane(pane)
  local kit = ARLE.UIKit
  -- Opening the pane with no answers, or old ones, asks the guild again.
  if (not queriedAt or GetTime() - queriedAt > STALE_AFTER) and not pane.asking then
    pane.asking = true
    C_Timer.After(0, function()
      pane.asking = nil
      Refresh(true)
    end)
  end
  local list, latest = Members()
  local counts = { current = 0, outdated = 0, missing = 0, checking = 0, you = 0 }
  for _, m in ipairs(list) do
    counts[m.state] = counts[m.state] + 1
  end
  pane.summary:SetText(string.format(
    "Latest v%s  ·  %d online  ·  %d up to date  ·  %d outdated  ·  %d not running%s",
    latest, #list, counts.current + counts.you, counts.outdated, counts.missing,
    counts.checking > 0 and "   (asking...)" or ""
  ))

  local width = math.max(pane.list:GetWidth(), 200)
  pane.child:SetWidth(width)
  for i, m in ipairs(list) do
    local row = pane.rows[i]
    if not row then
      row = CreateFrame("Frame", nil, pane.child)
      row:SetHeight(ROW_H)
      row.name = kit.Text(row, "GameFontHighlight")
      row.name:SetPoint("LEFT", 2, 0)
      row.name:SetWidth(width * 0.38)
      row.rank = kit.Text(row, "GameFontDisableSmall")
      row.rank:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
      row.rank:SetWidth(width * 0.27)
      row.state = kit.Text(row, "GameFontHighlightSmall")
      row.state:SetPoint("RIGHT", -2, 0)
      pane.rows[i] = row
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT")
    local color = m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
    row.name:SetText(m.name)
    if color then
      row.name:SetTextColor(color.r, color.g, color.b)
    else
      row.name:SetTextColor(1, 1, 1)
    end
    row.rank:SetText(m.rank or "")
    local st = STATE_TEXT[m.state]
    row.state:SetText(st[1] .. (m.version and m.state ~= "current" and (" v" .. m.version) or ""))
    row.state:SetTextColor(st[2], st[3], st[4])
    row:Show()
  end
  for i = #list + 1, #pane.rows do
    pane.rows[i]:Hide()
  end
  pane.child:SetHeight(math.max(#list * ROW_H, 1))

  local officer = IsOfficer()
  pane.warn:SetShown(officer)
  pane.warn:SetText(WarnArmed() and "Click again to post" or "Warn in guild chat")
  pane.warn:SetEnabled(officer and (counts.outdated + counts.missing) > 0 and GetTime() - lastWarn >= WARN_COOLDOWN)
  pane.refresh:SetEnabled(GetTime() - lastRefresh >= REFRESH_COOLDOWN)
end

function entry:GetStatus()
  local _, latest = Members()
  if Compare(latest, Mine()) > 0 then
    return "|cffff9944You have v" .. Mine() .. "; v" .. latest .. " is out.|r"
  end
  return "You have v" .. Mine() .. " (latest known)"
end

-- Once the player is confirmed in the guild (built-in entries only enable
-- then): officers ask everyone, which also announces their own version;
-- everyone else just says hello.
function entry:OnEnable()
  C_Timer.After(HELLO_DELAY, function()
    if not ARLE:IsMember() then
      return
    end
    if IsOfficer() then
      Refresh(true)
    else
      ARLE:Send("H", Mine(), "GUILD")
    end
  end)
end

ARLE.OfficerRefresh = Refresh
ARLE.OfficerMembers = Members
ARLE.WarnGuild = Warn
ARLE:RegisterModule(entry)
