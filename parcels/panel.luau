--!nonstrict
-- Parcel tracker panel - a large title with a summary, one field to paste a
-- tracking number (optionally followed by a name), a segmented filter and a
-- card per parcel. Clicking a card expands its event timeline and actions.
-- All data comes from the service through noctalia.state; edits go back as
-- parcels.cmd commands.

local common = require("./lib/common.luau")
local parts = require("./lib/parts.luau")

local parcels = noctalia.state.get("parcels.list") or {}
local busy = noctalia.state.get("parcels.busy") == true
local lastRefresh = noctalia.state.get("parcels.lastRefresh") or 0
local lastError = noctalia.state.get("parcels.error") or ""
local hasKey = noctalia.state.get("parcels.hasKey") == true

local inputText = ""
-- Bumped after adding so the input is recreated empty (ui.input is uncontrolled).
local formKey = 0
local filter = "active" -- active | done | all
local expanded = nil    -- number of the expanded card
local isOpen = false

local render

local PANEL_HEIGHT = 680 -- keep in sync with [[panel]] height in plugin.toml
local ROW_HEIGHT = 44
local ADD_WIDTH = ROW_HEIGHT

local addHovered = false

-- Font picker: a second view of the panel, since plugin settings have no
-- font field. Families come from fc-list once, on first open.
local view = "parcels" -- parcels | fonts
local fonts = nil      -- sorted family names, nil until loaded
local fontQuery = ""
local MAX_FONT_ROWS = 80

local function send(cmd)
  cmd.nonce = noctalia.nowMs()
  noctalia.state.set("parcels.cmd", cmd)
end

local function text(value, size, color, weight)
  return parts.label({ text = value, fontSize = size, color = color, fontWeight = weight, maxLines = 1 })
end

-- "20450012345678 Scarpe" -> number, label
local function parseInput(value)
  local number, label = noctalia.string.trim(value):match("^(%S+)%s*(.*)$")
  return number or "", label or ""
end

local function addParcel()
  local number, label = parseInput(inputText)
  if number == "" then
    return
  end
  send({ op = "add", number = number, label = label })
  inputText = ""
  formKey = formKey + 1
  filter = "active"
  render()
end

-- Square "+" next to the field, iOS style: a soft blue tint while the field
-- is empty, solid blue with a white glyph once there is something to add.
-- A clickable row rather than ui.button, so it takes exactly the field's
-- height and radius.
local function addButton(ready)
  local blue = common.COLORS.blue
  local fill
  if ready then
    fill = addHovered and common.tint(blue, 0.85) or blue
  else
    fill = common.tint(blue, addHovered and 0.24 or 0.14)
  end
  return ui.row({
    key = "add", width = ADD_WIDTH, height = ROW_HEIGHT, radius = 12, fill = fill,
    align = "center", justify = "center", tooltip = noctalia.tr("ui.add"),
    onClick = addParcel,
    onHover = function(state)
      addHovered = state == "true"
      render()
    end,
  }, {
    ui.glyph({ name = "plus", size = 22, color = ready and "#ffffff" or blue }),
  })
end

local function summary()
  local active, pickup = 0, 0
  for _, p in ipairs(parcels) do
    if common.isActive(p.status) then
      active = active + 1
    end
    if p.status == "pickup" then
      pickup = pickup + 1
    end
  end
  local s = noctalia.trp("ui.summary_active", active)
  if pickup > 0 then
    s = s .. " · " .. noctalia.trp("ui.summary_pickup", pickup)
  end
  return s
end

local function timeline(p)
  local rows = {}
  for i, e in ipairs(p.events or {}) do
    local first = i == 1
    local dot = first and common.meta(p.status).color or "on_surface/0.25"
    table.insert(rows, ui.row({ key = `ev-{p.number}-{i}`, gap = 12, align = "start" }, {
      ui.column({ width = 10, align = "center", paddingV = 4 }, {
        ui.box({ width = 10, height = 10, radius = 5, fill = dot }),
      }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        parts.label({ text = e.text, fontSize = 13, maxLines = 2, maxWidth = 330,
          color = first and "on_surface" or "on_surface_variant", fontWeight = first and "bold" or nil }),
        text(e.sub or "", 11, "outline"),
      }),
    }))
  end
  if #rows == 0 then
    table.insert(rows, text(noctalia.tr("ui.no_history"), 12, "outline"))
  end
  return ui.column({ gap = 10, paddingV = 6 }, rows)
end

