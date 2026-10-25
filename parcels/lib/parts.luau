--!nonstrict
-- Small ui.* building blocks shared by the panel and the desktop widgets, so
-- a status looks identical everywhere: a tinted icon tile, a pill chip and
-- the 5-segment progress strip.

local common = require("./common.luau")

local M = {}

-- ui.label with the font picked in the panel (published by the service as
-- parcels.font); empty leaves fontFamily unset so the shell font is inherited.
-- Entries re-render on the parcels.font watch to pick up a change.
function M.label(props)
  local font = noctalia.state.get("parcels.font") or ""
  if font ~= "" and props.fontFamily == nil then
    props.fontFamily = font
  end
  return ui.label(props)
end

-- Rounded square with the status glyph on a 16% tint of the status color.
function M.tile(status, size)
  local meta = common.meta(status)
  size = size or 40
  return ui.column({
    width = size, height = size, radius = math.floor(size * 0.28),
    fill = common.tint(meta.color, 0.16), align = "center", justify = "center",
  }, {
    ui.glyph({ name = meta.glyph, size = math.floor(size * 0.5), color = meta.color }),
  })
end

function M.chip(status)
  local meta = common.meta(status)
  return ui.row({ paddingH = 9, paddingV = 4, radius = 999, fill = common.tint(meta.color, 0.15), align = "center" }, {
    M.label({ text = common.label(status), fontSize = 11, fontWeight = "bold", color = meta.color }),
  })
end

-- Segments before the current step are solid, the current one is softer,
-- the rest show the track.
function M.steps(status, height)
  local meta = common.meta(status)
  local segments = {}
  for i = 1, 5 do
    local fill = "on_surface/0.10"
    if i < meta.step then
      fill = meta.color
    elseif i == meta.step then
      fill = common.tint(meta.color, 0.55)
    end
    table.insert(segments, ui.box({ flexGrow = 1, height = height or 4, radius = 2, fill = fill }))
  end
  return ui.row({ gap = 4 }, segments)
end

-- "Leopoli · 19/10 06:33" from whatever parts the parcel has.
function M.whereWhen(p)
  local parts = {}
  if p.detail ~= "" then
    table.insert(parts, p.detail)
  end
  if p.eventTime ~= "" then
    table.insert(parts, p.eventTime)
  end
  return table.concat(parts, " · ")
end

return M
