--!nonstrict
-- Parcel tracker bar widget - a package glyph with a round badge counting the
-- parcels still on their way. Glyph and badge turn orange when something can
-- be collected and red when a parcel has a problem. Click opens the panel,
-- right click refreshes.

local common = require("./lib/common.luau")

local parcels = noctalia.state.get("parcels.list") or {}
local busy = noctalia.state.get("parcels.busy") == true

local function summary()
  local active, color = 0, nil
  for _, p in ipairs(parcels) do
    if common.isActive(p.status) then
      active = active + 1
      if p.status == "failed" or p.status == "exception" or p.status == "needs_key" then
        color = common.COLORS.red
      elseif (p.status == "pickup" or p.status == "out_for_delivery") and color ~= common.COLORS.red then
        color = common.COLORS.orange
      end
    end
  end
  return active, color
end

local function tooltip()
  local rows = {}
  for _, p in ipairs(common.sorted(parcels)) do
    if common.isActive(p.status) then
      table.insert(rows, { common.title(p), common.label(p.status) })
    end
  end
  if #rows == 0 then
    return noctalia.tr("ui.no_active")
  end
  return rows
end

local function render()
  local active, color = summary()
  local children = {
    ui.glyph({ name = busy and "loader-2" or "package", color = color }),
  }
  if active > 0 and noctalia.getConfig("show_count") ~= false then
    table.insert(children, ui.row({ minWidth = 18, height = 18, paddingH = 5, radius = 9,
      fill = color or "on_surface/0.18", align = "center", justify = "center" }, {
      ui.label({ text = tostring(active), fontSize = 11, fontWeight = "bold", color = color and "#ffffff" or nil }),
    }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltip())
end

noctalia.state.watch("parcels.list", function(value)
  parcels = value or {}
  render()
end)

noctalia.state.watch("parcels.busy", function(value)
  busy = value == true
  render()
end)

-- Watches drive every change; the tick only covers the first draw.
noctalia.setUpdateInterval(60000)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("sergiiosy/parcels:panel")
end

function onRightClick()
  noctalia.state.set("parcels.cmd", { op = "refresh", nonce = noctalia.nowMs() })
end
