import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Connections.js" as Data

// SSH-подключения (tabby). Кнопка в баре -> попап с папками, поиском и
// клавиатурой. Клик по записи открывает новое окно терминала (omarchy default,
// сейчас foot); "c"/"y" или кнопка — копируют команду ssh в буфер.
// Показываются только записи, у которых хотя бы один ключ лежит на диске.
Panel {
  id: root

  moduleName: "omarchy-ssh-connections"
  ipcTarget: "omarchy-ssh-connections"

  // ---------- пути и данные ----------
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string storePath: home + "/.config/omarchy/ssh-connections.json"

  property string storeText: ""
  property var namesCfg: ({})
  property var existsMap: ({})
  property var collapsed: ({})
  property bool collapsedInit: false

  property var model: ({ sections: [], visible: 0, hidden: 0 })
  property var filtered: ({ sections: [], flat: [], total: 0, query: "" })
  property int cursor: -1
  property string query: ""
  property int visibleTotal: 0
  property int hiddenTotal: 0

  // ---- слой ручных правок (удаление/редактирование поверх store) ----
  property var overrides: ({ deleted: [], edits: {} })
  property var editingEntry: null
  property string editName: ""
  property string editHost: ""
  property string editUser: ""
  property string editPort: ""
  property string editError: ""
  property bool confirmDeleteOpen: false
  property string confirmMessage: ""
  property var deleteCandidate: null
  property string savedNotice: ""
  Timer { id: noticeTimer; interval: 1500; onTriggered: root.savedNotice = "" }

  // ---------- палитра ----------
  readonly property color fg: root.barForeground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color accentC: Color.accent
  readonly property string fam: Style.font.family

  function hueFor(key) { return Data.hueFor(key) }

  function togglePanel() { root.toggle() }

  // ---------- данные ----------
  FileView {
    id: storeView
    path: root.storePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.storeText = String(text() || "")
      root.scheduleProbe()
    }
    onFileChanged: reload()
    onLoadFailed: { root.storeText = ""; root.recompute() }
  }

  FileView {
    id: namesView
    path: root.pluginDir + "/folderNames.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.namesCfg = JSON.parse(String(text() || "{}")) } catch (e) { root.namesCfg = {} }
      if (!root.collapsedInit) {
        var def = root.namesCfg.collapsedByDefault || []
        var c = {}
        for (var i = 0; i < def.length; i++) c[def[i]] = true
        root.collapsed = c
        root.collapsedInit = true
      }
      root.recompute()
    }
    onFileChanged: reload()
    onLoadFailed: { root.namesCfg = {}; root.recompute() }
  }

  // Проба ключей: какие unix-пути реально лежат на диске (bash stat разом).
  function probeScript() { return "for k in \"$@\"; do [ -f \"$k\" ] && echo \"1 $k\" || echo \"0 $k\"; done" }
  function unixCandidateKeys() {
    var seen = {}
    var out = []
    var raw = root.storeText
    var conns = []
    try { conns = JSON.parse(raw).connections || [] } catch (e) { return out }
    for (var i = 0; i < conns.length; i++) {
      var keys = conns[i].keys || []
      for (var j = 0; j < keys.length; j++) {
        var k = String(keys[j] || "")
        if (k.charAt(0) !== "/" || /^\/[A-Za-z]:/.test(k) || k.indexOf("\\") !== -1) continue
        if (seen[k]) continue
        seen[k] = true
        out.push(k)
      }
    }
    return out
  }
  function scheduleProbe() {
    var keys = root.unixCandidateKeys()
    if (keys.length === 0) { root.existsMap = {}; root.recompute(); return }
    var cmd = ["bash", "-c", root.probeScript(), "probe"].concat(keys)
    if (JSON.stringify(cmd) !== JSON.stringify(keyProbe.command)) keyProbe.command = cmd
    if (!keyProbe.running) keyProbe.running = true
  }

  Process {
    id: keyProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(String(text || ""))
    }
  }

  function applyProbe(output) {
    var map = {}
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.length < 3) continue
      var sp = line.indexOf(" ")
      var ok = line.slice(0, sp) === "1"
      map[line.slice(sp + 1)] = ok
    }
    root.existsMap = map
    root.recompute()
  }

  FileView {
    id: overridesView
    path: root.pluginDir + "/overrides.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.applyOverridesText(String(text() || ""))
      root.recompute()
    }
    onFileChanged: reload()
    onLoadFailed: { /* файла ещё нет — это нормально */ }
  }

  function applyOverridesText(raw) {
    try {
      var parsed = JSON.parse(raw || "{}")
      root.overrides = {
        deleted: Array.isArray(parsed.deleted) ? parsed.deleted : [],
        edits: parsed.edits && typeof parsed.edits === "object" ? parsed.edits : {}
      }
    } catch (e) {
      root.overrides = { deleted: [], edits: {} }
    }
  }

  // Дебаунс-запись overrides.json (tmp + mv). Вызывается после каждой правки.
  Timer {
    id: saveTimer
    interval: 250
    onTriggered: root.persistOverrides()
  }
  function scheduleSave() { saveTimer.restart() }
  function persistOverrides() {
    var json = JSON.stringify(root.overrides, null, 1)
    var path = root.pluginDir + "/overrides.json"
    var cmd = ["bash", "-c", "printf '%s' \"$1\" > \"$2.tmp\" && mv \"$2.tmp\" \"$2\"", "sshconn-overrides", json, path]
    if (JSON.stringify(cmd) !== JSON.stringify(saveProc.command)) saveProc.command = cmd
    if (!saveProc.running) saveProc.running = true
  }
  Process { id: saveProc }

  // ---- действия: удаление / редактирование ----
  function requestDelete(view) {
    root.deleteCandidate = view
    root.confirmMessage = "Удалить «" + String(view.name || view.host) + "»?\n"
      + "(id " + String(view.id).slice(0, 8) + " — скрывается и не вернётся при реимпорте из tabby)"
    root.confirmDeleteOpen = true
  }
  function applyDelete() {
    root.confirmDeleteOpen = false
    var cand = root.deleteCandidate
    root.deleteCandidate = null
    if (!cand || !cand.id) return
    var d = []
    for (var i = 0; i < root.overrides.deleted.length; i++) if (root.overrides.deleted[i] !== cand.id) d.push(root.overrides.deleted[i])
    d.push(cand.id)
    var e = {}
    for (var k in root.overrides.edits) if (k !== cand.id) e[k] = root.overrides.edits[k]
    root.overrides = { deleted: d, edits: e }
    root.scheduleSave()
    root.savedNotice = "удалено: " + String(cand.name || cand.host)
    noticeTimer.restart()
  }
  function cancelDelete() { root.confirmDeleteOpen = false; root.deleteCandidate = null }

  function startEdit(view) {
    root.editingEntry = view
    root.editName = String(view.name || "")
    root.editHost = String(view.host || "")
    root.editUser = String(view.user || "")
    root.editPort = String(view.port || "")
    root.editError = ""
  }
  function cancelEdit() {
    root.editingEntry = null
    root.editName = root.editHost = root.editUser = root.editPort = ""
    root.editError = ""
    keyCatcher.forceActiveFocus()
  }
  function saveEdit() {
    var name = String(root.editName || "").trim()
    var host = String(root.editHost || "").trim()
    var portText = String(root.editPort || "").trim()
    var port = 22
    if (portText !== "") {
      port = parseInt(portText, 10)
      if (!(port > 0 && port < 65536)) { root.editError = "Порт — число 1..65535"; return }
    }
    if (name === "") { root.editError = "Имя обязательно"; return }
    if (host === "") { root.editError = "Host обязателен"; return }
    var entry = root.editingEntry
    if (!entry || !entry.id) { root.editError = "Нет id записи"; return }
    var edits = {}
    for (var k in root.overrides.edits) edits[k] = root.overrides.edits[k]
    // правка хранит полный набор полей; удаление/реимпорт учитывают id записи
    edits[entry.id] = {
      name: name,
      host: host,
      user: String(root.editUser || "").trim(),
      port: port
    }
    root.overrides = { deleted: root.overrides.deleted, edits: edits }
    root.scheduleSave()
    root.savedNotice = "сохранено: " + name
    noticeTimer.restart()
    root.cancelEdit()
  }

  // ---------- модель ----------
  function recompute() {
    var m = Data.buildModel(root.storeText, root.namesCfg, root.existsMap, root.overrides)
    root.model = m
    root.visibleTotal = m.visible
    root.hiddenTotal = m.hidden
    var flt = Data.filterModel(m, root.query, root.collapsed)
    root.filtered = flt
    if (root.cursor >= flt.flat.length) root.cursor = flt.flat.length - 1
    if (root.cursor < 0 && flt.flat.length > 0) root.cursor = 0
  }
  onStoreTextChanged: root.scheduleProbe()
  onQueryChanged: root.recompute()
  Component.onCompleted: root.recompute()

  function toggleSection(key) {
    var next = {}
    for (var k in root.collapsed) next[k] = root.collapsed[k]
    next[key] = root.collapsed[key] === true ? false : true
    root.collapsed = next
    root.recompute()
  }

  // ---------- клавиатура ----------
  function moveCursor(dy) {
    var n = root.filtered.flat.length
    if (n === 0) { root.cursor = -1; return }
    var c = root.cursor < 0 ? 0 : root.cursor
    root.cursor = Math.max(0, Math.min(n - 1, c + dy))
  }
  function activateCursor() {
    if (root.cursor >= 0 && root.cursor < root.filtered.flat.length)
      root.openConn(root.filtered.flat[root.cursor])
  }
  function copyCursor() {
    if (root.cursor >= 0 && root.cursor < root.filtered.flat.length)
      root.copyConn(root.filtered.flat[root.cursor])
  }
  function handleTextKey(t) {
    if (t === "c" || t === "C" || t === "y") { root.copyCursor(); return }
    if (t === "e" || t === "E") {
      if (root.cursor >= 0 && root.cursor < root.filtered.flat.length)
        root.startEdit(root.filtered.flat[root.cursor])
      return
    }
    if (t === "/") { searchField.forceActiveFocus(); return }
    if (t.length === 1) {
      searchField.text = searchField.text + t
      searchField.forceActiveFocus()
      searchField.cursorPosition = searchField.text.length
    }
  }

  // ---------- действия ----------
  function commandText(view) {
    var q = function (s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }
    var parts = []
    var argv = view.command || []
    for (var i = 0; i < argv.length; i++) parts.push(q(argv[i]))
    return parts.join(" ")
  }
  function openConn(view) {
    var argv = ["omarchy-launch-terminal", "-e"].concat(view.command)
    openProc.command = argv
    openProc.running = true
    root.close()
  }
  function copyConn(view) {
    copyProc.command = ["bash", "-c", "printf '%s' \"$1\" | wl-copy", "sshconn-copy", root.commandText(view)]
    copyProc.running = true
    root.copiedName = String(view.name || view.host || "")
    copyTimer.restart()
  }

  property string copiedName: ""
  Timer {
    id: copyTimer
    interval: 1500
    onTriggered: root.copiedName = ""
  }

  Process { id: openProc }
  Process { id: copyProc }

  // ---------- кнопка в баре ----------
  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  Item {
    id: pill
    implicitWidth: pillContent.implicitWidth + Style.space(20)
    implicitHeight: Math.max(Style.space(24), pillContent.implicitHeight + Style.space(10))
    anchors.centerIn: parent

    Rectangle {
      anchors.fill: parent
      radius: Style.space(8)
      color: root.accentC
      opacity: root.opened ? 1 : 0.92
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }
    MouseArea {
      id: pillArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.togglePanel()
    }
    RowLayout {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        textFormat: Text.PlainText
        text: "\uf120"
        color: Color.background
        font.family: root.fam
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        text: "SSH"
        color: Color.background
        font.family: root.fam
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }
      Rectangle {
        id: countChip
        Layout.minimumWidth: Math.max(Style.space(19), chipText.implicitWidth + Style.space(8))
        Layout.preferredHeight: Style.space(15)
        Layout.alignment: Qt.AlignVCenter
        radius: Style.space(8)
        color: Color.background
        Text {
          id: chipText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(root.visibleTotal)
          color: root.accentC
          font.family: root.fam
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  // ---------- попап ----------
  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(Style.space(560), Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmDeleteOpen || root.editingEntry !== null || !keyCatcher.activeFocus

      onCloseRequested: root.close()
      onActivateRequested: root.activateCursor()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onTabRequested: function(direction) { searchField.forceActiveFocus() }
      onTextKey: root.handleTextKey(text)
      onDeleteRequested: {
        if (root.cursor >= 0 && root.cursor < root.filtered.flat.length)
          root.requestDelete(root.filtered.flat[root.cursor])
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          policy: panelFlick.contentHeight > panelFlick.height
            ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        }

        Column {
          id: content
          width: panelFlick.width - Style.space(8)
          spacing: Style.space(6)

          PanelHero {
            id: hero
            width: parent.width
            title: "SSH подключения"
            meta: root.visibleTotal + " с ключом на диске"
              + (root.hiddenTotal > 0 ? " · " + root.hiddenTotal + " скрыто" : "")
            foreground: root.fg
            fontFamily: root.fam
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uf120"
                color: root.fg
                font.family: root.fam
                font.pixelSize: Style.font.display
              }
            }
          }

          TextField {
            id: searchField
            width: parent.width
            visible: root.editingEntry === null
            placeholderText: "имя, host, ключ…"
            foreground: root.fg
            font.family: root.fam
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(7)
            onTextEdited: root.query = text
            onAccepted: if (root.filtered.flat.length > 0) root.activateCursor()
            Keys.onEscapePressed: {
              text = ""
              root.query = ""
              keyCatcher.forceActiveFocus()
            }
            Keys.onDownPressed: function(event) {
              if (root.filtered.flat.length > 0) {
                event.accepted = true
                root.cursor = 0
                keyCatcher.forceActiveFocus()
              }
            }
          }

          // ---- редактор записи ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.editingEntry !== null

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Редактирование"
              color: root.fg
              font.family: root.fam
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            TextField {
              width: parent.width
              text: root.editName
              placeholderText: "имя"
              foreground: root.fg
              font.family: root.fam
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
              onTextEdited: root.editName = text
              Keys.onEscapePressed: root.cancelEdit()
            }
            TextField {
              width: parent.width
              text: root.editHost
              placeholderText: "host"
              foreground: root.fg
              font.family: root.fam
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(6)
              onTextEdited: root.editHost = text
              Keys.onEscapePressed: root.cancelEdit()
            }
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: editUserField
                Layout.fillWidth: true
                text: root.editUser
                placeholderText: "user (пусто = по умолчанию)"
                foreground: root.fg
                font.family: root.fam
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(6)
                onTextEdited: root.editUser = text
                Keys.onEscapePressed: root.cancelEdit()
              }
              TextField {
                id: editPortField
                Layout.preferredWidth: Style.space(90)
                text: root.editPort
                placeholderText: "порт"
                foreground: root.fg
                font.family: root.fam
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(6)
                onTextEdited: root.editPort = text
                Keys.onEscapePressed: root.cancelEdit()
              }
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.editError !== ""
              text: root.editError
              color: Color.urgent
              font.family: root.fam
              font.pixelSize: Style.font.caption
            }
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              Button {
                text: "Сохранить"
                foreground: Color.background
                fontFamily: root.fam
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(5)
                Layout.fillWidth: true
                onClicked: root.saveEdit()
              }
              Button {
                text: "Отмена"
                foreground: root.fg
                fontFamily: root.fam
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(5)
                Layout.fillWidth: true
                onClicked: root.cancelEdit()
              }
            }
          }

          // ---- секции ----
          Column {
            id: sectionsCol
            width: parent.width
            spacing: Style.space(2)
            visible: root.editingEntry === null
              && (root.filtered.flat.length > 0 || root.filtered.sections.length > 0)

            Repeater {
              model: root.filtered.sections

              delegate: Column {
                required property var modelData
                width: sectionsCol.width
                spacing: Style.space(2)

                property var section: modelData

                FolderHeader {
                  width: parent.width
                  label: section.label
                  count: section.count
                  openedSection: section.open
                  hue: root.hueFor(section.key)
                  foreground: root.fg
                  fontFamily: root.fam
                  onToggled: root.toggleSection(section.key)
                }

                Column {
                  width: sectionsCol.width
                  spacing: Style.space(1)
                  visible: section.open

                  Repeater {
                    model: section.items

                    delegate: ConnRow {
                      required property var modelData
                      required property int index
                      width: sectionsCol.width
                      entry: modelData
                      hue: root.hueFor(section.key)
                      cursorSelected: modelData.flat === root.cursor
                      foreground: root.fg
                      fontFamily: root.fam
                      onOpenRequested: function(e) { root.openConn(e) }
                      onCopyRequested: function(e) { root.copyConn(e) }
                      onEditRequested: function(e) { root.startEdit(e) }
                      onDeleteRequested: function(e) { root.requestDelete(e) }
                    }
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.editingEntry === null && root.query !== "" && root.filtered.flat.length === 0
            text: "Ничего не найдено"
            color: root.dim
            font.family: root.fam
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.editingEntry === null && root.query === "" && root.filtered.flat.length === 0 && !storeView.loaded
            text: "Нет данных: " + root.storePath
            color: root.dim
            font.family: root.fam
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---- футер: подсказки ----
          RowLayout {
            width: parent.width
            spacing: Style.space(12)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.savedNotice !== ""
                ? root.savedNotice
                : (root.copiedName !== ""
                  ? "скопировано: " + root.copiedName
                  : "ключи на диске · скрыто " + root.hiddenTotal)
              color: root.savedNotice !== "" ? root.accentC : root.dim
              font.family: root.fam
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: root.editingEntry !== null
                ? "Esc — отмена"
                : "Enter открыть · C копировать · E править · X удалить · Esc закрыть"
              color: root.dim
              font.family: root.fam
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              Layout.alignment: Qt.AlignVCenter
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmDeleteOpen
        z: 20
        message: root.confirmMessage
        confirmText: "Удалить"
        cancelText: "Отмена"
        onConfirmed: root.applyDelete()
        onCanceled: root.cancelDelete()
      }
    }
  }

  // ---------- компоненты ----------
  component FolderHeader: Item {
    id: header

    property string label: ""
    property int count: 0
    property bool openedSection: true
    property color hue: "#00000000"
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    signal toggled()

    height: Math.max(Style.space(22), row.implicitHeight)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: header.toggled()
    }

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Rectangle {
        width: Style.space(8)
        height: Style.space(8)
        radius: Style.space(2)
        color: header.hue
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        text: openedSection ? "\u25BE" : "\u25B8"
        color: Qt.darker(header.hue, 1.5)
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        text: label.toUpperCase()
        color: header.hue
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.fillWidth: true
        elide: Text.ElideRight
        Layout.alignment: Qt.AlignVCenter
      }
      Text {
        textFormat: Text.PlainText
        visible: count > 0
        text: String(count)
        color: Qt.darker(foreground, 1.5)
        font.family: fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component ConnRow: CursorSurface {
    id: row

    property var entry: null
    property bool cursorSelected: false
    property color hue: "#00000000"
    property string fontFamily: Style.font.family
    signal openRequested(var entry)
    signal copyRequested(var entry)
    signal editRequested(var entry)
    signal deleteRequested(var entry)

    hasCursor: hover.hovered || cursorSelected
    implicitHeight: Math.max(Style.space(34), content.implicitHeight + Style.space(8))

    // цветной бар папки слева
    Rectangle {
      id: leftBar
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(3)
      anchors.bottomMargin: Style.space(3)
      anchors.leftMargin: Style.space(3)
      width: Style.space(3)
      radius: Style.space(1.5)
      color: row.hue
      visible: row.hue.a > 0
    }

    onCursorSelectedChanged: {
      if (cursorSelected) {
        var topY = row.mapToItem(panelFlick.contentItem, 0, 0).y
        var bottomY = topY + row.height
        if (topY < panelFlick.contentY) panelFlick.contentY = topY
        else if (bottomY > panelFlick.contentY + panelFlick.height)
          panelFlick.contentY = bottomY - panelFlick.height
      }
    }

    HoverHandler { id: hover }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: false
      cursorShape: Qt.PointingHandCursor
      onClicked: row.openRequested(row.entry)
    }

    RowLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(11)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(8)

      // иконка в цвете папки (лёгкая подложка)
      Rectangle {
        width: Style.space(24)
        height: Style.space(24)
        radius: Style.space(6)
        color: row.hue.a > 0 ? Qt.rgba(row.hue.r, row.hue.g, row.hue.b, 0.14) : "#31324488"
        Layout.alignment: Qt.AlignVCenter

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "\uf120"
          color: row.hue.a > 0 ? row.hue : root.accentC
          font.family: root.fam
          font.pixelSize: Style.font.bodySmall
        }
      }

      Column {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: entry ? String(entry.name || entry.host || "") : ""
          color: row.foreground
          font.family: root.fam
          font.pixelSize: Style.font.bodySmall
          font.bold: cursorSelected || hover.hovered
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: entry && entry.host !== ""
          text: entry ? (entry.user ? entry.user + "@" : "") + entry.host + ":" + entry.port : ""
          color: root.dim
          font.family: root.fam
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        text: entry ? String(entry.keyType || "") : ""
        color: Qt.darker(root.accentC, 1.2)
        font.family: root.fam
        font.pixelSize: Style.font.caption
        font.bold: true
        visible: entry && entry.keyType !== ""
        Layout.alignment: Qt.AlignVCenter
      }

      Button {
        text: "copy"
        visible: cursorSelected || hover.hovered
        foreground: root.dim
        fontFamily: root.fam
        fontSize: Style.font.caption
        horizontalPadding: Style.space(5)
        verticalPadding: Style.space(3)
        focusable: false
        Layout.alignment: Qt.AlignVCenter
        onClicked: row.copyRequested(row.entry)
      }

      Button {
        text: "edit"
        visible: cursorSelected || hover.hovered
        foreground: Qt.darker(root.fg, 1.25)
        fontFamily: root.fam
        fontSize: Style.font.caption
        horizontalPadding: Style.space(5)
        verticalPadding: Style.space(3)
        focusable: false
        Layout.alignment: Qt.AlignVCenter
        onClicked: row.editRequested(row.entry)
      }

      Button {
        text: "del"
        visible: cursorSelected || hover.hovered
        foreground: Color.urgent
        fontFamily: root.fam
        fontSize: Style.font.caption
        horizontalPadding: Style.space(5)
        verticalPadding: Style.space(3)
        focusable: false
        Layout.alignment: Qt.AlignVCenter
        onClicked: row.deleteRequested(row.entry)
      }
    }
  }
}
