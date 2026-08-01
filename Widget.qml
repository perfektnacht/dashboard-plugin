import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "perfektnacht.dashboard-plugin"
  ipcTarget: "perfektnacht.dashboard-plugin"

  readonly property string script: Qt.resolvedUrl("bin/dashboard")
    .toString()
    .replace(/^file:\/\//, "")

  // The service list lives outside this checkout. `omarchy plugin update` is a
  // git fast-forward of the plugin directory, so anything stored in here would
  // be a merge conflict at best and silently reverted user data at worst.
  readonly property string defaultDataFile: Quickshell.env("HOME")
    + "/.config/omarchy/dashboard/services.json"
  readonly property string dataFile: String(root.setting("dataFile", defaultDataFile)
    || defaultDataFile)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color fainter: Qt.darker(foreground, 1.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int panelWidth: Style.space(400)
  readonly property int rowHeight: Style.space(50)
  // The tile every icon sits in, and the box the artwork is drawn into inside
  // it. Two numbers rather than one because the icons come from anywhere:
  // a padded tile at a fixed canvas size is what stops a screenshot-ish PNG
  // and a bleed-to-the-edge gradient SVG from reading at different weights.
  readonly property int iconSlot: Style.space(32)
  readonly property int iconCanvas: Style.space(20)
  readonly property int maxListHeight: Style.space(340)

  property var services: []
  // The filtered list the delegate renders: { key, name, url, icon, service }.
  property var rows: []
  // icon name (as the user typed it) -> absolute cached path, "" for a miss.
  // Reassigned wholesale so row bindings re-evaluate; mutating it would not.
  property var iconPaths: ({})
  // url -> "up" | "down". A url that isn't in here yet has not been probed;
  // that's a third state the dot draws, not a synonym for "down". Reassigned
  // wholesale for the same reason iconPaths is.
  property var statuses: ({})
  property bool statusPending: false

  // Panel preferences. These live beside the service list rather than in
  // shell.json, because shell.json is read-only to a plugin and both of these
  // are toggled from the panel itself. Defaults hold until the file is read,
  // so the first open after a shell start behaves like every later one.
  property bool checkStatus: true
  property bool pollStatus: false
  property string prefError: ""
  property var prefQueue: []

  property string query: ""
  property int highlightedIndex: -1
  property bool loaded: false
  property bool listPending: false
  property bool iconsPending: false
  property bool iconsPendingRefresh: false

  property string loadError: ""
  property string saveError: ""
  property string formError: ""

  // "list" shows the services, "form" replaces them with the add/edit fields,
  // "settings" with the preference toggles. One panel, three states, so the
  // popup never grows a second window.
  property string mode: "list"
  // Which toggle the keyboard cursor is on in settings mode.
  property int settingsIndex: 0
  // Empty while adding, the service id while editing.
  property string editingId: ""
  property string pendingDeleteId: ""
  property var savePending: null

  readonly property string errorText: loadError !== "" ? loadError : saveError

  // The hero's second line. PanelHero uppercases it, so it's written in
  // sentence case here. How many services there are, how many the search
  // narrowed them to, and — once the probes land — how many are actually
  // answering, which is the one number worth reading from across the room.
  readonly property string heroMeta: {
    if (!loaded) return "Loading…"
    var total = services.length
    if (total === 0) return "No services yet"
    if (query.trim() !== "") return rows.length + " of " + total + " shown"

    var base = total + (total === 1 ? " service" : " services")
    if (!checkStatus) return base

    var up = 0
    var known = 0
    for (var i = 0; i < services.length; i++) {
      var state = statusFor(services[i].url)
      if (state === "") continue
      known++
      if (state === "up") up++
    }
    if (known === 0) return base + " · checking…"
    // "All up" rather than "4 up" when nothing is down: the interesting
    // reading of this line is whether anything needs attention, and a bare
    // count makes you compare two numbers to find out.
    if (known === total && up === total) return base + " · all up"
    return base + " · " + up + " up"
  }

  readonly property var pendingDeleteService: {
    for (var i = 0; i < services.length; i++)
      if (services[i].id === pendingDeleteId) return services[i]
    return null
  }

  // ------------------------------------------------------------------ data

  function requestList() {
    if (listProc.running) {
      listPending = true
      return
    }
    listPending = false
    loadError = ""
    listProc.command = [script, "--file", dataFile, "list"]
    listProc.running = true
  }

  // One process for the whole list rather than one per row: the helper fetches
  // uncached icons in parallel, so a cold cache costs one round trip's latency
  // instead of one per service. Called on load and after a save, never on a
  // keystroke — filtering doesn't change which icons exist.
  function requestIcons(refresh) {
    var names = []
    var seen = {}
    for (var i = 0; i < services.length; i++) {
      var name = String(services[i].icon || "")
      // Prefixed so an icon literally named "constructor" doesn't collide with
      // something already on Object.prototype.
      if (name === "" || seen["n:" + name]) continue
      seen["n:" + name] = true
      names.push(name)
    }
    if (names.length === 0) {
      iconPaths = ({})
      return
    }
    if (iconProc.running) {
      iconsPending = true
      iconsPendingRefresh = iconsPendingRefresh || refresh === true
      return
    }
    iconsPending = false
    iconsPendingRefresh = false
    var command = [script, "icons"]
    if (refresh === true) command.push("--refresh")
    iconProc.command = command.concat(names)
    iconProc.running = true
  }

  // One process for the whole sweep, same as the icons: the helper probes in
  // parallel, so a panel of ten services waits for the slowest one instead of
  // the sum, and one unplugged box can't stall the dots behind it. Called when
  // the list lands and after a save — never on a keystroke, since filtering
  // doesn't change whether a service is answering.
  function requestStatus() {
    if (!checkStatus) {
      statuses = ({})
      return
    }
    // Nothing probes the network behind a closed panel — including the list
    // load that runs once at shell startup, which would otherwise sweep every
    // service before the user had opened anything. Opening re-reads the list,
    // and the sweep rides along with it.
    if (!opened) return
    var urls = []
    var seen = {}
    for (var i = 0; i < services.length; i++) {
      var url = String(services[i].url || "")
      // Prefixed so a service pointed at a url named "constructor" — however
      // unlikely — doesn't collide with something on Object.prototype.
      if (url === "" || seen["u:" + url]) continue
      seen["u:" + url] = true
      urls.push(url)
    }
    if (urls.length === 0) {
      statuses = ({})
      return
    }
    if (statusProc.running) {
      statusPending = true
      return
    }
    statusPending = false
    statusProc.command = [script, "status"].concat(urls)
    statusProc.running = true
  }

  function requestPrefs() {
    if (prefsProc.running) return
    prefsProc.command = [script, "--file", dataFile, "prefs"]
    prefsProc.running = true
  }

  // The toggle has already moved by the time this runs — a switch that waits on
  // a subprocess to animate feels broken. A failed write is reported in the
  // settings view rather than rolled back: the setting is live either way, and
  // what the user needs to know is that it won't survive a restart.
  //
  // Queued rather than fired straight off, because `set-pref` is a
  // read-modify-write of one shared file. Flipping both toggles quickly enough
  // to overlap two helpers would have the second one read the file before the
  // first had written it, and silently drop a setting.
  function setPref(key, value) {
    prefError = ""
    prefQueue = prefQueue.concat([{ key: key, value: value === true }])
    flushPrefs()
  }

  function flushPrefs() {
    if (prefProc.running || prefQueue.length === 0) return
    var next = prefQueue[0]
    prefQueue = prefQueue.slice(1)
    prefProc.command = [script, "--file", dataFile, "set-pref", next.key,
      next.value ? "true" : "false"]
    prefProc.running = true
  }

  // Writes go through the helper too, so the shell process never blocks on
  // disk and a malformed payload is rejected before the old file is touched.
  function persist(next, refreshIcons) {
    if (saveProc.running) {
      savePending = { services: next, refreshIcons: refreshIcons === true }
      return
    }
    savePending = null
    saveError = ""
    saveProc.payload = next
    saveProc.refreshIcons = refreshIcons === true
    saveProc.command = [script, "--file", dataFile, "save", JSON.stringify(next)]
    saveProc.running = true
  }

  function newId() {
    return "svc-" + Date.now().toString(36) + "-"
      + Math.floor(Math.random() * 1679616).toString(36)
  }

  // ------------------------------------------------------------------ rows

  function refreshRows() {
    var text = query.trim().toLowerCase()
    var out = []
    for (var i = 0; i < services.length; i++) {
      var service = services[i]
      var haystack = (service.name + " " + service.url + " "
        + (service.icon || "")).toLowerCase()
      if (text && haystack.indexOf(text) === -1) continue
      out.push({
        key: service.id,
        name: service.name,
        url: service.url,
        icon: String(service.icon || ""),
        service: service
      })
    }
    rows = out
    highlightedIndex = rows.length > 0 ? 0 : -1
  }

  function highlightedRow() {
    if (highlightedIndex < 0 || highlightedIndex >= rows.length) return null
    return rows[highlightedIndex]
  }

  // Read through a function rather than indexing `iconPaths` in the delegate:
  // an icon named "constructor" or "toString" would otherwise pick up
  // something off Object.prototype and hand a row a function as its path.
  function iconPathFor(name) {
    if (!name) return ""
    var value = iconPaths[name]
    return typeof value === "string" ? value : ""
  }

  // Same guard as iconPathFor: a service pointed at "toString" would otherwise
  // pick a function up off Object.prototype and hand a row a state that is
  // neither "up", "down", nor "".
  function statusFor(url) {
    if (!url) return ""
    var value = statuses[url]
    return value === "up" || value === "down" ? value : ""
  }

  function clearSearch() {
    query = ""
    searchField.text = ""
  }

  // ------------------------------------------------------------- settings

  // The two toggles, in the order they're drawn. Kept as data so the keyboard
  // cursor, the click handlers, and the rows themselves can't disagree about
  // what is where.
  readonly property var settingsRows: [
    { key: "checkStatus", value: checkStatus },
    { key: "pollStatus", value: pollStatus }
  ]

  function openSettings() {
    mode = "settings"
    prefError = ""
    settingsIndex = 0
    pendingDeleteId = ""
    // The search field is hidden in this mode, so nothing would hold focus and
    // the catcher's keys would go nowhere.
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closeSettings() {
    if (mode !== "settings") return
    mode = "list"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // The two settings depend on each other — you can't keep re-checking if you
  // never check — but neither switch is ever disabled for it. A switch you
  // aren't allowed to touch until you find the other one it's hiding behind is
  // a worse explanation of that relationship than just doing what was asked:
  // turning polling on turns checking on with it, and turning checking off
  // takes polling down, so what the two switches show is always what runs.
  function toggleSetting(key) {
    if (key === "checkStatus") {
      checkStatus = !checkStatus
      setPref("checkStatus", checkStatus)
      if (!checkStatus && pollStatus) {
        pollStatus = false
        setPref("pollStatus", false)
      }
      // Probe straight away when switched on, so the dots fill in while the
      // settings view is still up and the toggle visibly did something.
      // Switching off clears them, which is what requestStatus does too.
      requestStatus()
    } else if (key === "pollStatus") {
      pollStatus = !pollStatus
      setPref("pollStatus", pollStatus)
      if (pollStatus && !checkStatus) {
        checkStatus = true
        setPref("checkStatus", true)
        requestStatus()
      }
    }
  }

  // --------------------------------------------------------------- opening

  // omarchy-launch-browser resolves the xdg default browser and launches it
  // detached — the whole point of not hardcoding a browser or shelling out to
  // xdg-open. execDetached takes argv, so the URL is never parsed by a shell.
  function openService(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
    root.close()
  }

  function activateRow(row) {
    if (!row) return
    openService(row.url)
  }

  // ---------------------------------------------------------------- form

  // Accept what a homelab user actually types. A bare `nas:8096` or
  // `192.168.1.10` is a host, not a URI scheme, so it gets http:// in front.
  // Anything with a real scheme has to be http or https: the row is one click
  // from a browser launch, and `file://` or `javascript:` there is a trap.
  // Returns "" when the input can't be made into a usable URL.
  function normalizeUrl(raw) {
    var text = String(raw || "").trim()
    if (text === "") return ""
    if (/\s/.test(text)) return ""

    var schemed = text.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\//)
    if (schemed) {
      var scheme = schemed[1].toLowerCase()
      if (scheme !== "http" && scheme !== "https") return ""
      // Reject `http://` with nothing after it.
      return text.length > schemed[0].length ? text : ""
    }

    // `something:` with no `//` is a non-http URI (mailto:, javascript:)
    // unless what follows is a port number — `nas:8096` is the shape people
    // type for a service on the LAN.
    var colon = text.match(/^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/)
    if (colon && !/^\d+(\/|$)/.test(colon[2])) return ""

    return "http://" + text
  }

  // True when the field holds something the user meant as a URL rather than a
  // name. Used only to pick the right error message — the validity decision
  // belongs to isValidIconUrl.
  function looksLikeIconUrl(text) {
    return /:\/\//.test(text) || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(text)
  }

  // Mirrors valid_icon_url in bin/dashboard, so a bad paste is caught inline
  // instead of silently becoming a fallback glyph. https only, no `..`, and a
  // known image suffix; the host is deliberately unrestricted because
  // self-hosting an icon set is a reasonable thing to do.
  function isValidIconUrl(text) {
    if (text.indexOf("..") !== -1) return false
    return /^https:\/\/[A-Za-z0-9.-]+(:[0-9]+)?\/[A-Za-z0-9._~%@/+-]*\.(svg|png|webp)$/i.test(text)
  }

  // The icon field takes three shapes, because both icon sites put "copy link
  // address" on every icon and that is how people actually use them:
  //
  //   plex        a bare name, looked up in each collection in turn
  //   plex.svg    the same thing, spelled as the sites spell it
  //   https://…   a pasted URL, fetched exactly as written
  //
  // A name is lowercased and given its extension; a URL is preserved verbatim,
  // since URLs are case-sensitive. Returns "" for "no icon" and null for
  // "unusable", which the caller turns into an inline error.
  function normalizeIconName(raw) {
    var text = String(raw || "").trim()
    if (text === "") return ""

    if (/^https:\/\//i.test(text)) return isValidIconUrl(text) ? text : null
    // Any other scheme — http://, file://, ftp:// — is a URL we won't fetch,
    // not a filename with a colon in it.
    if (looksLikeIconUrl(text)) return null

    text = text.toLowerCase()
    // Keep an extension the collections actually publish — `foo.png` asks for
    // the PNG, and appending `.svg` to it names a file that exists nowhere.
    // Bare names still mean SVG. Mirrors icon_key() in bin/dashboard.
    if (!/\.(svg|png|webp)$/.test(text)) text += ".svg"
    if (!/^[a-z0-9._-]+$/.test(text) || text.charAt(0) === ".") return null
    return text
  }

  function openForm(service) {
    mode = "form"
    editingId = service ? service.id : ""
    formError = ""
    nameField.text = service ? service.name : ""
    urlField.text = service ? service.url : ""
    iconField.text = service ? String(service.icon || "") : ""
    Qt.callLater(function() {
      nameField.forceActiveFocus()
      nameField.selectAll()
    })
  }

  function closeForm() {
    if (mode !== "form") return
    mode = "list"
    editingId = ""
    formError = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function submitForm() {
    var name = nameField.text.trim()
    if (name === "") {
      formError = "Name can't be empty"
      nameField.forceActiveFocus()
      return
    }

    var url = normalizeUrl(urlField.text)
    if (url === "") {
      formError = urlField.text.trim() === ""
        ? "URL can't be empty"
        : "URL must be an http:// or https:// address"
      urlField.forceActiveFocus()
      return
    }

    var icon = normalizeIconName(iconField.text)
    if (icon === null) {
      // Two very different mistakes; naming the one they made is the whole
      // value of an inline error.
      formError = looksLikeIconUrl(iconField.text.trim())
        ? "Icon URLs must be https:// and end in .svg, .png, or .webp"
        : "Icon names look like plex.svg — letters, digits, . _ - only"
      iconField.forceActiveFocus()
      return
    }

    formError = ""

    var next = []
    var replaced = false
    for (var i = 0; i < services.length; i++) {
      var service = services[i]
      if (editingId !== "" && service.id === editingId) {
        // Keep id and position: editing a row shouldn't move it.
        next.push({ id: service.id, name: name, url: url, icon: icon })
        replaced = true
      } else {
        next.push({
          id: service.id,
          name: service.name,
          url: service.url,
          icon: String(service.icon || "")
        })
      }
    }
    if (!replaced) next.push({ id: newId(), name: name, url: url, icon: icon })

    // --refresh so a corrected icon name is retried immediately instead of
    // waiting out the helper's negative cache.
    persist(next, true)
  }

  // Shared by the three form fields. Escape backs out to the list rather than
  // closing the panel, Enter saves from any field, and Tab cycles the fields
  // instead of switching panels — inside a form that is what Tab means.
  function handleFormKey(event, next, previous) {
    if (event.key === Qt.Key_Escape) {
      closeForm()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      submitForm()
      event.accepted = true
    } else if (event.key === Qt.Key_Backtab
      || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
      previous.forceActiveFocus()
      previous.selectAll()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab) {
      next.forceActiveFocus()
      next.selectAll()
      event.accepted = true
    }
  }

  function requestDelete(id) {
    if (!id) return
    pendingDeleteId = id
  }

  function confirmDelete() {
    var id = pendingDeleteId
    pendingDeleteId = ""
    if (id === "") return
    var next = []
    for (var i = 0; i < services.length; i++) {
      if (services[i].id === id) continue
      next.push(services[i])
    }
    persist(next, false)
  }

  // ------------------------------------------------------------ lifecycle

  Component.onCompleted: {
    requestList()
    requestPrefs()
  }

  // `settings` is injected after construction, so the data file can change
  // out from under the first load. Preferences live beside the data file, so
  // they move with it.
  onDataFileChanged: {
    requestList()
    requestPrefs()
  }

  onOpenedChanged: {
    if (!opened) return
    if (mode === "form") closeForm()
    if (mode === "settings") closeSettings()
    pendingDeleteId = ""
    saveError = ""
    query = ""
    // Recompute explicitly: if the field was already empty, clearing it below
    // fires no onTextChanged and `rows` would keep the previous results.
    refreshRows()
    // Re-read on every open so hand edits to services.json show up without a
    // shell restart. `rows` keeps the previous list until the new one lands,
    // so this never flashes an empty panel. The status sweep rides along with
    // the list load, so opening the panel is what refreshes the dots.
    requestList()
    requestPrefs()
    Qt.callLater(function() {
      searchField.text = ""
      searchField.forceActiveFocus()
    })
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.services = JSON.parse(String(text || "[]"))
        } catch (error) {
          root.services = []
          root.loadError = "Could not read the service list"
        }
        root.loaded = true
        root.refreshRows()
        root.requestIcons(false)
        root.requestStatus()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The helper reports a hand-mangled services.json by name; that is
        // far more actionable than "could not read".
        var message = String(text || "").trim().split("\n")[0]
        listProc.failureText = message.replace(/^dashboard:\s*/, "")
      }
    }
    property string failureText: ""
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.loadError = failureText !== ""
          ? failureText
          : "Could not read the service list"
      }
      failureText = ""
      root.loaded = true
      if (root.listPending) Qt.callLater(root.requestList)
    }
  }

  Process {
    id: iconProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.iconPaths = JSON.parse(String(text || "{}"))
        } catch (error) {
          // Every row falls back to the glyph; not worth an error banner.
          root.iconPaths = ({})
        }
      }
    }
    // A failed icon run needs no error banner: every row already falls back to
    // the glyph, and a missing logo is not worth a line of red text.
    onExited: {
      if (root.iconsPending) {
        var refresh = root.iconsPendingRefresh
        Qt.callLater(function() { root.requestIcons(refresh) })
      }
    }
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.statuses = JSON.parse(String(text || "{}"))
        } catch (error) {
          // Every row falls back to the waiting dot. A sweep that couldn't be
          // parsed says nothing about the services, so it shouldn't be
          // reported as though every one of them were down.
          root.statuses = ({})
        }
      }
    }
    // A failed sweep needs no error banner for the same reason: the list is
    // still a list of links, and the dots simply stay grey.
    onExited: {
      if (root.statusPending) Qt.callLater(root.requestStatus)
    }
  }

  Process {
    id: prefsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var values = {}
        try {
          values = JSON.parse(String(text || "{}"))
        } catch (error) {
          values = {}
        }
        // Absent keys keep their defaults, so a prefs file written by an older
        // version — or none at all — is a normal state, not a missing one.
        if (typeof values.checkStatus === "boolean") root.checkStatus = values.checkStatus
        if (typeof values.pollStatus === "boolean") root.pollStatus = values.pollStatus
      }
    }
  }

  Process {
    id: prefProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim().split("\n")[0]
        prefProc.failureText = message.replace(/^dashboard:\s*/, "")
      }
    }
    property string failureText: ""
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.prefError = failureText !== ""
          ? failureText
          : "Could not save this setting"
      }
      failureText = ""
      root.flushPrefs()
    }
  }

  // Only while the panel is open, and only when asked for: a bar widget has no
  // business probing the network behind a closed popup.
  Timer {
    running: root.opened && root.checkStatus && root.pollStatus
    interval: 15000
    repeat: true
    onTriggered: root.requestStatus()
  }

  Process {
    id: saveProc
    property var payload: null
    property bool refreshIcons: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim().split("\n")[0]
        saveProc.failureText = message.replace(/^dashboard:\s*/, "")
      }
    }
    property string failureText: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.services = payload
        root.refreshRows()
        root.requestIcons(refreshIcons)
        // A new or edited row has no dot until it's been probed, and an edited
        // URL's old verdict is about an address that is no longer on the list.
        root.requestStatus()
        // The form stays up on failure so the entry isn't lost.
        if (root.mode === "form") root.closeForm()
      } else {
        var message = failureText !== "" ? failureText : "Could not save services"
        root.saveError = message
        if (root.mode === "form") root.formError = message
      }
      failureText = ""
      if (root.savePending) {
        var next = root.savePending
        root.savePending = null
        Qt.callLater(function() { root.persist(next.services, next.refreshIcons) })
      }
    }
  }

  // ------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕮"
    active: root.opened
    tooltipText: "Network dashboard"
    onPressed: function(mouseButton) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(
      root.panelWidth
        + panel.padding * 2
        + Border.left(panel.borderSpec)
        + Border.right(panel.borderSpec))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The form owns every key while it is up: its fields handle Escape,
      // Enter, and Tab themselves, and the catcher's vim-style h/j/k/l would
      // otherwise eat characters that never reach the focused field.
      blocked: root.mode === "form"
      // The search field keeps focus and handles all of this first; these
      // handlers are the fallback for the moment after a click lands somewhere
      // that isn't a text input. The pendingDeleteId guards keep a stray key
      // from acting on the list underneath an open confirmation.
      // Settings mode has no text field to hold focus, so the catcher drives it
      // directly: Escape goes back to the list, the cursor walks the toggles,
      // and Enter or Space flips the one it is on.
      onCloseRequested: {
        if (root.pendingDeleteId !== "") root.pendingDeleteId = ""
        else if (root.mode === "settings") root.closeSettings()
        else root.close()
      }
      onTabRequested: function(direction) {
        // Tabbing to the next bar panel from inside settings would strand the
        // user's changes behind a panel they'd have to come back to.
        if (root.pendingDeleteId !== "" || root.mode === "settings") return
        root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.pendingDeleteId !== "" || dy === 0) return
        if (root.mode === "settings") {
          root.settingsIndex = dy > 0
            ? Math.min(root.settingsRows.length - 1, root.settingsIndex + 1)
            : Math.max(0, root.settingsIndex - 1)
          return
        }
        if (root.rows.length === 0) return
        root.highlightedIndex = dy > 0
          ? Math.min(root.rows.length - 1, root.highlightedIndex + 1)
          : Math.max(0, root.highlightedIndex - 1)
      }
      onActivateRequested: {
        if (root.pendingDeleteId !== "") return
        if (root.mode === "settings") {
          var setting = root.settingsRows[root.settingsIndex]
          if (setting) root.toggleSetting(setting.key)
          return
        }
        root.activateRow(root.highlightedRow())
      }
      onDeleteRequested: {
        if (root.pendingDeleteId !== "" || root.mode === "settings") return
        var row = root.highlightedRow()
        if (row) root.requestDelete(row.key)
      }
      onTextKey: function(text) {
        // In settings mode a stray letter has nowhere to go: typing into the
        // hidden search field would silently filter a list you can't see.
        if (root.pendingDeleteId !== "" || root.mode === "settings") return
        searchField.text += text
        searchField.forceActiveFocus()
        searchField.cursorPosition = searchField.text.length
      }

      // Ctrl+, is claimed here rather than in the search field's key handler,
      // where every other shortcut lives. PanelKeyCatcher sees keys first and
      // forwards anything with printable text straight into the search box —
      // Ctrl+N survives that because Qt hands it a control character, but
      // Ctrl+, arrives as a plain "," and lands in the query before a field
      // handler ever runs. A Shortcut consumes the event outright. Scoped to
      // an open panel in list mode, so it can't fire from the form, from the
      // settings view it opens, or from a closed popup.
      Shortcut {
        sequence: "Ctrl+,"
        enabled: root.opened && root.mode === "list"
        onActivated: root.openSettings()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------------ list: header
        //
        // Add lives in the hero's trailing slot rather than beside the search
        // field: it's an action on the whole list, not on the query, and the
        // search row reads as a single control without it.
        PanelHero {
          visible: root.mode === "list"
          width: parent.width
          title: "Dashboard"
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: "󰕮"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            Row {
              spacing: Style.spacing.xs

              // Full foreground, not the dimmed variant the row actions use.
              // These two sit in the corner, which is the first place a glyph
              // gets lost — dimmed, they read as decoration rather than as
              // controls.
              PanelActionButton {
                iconText: "󰒓"
                tooltipText: "Settings  (Ctrl+,)"
                foreground: root.foreground
                hoverColor: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.openSettings()
              }

              PanelActionButton {
                iconText: "󰐕"
                tooltipText: "Add a service  (Ctrl+N)"
                foreground: root.foreground
                hoverColor: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.openForm(null)
              }
            }
          }
        }

        // ------------------------------------------------------ list: search
        Item {
          id: searchRow
          width: parent.width
          height: searchField.implicitHeight
          visible: root.mode === "list"

          TextField {
            id: searchField
            anchors.fill: parent
            placeholderText: "Search services…"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body

            onTextChanged: {
              root.query = text
              root.refreshRows()
            }

            // The field holds focus while the panel is open, so PanelKeyCatcher
            // never sees these keys — every shortcut the panel supports has to
            // be handled (and forwarded) here too.
            Keys.onPressed: function(event) {
              // The confirmation gets first refusal: it needs Left/Right, which
              // the text cursor would otherwise swallow.
              if (root.pendingDeleteId !== "" && confirmDialog.handleKey(event)) {
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.switchPanel((event.modifiers & Qt.ShiftModifier)
                  || event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                if (root.rows.length > 0)
                  root.highlightedIndex = Math.min(root.rows.length - 1,
                    root.highlightedIndex + 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                if (root.rows.length > 0)
                  root.highlightedIndex = Math.max(0, root.highlightedIndex - 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activateRow(root.highlightedRow())
                event.accepted = true
              } else if (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier)) {
                root.openForm(null)
                event.accepted = true
              } else if (event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier)) {
                var editRow = root.highlightedRow()
                if (editRow) root.openForm(editRow.service)
                event.accepted = true
              } else if (event.key === Qt.Key_Delete) {
                var deleteRow = root.highlightedRow()
                if (deleteRow) root.requestDelete(deleteRow.key)
                event.accepted = true
              }
            }
          }
        }

        Text {
          visible: root.mode === "list" && root.errorText !== ""
          width: parent.width
          text: root.errorText
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          visible: root.mode === "list"
          width: parent.width
          foreground: root.foreground
        }

        ListView {
          id: serviceList
          visible: root.mode === "list"
          width: parent.width
          height: visible ? Math.min(contentHeight, root.maxListHeight) : 0
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.rows
          currentIndex: root.highlightedIndex
          // Deferred a turn: `rows` is rebuilt on every keystroke, and swapping
          // the model resets the view out from under an immediate call, leaving
          // contentY at 0 with the cursor off screen.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0 && currentIndex < count)
              positionViewAtIndex(currentIndex, ListView.Contain)
          }

          // CursorSurface is the shell's row contract: idle rows paint
          // nothing, and the one row under the keyboard cursor (or the mouse,
          // which moves the cursor) carries the shared hover fill and border.
          // A list of near-invisible filled slabs was competing with itself;
          // one lit row against an empty column is what the built-in panels do.
          delegate: CursorSurface {
            id: serviceRow
            required property var modelData
            required property int index
            readonly property bool highlighted: index === root.highlightedIndex
            // "" means either "not fetched yet" or "no such icon upstream".
            // Both render the fallback glyph, so the row never waits on the
            // network to become useful.
            readonly property string iconPath: root.iconPathFor(modelData.icon)
            // "up", "down", or "" for not probed yet. Not called `state`:
            // that name is taken by Item's own state machine, and assigning a
            // string to it would try to activate a state called "up".
            readonly property string reachability: root.statusFor(modelData.url)

            width: ListView.view.width
            height: root.rowHeight
            hasCursor: highlighted
            foreground: root.foreground
            accent: Color.accent

            BorderSurface {
              id: iconHolder
              width: root.iconSlot
              height: root.iconSlot
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.cornerRadius
              // A frame of its own, so a logo with a white plate and a logo
              // that bleeds to its own edges still occupy the same square.
              color: Util.alpha(root.foreground, 0.07)
              borderSpec: Border.none()

              Image {
                id: iconImage
                anchors.centerIn: parent
                width: root.iconCanvas
                height: root.iconCanvas
                visible: serviceRow.iconPath !== "" && status === Image.Ready
                source: serviceRow.iconPath !== ""
                  ? Util.fileUrl(serviceRow.iconPath)
                  : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // An SVG is rasterised at sourceSize, not scaled from an
                // intrinsic bitmap — without this it decodes at its viewBox
                // size and comes out soft. Physical pixels, so HiDPI is crisp.
                sourceSize.width: Math.round(root.iconCanvas * Screen.devicePixelRatio)
                sourceSize.height: Math.round(root.iconCanvas * Screen.devicePixelRatio)
              }

              // Theme-aware fallback: a glyph in the bar foreground repaints on
              // a theme switch, which a bundled default bitmap could not.
              Text {
                anchors.centerIn: parent
                visible: !iconImage.visible
                text: "󰖟"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }

            }

            Column {
              id: rowText
              anchors.left: iconHolder.right
              anchors.right: rowActions.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlGap
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: serviceRow.modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: serviceRow.modelData.url
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // Reachability as a word rather than a colored dot. A dot carries
            // its whole meaning in its hue, which is one filter or one
            // colour-blind user away from saying nothing at all; a word still
            // reads, and keeps the colour as a second channel rather than the
            // only one.
            //
            // Shares the slot with the row actions instead of taking width of
            // its own: you want the status while scanning the list and the
            // buttons once you've picked a row, never both at once. Nothing
            // reflows, because the two trade places rather than stack.
            Text {
              id: rowStatus
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // Further in than the action buttons sit. Their glyphs are
              // centred in a 22px box, so they already clear the edge; a
              // right-aligned word would otherwise end flush against it.
              anchors.rightMargin: Style.spacing.rowPaddingX
              visible: root.checkStatus
              opacity: serviceRow.highlighted ? 0 : 1
              text: {
                if (serviceRow.reachability === "up") return "UP"
                if (serviceRow.reachability === "down") return "DOWN"
                // Nothing until the sweep lands. The hero already says it's
                // checking; four rows of placeholder would just be noise.
                return ""
              }
              color: serviceRow.reachability === "down" ? Color.urgent : Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true

              Behavior on opacity { NumberAnimation { duration: 80 } }
            }

            // Only on the row you're pointing at. Two glyph buttons on every
            // row is most of the clutter in a list this short, and the mouse
            // moves the cursor here on enter, so they're already up by the
            // time a pointer could reach them. `enabled` tracks the fade so a
            // faded-out button can't take a click it isn't offering; the Row
            // keeps its width either way, so the name never reflows.
            Row {
              id: rowActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.spacing.xs
              opacity: serviceRow.highlighted ? 1 : 0
              enabled: serviceRow.highlighted

              Behavior on opacity { NumberAnimation { duration: 80 } }

              PanelActionButton {
                iconText: "󰏫"
                tooltipText: "Edit"
                foreground: root.dim
                hoverColor: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.openForm(serviceRow.modelData.service)
              }

              PanelActionButton {
                iconText: "󰆴"
                tooltipText: "Delete"
                foreground: root.dim
                hoverColor: Color.urgent
                fontFamily: root.fontFamily
                onClicked: root.requestDelete(serviceRow.modelData.key)
              }
            }

            // Behind the action buttons so Edit and Delete win the click; the
            // rest of the row opens the service.
            MouseArea {
              anchors.fill: parent
              z: -1
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.highlightedIndex = serviceRow.index
              onClicked: root.activateRow(serviceRow.modelData)
            }
          }
        }

        // An empty list is the first thing a new user sees, and one grey
        // sentence on an otherwise blank panel reads like a failure. A glyph
        // gives it a center of gravity and says which empty this is.
        Column {
          visible: root.mode === "list" && root.rows.length === 0
          width: parent.width
          topPadding: Style.space(18)
          bottomPadding: Style.space(18)
          spacing: Style.space(10)

          readonly property bool searching: root.loaded && root.services.length > 0

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.loaded
            text: parent.searching ? "󰍉" : "󰒋"
            color: Util.alpha(root.foreground, 0.22)
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            width: parent.width
            text: {
              if (!root.loaded) return "Loading…"
              if (root.services.length === 0)
                return "No services yet — 󰐕 or Ctrl+N to add one"
              return "No matching services"
            }
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        // --------------------------------------------------------- settings
        Column {
          id: settingsColumn
          width: parent.width
          visible: root.mode === "settings"
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Dashboard"
            meta: "Settings"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "󰒓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Back  (Esc)"
                foreground: root.dim
                hoverColor: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.closeSettings()
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "REACHABILITY"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Check when the panel opens"
            description: "One request per service, in parallel"
            checked: root.checkStatus
            hasCursor: root.settingsIndex === 0
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: {
              root.settingsIndex = 0
              root.toggleSetting("checkStatus")
            }
            onHovered: function(isHovered) { if (isHovered) root.settingsIndex = 0 }
          }

          Toggle {
            width: parent.width
            label: "Keep checking while open"
            description: "Re-check every 15 seconds"
            checked: root.pollStatus
            hasCursor: root.settingsIndex === 1
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: {
              root.settingsIndex = 1
              root.toggleSetting("pollStatus")
            }
            onHovered: function(isHovered) { if (isHovered) root.settingsIndex = 1 }
          }

          Text {
            width: parent.width
            text: "A service counts as up if it answers at all — a login page "
              + "or a 404 still means it's running. Only a refused connection, "
              + "an unknown name, or a timeout is down."
            color: root.fainter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.prefError !== ""
            width: parent.width
            text: root.prefError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ------------------------------------------------------------- form
        Column {
          id: formColumn
          width: parent.width
          visible: root.mode === "form"
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.editingId === "" ? "NEW SERVICE" : "EDIT SERVICE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            text: "Name"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: nameField
            width: parent.width
            placeholderText: "Jellyfin"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.formError = ""
            Keys.onPressed: function(event) { root.handleFormKey(event, urlField, iconField) }
          }

          Text {
            width: parent.width
            text: "URL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: urlField
            width: parent.width
            placeholderText: "jellyfin.local:8096"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.formError = ""
            Keys.onPressed: function(event) { root.handleFormKey(event, iconField, nameField) }
          }

          Text {
            width: parent.width
            text: "Icon  ·  a name like plex.svg, or a copied icon link"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          TextField {
            id: iconField
            width: parent.width
            placeholderText: "jellyfin.svg  or  https://…  (optional)"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.formError = ""
            Keys.onPressed: function(event) { root.handleFormKey(event, nameField, urlField) }
          }

          Text {
            visible: root.formError !== ""
            width: parent.width
            text: root.formError
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Item {
            width: parent.width
            height: formActions.implicitHeight

            Row {
              id: formActions
              anchors.right: parent.right
              spacing: Style.spacing.controlGap

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.closeForm()
              }

              Button {
                text: root.editingId === "" ? "Add" : "Save"
                bordered: true
                selected: true
                foreground: root.foreground
                accent: Color.accent
                fontFamily: root.fontFamily
                onClicked: root.submitForm()
              }
            }
          }
        }
      }

      // Overlays the whole panel, so it has to be the last child to paint on
      // top of the list it is asking about.
      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.pendingDeleteId !== ""
        message: root.pendingDeleteService
          ? "Delete " + root.pendingDeleteService.name + "?"
          : "Delete this service?"
        confirmText: "Delete"
        foreground: root.foreground
        background: Color.popups.background
        fontFamily: root.fontFamily
        // Land on Cancel every time. The component remembers the last
        // selection, and Enter on a destructive default is how a service
        // disappears because the user was still typing.
        onOpenedChanged: if (opened) selectedIndex = 0
        onCanceled: {
          root.pendingDeleteId = ""
          searchField.forceActiveFocus()
        }
        onConfirmed: {
          root.confirmDelete()
          searchField.forceActiveFocus()
        }
      }
    }
  }
}
