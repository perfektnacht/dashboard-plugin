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
| 󰒓, Ctrl+, | Settings |
| Escape | Leave the form or settings, or close the panel |
| Tab / Shift+Tab | In the list, move to the next/previous bar panel. In the form, move between fields |

The list is re-read every time the panel opens, so edits to `services.json` from
a text editor show up as soon as you open it again.

## Reachability

Each row says **UP** or **DOWN** at its right edge, and nothing at all until the
check comes back. The hero line counts them — `4 services · 2 up`, or `· all up`
when nothing needs attention.

It's a word rather than a coloured dot on purpose: a dot carries its whole
meaning in its hue, which is one colour-blind reader or one heavily tinted theme
away from saying nothing. The colour is still there as a second channel.

The status shares its slot with the row's 󰏫 and 󰆴 buttons, which appear on the
row under the cursor. You want the status while scanning the list and the
buttons once you've picked a row, so the two trade places instead of stacking —
which is also why an unpointed-at list shows no cursor at all.

The check is an HTTP GET, not a ping. Every row here is one click from a
browser, so the question worth answering is whether a browser would get
something back — and a machine keeps answering ICMP long after the container
behind the port has stopped.

**Anything that answers counts as up**, including `401`, `403`, and `404`: a
service that demands a login is a service that is running, and a good half of a
homelab sits behind an auth page or a reverse proxy that 404s the bare root.
Only a refused connection, a name that won't resolve, or a timeout is down.
Certificates aren't verified — homelab TLS is self-signed more often than not,
and nothing is read from the response anyway.

Every service is probed in parallel, once per open, so the panel waits for the
slowest one rather than the sum of them all. Set
`OMARCHY_DASHBOARD_STATUS_TIMEOUT` to change the four-second budget.

### Settings

󰒓 in the panel header, or Ctrl+, — Up/Down to move, Enter or Space to flip a
switch, Escape to go back.

