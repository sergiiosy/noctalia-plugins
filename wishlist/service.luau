--!nonstrict
-- Steam Wishlist service - the headless [[service]] entry.
--
-- Resolves the Steam profile to a SteamID64, reads its public wishlist
-- (IWishlistService/GetWishlist) and the store data for the chosen region in
-- batches (IStoreBrowseService/GetItems: name, price, discount and its end,
-- cover art). Keeps the lowest price seen per game, downloads the covers to
-- pluginDataDir()/covers and publishes through noctalia.state:
--
--   wishlist.games    array of games (format in lib/common.luau)
--   wishlist.status   { busy, error, updated, count, sale }
--
-- Notifications: a game of the wishlist going on sale (once per sale), a
-- price alert reached, and one summary the very first time.
--
-- UI entries send commands by setting wishlist.cmd to
-- { op = "refresh" | "alert", appid, cents, nonce }.

local common = require("./lib/common.luau")

local API = "https://api.steampowered.com"
local COVER_BASE = "https://shared.akamai.steamstatic.com/store_item_assets/"
local BATCH = 50
-- "Lowest seen" only means something after watching the price for a while.
local LOWEST_AFTER = 7 * 86400
-- Steam changes its daily deals at 17:00 UTC: look again a few minutes later.
local DAILY_DEALS_UTC = 17 * 3600 + 300

local dataDir = noctalia.pluginDataDir()
local dataPath = dataDir .. "/wishlist.json"
local coverDir = dataDir .. "/covers"

-- Persisted. Maps are keyed by tostring(appid) so they stay JSON objects.
local store = {
  profile = nil, steamid = nil, -- the profile setting the steamid belongs to
  games = {},
  history = {},   -- appid -> { low = cents, since = unix }
  notified = {},  -- appid -> key of the sale already announced
  alerts = {},    -- appid -> cents
  alertSent = {}, -- appid -> price already announced for the alert
  covers = {},    -- appid -> true once downloaded
  seeded = false,
}

local busy = false
local lastError = ""
local nextRefreshAt = 0
local coverQueue, coverQueued = {}, {}

local function config()
  return {
    profile = noctalia.string.trim(noctalia.getConfig("profile") or ""),
    country = noctalia.getConfig("country") or "UA",
    hours = noctalia.getConfig("refresh_hours") or 6,
    notify = noctalia.getConfig("notify") ~= false,
    minDiscount = noctalia.getConfig("min_discount") or 0,
  }
end

local cfg = config()

---- Persistence and publishing

local function load()
  local raw = noctalia.readFile(dataPath)
  local decoded = raw and noctalia.json.decode(raw)
  if type(decoded) == "table" then
    for k, v in pairs(decoded) do
      store[k] = v
    end
  end
end

local function save()
  noctalia.writeFile(dataPath, noctalia.json.encode(store))
end

local function publish()
  local now = os.time()
  local games, sale = {}, 0
  for _, g in ipairs(store.games) do
    local id = tostring(g.appid)
    local h = store.history[id]
    local copy = {}
    for k, v in pairs(g) do
      copy[k] = v
    end
    copy.cover = store.covers[id] and (coverDir .. "/" .. id .. ".jpg") or nil
    copy.alert = store.alerts[id]
    copy.lowest = h ~= nil and g.available and g.final ~= nil and g.final <= h.low and now - h.since >= LOWEST_AFTER
    if g.available and (g.discount or 0) > 0 then
      sale = sale + 1
    end
    table.insert(games, copy)
  end
  noctalia.state.set("wishlist.games", games)
  noctalia.state.set("wishlist.status", {
    busy = busy, error = lastError, updated = store.updated or 0, count = #games, sale = sale,
  })
end

local function fail(message)
  busy = false
  lastError = message
  publish()
end

---- HTTP

local function getJson(url, cb)
  local accepted = noctalia.http({ url = url, method = "GET" }, function(res)
    local decoded = res.ok and res.body and noctalia.json.decode(res.body) or nil
    if type(decoded) ~= "table" then
      cb(nil, noctalia.tr("error.network", { status = tostring(res.status or 0) }))
    else
      cb(decoded, nil)
    end
  end)
  if not accepted then
    cb(nil, noctalia.tr("error.network", { status = "0" }))
  end
end

