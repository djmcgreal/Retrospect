-- The flight paths a character knows, read at a flight master.
--
-- The flight master's list holds a slot for every point on the continent, discovered or not, so
-- each slot's type is what says which the character has: CURRENT (this one) and REACHABLE are
-- known; DISTANT, which the stock TaxiFrame hides, is undiscovered. DISTANT also covers a known
-- point on a separate network (Undercity's, seen from Booty Bay), so one visit can miss points the
-- character has. Flight points are never unlearned, so each visit adds what it lists and keeps
-- what earlier visits saw. Same rule as ShortestPathForever's Transport/Taxi.lua, which records it
-- on Forever build 70862: at Stormwind, 5 known points CURRENT/REACHABLE, the 13 others DISTANT.

local Core = NorgannonCore
local R = Retrospect
if R.disabled then return end

local Scan = R.Scan
local Store = R.Store

-- A taxi record without this rule was written before it and lists every point on the map.
local RULE = 2

function Scan:Taxi()
  local count = R.Global("NumTaxiNodes") or 0
  if count == 0 then
    Scan.Note("Flight paths", false, "the flight master listed nothing")
    return
  end
  -- Slot -> node, from the map query; whether a slot is known comes from the classic list.
  local uiMap = R.Global("GetTaxiMapID")
  local bySlot = {}
  for _, node in ipairs(uiMap and R.In("C_TaxiMap", "GetAllTaxiNodes", uiMap) or {}) do
    if node.slotIndex and node.nodeID then bySlot[node.slotIndex] = node end
  end

  local c = Store:Me()
  local taxi = c.taxi
  if not taxi or taxi.rule ~= RULE then taxi = { rule = RULE, names = {} } end
  local ids = Store.UnpackIds(taxi.nodes)
  local here, added = 0, 0
  for slot = 1, count do
    local kind = R.Global("TaxiNodeGetType", slot)
    local node = bySlot[slot]
    if node and (kind == "CURRENT" or kind == "REACHABLE") then
      here = here + 1
      if not ids[node.nodeID] then added = added + 1 end
      ids[node.nodeID] = true
      local name = R.Global("TaxiNodeName", slot)
      taxi.names[node.nodeID] = (name and name ~= "") and name or node.name
    end
  end
  if here == 0 then
    Scan.Note("Flight paths", false, "none known among " .. count .. " slots")
    return
  end
  local total
  taxi.nodes, total = Store.PackIds(ids)
  taxi.seen = R.Now()
  c.taxi = taxi
  Scan.Note("Flight paths", true, here .. " reachable here, " .. added .. " new, " .. total .. " known")
  R:Changed(Store:MyKey())
end

Core:On("TAXIMAP_OPENED", "retrospect.taxi", function()
  Core:NextFrame(function() Scan:Taxi() end, "retrospect.taxi")
end)
