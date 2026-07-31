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
  readonly property int iconSlot: Style.space(24)
  readonly property int maxListHeight: Style.space(340)

  property var services: []
  // The filtered list the delegate renders: { key, name, url, icon, service }.
  property var rows: []
  // icon name (as the user typed it) -> absolute cached path, "" for a miss.
  // Reassigned wholesale so row bindings re-evaluate; mutating it would not.
  property var iconPaths: ({})

  property string query: ""
  property int highlightedIndex: -1
  property bool loaded: false
  property bool listPending: false
  property bool iconsPending: false
  property bool iconsPendingRefresh: false

  property string loadError: ""
  property string saveError: ""
  property string formError: ""

  // "list" shows the services, "form" replaces them with the add/edit fields.
  // One panel, two states, so the popup never grows a second window.
  property string mode: "list"
  // Empty while adding, the service id while editing.
  property string editingId: ""
  property string pendingDeleteId: ""
  property var savePending: null

  readonly property string errorText: loadError !== "" ? loadError : saveError

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

  function clearSearch() {
    query = ""
    searchField.text = ""
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

  Component.onCompleted: requestList()

  // `settings` is injected after construction, so the data file can change
  // out from under the first load.
  onDataFileChanged: requestList()

  onOpenedChanged: {
    if (!opened) return
    if (mode === "form") closeForm()
    pendingDeleteId = ""
    saveError = ""
    query = ""
    // Recompute explicitly: if the field was already empty, clearing it below
    // fires no onTextChanged and `rows` would keep the previous results.
    refreshRows()
    // Re-read on every open so hand edits to services.json show up without a
    // shell restart. `rows` keeps the previous list until the new one lands,
    // so this never flashes an empty panel.
    requestList()
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
      onCloseRequested: {
        if (root.pendingDeleteId !== "") root.pendingDeleteId = ""
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.pendingDeleteId !== "") return
        root.switchPanel(direction)
      }
      onMoveRequested: function(dx, dy) {
        if (root.pendingDeleteId !== "" || dy === 0 || root.rows.length === 0) return
        root.highlightedIndex = dy > 0
          ? Math.min(root.rows.length - 1, root.highlightedIndex + 1)
          : Math.max(0, root.highlightedIndex - 1)
      }
      onActivateRequested: {
        if (root.pendingDeleteId !== "") return
        root.activateRow(root.highlightedRow())
      }
      onDeleteRequested: {
        if (root.pendingDeleteId !== "") return
        var row = root.highlightedRow()
        if (row) root.requestDelete(row.key)
      }
      onTextKey: function(text) {
        if (root.pendingDeleteId !== "") return
        searchField.text += text
        searchField.forceActiveFocus()
        searchField.cursorPosition = searchField.text.length
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        // ------------------------------------------------ list: search + add
        Item {
          id: searchRow
          width: parent.width
          height: Math.max(searchField.implicitHeight, addButton.implicitHeight)
          visible: root.mode === "list"

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: addButton.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
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

          PanelActionButton {
            id: addButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰐕"
            tooltipText: "Add a service  (Ctrl+N)"
            foreground: root.dim
            hoverColor: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.openForm(null)
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

          delegate: BorderSurface {
            id: serviceRow
            required property var modelData
            required property int index
            readonly property bool highlighted: index === root.highlightedIndex
            // "" means either "not fetched yet" or "no such icon upstream".
            // Both render the fallback glyph, so the row never waits on the
            // network to become useful.
            readonly property string iconPath: root.iconPathFor(modelData.icon)

            width: ListView.view.width
            height: root.rowHeight
            radius: Style.cornerRadius
            color: highlighted
              ? Style.hoverFillFor(root.foreground, Color.accent)
              : Util.alpha(root.foreground, 0.025)
            borderSpec: Border.none()

            Item {
              id: iconHolder
              width: root.iconSlot
              height: root.iconSlot
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.verticalCenter: parent.verticalCenter

              Image {
                id: iconImage
                anchors.fill: parent
                visible: serviceRow.iconPath !== "" && status === Image.Ready
                source: serviceRow.iconPath !== ""
                  ? Util.fileUrl(serviceRow.iconPath)
                  : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                // An SVG is rasterised at sourceSize, not scaled from an
                // intrinsic bitmap — without this it decodes at its viewBox
                // size and comes out soft. Physical pixels, so HiDPI is crisp.
                sourceSize.width: Math.round(iconHolder.width * Screen.devicePixelRatio)
                sourceSize.height: Math.round(iconHolder.height * Screen.devicePixelRatio)
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

            Row {
              id: rowActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.spacing.xs

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

        Text {
          visible: root.mode === "list" && root.rows.length === 0
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