local function urlEncode(text)
  return (tostring(text):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

---- Profile -> SteamID64

-- Accepts a SteamID64, ".../profiles/<id>", ".../id/<name>" or just <name>.
local function resolveProfile(cb)
  local p = cfg.profile
  if store.steamid and store.profile == p then
    return cb(store.steamid)
  end
  local id = p:match("^(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d)$") or p:match("/profiles/(%d+)")
  if id then
    store.profile, store.steamid = p, id
    return cb(id)
  end
  local vanity = p:match("/id/([^/%?#]+)") or p:match("^([%w_%-]+)$")
  if not vanity then
    return fail(noctalia.tr("error.profile"))
  end
  noctalia.http({ url = "https://steamcommunity.com/id/" .. urlEncode(vanity) .. "/?xml=1", method = "GET" },
    function(res)
      local found = res.ok and res.body and res.body:match("<steamID64>(%d+)</steamID64>")
      if not found then
        return fail(noctalia.tr("error.profile"))
      end
      store.profile, store.steamid = p, found
      cb(found)
    end)
end

---- Store data

local function toGame(item, wished)
  local bpo = item.best_purchase_option or {}
  local assets = item.assets or {}
  local active = type(bpo.active_discounts) == "table" and bpo.active_discounts[1] or nil
  local header = nil
  if type(assets.asset_url_format) == "string" and type(assets.header) == "string" then
    header = COVER_BASE .. assets.asset_url_format:gsub("%${FILENAME}", assets.header)
  end
  local final = tonumber(bpo.final_price_in_cents)
  return {
    appid = item.appid,
    name = item.name or ("App " .. tostring(item.appid)),
    path = item.store_url_path,
    final = final,
    orig = tonumber(bpo.original_price_in_cents) or final,
    finalFmt = bpo.formatted_final_price,
    origFmt = bpo.formatted_original_price,
    discount = tonumber(bpo.discount_pct) or 0,
    ends = active and tonumber(active.discount_end_date) or nil,
    coming = type(item.release) == "table" and item.release.is_coming_soon == true,
    free = item.is_free == true,
    available = final ~= nil or item.is_free == true,
    added = wished and wished.date_added or 0,
    headerUrl = header,
  }
end

local function fetchItems(appids, cb)
  local ids = {}
  for _, id in ipairs(appids) do
    table.insert(ids, { appid = id })
  end
  local input = noctalia.json.encode({
    ids = ids,
    context = { country_code = cfg.country, language = "italian" },
    data_request = { include_assets = true, include_release = true },
  })
  getJson(API .. "/IStoreBrowseService/GetItems/v1/?input_json=" .. urlEncode(input), function(data, err)
    if err then
      return cb(nil, err)
    end
    cb(data.response and data.response.store_items or {}, nil)
  end)
end

---- Notifications

local function notifySales(games)
  if not cfg.notify then
    return
  end
  local fresh = {}
  for _, g in ipairs(games) do
    local id = tostring(g.appid)
    if g.available and g.discount > 0 then
      local key = tostring(g.ends or g.discount)
      if store.notified[id] ~= key then
        store.notified[id] = key
        if g.discount >= cfg.minDiscount then
          table.insert(fresh, g)
        end
      end
    else
      store.notified[id] = nil -- a later sale is announced again
    end
    -- Price alert reached (once per price).
    local alert = store.alerts[id]
    if alert and g.available and g.final and g.final <= alert and store.alertSent[id] ~= g.final then
      store.alertSent[id] = g.final
      noctalia.notify(noctalia.tr("notify.alert_title", { name = g.name }),
        noctalia.tr("notify.alert_body", { price = g.finalFmt or "", discount = tostring(g.discount) }))
    end
  end
  table.sort(fresh, function(a, b) return a.discount > b.discount end)
  if #fresh == 1 then
    local g = fresh[1]
    noctalia.notify(noctalia.tr("notify.sale_title", { name = g.name, discount = tostring(g.discount) }),
      noctalia.tr("notify.sale_body", { price = g.finalFmt or "", orig = g.origFmt or "",
        ends = common.endsText(g.ends) or "" }))
  elseif #fresh > 1 then
    local names = {}
    for i = 1, math.min(3, #fresh) do
      table.insert(names, `{fresh[i].name} (-{fresh[i].discount}%)`)
    end
    noctalia.notify(noctalia.tr("notify.sales_title", { count = tostring(#fresh) }),
      table.concat(names, ", ") .. (#fresh > 3 and "…" or ""))
  end
end

---- Covers

local function queueCovers()
  for _, g in ipairs(store.games) do
    local id = tostring(g.appid)
    if g.headerUrl and not store.covers[id] and not coverQueued[id] then
      coverQueued[id] = true
      -- Games on sale first: they are the ones on screen.
      table.insert(coverQueue, (g.discount or 0) > 0 and 1 or #coverQueue + 1, g)
    end
  end
end

local function downloadNextCover()
  local g = table.remove(coverQueue, 1)
  if not g then
    return
  end
  local id = tostring(g.appid)
  noctalia.download(g.headerUrl, coverDir .. "/" .. id .. ".jpg", function(ok)
    coverQueued[id] = nil
    if ok then
      store.covers[id] = true
      -- Publish in small steps, not on every single image.
      if #coverQueue % 10 == 0 then
        save()
        publish()
      end
    end
  end)
end

---- Refresh

local function scheduleNext()
  local now = os.time()
  local nextDeals = now - (now % 86400) + DAILY_DEALS_UTC
  if nextDeals <= now then
    nextDeals = nextDeals + 86400
  end
  nextRefreshAt = math.min(now + cfg.hours * 3600, nextDeals)
end

local function finish(games)
  local now = os.time()
  for _, g in ipairs(games) do
    local id = tostring(g.appid)
    if g.available and g.final then
      local h = store.history[id]
      if not h then
        store.history[id] = { low = g.final, since = now }
      elseif g.final < h.low then
        h.low = g.final
      end
    end
  end
  if store.seeded then
    notifySales(games)
  else
    -- First run: remember the current sales silently, say how many there are.
    local sale = 0
    for _, g in ipairs(games) do
      if g.available and g.discount > 0 then
        sale = sale + 1
        store.notified[tostring(g.appid)] = tostring(g.ends or g.discount)
      end
    end
    store.seeded = true
    if cfg.notify and sale > 0 then
      noctalia.notify(noctalia.tr("notify.first_title"), noctalia.tr("notify.first_body",
        { count = tostring(sale), total = tostring(#games) }))
    end
  end
  store.games = games
  store.updated = now
  busy = false
  lastError = ""
  save()
  queueCovers()
  publish()
end

local function refresh()
  if busy then
    return
  end
  if cfg.profile == "" then
    return fail(noctalia.tr("error.no_profile"))
  end
  busy = true
  scheduleNext()
  publish()
  resolveProfile(function(steamid)
    getJson(API .. "/IWishlistService/GetWishlist/v1/?steamid=" .. steamid, function(data, err)
      if err then
        return fail(err)
      end
      local items = data.response and data.response.items
      if type(items) ~= "table" or #items == 0 then
        return fail(noctalia.tr("error.private"))
      end
      local wished, ids = {}, {}
      for _, w in ipairs(items) do
        wished[w.appid] = w
        table.insert(ids, w.appid)
      end
      -- Batches one after another, to be gentle with the store API.
      local games, index = {}, 1
      local function nextBatch()
        if index > #ids then
          return finish(games)
        end
        local batch = {}
        for i = index, math.min(index + BATCH - 1, #ids) do
          table.insert(batch, ids[i])
        end
        index = index + BATCH
        fetchItems(batch, function(list, ferr)
          if ferr then
            return fail(ferr)
          end
          for _, item in ipairs(list) do
            if item.appid then
              table.insert(games, toGame(item, wished[item.appid]))
            end
          end
          nextBatch()
        end)
      end
      nextBatch()
    end)
  end)
end

---- Commands

noctalia.state.watch("wishlist.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.op == "refresh" then
    refresh()
  elseif cmd.op == "alert" and cmd.appid then
    local id = tostring(cmd.appid)
    store.alerts[id] = tonumber(cmd.cents)
    store.alertSent[id] = nil
    save()
    publish()
  end
end)

function onConfigChanged()
  local old = cfg
  cfg = config()
  if old.profile ~= cfg.profile or old.country ~= cfg.country then
    -- Another wishlist or another currency: the old prices mean nothing.
    store.games, store.history, store.notified, store.alertSent = {}, {}, {}, {}
    store.seeded = false
    if old.profile ~= cfg.profile then
      store.steamid, store.alerts = nil, {}
    end
    save()
  end
  refresh()
end

-- One-second tick: one cover download per tick, refresh on schedule.
noctalia.setUpdateInterval(1000)

function update()
  if not busy and os.time() >= nextRefreshAt then
    refresh()
  elseif #coverQueue > 0 then
    downloadNextCover()
  end
end

-- noctalia msg plugin sergiiosy/wishlist:service all refresh
function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

noctalia.runAsync({ "mkdir", "-p", coverDir })
load()
-- Covers already on disk from an earlier session are reused.
publish()
