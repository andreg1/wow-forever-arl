-- Saved variables: ARLExtensionsDB (account wide: settings per feature, the
-- theme) and ARLExtensionsCharDB (this character: feature data such as item
-- locks, gear set links, remembered weapons).
local _, ns = ...
local ARLE = ns.ARLE

local pending -- features registered before the saved variables loaded

function ARLE:EnsureDB(id, defaults)
  local modules = self.db.modules
  local db = modules[id]
  if type(db) ~= "table" then
    db = {}
    modules[id] = db
  end
  if defaults then
    for key, value in pairs(defaults) do
      if db[key] == nil then
        if type(value) == "table" then
          -- Tables (lists, maps) are copied so features never share one.
          local copy = {}
          for k, v in pairs(value) do
            copy[k] = v
          end
          db[key] = copy
        else
          db[key] = value
        end
      end
    end
  end
  if db.enabled == nil then
    db.enabled = true
  end
  return db
end

-- This character's table for one feature.
function ARLE:CharDB(id)
  local sv = _G.ARLExtensionsCharDB
  if type(sv) ~= "table" then
    sv = {}
    _G.ARLExtensionsCharDB = sv
  end
  sv.features = type(sv.features) == "table" and sv.features or {}
  local t = sv.features[id]
  if type(t) ~= "table" then
    t = {}
    sv.features[id] = t
  end
  return t
end

function ARLE:QueueBind(def)
  pending = pending or {}
  pending[#pending + 1] = def
end

function ARLE:InitDB()
  if self.db then
    return
  end
  local sv = _G.ARLExtensionsDB
  if type(sv) ~= "table" then
    sv = {}
    _G.ARLExtensionsDB = sv
  end
  if type(sv.modules) ~= "table" then
    sv.modules = {}
  end
  -- ARL is the default theme. Versions before 0.3.0 wrote "auto" for
  -- everyone who never picked one, so that moves to ARL once.
  if sv.theme == nil or (sv.theme == "auto" and not sv.themeV3) then
    sv.theme = "arl"
  end
  sv.themeV3 = true
  self.db = sv
  if pending then
    local queued = pending
    pending = nil
    for i = 1, #queued do
      self:Bind(queued[i])
    end
  end
end
