-- EllesmereUI integration: a "Associação Rei Leão's Extensions" section in EUI's own
-- options window (Plugin API), so EUI players can flip modules from where
-- they already configure their UI. Settings still live in /arl.
local _, ns = ...
local ARLE = ns.ARLE

if not (EllesmereUI and EllesmereUI.RegisterPlugin) then
  return
end

local PLUGIN, KEY = ARLE.name, "Modules"
local fromPage = false -- a toggle on EUI's own page is changing state

local function BuildPage(_, parent, yOffset)
  local W = EllesmereUI.Widgets
  local y = yOffset
  local _, h
  if not ARLE.ready then
    return 0
  end
  if not ARLE:IsMember() then
    _, h = W:SectionHeader(parent, "GUILD MEMBERS ONLY", y)
    y = y - h
    _, h = W:SectionHeader(parent, "Only " .. ARLE.guildName .. " members can use these extensions", y)
    y = y - h
    return math.abs(y)
  end
  for _, group in ipairs(ARLE:GetGroups()) do
    -- Settings has no on/off switch (it lives in /arl), so it is left out
    -- here, and so is a group with nothing else in it.
    local toggles = {}
    for _, info in ipairs(group.modules) do
      if not info.builtin then
        toggles[#toggles + 1] = info
      end
    end
    if #toggles > 0 then
      _, h = W:SectionHeader(parent, group.label:upper(), y)
      y = y - h
    end
    for _, info in ipairs(toggles) do
      local id = info.id
      _, h = W:Toggle(parent, info.title, y, function()
        return ARLE:GetInfo(id).enabled
      end, function(value)
        fromPage = true
        ARLE:SetModuleEnabled(id, value)
        fromPage = false
      end)
      y = y - h
    end
  end
  return math.abs(y)
end

local registered = EllesmereUI.RegisterPlugin(PLUGIN, {
  label = ARLE.title,
  modules = {
    {
      key = KEY,
      title = "Extensions",
      description = "Turn ARL Extensions features on or off. /arl has their settings.",
      pages = { "Modules" },
      buildPage = BuildPage,
    },
  },
})

-- Keep EUI's cached page in step with toggles made in /arl.
if registered then
  ARLE:OnChange(function()
    if fromPage then
      return
    end
    local full = EllesmereUI.GetPluginModuleKey and EllesmereUI.GetPluginModuleKey(PLUGIN, KEY)
    if not full then
      return
    end
    if EllesmereUI.InvalidateModulePageCache then
      pcall(EllesmereUI.InvalidateModulePageCache, EllesmereUI, full)
    end
    if EllesmereUI.GetActiveModule and EllesmereUI:GetActiveModule() == full and EllesmereUI.RefreshPage then
      pcall(EllesmereUI.RefreshPage, EllesmereUI, true)
    end
  end)
end
