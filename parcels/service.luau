--!nonstrict
-- Parcel tracker service - the headless [[service]] entry.
--
-- Owns the parcel list (persisted to pluginDataDir()/parcels.json), polls the
-- carriers and publishes everything the UI entries need through noctalia.state:
--
--   parcels.list         array of parcel tables (see `newParcel`)
--   parcels.busy         true while a refresh is in flight
--   parcels.lastRefresh  unix seconds of the last finished refresh
--   parcels.error        last network/API error message, "" when fine
--   parcels.hasKey       whether a 17TRACK key is configured
--
-- UI entries send commands by setting parcels.cmd to
-- { op = "add" | "remove" | "refresh", number, label, nonce }.

local common = require("./lib/common.luau")

local NP_URL = "https://api.novaposhta.ua/v2.0/json/"
local T17_URL = "https://api.17track.net/track/v2.2/"
local T17_BATCH = 40
-- 17TRACK needs a few minutes after registration before it has events, so a
-- freshly added parcel gets one extra early refresh.
local FOLLOW_UP_SECONDS = 180
-- Timeline length kept per parcel.
local MAX_EVENTS = 6

local dataPath = noctalia.pluginDataDir() .. "/parcels.json"
-- Choices made in the panel (plugins cannot write their own settings).
local prefsPath = noctalia.pluginDataDir() .. "/prefs.json"
local prefs = {}

local parcels = {}
local pending = 0 -- requests in flight
local nextRefreshAt = 0
local lastError = ""

local function config()
  return {
    key = noctalia.string.trim(noctalia.getConfig("track17_key") or ""),
    phone = noctalia.string.trim(noctalia.getConfig("np_phone") or ""),
    minutes = noctalia.getConfig("refresh_minutes") or 30,
    notify = noctalia.getConfig("notify") ~= false,
  }
end

local cfg = config()

---- Persistence and publishing

local function load()
  local raw = noctalia.readFile(dataPath)
  if raw then
    local decoded = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      parcels = decoded
    end
  end
end

local function loadPrefs()
  local raw = noctalia.readFile(prefsPath)
  local decoded = raw and noctalia.json.decode(raw)
  prefs = type(decoded) == "table" and decoded or {}
  noctalia.state.set("parcels.font", prefs.font or "")
end

local function setFont(family)
  prefs.font = noctalia.string.trim(family or "")
  noctalia.writeFile(prefsPath, noctalia.json.encode(prefs, true))
  noctalia.state.set("parcels.font", prefs.font)
end

local function save()
  local ok, err = noctalia.writeFile(dataPath, noctalia.json.encode(parcels, true))
  if not ok then
    noctalia.log(`Could not save parcels: {err}`)
  end
end

local function publish()
  noctalia.state.set("parcels.list", parcels)
  noctalia.state.set("parcels.busy", pending > 0)
  noctalia.state.set("parcels.error", lastError)
  noctalia.state.set("parcels.hasKey", cfg.key ~= "")
end

local function find(number)
  for i, p in ipairs(parcels) do
    if p.number == number then
      return p, i
    end
  end
  return nil
end

-- Merge fresh carrier data into a parcel and notify when its status moved.
-- The first real status after `pending` stays silent: the user just added it.
local function apply(number, fields)
  local p = find(number)
  if not p then
    return -- removed while the request was in flight
  end
  local before = p.status
  local beforeText = p.statusText
  for k, v in pairs(fields) do
    p[k] = v
  end
  p.updated = os.time()

  -- Nova Poshta only reports the current status, so build the history
  -- ourselves from every change we observe. 17TRACK sends its own `events`.
  if fields.events == nil and p.statusText ~= "" and p.statusText ~= beforeText then
    p.events = p.events or {}
    local now = noctalia.formatTime("%d/%m %H:%M")
    local sub = p.detail ~= "" and `{p.detail} · {now}` or now
    table.insert(p.events, 1, { text = p.statusText, sub = sub })
    while #p.events > MAX_EVENTS do
      table.remove(p.events)
    end
  end

  local silent = before == "pending" or before == "needs_key" or before == p.status
  if cfg.notify and not silent then
    noctalia.notify(common.title(p), `{common.label(p.status)} - {p.statusText or ""}`)
  end