local function card(p)
  local isExpanded = expanded == p.number
  local carrier = p.provider ~= "" and p.provider or common.carrierName(p.carrier)
  local event = p.statusText ~= "" and p.statusText or common.label(p.status)
  local where = parts.whereWhen(p)
  if p.eta ~= "" then
    where = where ~= "" and `{where} · {noctalia.tr("ui.eta", { date = p.eta })}` or noctalia.tr("ui.eta", { date = p.eta })
  end

  local body = {
    ui.row({ gap = 12, align = "center" }, {
      parts.tile(p.status, 40),
      ui.column({ gap = 1, flexGrow = 1 }, {
        text(common.title(p), 15, "on_surface", "bold"),
        text(`{carrier} · {p.number}`, 12, "outline"),
      }),
      parts.chip(p.status),
    }),
    parts.steps(p.status),
    ui.column({ gap = 1 }, {
      text(event, 13, "on_surface"),
      where ~= "" and text(where, 11, "outline") or nil,
    }),
  }

  if isExpanded then
    table.insert(body, ui.separator({}))
    table.insert(body, timeline(p))
    table.insert(body, ui.row({ gap = 8 }, {
      ui.button({ text = noctalia.tr("ui.copy"), glyph = "copy", variant = "secondary", controlSize = "sm", flexGrow = 1,
        onClick = function() noctalia.copyToClipboard(p.number, "text/plain") end }),
      ui.button({ text = noctalia.tr("ui.remove"), glyph = "trash", variant = "destructive", controlSize = "sm", flexGrow = 1,
        onClick = function()
          expanded = nil
          send({ op = "remove", number = p.number })
        end }),
    }))
  end

  return ui.column({
    key = "parcel-" .. p.number, gap = 10, padding = 12, radius = 16,
    fill = isExpanded and "on_surface/0.09" or "on_surface/0.05",
    onClick = function()
      -- not `isExpanded and nil or p.number`: `and nil` always falls through to `or`
      if isExpanded then
        expanded = nil
      else
        expanded = p.number
      end
      render()
    end,
  }, body)
end

local function matchesFilter(p)
  if filter == "all" then
    return true
  elseif filter == "done" then
    return p.status == "delivered"
  end
  return common.isActive(p.status)
end

local function segmented()
  local buttons = {}
  for _, f in ipairs({ "active", "done", "all" }) do
    table.insert(buttons, ui.button({
      key = "seg-" .. f, text = noctalia.tr("filter." .. f), controlSize = "sm", flexGrow = 1,
      variant = filter == f and "secondary" or "ghost",
      onClick = function()
        filter = f
        render()
      end,
    }))
  end
  return ui.row({ gap = 2, padding = 2, radius = 10, fill = "on_surface/0.06" }, buttons)
end

local function loadFonts()
  noctalia.runAsync({ "fc-list", ":", "family" }, function(result)
    local seen, list = {}, {}
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      -- "DejaVu Sans,DejaVu Sans Condensed" -> first name is the family
      local family = noctalia.string.trim(line:match("^[^,]+") or "")
      if family ~= "" and family:sub(1, 1) ~= "." and not seen[family] then
        seen[family] = true
        table.insert(list, family)
      end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    fonts = list
    render()
  end)
end

local function fontRow(family, label, current)
  local selected = family == current
  return ui.row({
    key = "font-" .. (family == "" and "default" or family),
    gap = 10, paddingH = 12, paddingV = 10, radius = 10, align = "center",
    fill = selected and common.tint(common.COLORS.blue, 0.15) or "on_surface/0.04",
    onClick = function() send({ op = "font", value = family }) end,
  }, {
    ui.label({ text = label, fontSize = 15, flexGrow = 1, maxLines = 1,
      fontFamily = family ~= "" and family or nil,
      color = selected and common.COLORS.blue or "on_surface" }),
    ui.glyph({ name = "check", size = 16, color = common.COLORS.blue, visible = selected }),
  })
end

local function renderFonts()
  local current = noctalia.state.get("parcels.font") or ""
  local rows = { fontRow("", noctalia.tr("ui.font_default"), current) }

  if fonts == nil then
    table.insert(rows, text("…", 13, "outline"))
  else
    local q = fontQuery:lower()
    local shown = 0
    for _, family in ipairs(fonts) do
      if q == "" or family:lower():find(q, 1, true) then
        -- The current font always shows, even past the row cap.
        if shown < MAX_FONT_ROWS or family == current then
          table.insert(rows, fontRow(family, family, current))
          shown = shown + 1
        end
      end
    end
    if shown == 0 then
      table.insert(rows, text(noctalia.tr("ui.font_none"), 13, "outline"))
    end
  end

  panel.render(ui.column({ gap = 12, padding = 18, height = PANEL_HEIGHT }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("ui.back"),
        onClick = function()
          view = "parcels"
          render()
        end }),
      parts.label({ text = noctalia.tr("ui.font"), fontSize = 22, fontWeight = "bold", flexGrow = 1 }),
    }),
    ui.row({ gap = 8, paddingH = 12, radius = 12, fill = "on_surface/0.08", align = "center", height = ROW_HEIGHT }, {
      ui.glyph({ name = "search", size = 16, color = "outline" }),
      ui.input({ key = "font-search", value = fontQuery, placeholder = noctalia.tr("ui.font_search"),
        controlSize = "lg", fontSize = 14, width = 1, flexGrow = 1, focus = true, frameVisible = false,
        onChange = function(v)
          fontQuery = v
          render()
        end }),
    }),
    ui.scroll({ gap = 4, flexGrow = 1 }, rows),
  }))
