--!nonstrict
-- Steam Wishlist panel - header, tabs (On sale · All · Alerts), a search
-- field with the sort order, and one card per game: cover, name, the
-- Steam-style price badge, when the sale ends, "lowest seen", and buttons for
-- a price alert and the store page. Commands go back as wishlist.cmd.

local common = require("./lib/common.luau")

local C = common.COLORS
local PANEL_HEIGHT = 720 -- keep in sync with [[panel]] height in plugin.toml
local TEXT_W = 190       -- text column of a card (panel 440 - paddings - cover - buttons)
local MAX_ALL = 80       -- cards in "All" before asking to search

local games = noctalia.state.get("wishlist.games") or {}
local status = noctalia.state.get("wishlist.status") or {}

local isOpen = false
local tab = "sale"        -- sale | all | alerts, kept between openings
local sort = "discount"
local query = ""
local alertFor = nil      -- appid whose alert field is open
local alertText = ""

local render

local function send(cmd)
  cmd.nonce = noctalia.nowMs()
  noctalia.state.set("wishlist.cmd", cmd)
end

local function label(text, size, color, weight, lines, width)
  return ui.label({ text = text, fontSize = size, color = color, fontWeight = weight, maxLines = lines or 1,
    maxWidth = width })
end

---- Header and tools

local function header()
  local sub = noctalia.tr("ui.subtitle", { total = tostring(status.count or #games),
    sale = tostring(status.sale or 0) })
  return ui.row({ gap = 12, align = "center" }, {
    ui.column({ width = 44, height = 44, radius = 12, fill = common.tint(C.steam, 0.16), align = "center",
      justify = "center" }, {
      ui.glyph({ name = "brand-steam", size = 22, color = C.steam }),
    }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("ui.title"), fontSize = 22, fontWeight = "bold" }),
      label(sub, 12, "outline", nil, 1, 240),
    }),
    ui.button({ glyph = status.busy and "loader-2" or "refresh", variant = "ghost", controlSize = "sm",
      enabled = not status.busy, tooltip = noctalia.tr("ui.refresh"),
      onClick = function() send({ op = "refresh" }) end }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("ui.settings"),
      onClick = function() noctalia.openSettings() end }),
  })
end

local function tabBar(saleCount)
  local function tabButton(id, glyph, text)
    return ui.button({ key = "tab-" .. id, text = text, glyph = glyph, controlSize = "sm", flexGrow = 1,
      variant = tab == id and "secondary" or "ghost", selected = tab == id,
      onClick = function()
        tab = id
        alertFor = nil
        render()
      end })
  end
  return ui.row({ gap = 4, padding = 2, radius = 10, fill = "on_surface/0.06" }, {
    tabButton("sale", "discount", noctalia.tr("tab.sale", { count = tostring(saleCount) })),
    tabButton("all", "list", noctalia.tr("tab.all")),
    tabButton("alerts", "bell", noctalia.tr("tab.alerts")),
  })
end

local function tools()
  local options, index = {}, 0
  for i, s in ipairs(common.SORTS) do
    table.insert(options, noctalia.tr("sort." .. s))
    if s == sort then
      index = i - 1
    end
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.row({ gap = 8, paddingH = 10, radius = 10, fill = "on_surface/0.08", align = "center", height = 34, flexGrow = 1 }, {
      ui.glyph({ name = "search", size = 14, color = "outline" }),
      ui.input({ key = "search", value = query, placeholder = noctalia.tr("ui.search"), controlSize = "sm",
        fontSize = 13, width = 1, flexGrow = 1, frameVisible = false,
        onChange = function(v)
          query = v
          render()
        end }),
    }),
    ui.select({ options = options, selectedIndex = index, controlSize = "sm", width = 150,
      onChange = function(v)
        sort = common.SORTS[(tonumber(v) or 0) + 1] or "discount"
        render()
      end }),
  })
end

---- Game card

local function alertRow(g)
  local function commit()
    send({ op = "alert", appid = g.appid, cents = common.parseAmount(alertText) })
    alertFor = nil
    render()
  end
  local children = {
    ui.glyph({ name = "bell", size = 14, color = C.orange }),
    label(noctalia.tr("alert.below"), 12, "on_surface"),
    ui.input({ key = "alert-" .. tostring(g.appid), value = alertText, controlSize = "sm", width = 80, focus = true,
      onChange = function(v) alertText = v end, onSubmit = commit }),
    ui.button({ text = noctalia.tr("alert.save"), variant = "primary", controlSize = "sm", onClick = commit }),
  }
  if g.alert then
    table.insert(children, ui.button({ glyph = "trash", variant = "ghost", controlSize = "sm",
      tooltip = noctalia.tr("alert.remove"), onClick = function()
        send({ op = "alert", appid = g.appid, cents = nil })
        alertFor = nil
        render()
      end }))
  end
  return ui.row({ gap = 8, align = "center", paddingH = 10, paddingV = 6, radius = 10,
    fill = common.tint(C.orange, 0.12) }, children)
