-- Guild gate: only members of the guild may use or change anything. For
-- everyone else no pack is loaded and the panel shows a warning.
local _, ns = ...
local ARLE = ns.ARLE

ARLE.guildName = "Associação Rei Leão"

-- Lower case, accents dropped, spaces collapsed, so "Associacao Rei Leao"
-- or a differently cased spelling still matches.
local ACCENTS = {
  ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
  ["é"] = "e", ["ê"] = "e", ["è"] = "e", ["í"] = "i", ["ì"] = "i",
  ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ò"] = "o", ["ú"] = "u", ["ü"] = "u", ["ç"] = "c",
  ["Á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ã"] = "a", ["É"] = "e", ["Ê"] = "e",
  ["Í"] = "i", ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ú"] = "u", ["Ç"] = "c",
}
local function Normalize(name)
  name = name:gsub("[\195][\128-\191]", ACCENTS)
  return (name:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end
ARLE.NormalizeGuild = Normalize

-- Right after login the client can report no guild, or a guild without its
-- name, before the server's guild data arrives. Until then (or GUILD_SETTLE
-- seconds pass) the answer is "checking", never "outsider".
local GUILD_SETTLE = 8
local settled = false

-- "member", "outsider", or "checking" while the guild is not known yet.
function ARLE:GuildState()
  if not IsInGuild() then
    return settled and "outsider" or "checking"
  end
  local name = GetGuildInfo("player")
  if not name then
    return "checking"
  end
  return Normalize(name) == Normalize(self.guildName) and "member" or "outsider"
end

function ARLE:IsMember()
  return self:GuildState() == "member"
end

-- Refuses (with a chat line) when the player may not change anything.
function ARLE:Allowed()
  local state = self:GuildState()
  if state == "member" then
    return true
  end
  if state == "checking" then
    self:Print("Still checking your guild. Try again in a moment.")
  else
    self:Print("Only members of " .. self.guildName .. " can change extensions.")
  end
  return false
end

-- Turns every feature on for members and off for everyone else. Runs at
-- login and whenever the guild changes (joined, left, kicked) mid-session.
-- Loading packs (and enabling features) waits for combat to end. Losing the
-- guild only counts once it is still true a few seconds later: the client
-- can briefly report no guild mid-session (zoning), which must not switch
-- every feature off and on again.
local OUTSIDER_CONFIRM = 5
local unlockQueued, outsiderCheck = false, false

function ARLE:ApplyGuild()
  if not self.ready then
    return
  end
  local state = self:GuildState()
  if state == "member" and not self.unlocked then
    if InCombatLockdown and InCombatLockdown() then
      if not unlockQueued then
        unlockQueued = true
        self.Secure:Run(function()
          unlockQueued = false
          self:ApplyGuild()
          self:Changed()
        end)
      end
      return
    end
    self.unlocked = true
    for id in pairs(self.catalog) do
      if self:EnsureDB(id).enabled ~= false and not self:MissingFor(id) then
        self:LoadModuleAddon(id)
      end
    end
    for _, def in pairs(self.modules) do
      if def.db and def.db.enabled ~= false then
        self:CallEnable(def)
      end
    end
  elseif state == "outsider" and self.unlocked and not outsiderCheck then
    outsiderCheck = true
    C_Timer.After(OUTSIDER_CONFIRM, function()
      outsiderCheck = false
      if self.unlocked and self:GuildState() == "outsider" then
        self.unlocked = false
        for _, def in pairs(self.modules) do
          self:CallDisable(def)
        end
        self:Changed()
      end
    end)
  end
end

local function RequestGuild()
  if IsInGuild() and not GetGuildInfo("player") then
    if C_GuildInfo and C_GuildInfo.GuildRoster then
      C_GuildInfo.GuildRoster()
    elseif GuildRoster then
      GuildRoster()
    end
  end
end

local guildState
-- One chat line per session once the guild check settles (Settings can turn
-- it off): loaded for members, disabled for everyone else.
local announced = false
function ARLE:AnnounceLogin()
  if announced or not self.ready then
    return
  end
  local state = self:GuildState()
  if state == "checking" then
    return
  end
  announced = true
  if self.db.loginMessage == false then
    return
  end
  local version = self.version and (" v" .. self.version) or ""
  if state == "member" then
    self:Print(self.title .. version .. " loaded. Type /arl to open it, /arl help for commands.")
  else
    self:Print(self.title .. version .. " is disabled: it is only for members of " .. self.guildName .. ".")
  end
end

local function GuildChanged()
  local state = ARLE:GuildState()
  if state ~= guildState then
    guildState = state
    ARLE:ApplyGuild()
    if ARLE.ready then
      ARLE:Changed()
    end
  end
  ARLE:AnnounceLogin()
end

local guildEvents = CreateFrame("Frame")
guildEvents:RegisterEvent("PLAYER_GUILD_UPDATE")
guildEvents:RegisterEvent("GUILD_ROSTER_UPDATE")
guildEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
guildEvents:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_ENTERING_WORLD" then
    -- Ask the server for guild data so GetGuildInfo fills in, and stop
    -- waiting for it after a few seconds (a guildless player gets no reply).
    RequestGuild()
    if not settled then
      C_Timer.After(GUILD_SETTLE, function()
        settled = true
        GuildChanged()
      end)
    end
  end
  -- Only the timer settles the check: a roster event can arrive before
  -- IsInGuild() turns true, and settling then would call a member an
  -- outsider (and announce it). A known guild name needs no waiting.
  GuildChanged()
end)
