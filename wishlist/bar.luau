--!nonstrict
-- Steam Wishlist bar widget - the Steam glyph with a green badge counting the
-- wishlist games on sale. The tooltip lists the best deals. Click opens the
-- panel, right click refreshes the prices.

local common = require("./lib/common.luau")

local games = noctalia.state.get("wishlist.games") or {}
local status = noctalia.state.get("wishlist.status") or {}

local function tooltip(sale)
  if status.error and status.error ~= "" then
    return status.error
  end
  if #sale == 0 then
    return noctalia.tr("ui.no_sales")
  end
  local rows = {}
  for i, g in ipairs(common.sorted(sale, "discount")) do
    if i > 8 then
      break
    end
    table.insert(rows, { g.name, `-{g.discount}% · {g.finalFmt or ""}` })
  end
  return rows
end

local function render()
  local sale = common.onSale(games)
  local C = common.COLORS
  local children = {
    ui.glyph({ name = status.busy and #games == 0 and "loader-2" or "brand-steam",
      color = (status.error or "") ~= "" and C.red or (#sale > 0 and C.steam or nil) }),
  }
  if #sale > 0 and noctalia.getConfig("show_count") ~= false then
    table.insert(children, ui.row({ minWidth = 18, height = 18, paddingH = 5, radius = 9, fill = C.saleBg,
      align = "center", justify = "center" }, {
      ui.label({ text = tostring(#sale), fontSize = 11, fontWeight = "bold", color = C.saleFg }),
    }))
  end
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  barWidget.setTooltip(tooltip(sale))
end

noctalia.state.watch("wishlist.games", function(v) games = v or {}; render() end)
noctalia.state.watch("wishlist.status", function(v) status = v or {}; render() end)

noctalia.setUpdateInterval(60000)

function update()
  render()
end

function onClick()
  noctalia.togglePanel("sergiiosy/wishlist:panel")
end

function onRightClick()
  noctalia.state.set("wishlist.cmd", { op = "refresh", nonce = noctalia.nowMs() })
end