end

local function beginRequest()
  pending = pending + 1
  noctalia.state.set("parcels.busy", true)
end

local function endRequest()
  pending = math.max(0, pending - 1)
  if pending == 0 then
    noctalia.state.set("parcels.lastRefresh", os.time())
  end
  save()
  publish()
end

local function postJson(url, headers, body, cb)
  table.insert(headers, "Content-Type: application/json")
  beginRequest()
  local accepted = noctalia.http({
    url = url,
    method = "POST",
    headers = headers,
    body = noctalia.json.encode(body),
  }, function(res)
    local decoded = nil
    if res.ok and res.body and res.body ~= "" then
      decoded = noctalia.json.decode(res.body)
    end
    if not res.ok or type(decoded) ~= "table" then
      lastError = noctalia.tr("error.network", { status = tostring(res.status or 0) })
    else
      lastError = ""
      cb(decoded)
    end
    endRequest()
  end)
  if not accepted then
    lastError = noctalia.tr("error.network", { status = "0" })
    endRequest()
  end
end

---- Nova Poshta

-- https://developers.novaposhta.ua - TrackingDocument.getStatusDocuments
local NP_STATUS = {
  ["1"] = "info_received",
  ["2"] = "exception",       -- waybill deleted
  ["3"] = "not_found",
  ["4"] = "in_transit",
  ["41"] = "in_transit",
  ["5"] = "in_transit",
  ["6"] = "in_transit",      -- in the recipient's city
  ["7"] = "pickup",          -- arrived at the branch
  ["8"] = "pickup",          -- arrived at the parcel locker
  ["9"] = "delivered",
  ["10"] = "delivered",
  ["11"] = "delivered",
  ["101"] = "out_for_delivery",
  ["102"] = "exception",     -- refused by recipient
  ["103"] = "exception",
  ["104"] = "in_transit",    -- address changed
  ["105"] = "exception",     -- storage stopped
  ["106"] = "delivered",
  ["108"] = "exception",
  ["111"] = "failed",        -- delivery attempt failed
  ["112"] = "in_transit",    -- delivery date moved
}

local function nonEmpty(...)
  for _, v in ipairs({ ... }) do
    if type(v) == "string" and v ~= "" then
      return v
    end
  end
  return ""
end

local function refreshNovaPoshta(list)
  if #list == 0 then
    return
  end
  local docs = {}
  for _, p in ipairs(list) do
    table.insert(docs, { DocumentNumber = p.number, Phone = cfg.phone })
  end
  postJson(NP_URL, {}, {
    apiKey = "",
    modelName = "TrackingDocument",
    calledMethod = "getStatusDocuments",
    methodProperties = { Documents = docs },
  }, function(res)
    if res.success ~= true or type(res.data) ~= "table" then
      local errors = type(res.errors) == "table" and table.concat(res.errors, "; ") or ""
      lastError = `Nova Poshta: {errors}`
      return
    end
    for _, d in ipairs(res.data) do
      local status = NP_STATUS[tostring(d.StatusCode)] or "in_transit"
      local delivered = status == "delivered"
      apply(tostring(d.Number), {
        status = status,
        statusText = nonEmpty(d.Status),
        detail = nonEmpty(d.WarehouseRecipient, d.CityRecipient),
        eventTime = delivered and common.shortDate(nonEmpty(d.RecipientDateTime, d.ActualDeliveryDate)) or "",
        eta = delivered and "" or common.shortDate(nonEmpty(d.ScheduledDeliveryDate)),
        provider = "Nova Poshta",
      })
    end
  end)
end

---- 17TRACK

-- https://api.17track.net/en/doc - latest_status.status values
local T17_STATUS = {
  NotFound = "not_found",
  InfoReceived = "info_received",
  InTransit = "in_transit",
  Expired = "exception",
  AvailableForPickup = "pickup",
  OutForDelivery = "out_for_delivery",
  DeliveryFailure = "failed",
  Delivered = "delivered",
  Exception = "exception",
}