end

function render()
  if not isOpen then
    return
  end
  if view == "fonts" then
    renderFonts()
    return
  end

  local number = parseInput(inputText)
  local guess = common.guessCarrier(common.normalizeNumber(number))

  local field = {
    ui.glyph({ name = "search", size = 16, color = "outline" }),
    ui.input({ key = "input-" .. formKey, placeholder = noctalia.tr("ui.input_placeholder"),
      controlSize = "lg", fontSize = 14, width = 1, flexGrow = 1, focus = true, frameVisible = false,
      onChange = function(v)
        inputText = v
        render()
      end,
      onSubmit = addParcel }),
  }
  if guess ~= "" then
    table.insert(field, ui.row({ paddingH = 8, paddingV = 3, radius = 6, fill = common.tint(common.COLORS.blue, 0.15) }, {
      parts.label({ text = guess, fontSize = 11, fontWeight = "bold", color = common.COLORS.blue }),
    }))
  end

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.column({ gap = 0, flexGrow = 1 }, {
        parts.label({ text = noctalia.tr("ui.title"), fontSize = 22, fontWeight = "bold" }),
        text(summary(), 12, "outline"),
      }),
      ui.button({ glyph = busy and "loader-2" or "refresh", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.refresh"), enabled = not busy,
        onClick = function() send({ op = "refresh" }) end }),
      ui.button({ glyph = "typography", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.font"), onClick = function()
          view = "fonts"
          if fonts == nil then
            loadFonts()
          end
          render()
        end }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"), onClick = function() noctalia.openSettings() end }),
    }),
    -- The field takes whatever width the panel leaves after the fixed-size
    -- button; the input starts at width 1 so its natural width never pushes
    -- the button past the panel edge.
    ui.row({ gap = 8, align = "center" }, {
      ui.row({ gap = 8, paddingH = 12, radius = 12, fill = "on_surface/0.08", align = "center",
        flexGrow = 1, height = ROW_HEIGHT }, field),
      addButton(number ~= ""),
    }),
    segmented(),
  }

  if not hasKey then
    table.insert(children, parts.label({ text = noctalia.tr("ui.key_hint"), fontSize = 11, color = "outline", maxLines = 3 }))
  end
  if lastError ~= "" then
    table.insert(children, parts.label({ text = lastError, fontSize = 11, color = common.COLORS.red, maxLines = 2 }))
  end

  local cards = {}
  for _, p in ipairs(common.sorted(parcels)) do
    if matchesFilter(p) then
      table.insert(cards, card(p))
    end
  end
  if #cards == 0 then
    table.insert(cards, ui.column({ gap = 8, padding = 32, align = "center" }, {
      ui.glyph({ name = "package", size = 36, color = "outline" }),
      parts.label({ text = noctalia.tr(filter == "done" and "ui.empty_done" or "ui.empty"), color = "outline",
        textAlign = "center", maxLines = 2 }),
    }))
  end
  table.insert(children, ui.scroll({ gap = 8, flexGrow = 1, revealKey = expanded and ("parcel-" .. expanded) or nil }, cards))

  local footer = busy and noctalia.tr("ui.refreshing")
    or (lastRefresh > 0 and noctalia.tr("ui.updated", { time = noctalia.formatTime("%H:%M", lastRefresh) }) or "")
  table.insert(children, ui.row({ justify = "space_between" }, {
    text(footer, 11, "outline"),
    text("Nova Poshta · 17TRACK", 11, "outline"),
  }))

  -- The root must span the whole panel, or the scroll list is sized to its
  -- content and an expanded card ends up hidden behind a scrollbar.
  panel.render(ui.column({ gap = 12, padding = 18, height = PANEL_HEIGHT }, children))
end

noctalia.state.watch("parcels.list", function(v) parcels = v or {}; render() end)
noctalia.state.watch("parcels.busy", function(v) busy = v == true; render() end)
noctalia.state.watch("parcels.lastRefresh", function(v) lastRefresh = v or 0; render() end)
noctalia.state.watch("parcels.error", function(v) lastError = v or ""; render() end)
noctalia.state.watch("parcels.hasKey", function(v) hasKey = v == true; render() end)
noctalia.state.watch("parcels.font", function() render() end)

function onOpen(_context)
  isOpen = true
  view = "parcels"
  render()
end

function onClose()
  isOpen = false
end
