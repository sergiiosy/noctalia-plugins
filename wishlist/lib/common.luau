--!nonstrict
-- Shared helpers: colors, sorting, the price badge and small formatters, so
-- the panel and the desktop widget show a game the same way.
--
-- A game, as published by the service in wishlist.games:
--   appid, name, path, final, orig (cents), finalFmt, origFmt, discount (%),
--   ends (Unix seconds or nil), coming, free, available, added, cover (local
--   path or nil), lowest (true when the price is the lowest seen), alert (cents or nil)

local M = {}

M.COLORS = {
  steam = "#66c0f4",
  saleBg = "#4c6b22",
  saleFg = "#d6f06b",
  orange = "#ff9f0a",
  red = "#ff453a",
  gray = "#8e8e93",
}
local C = M.COLORS

function M.tint(hex, alpha)
  return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
end

M.SORTS = { "discount", "price", "ends", "added" }

local function finalOrMax(g)
  return g.available and g.final or math.huge
end

function M.sorted(list, sort)
  local copy = {}
  for i, g in ipairs(list) do
    copy[i] = g
  end
  local by = {
    discount = function(a, b)
      if a.discount ~= b.discount then
        return a.discount > b.discount
      end
      return finalOrMax(a) < finalOrMax(b)
    end,
    price = function(a, b)
      return finalOrMax(a) < finalOrMax(b)
    end,
    ends = function(a, b)
      return (a.ends or math.huge) < (b.ends or math.huge)
    end,
    added = function(a, b)
      return (a.added or 0) > (b.added or 0)
    end,
  }
  table.sort(copy, by[sort] or by.discount)
  return copy
end

function M.onSale(games)
  local out = {}
  for _, g in ipairs(games or {}) do
    if g.available and (g.discount or 0) > 0 then
      table.insert(out, g)
    end
  end
  return out
end

-- "finisce tra 8 h" / "fino al 3 nov".
function M.endsText(ends, now)
  if not ends then
    return nil
  end
  now = now or os.time()
  local h = math.floor((ends - now) / 3600 + 0.5)
  if h < 24 then
    return noctalia.tr("ui.ends_in", { h = tostring(math.max(h, 0)) })
  end
  return noctalia.tr("ui.ends_on", { date = noctalia.formatTime("%d/%m", ends) })
end

-- "300" (₴) -> cents, "" -> nil.
function M.parseAmount(text)
  local n = tonumber((tostring(text or ""):gsub(",", "."):gsub("[^%d%.]", "")))
  if n and n > 0 then
    return math.floor(n * 100 + 0.5)
  end
  return nil
end

-- Steam-style price: a green "-70%" box joined to the price box. Without a
-- discount just the price; "In arrivo" / "Non disponibile" when there is none.
function M.priceRow(g, size)
  size = size or 13
  if not g.available then
    return ui.label({ text = noctalia.tr(g.coming and "price.coming" or "price.unavailable"), fontSize = size - 1,
      color = "outline", maxLines = 1 })
  end
  if g.free then
    return ui.label({ text = noctalia.tr("price.free"), fontSize = size, fontWeight = "bold", maxLines = 1 })
  end
  if (g.discount or 0) == 0 then
    return ui.label({ text = g.finalFmt or "", fontSize = size, fontWeight = "bold", color = "outline", maxLines = 1 })
  end
  return ui.row({ gap = 0, align = "center" }, {
    ui.row({ paddingH = 6, paddingV = 3, radius = 6, fill = C.saleBg }, {
      ui.label({ text = `-{g.discount}%`, fontSize = size, fontWeight = "heavy", color = C.saleFg }),
    }),
    ui.row({ gap = 6, paddingH = 7, paddingV = 3, radius = 6, fill = "on_surface/0.08", align = "center" }, {
      ui.label({ text = g.origFmt or "", fontSize = size - 3, color = "outline" }),
      ui.label({ text = g.finalFmt or "", fontSize = size, fontWeight = "bold", color = C.saleFg }),
    }),
  })
end

-- Cover image, or a dark placeholder until it is downloaded.
function M.cover(g, width, height)
  if g.cover then
    return ui.image({ path = g.cover, width = width, height = height, radius = 8, fit = "cover" })
  end
  return ui.column({ width = width, height = height, radius = 8, fill = "#0b141d", align = "center", justify = "center" }, {
    ui.glyph({ name = "brand-steam", size = math.floor(height * 0.4), color = "#2a475e" }),
  })
end

function M.storeUrl(g)
  return "https://store.steampowered.com/" .. (g.path or ("app/" .. tostring(g.appid)))
end

function M.open(g)
  noctalia.runAsync({ "xdg-open", M.storeUrl(g) })
end

return M
