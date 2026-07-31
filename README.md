# Dashboard

An Omarchy Shell bar plugin listing the services on your network. Each row is a
link — icon, name, URL — and clicking it opens the service in whichever browser
`xdg-settings` says is yours. Services are added, edited, and deleted from
inside the panel; nothing has to be hand-edited to use it.

<!-- Screenshot placeholder: drop a capture of the open panel at
     docs/screenshot.png and swap this comment for
     ![The dashboard panel](docs/screenshot.png) -->

## Controls

| Key / click | Does |
| ----------- | ---- |
| Type | Filter by name, URL, or icon name |
| Up / Down | Move the highlight |
| Enter, click | Open the highlighted service in the default browser |
| 󰐕, Ctrl+N | Add a service |
| 󰏫, Ctrl+E | Edit the highlighted service |
| 󰆴, Delete | Delete the highlighted service (asks first) |
| Escape | Leave the form, or close the panel |
| Tab / Shift+Tab | In the list, move to the next/previous bar panel. In the form, move between fields |

The list is re-read every time the panel opens, so edits to `services.json` from
a text editor show up as soon as you open it again.

## Services

Services live in `~/.config/omarchy/dashboard/services.json` — **outside** this
repository. `omarchy plugin update` is a git fast-forward of the plugin
checkout, so anything kept in here would be a merge conflict at best and
silently reverted user data at worst. The file is created with a small example
list the first time the panel opens.

```json
[
  {
    "id": "seed-jellyfin",
    "name": "Jellyfin",
    "url": "http://jellyfin.local:8096",
    "icon": "jellyfin.svg"
  }
]
```

| Field | |
| ----- | --- |
| `id` | Unique within the file. Generated for you; keep it stable when hand-editing so an edit doesn't read as a delete plus an add. |
| `name` | What the row says. Required. |
| `url` | Required. `http://` and `https://` only. |
| `icon` | An icon name (`plex.svg`) or a full `https://` icon URL. Optional — see [Icons](#icons). |

It stays pretty-printed and hand-editable. The plugin validates it on every
read: a malformed file is reported in the panel rather than quietly replaced,
so a bad edit never costs you the list.

To keep it somewhere else, set `dataFile` on the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "perfektnacht.dashboard-plugin", "dataFile": "~/Sync/dashboard.json" }
```

## Icons

The icon field takes three forms.

| You type | What happens |
| -------- | ------------ |
| `plex` | A bare name. `.svg` is added and the name is lowercased, then it is looked up in each collection in turn. |
| `plex.svg` | The same thing, spelled the way the icon sites spell it. |
| `plex.png`, `plex.webp` | An explicit format. Both collections file each icon under a directory named for its format, so the extension picks `png/plex.png` rather than `svg/plex.svg`. |
| `https://cdn.jsdelivr.net/gh/selfhst/icons/svg/arr-dashboard.svg` | A full URL, exactly as **copy link address** gives it to you on either site. Fetched as written. |

SVG is the default and is usually what you want — it stays sharp at any size and
scales with the bar. Reach for `.png` only when an icon exists in one collection
as a raster and not as a vector.

The URL form is there because it is what the sites make easy: right-click the
icon, copy link address, paste. It also covers icons neither collection has —
point it at your own server and it will be fetched from there.

### Two collections

There are two well-known icon sets, they are different projects, and neither is
a superset of the other — `arr-dashboard`, for instance, exists only in the
second:

