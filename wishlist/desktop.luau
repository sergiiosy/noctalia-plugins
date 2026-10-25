--!nonstrict
-- Steam Wishlist desktop widget - the four best current deals as a 2x2 grid
-- of covers with their discounted price. Click a cover to open the store page.

local common = require("./lib/common.luau")

local WIDTH = 420
local CELL = 202
local CELL_H = 94 -- Steam header art is 460x215

local games = noctalia.state.get("wishlist.games") or {}

local function cell(g)
  return ui.column({ key = "d-" .. tostring(g.appid), gap = 4, width = CELL, onClick = function() common.open(g) end }, {
    common.cover(g, CELL, CELL_H),
    ui.label({ text = g.name, fontSize = 12, fontWeight = "bold", maxLines = 1, maxWidth = CELL }),
    common.priceRow(g, 12),
  })
end

local function render()
  local sale = common.sorted(common.onSale(games), "discount")
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "brand-steam", size = 18, color = common.COLORS.steam }),
      ui.label({ text = noctalia.tr("ui.deals_title"), fontSize = 15, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr("ui.on_sale_count", { count = tostring(#sale) }), fontSize = 12, color = "outline" }),
    }),
  }
  if #sale == 0 then
    table.insert(rows, ui.label({ text = noctalia.tr("ui.no_sales"), fontSize = 12, color = "outline", maxLines = 2,
      maxWidth = WIDTH - 8 }))
  end
  for i = 1, math.min(4, #sale), 2 do
    local line = { cell(sale[i]) }
    if sale[i + 1] then
      table.insert(line, cell(sale[i + 1]))
    end
    table.insert(rows, ui.row({ gap = 8 }, line))
  end
  desktopWidget.render(ui.column({ width = WIDTH, padding = 4, gap = 10 }, rows))
end

noctalia.state.watch("wishlist.games", function(v) games = v or {}; render() end)

noctalia.setUpdateInterval(60000)

function update()
  render()
end
