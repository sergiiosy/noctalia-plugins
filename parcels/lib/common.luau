--!nonstrict
-- Shared helpers for every entry: carrier detection, the normalized status
-- vocabulary (glyph, color, label) and small formatting utilities.
--
-- Every carrier status is mapped onto one of these normalized values, so the
-- UI entries never need to know which API a parcel came from:
--   pending, not_found, info_received, in_transit, out_for_delivery,
--   pickup, delivered, failed, exception, needs_key

local M = {}

-- Apple system colors (dark appearance): fixed on purpose, so statuses read
-- the same whatever wallpaper palette the shell picked.
M.COLORS = {
  blue = "#0a84ff",
  indigo = "#5e5ce6",
  orange = "#ff9f0a",
  green = "#30d158",
  red = "#ff453a",
  gray = "#8e8e93",
}
local C = M.COLORS

-- `step` places the parcel on the 5-segment progress strip
-- (created, in transit, out for delivery, at pickup point, delivered).
M.STATUS = {
  pending          = { glyph = "clock",          color = C.gray,   step = 0, rank = 6 },
  needs_key        = { glyph = "key",            color = C.red,    step = 0, rank = 2 },
  not_found        = { glyph = "search",         color = C.gray,   step = 0, rank = 7 },
  info_received    = { glyph = "file-text",      color = C.gray,   step = 1, rank = 5 },
  in_transit       = { glyph = "truck",          color = C.blue,   step = 2, rank = 4 },
  out_for_delivery = { glyph = "truck-delivery", color = C.indigo, step = 3, rank = 1 },
  pickup           = { glyph = "building-store", color = C.orange, step = 4, rank = 0 },
  failed           = { glyph = "alert-triangle", color = C.red,    step = 3, rank = 2 },
  exception        = { glyph = "alert-triangle", color = C.red,    step = 2, rank = 3 },
  delivered        = { glyph = "circle-check",   color = C.green,  step = 5, rank = 9 },
}

-- "#rrggbb" + alpha 0..1 -> "#rrggbbaa", for tinted backgrounds.
function M.tint(hex, alpha)
  return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
end

function M.meta(status)
  return M.STATUS[status] or M.STATUS.pending
end

function M.label(status)
  return noctalia.tr("status." .. (M.STATUS[status] and status or "pending"))
end

-- A parcel still on its way: counted in the bar and kept on the poll list.
function M.isActive(status)
  return status ~= "delivered"
end

-- Something the user has to act on (collect it, or look into a problem).
function M.needsAttention(status)
  return status == "pickup" or status == "out_for_delivery" or status == "failed"
    or status == "exception" or status == "needs_key"
end

-- Strip spaces and dashes, upper-case letters: "rr 123-456 789 cn" -> "RR123456789CN".
function M.normalizeNumber(raw)
  return string.upper((tostring(raw or ""):gsub("[%s%-]", "")))
end

-- Nova Poshta waybills are 14 digits; everything else goes through 17TRACK,
-- which auto-detects Ukrposhta, China Post, Cainiao, Yanwen and the rest.
function M.detectCarrier(number)
  if #number == 14 and number:match("^%d+$") then
    return "novaposhta"
  end
  return "track17"
end

function M.carrierName(carrier)
  return carrier == "novaposhta" and "Nova Poshta" or "17TRACK"
end

-- Best guess shown while typing; only a hint, 17TRACK detects the real carrier.
function M.guessCarrier(number)
  if number == "" then
    return ""
  elseif M.detectCarrier(number) == "novaposhta" then
    return "Nova Poshta"
  elseif number:match("UA$") then
    return "Ukrposhta"
  elseif number:match("CN$") or number:match("^LP") or number:match("^YT") or number:match("^UB") then
    return noctalia.tr("ui.guess_china")
  end
  return "17TRACK"
end

-- Shorten the date formats the carriers return to "dd/mm hh:mm".
-- Accepts "2024-05-20T10:00:00+08:00", "2024-05-20 10:00:00",
-- "20-05-2024 10:00:00" and "20.05.2024 10:00:00"; anything else passes through.
function M.shortDate(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  local y, mo, d, h, mi = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)")
  if not y then
    d, mo, y, h, mi = text:match("^(%d%d)[%.%-](%d%d)[%.%-](%d%d%d%d)[T ](%d%d):(%d%d)")
  end
  if y then
    return `{d}/{mo} {h}:{mi}`
  end
  local y2, mo2, d2 = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y2 then
    d2, mo2, y2 = text:match("^(%d%d)[%.%-](%d%d)[%.%-](%d%d%d%d)")
  end
  if y2 then
    return `{d2}/{mo2}`
  end
  return text
end

function M.title(parcel)
  if parcel.label and parcel.label ~= "" then
    return parcel.label
  end
  return parcel.number
end

-- Most urgent first (pickup, out for delivery, problems), delivered last;
-- ties keep insertion order.
function M.sorted(list)
  local copy = {}
  for i, p in ipairs(list or {}) do
    copy[i] = p
  end
  table.sort(copy, function(a, b)
    local ra, rb = M.meta(a.status).rank, M.meta(b.status).rank
    if ra ~= rb then
      return ra < rb
    end
    return (a.added or 0) < (b.added or 0)
  end)
  return copy
end

return M