1. [dashboardicons.com](https://dashboardicons.com) — `homarr-labs/dashboard-icons`
2. [selfh.st/icons](https://selfh.st/icons) — `selfhst/icons`

A bare name is tried against them **in that order**, so a name both collections
carry (`plex` is in both) resolves to the dashboardicons.com artwork. Only when
every source has failed is the name recorded as a miss.

Copying a link from either site works, since a pasted URL skips the lookup
entirely.

### Fetching and caching

Icons are fetched from jsDelivr — the CDN both sites publish through — and
cached in `~/.cache/omarchy/dashboard/icons/`. Fetching happens in
`bin/dashboard`, never in the shell process, and all of a list's uncached icons
are fetched in parallel, so a cold cache costs one round trip rather than one
per service.

Cache files are named after a hash of the URL they came from, keeping the
extension. Both collections publish many of the same file names, and a pasted
URL can end in any basename at all, so naming cache entries after what you typed
would let a selfh.st icon quietly overwrite a dashboardicons.com one.

A name no source has is cached as a **miss** for a day. Without that, a typo
would re-ask the CDN every single time the panel opened. Correcting the entry in
the form retries immediately; `bin/dashboard clear-cache` forgets everything, and
`bin/dashboard icons --refresh <icon>` retries just one.

Rows whose icon is missing, misspelled, or not fetched yet draw 󰖟 in the theme
foreground instead. That is deliberate rather than a bundled placeholder image:
a glyph repaints when you switch themes, a shipped PNG does not.

### What is accepted

A pasted URL must be `https://` and end in `.svg`, `.png`, or `.webp`. Anything
else — `http://`, another scheme, a `..` anywhere in the path, a query string —
is refused with an inline error rather than silently falling back to the glyph.

**The host is not restricted, and the URL is fetched exactly as written.** That
is what makes self-hosted icons work, and it means a URL you paste is a URL your
shell will request. Paste links from sites you trust.

Bare names stay on the old strict rules: lowercase letters, digits, `.`, `_` and
`-` only, no path separators, no leading dot.

## Install

```bash
omarchy plugin add https://github.com/perfektnacht/dashboard-plugin.git --enable
```

`--enable` registers the plugin, but a bar widget also needs a place in the
layout. If the icon doesn't appear, put it in a section explicitly:

```bash
omarchy plugin enable perfektnacht.dashboard-plugin --section right
```

### By hand

```bash
git clone https://github.com/perfektnacht/dashboard-plugin.git \
  ~/.config/omarchy/plugins/perfektnacht.dashboard-plugin
omarchy plugin rescan
omarchy plugin enable perfektnacht.dashboard-plugin --section right
```

Symlinking a checkout into the plugins directory works too. The widget resolves
`bin/dashboard` relative to its own QML file, and the helper keeps no state
inside the repository, so neither cares whether it was reached through a link.

## Updating

```bash
omarchy plugin update perfektnacht.dashboard-plugin
omarchy restart shell
```

The update only fast-forwards the repository on disk. The shell loads
`Widget.qml` when the plugin mounts and Qt caches the component type, so a
running bar keeps serving the old widget until the shell restarts — you will see
the previous version's behaviour and reasonably conclude the update did nothing.
`omarchy plugin rescan` is not enough here; it rescans the plugin directory for
added and removed plugins rather than re-reading changed QML.

Your services are untouched by an update: they were never in this directory.

## Uninstall

This disables the plugin and deletes its directory, prompting first:

```bash
omarchy plugin remove perfektnacht.dashboard-plugin
```

`~/.config/omarchy/dashboard/services.json` and the icon cache survive, so
reinstalling picks up where you left off. Delete them yourself if you don't want
that.

Omarchy shell plugins run unsandboxed inside the shell process — read the source
of this one (and any other) before you enable it.

## Requirements

- Omarchy Shell
- `jq`
- `curl` (icon fetching; everything else works without a network)
- `sha256sum` (coreutils) — names cache entries
- `qt6-svg` — Qt's SVG image handler. Without it SVG icons stay as the fallback
  glyph and nothing else breaks; `.png` icon URLs still render.

## bin/dashboard

Every read, write, and fetch goes through this script so the QML thread never
blocks on disk or network. `--help` lists everything; the short version:

```bash
bin/dashboard list                   # print the services as JSON, seeding on first run
bin/dashboard save '[...]'           # validate and write atomically (temp file + mv)
bin/dashboard icon plex.svg          # print the cached path, fetching if needed
bin/dashboard icon https://host/i.svg   # the URL form works here too
bin/dashboard icons plex arr-dashboard  # resolve several at once as JSON
bin/dashboard path                   # where the service file is
bin/dashboard cache-dir              # where cached icons live
bin/dashboard clear-cache            # forget every cached icon and miss
```

Add `--file PATH` before the subcommand to work on a different service file, and
`--refresh` to ignore the negative icon cache. `icon` exits `3` when no source
has the icon, which is kept distinct from `1` (an error) and `2` (bad usage).

## Development

```bash
omarchy plugin validate .            # check manifest.json against the plugin schema
jq empty manifest.json               # check the manifest parses
shellcheck bin/dashboard
```

`omarchy plugin validate` needs an Omarchy machine, so CI can't run it —
`.github/workflows/ci.yml` covers the rest: manifest fields, shellcheck, the
helper's behaviour including path-traversal and negative-cache handling, and a
grep for hardcoded colors in `Widget.qml`. Run `omarchy plugin validate .`
locally before tagging a release.

Every color in the widget comes from `Color`, `Style`, or `bar.foreground`, so
switching themes repaints it live. Keep it that way: a literal hex value is a
color that stops following the theme, and CI fails on one.

## License

MIT