end

local function card(g, now)
  local meta = {}
  if (g.discount or 0) > 0 and g.ends then
    table.insert(meta, common.endsText(g.ends, now))
  end
  if g.lowest and (g.discount or 0) > 0 then
    table.insert(meta, noctalia.tr("ui.lowest"))
  end
  if g.alert then
    table.insert(meta, noctalia.tr("ui.alert_meta", { price = string.format("%d", math.floor(g.alert / 100)) }))
  end
  local text = {
    label(g.name, 13, "on_surface", "bold", 1, TEXT_W),
    common.priceRow(g, 13),
  }
  if #meta > 0 then
    table.insert(text, label(table.concat(meta, " · "), 11, g.lowest and C.saleFg or "outline", nil, 2, TEXT_W))
  end
  local rows = {
    ui.row({ gap = 12, align = "center" }, {
      ui.column({ onClick = function() common.open(g) end }, { common.cover(g, 128, 60) }),
      ui.column({ gap = 5, flexGrow = 1 }, text),
      ui.column({ gap = 6 }, {
        ui.button({ glyph = g.alert and "bell-ringing" or "bell", variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("alert.tooltip"), onClick = function()
            if alertFor == g.appid then
              alertFor = nil
            else
              alertFor = g.appid
              alertText = g.alert and tostring(math.floor(g.alert / 100))
                or (g.final and tostring(math.floor(g.final * 0.6 / 100)) or "")
            end
            render()
          end }),
        ui.button({ glyph = "external-link", variant = "ghost", controlSize = "sm",
          tooltip = noctalia.tr("ui.open"), onClick = function() common.open(g) end }),
      }),
    }),
  }
  if alertFor == g.appid then
    table.insert(rows, alertRow(g))
  end
  return ui.column({ key = "g-" .. tostring(g.appid), gap = 8, padding = 8, radius = 14, fill = "on_surface/0.05" }, rows)
end

local function matches(g)
  return query == "" or g.name:lower():find(query:lower(), 1, true) ~= nil
end

local function empty(text)
  return ui.column({ padding = 24, align = "center" }, {
    ui.label({ text = text, fontSize = 13, color = "outline", textAlign = "center", maxLines = 4, maxWidth = 340 }),
  })
end

---- Render

function render()
  if not isOpen then
    return
  end
  local now = os.time()
  local sale = common.onSale(games)
  local children = { header() }
  if (status.error or "") ~= "" then
    table.insert(children, ui.row({ gap = 8, paddingH = 12, paddingV = 10, radius = 12,
      fill = common.tint(C.red, 0.12), align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = C.red }),
      label(status.error, 12, "on_surface", nil, 4, 340),
    }))
  end
  table.insert(children, tabBar(#sale))
  if tab ~= "alerts" then
    table.insert(children, tools())
  end

  local cards = {}
  if tab == "sale" then
    for _, g in ipairs(common.sorted(sale, sort)) do
      if matches(g) then
        table.insert(cards, card(g, now))
      end
    end
    if #cards == 0 then
      table.insert(cards, empty(noctalia.tr(#games == 0 and "ui.loading" or "ui.no_sales")))
    end
  elseif tab == "all" then
    local shown, total = 0, 0
    for _, g in ipairs(common.sorted(games, sort)) do
      if matches(g) then
        total = total + 1
        if shown < MAX_ALL then
          shown = shown + 1
          table.insert(cards, card(g, now))
        end
      end
    end
    if total > shown then
      table.insert(cards, empty(noctalia.tr("ui.more", { count = tostring(total - shown) })))
    end
  else
    for _, g in ipairs(games) do
      if g.alert then
        table.insert(cards, card(g, now))
      end
    end
    table.insert(cards, empty(noctalia.tr("alert.help")))
  end
  table.insert(children, ui.scroll({ gap = 8, flexGrow = 1 }, cards))

  local footer = status.busy and noctalia.tr("ui.refreshing")
    or ((status.updated or 0) > 0 and noctalia.tr("ui.updated", { time = noctalia.formatTime("%d/%m %H:%M", status.updated) })
    or "")
  table.insert(children, ui.row({ justify = "space_between" }, {
    label(footer, 11, "outline"),
    label(noctalia.tr("country." .. (noctalia.getConfig("country") or "UA")), 11, "outline"),
  }))

  -- Small padding: the host already adds 14 px around the panel.
  panel.render(ui.column({ gap = 10, padding = 4, height = PANEL_HEIGHT - 28 }, children))
end

noctalia.state.watch("wishlist.games", function(v) games = v or {}; render() end)
noctalia.state.watch("wishlist.status", function(v) status = v or {}; render() end)

function onOpen(_context)
  isOpen = true
  alertFor = nil
  render()
end

function onClose()
  isOpen = false
end