| Setting | Default | |
| ------- | ------- | --- |
| Check when the panel opens | on | Probe every service each time the panel opens. Off means no UP/DOWN and no requests. |
| Keep checking while open | off | Re-check every 15 seconds for as long as the panel stays open. Never runs behind a closed panel. |
| CRT mode | off | The phosphor shader — see [CRT mode](#crt-mode). |

The two reachability toggles move together, since neither half makes sense
alone: turning polling on turns checking on with it, and turning checking off
takes polling down.

These are stored in `prefs.json` beside the service list — not in `shell.json`,
which a plugin can't write. Moving the list with `dataFile` moves them too.
Deleting the file resets both to their defaults.

## CRT mode

The panel's contents can be rendered through a phosphor shader — barrel warp,
scanlines, aperture grille, bloom, and a moulded bezel around a rounded glass
edge.

It is **off by default**, and lives under **Appearance → CRT mode** in the
settings panel (󰒓 or Ctrl+,). It's a strong look, and not one to inherit by
installing a list of links. Like the other toggles it's stored in `prefs.json`,
so it survives a shell restart.

**The image is static.** Every stage is a function of position alone, so the
panel is drawn once and then costs nothing until something on it changes. There
was a mains-hum flicker early on; it was removed rather than dialled back,
because it was the only time-varying part of the effect and so on its own forced
a repaint every frame the panel was open. Nobody could see it. Measured on the
machine it was built on, an idle CRT panel now sits at the same GPU load as an
idle plain one, which is none.

**The phosphor colour follows your theme's accent.** A fixed Pip-Boy green was
the first thing tried and it was the wrong thing: the shader converts to
luminance before tinting, so a fixed colour erases the palette completely and
renders every dark theme identically. Driven from the accent, `matte-black` gets
a genuine amber tube, `gruvbox` a sage one, `ristretto` a red one — and the
panel still belongs to the desktop around it.

**Light themes switch it off automatically.** A phosphor screen is bright marks
on a dark tube. A light theme has luminance near 1 nearly everywhere, so the
panel turns into one glowing slab with the text lost inside it, and no choice of
tint rescues it. `catppuccin-latte`, `flexoki-light`, `lupine`, `rose-pine` and
`white` all render as a normal panel instead. That detection is a luminance test
on `Color.background`, so a third-party light theme is covered too.

The toggle still works on a light theme and still remembers what you set — it
just doesn't run, and says so. Switch to a dark theme and it comes back on
without you touching it again.

Two costs worth knowing about:

- **Every change to the panel is redrawn through the shader.** Typing in the
  search field, moving the cursor and status arriving all repaint the whole
  panel through it. That is bounded work rather than continuous, but it has only
  been measured on a discrete GPU, where the shader is too cheap to show up at
  all against the cost of drawing a window. On much older integrated graphics it
  may well be the part you notice, and there is no measurement here claiming
  otherwise.
- **The panel is bigger in CRT mode.** The frame and the margin of dark glass
  inside it are paid for by growing the panel, not by scaling the content down —
  a CRT effect has no business resampling the text of a list you actually read.

Editing the shader means recompiling it; see [Development](#development).

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

Because it lives outside the checkout, **this file outlives the plugin.**
Uninstalling, reinstalling, or deleting the plugin directory leaves it alone —
see [Removing the plugin does not remove your
services](#removing-the-plugin-does-not-remove-your-services).

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

### Removing the plugin does not remove your services

`omarchy plugin remove` deletes the *code*. Your service list is not in the
plugin directory and never was, so it survives — as do your settings and the
icon cache. Reinstalling picks up exactly where you left off.

That is the point of storing it outside the checkout, but it inverts the usual
expectation, so it is worth being explicit: **reinstalling is not a reset.**
Nothing you do to the plugin directory clears your data, including these, all of
which look like they should and don't:

| What you might try | Why it doesn't clear anything |
| ------------------ | ----------------------------- |
| `omarchy plugin remove` then reinstall | Removes the code. The data is elsewhere. |
| Deleting `~/.config/omarchy/plugins/perfektnacht.dashboard-plugin/` | Same — that directory holds no service data. |
| Deleting the `.perfektnacht.dashboard-plugin.bak.<timestamp>` directory | `omarchy plugin add` moves an existing install aside to that hidden backup before cloning. It is a copy of the **code only**. Deleting it is harmless and reclaims nothing but the code. |
| Reinstalling from a different clone or a fresh git URL | `dataFile` resolves to the same path regardless of where the code came from. |

There is exactly one place to look, and deleting it is the reset:

```bash
# Back it up first — this is the only copy of your list.
mv ~/.config/omarchy/dashboard ~/dashboard-services.bak

# Or, if you really mean it:
rm -rf ~/.config/omarchy/dashboard
```

That directory holds `prefs.json` as well, so this resets the settings with the
list. The next time the panel opens it recreates the directory and reseeds the
three examples, exactly as on a first install. If you set `dataFile`, clear that
path instead — the default above is no longer the one in use.

The icon cache is separate and safe to delete at any time; it refetches.

```bash
~/.config/omarchy/plugins/perfektnacht.dashboard-plugin/bin/dashboard clear-cache
```

Omarchy shell plugins run unsandboxed inside the shell process — read the source
of this one (and any other) before you enable it.

## Requirements

- Omarchy Shell
- `jq`
- `curl` (icon fetching and reachability checks; everything else works without a
  network)
- `sha256sum` (coreutils) — names cache entries
- `qt6-svg` — Qt's SVG image handler. Without it SVG icons stay as the fallback
  glyph and nothing else breaks; `.png` icon URLs still render.

`qt6-shadertools` is **not** required to run this. The CRT shader is compiled
ahead of time and the resulting `.qsb` is committed, so installing the plugin
needs nothing extra. It is only needed to *change* the shader — see below.

## bin/dashboard

Every read, write, and fetch goes through this script so the QML thread never
blocks on disk or network. `--help` lists everything; the short version:

```bash
bin/dashboard list                   # print the services as JSON, seeding on first run
bin/dashboard save '[...]'           # validate and write atomically (temp file + mv)
bin/dashboard icon plex.svg          # print the cached path, fetching if needed
bin/dashboard icon https://host/i.svg   # the URL form works here too
bin/dashboard icons plex arr-dashboard  # resolve several at once as JSON
bin/dashboard status http://nas:8096 http://router  # probe in parallel, JSON of url -> up/down
bin/dashboard prefs                  # print the panel preferences as JSON
bin/dashboard set-pref pollStatus true   # set one preference
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
qmllint -I /usr/share/omarchy/shell Widget.qml
```

### Editing the shader

`shaders/crt.frag` is the source; `shaders/crt.frag.qsb` is what Qt actually
loads. **Editing the `.frag` alone changes nothing** — recompile it, and commit
everything it writes:

```bash
bin/build-shader        # needs qt6-shadertools (Arch) / qt6-shader-baker (Debian)
```

It finds `qsb` wherever the distribution put it — on Arch that is
`/usr/lib/qt6/bin/qsb`, which is not on `PATH` — or takes `QSB=/path/to/qsb`.
Alongside the `.qsb` it writes a `.sha256` of the source it compiled, and CI
fails if that hash stops matching the `.frag`. That is the check for the failure
this warns about: the compiled artifact has to be committed, because installing
the plugin is a clone with no build step, so a `.frag` edit that never got
recompiled would otherwise be completely silent.

CI also checks two things the compiler will not. Every uniform must have a
matching `property` on the `ShaderEffect` — a mismatch is not an error in
either language; the uniform just reads zero. And the offset comments in the
uniform block are re-derived from the `std140` rules, so a reordering that
shifts them is caught while it is still a stale comment.

The uniform block is `std140`, which means the order of the declarations is
load-bearing: a `vec2` has to sit on an 8-byte boundary and a `vec4` on a
16-byte one. Get it wrong and the values arrive silently in the wrong slots
rather than failing to compile, so keep the offset comments in the block honest
when adding a uniform. Every uniform is also a property on the `ShaderEffect` in
`Widget.qml`, matched by name — add one in the shader and you must add it there
too, or it reads as zero.

`omarchy plugin validate` needs an Omarchy machine, so CI can't run it —
`.github/workflows/ci.yml` covers the rest: manifest fields, shellcheck, the
helper's behaviour including path-traversal and negative-cache handling, and a
grep for hardcoded colors in `Widget.qml`. Run `omarchy plugin validate .`
locally before tagging a release.

Every color in the widget comes from `Color`, `Style`, or `bar.foreground`, so
switching themes repaints it live. Keep it that way: a literal hex value is a
color that stops following the theme, and CI fails on one. That applies to the
shader as well — its tint and bezel colours are passed in from the theme rather
than baked into the `.frag`, which is why CRT mode looks different on every
theme instead of the same green on all of them.

## License

MIT