local T17_ALREADY_REGISTERED = -18019901
local T17_NOT_REGISTERED = -18019902

local function chunks(list, size)
  local out, cur = {}, {}
  for _, v in ipairs(list) do
    table.insert(cur, v)
    if #cur == size then
      table.insert(out, cur)
      cur = {}
    end
  end
  if #cur > 0 then
    table.insert(out, cur)
  end
  return out
end

local function t17(method, numbers, cb)
  local body = {}
  for _, n in ipairs(numbers) do
    table.insert(body, { number = n })
  end
  postJson(T17_URL .. method, { "17token: " .. cfg.key }, body, function(res)
    if res.code ~= 0 then
      local msg = res.data and res.data.errors and res.data.errors[1] and res.data.errors[1].message
      lastError = `17TRACK: {msg or ("code " .. tostring(res.code))}`
      return
    end
    cb(res.data or {})
  end)
end

local function scheduleFollowUp()
  nextRefreshAt = math.min(nextRefreshAt, os.time() + FOLLOW_UP_SECONDS)
end

local function rejectionCode(item)
  return type(item.error) == "table" and item.error.code or nil
end

local function fetchTrackInfo(numbers)
  for _, batch in ipairs(chunks(numbers, T17_BATCH)) do
    t17("gettrackinfo", batch, function(data)
      for _, item in ipairs(data.accepted or {}) do
        local info = item.track_info or {}
        local latest = info.latest_status or {}
        local event = info.latest_event or {}
        local eta = info.time_metrics and info.time_metrics.estimated_delivery_date or {}
        local providers = info.tracking and info.tracking.providers or {}
        local provider = providers[1] and providers[1].provider and providers[1].provider.name
        local status = T17_STATUS[latest.status] or "in_transit"
        local events = {}
        local raw = providers[1] and providers[1].events or {}
        for i = 1, math.min(#raw, MAX_EVENTS) do
          local e = raw[i]
          local sub = {}
          if nonEmpty(e.location) ~= "" then
            table.insert(sub, e.location)
          end
          if nonEmpty(e.time_iso) ~= "" then
            table.insert(sub, common.shortDate(e.time_iso))
          end
          table.insert(events, { text = nonEmpty(e.description), sub = table.concat(sub, " · ") })
        end
        apply(item.number, {
          events = events,
          status = status,
          statusText = nonEmpty(event.description, common.label(status)),
          detail = nonEmpty(event.location),
          eventTime = common.shortDate(nonEmpty(event.time_iso)),
          eta = status == "delivered" and "" or common.shortDate(nonEmpty(eta.to, eta.from)),
          provider = nonEmpty(provider, "17TRACK"),
        })
      end
      for _, item in ipairs(data.rejected or {}) do
        local p = find(item.number)
        local code = rejectionCode(item)
        if p and code == T17_NOT_REGISTERED then
          p.registered = false -- dropped on 17TRACK's side; register again next round
        elseif p and p.status == "pending" then
          -- Typically "no data yet" right after registration: say so instead
          -- of an endless "checking", and look again soon.
          p.statusText = noctalia.tr("ui.waiting_data")
          scheduleFollowUp()
          noctalia.log(`17TRACK rejected {item.number}: {tostring(code)}`)
        end
      end
    end)
  end
end

local function refreshTrack17(list)
  if #list == 0 then
    return
  end
  if cfg.key == "" then
    for _, p in ipairs(list) do
      p.status = "needs_key"
      p.statusText = noctalia.tr("error.needs_key")
    end
    return
  end

  local registered, unregistered = {}, {}
  for _, p in ipairs(list) do
    table.insert(p.registered and registered or unregistered, p.number)
  end
  fetchTrackInfo(registered)

  -- Registration costs 17TRACK quota, so it happens once per parcel.
  for _, batch in ipairs(chunks(unregistered, T17_BATCH)) do
    t17("register", batch, function(data)
      local ready = {}
      for _, item in ipairs(data.accepted or {}) do
        local p = find(item.number)
        if p then
          p.registered = true
          table.insert(ready, p.number)
        end
      end
      for _, item in ipairs(data.rejected or {}) do
        local p = find(item.number)
        if p then
          if rejectionCode(item) == T17_ALREADY_REGISTERED then
            p.registered = true
            table.insert(ready, p.number)
          else
            p.status = "exception"
            p.statusText = item.error and item.error.message or "17TRACK"
          end
        end
      end
      if #ready > 0 then
        scheduleFollowUp()
      end
      fetchTrackInfo(ready)
    end)
  end
end

---- Refresh loop

local function refresh()
  local np, tr = {}, {}
  for _, p in ipairs(parcels) do
    -- Delivered parcels are final; stop asking about them.
    if common.isActive(p.status) then
      table.insert(p.carrier == "novaposhta" and np or tr, p)
    end
  end
  nextRefreshAt = os.time() + cfg.minutes * 60
  refreshNovaPoshta(np)
  refreshTrack17(tr)
  save()
  publish()
end

local function newParcel(number, label)
  return {
    number = number,
    label = label or "",
    carrier = common.detectCarrier(number),
    added = os.time(),
    status = "pending",
    statusText = "",
    detail = "",
    eventTime = "",
    eta = "",
    provider = "",
    registered = false,
    updated = 0,
  }
end

local function addParcel(rawNumber, label)
  local number = common.normalizeNumber(rawNumber)
  if #number < 6 then
    noctalia.notifyError(noctalia.tr("error.invalid_title"), noctalia.tr("error.invalid_body"))
    return
  end
  local existing = find(number)
  if existing then
    if label and label ~= "" then
      existing.label = label
      save()
      publish()
    end
    return
  end
  table.insert(parcels, newParcel(number, noctalia.string.trim(label or "")))
  save()
  refresh()
  scheduleFollowUp()
end

local function removeParcel(rawNumber)
  local number = common.normalizeNumber(rawNumber)
  local p, index = find(number)
  if not p then
    return
  end
  table.remove(parcels, index)
  save()
  publish()
  -- Keep the 17TRACK account tidy; the registration quota is not refunded.
  if p.carrier == "track17" and p.registered and cfg.key ~= "" then
    t17("deletetrack", { number }, function() end)
  end
end

local actions = {
  add = function(cmd) addParcel(cmd.number, cmd.label) end,
  remove = function(cmd) removeParcel(cmd.number) end,
  refresh = function() refresh() end,
  font = function(cmd) setFont(cmd.value) end,
}

noctalia.state.watch("parcels.cmd", function(cmd)
  local action = type(cmd) == "table" and actions[cmd.op]
  if action then
    action(cmd)
  end
end)

function onConfigChanged()
  local hadKey = cfg.key ~= ""
  cfg = config()
  if cfg.key ~= "" and not hadKey then
    for _, p in ipairs(parcels) do
      if p.status == "needs_key" then
        p.status = "pending"
      end
    end
  end
  refresh()
end

-- Tick once a minute; the real cadence is refresh_minutes (or the early
-- follow-up after adding a parcel).
noctalia.setUpdateInterval(60000)

function update()
  if pending == 0 and os.time() >= nextRefreshAt then
    refresh()
  end
end

-- noctalia msg plugin sergiiosy/parcels:service all <event> [payload]
--   add <number> [label]   track a new parcel
--   remove <number>        stop tracking it
--   refresh                poll every carrier now
--   font [family]          font for panel and desktop widgets ("" = shell font)
function onIpc(event, payload)
  payload = noctalia.string.trim(payload or "")
  if event == "add" then
    local number, label = payload:match("^(%S+)%s*(.*)$")
    if number then
      addParcel(number, label)
    end
  elseif event == "remove" then
    removeParcel(payload)
  elseif event == "refresh" then
    refresh()
  elseif event == "font" then
    setFont(payload)
  end
end

loadPrefs()
load()
refresh()
