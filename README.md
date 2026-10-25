# Noctalia plugins

Plugins for the [Noctalia](https://noctalia.dev) shell.

| Plugin | Id | What it does |
|---|---|---|
| [Steam Wishlist](wishlist/) | `sergiiosy/wishlist` | Discounts on the games of your Steam wishlist, with prices for your region, price alerts and covers. |

## Install

Add this repository as a plugin source, then enable the plugin:

```sh
noctalia msg plugins source add sergiiosy git https://github.com/sergiiosy/noctalia-plugins
noctalia msg plugins enable sergiiosy/wishlist
```

The plugin then shows up in **Settings → Plugins**, and updates arrive with
`noctalia msg plugins update`.

To remove it:

```sh
noctalia msg plugins disable sergiiosy/wishlist
noctalia msg plugins source remove sergiiosy
```

## Requirements

Noctalia 5.3 or newer (plugin API 33).

## License

MIT, see [LICENSE](LICENSE).
