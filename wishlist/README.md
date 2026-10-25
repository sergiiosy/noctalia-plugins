# Steam Wishlist

See which games of your Steam wishlist are on sale, with the prices of your own store
region, right from the Noctalia bar. No API key and no login: it only needs your wishlist
to be public.

| Plugin | |
|---|---|
| Id | `sergiiosy/wishlist` |
| Entries | `sergiiosy/wishlist:service`, `sergiiosy/wishlist:bar`, `sergiiosy/wishlist:panel`, `sergiiosy/wishlist:deals` |
| Languages | English, Italian |

## Usage

1. Add the bar widget `sergiiosy/wishlist:bar`.
2. Open **Settings → Plugins → Steam Wishlist** and enter your Steam profile
   (`https://steamcommunity.com/id/<name>/`, `https://steamcommunity.com/profiles/<id>` or a
   SteamID64) and your store region.
3. Optionally add the desktop widget `sergiiosy/wishlist:deals`
   (`noctalia msg desktop-widgets-edit`).

Your wishlist must be public: on Steam, **Profile → Edit Profile → Privacy Settings → Game
details: Public**.

- **Bar**: the Steam glyph with a green badge counting the wishlist games on sale. The tooltip
  lists the best deals. Click opens the panel, right click refreshes the prices.
- **Panel** (`noctalia msg panel-toggle sergiiosy/wishlist:panel`), three tabs:
  - **On sale**: cover, name, a Steam-style `-70%` price badge with the old and new price, when
    the sale ends, and "lowest price seen";
  - **All**: the whole wishlist (the first 80, the rest through the search), including
    "Coming soon" and "Not sold in this region";
  - **Alerts**: games with a price alert.

  Search by name and sort by biggest discount, lowest price, ending soonest or recently added.
  Clicking a cover or ↗ opens the store page.
- **Price alerts**: the 🔔 button on a game sets a price; you get a notification when the
  game drops below it.
- **Notifications**: a wishlist game going on sale (once per sale; several at once become one
  notification), a price alert reached, and a summary the very first time.
- **Desktop widget** `sergiiosy/wishlist:deals`: the four best deals with their covers.

## Requirements

- `xdg-open` (xdg-utils), to open store pages in the browser.

## Settings

| Setting | Default | Notes |
|---|---|---|
| Steam profile | empty | Profile link or SteamID64 |
| Store region | Ukraine (₴) | Also Italy, Poland, Germany, United States, United Kingdom. Changing it restarts the price history |
| Check every | 6 hours | Prices are also checked right after Steam's daily deals change (17:00 UTC) |
| Notifications | on | |
| Minimum discount to notify | 0 % | Smaller discounts show in the panel without a notification |
| Show the number of games on sale | on | Bar widget setting |

## IPC

```sh
noctalia msg plugin sergiiosy/wishlist:service all refresh   # read the prices now
noctalia msg panel-toggle sergiiosy/wishlist:panel
```

## Notes

- **Network**: only Steam's public endpoints, over HTTPS:
  - `steamcommunity.com/id/<name>/?xml=1`, once, to turn a profile name into a SteamID64;
  - `api.steampowered.com/IWishlistService/GetWishlist/v1` for the wishlist;
  - `api.steampowered.com/IStoreBrowseService/GetItems/v1` for names, prices, discounts and
    cover art, in batches of 50 games (a 300-game wishlist is 6 requests);
  - `shared.akamai.steamstatic.com` for the cover images, one per second, only once per game.
- **Files**: everything is written in the plugin data directory
  (`~/.local/state/noctalia/plugins/data/sergiiosy/wishlist/`): `wishlist.json` (games, price
  history, alerts, sales already notified) and `covers/` (the cover images).
- **Processes**: `mkdir -p` once for the covers folder, and `xdg-open <store URL>` when you
  open a game.
- "Lowest price seen" is the lowest price **this plugin** has seen, shown after watching a game
  for at least 7 days. It is not Steam's all-time low.
- Nothing is sent anywhere except the requests above; the profile and the prices stay on your
  computer.
