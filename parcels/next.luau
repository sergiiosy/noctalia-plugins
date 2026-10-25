--!nonstrict
-- Parcel tracker "next" desktop widget - a small square tile, iOS style,
-- showing only the most urgent parcel still on its way: what to collect
-- first, otherwise what arrives next.

local common = require("./lib/common.luau")
local parts = require("./lib/parts.luau")

local parcels = noctalia.state.get("parcels.list") or {}

local function render()
  local next = nil
  for _, p in ipairs(common.sorted(parcels)) do
    if common.isActive(p.status) then
      next = p
      break
    end
  end

  local children
  if next then
    local meta = common.meta(next.status)
    local carrier = next.provider ~= "" and next.provider or common.carrierName(next.carrier)
    children = {
      parts.tile(next.status, 36),
      ui.spacer({ flexGrow = 1 }),
      parts.label({ text = string.upper(common.label(next.status)), fontSize = 11, fontWeight = "bold", color = meta.color, maxLines = 1 }),
      parts.label({ text = common.title(next), fontSize = 20, fontWeight = "bold", maxLines = 1, maxWidth = 150 }),
      parts.label({ text = carrier, fontSize = 12, color = "on_surface_variant", maxLines = 1, maxWidth = 150 }),
      next.detail ~= "" and parts.label({ text = next.detail, fontSize = 12, color = "on_surface_variant", maxLines = 2, maxWidth = 150 }) or nil,
    }
  else
    children = {
      parts.tile("delivered", 36),
      ui.spacer({ flexGrow = 1 }),
      parts.label({ text = noctalia.tr("ui.no_active"), fontSize = 14, fontWeight = "bold", maxLines = 2, maxWidth = 150 }),
    }
  end

  desktopWidget.render(ui.column({ gap = 2, width = 150, height = 150, padding = 4 }, children))
end

noctalia.state.watch("parcels.list", function(v) parcels = v or {}; render() end)
noctalia.state.watch("parcels.font", function() render() end)

render()
