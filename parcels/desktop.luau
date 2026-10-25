--!nonstrict
-- Parcel tracker desktop widget - a read-only list of tracked parcels, most
-- urgent first, each with its status tile and a compact progress strip.
-- Desktop widgets cannot take keyboard focus, so adding parcels happens in
-- the panel; the refresh button pokes the service.

local common = require("./lib/common.luau")
local parts = require("./lib/parts.luau")

local maxItems = noctalia.getConfig("max_items") or 6
local showDelivered = noctalia.getConfig("show_delivered") ~= false

local parcels = noctalia.state.get("parcels.list") or {}
local busy = noctalia.state.get("parcels.busy") == true

local function row(p)
  local meta = common.meta(p.status)
  local sub = common.label(p.status)
  if p.detail ~= "" then
    sub = `{sub} · {p.detail}`
  end

  return ui.column({ key = "parcel-" .. p.number, gap = 8 }, {
    ui.separator({ color = "on_surface/0.08" }),
    ui.row({ gap = 10, align = "center" }, {
      parts.tile(p.status, 30),
      ui.column({ gap = 1, flexGrow = 1 }, {
        parts.label({ text = common.title(p), fontSize = 13, fontWeight = "bold", maxLines = 1, maxWidth = 220 }),
        parts.label({ text = sub, fontSize = 11, fontWeight = "bold", color = meta.color, maxLines = 1, maxWidth = 220 }),
      }),
      ui.column({ width = 54 }, { parts.steps(p.status, 3) }),
    }),
  })
end

local function render()
  local visible, active = {}, 0
  for _, p in ipairs(common.sorted(parcels)) do
    if common.isActive(p.status) then
      active = active + 1
    end
    if (showDelivered or common.isActive(p.status)) and #visible < maxItems then
      table.insert(visible, row(p))
    end
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "package", size = 18, color = common.COLORS.orange }),
      parts.label({ text = noctalia.tr("ui.title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      parts.label({ text = noctalia.trp("ui.active_count", active), fontSize = 12, fontWeight = "bold", color = "outline" }),
      ui.button({ glyph = busy and "loader-2" or "refresh", variant = "ghost", controlSize = "sm",
        enabled = not busy,
        onClick = function() noctalia.state.set("parcels.cmd", { op = "refresh", nonce = noctalia.nowMs() }) end }),
    }),
  }

  if #visible == 0 then
    table.insert(children, parts.label({ text = noctalia.tr("ui.empty_desktop"), fontSize = 12, color = "outline" }))
  else
    for _, r in ipairs(visible) do
      table.insert(children, r)
    end
  end

  desktopWidget.render(ui.column({ gap = 8, minWidth = 340, padding = 4 }, children))
end

noctalia.state.watch("parcels.list", function(v) parcels = v or {}; render() end)
noctalia.state.watch("parcels.font", function() render() end)
noctalia.state.watch("parcels.busy", function(v) busy = v == true; render() end)

render()
