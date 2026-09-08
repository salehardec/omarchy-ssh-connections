// Connections.js — чистая модель списка SSH-подключений.
// Импортируется в QML (`import "Connections.js" as Data`) и в node для тестов.
// Без Qt/FS: вход — сырой текст store, конфиг имён папок, карта существования ключей.

function cleanName(raw, host) {
  var name = String(raw || "").trim()
  // хвост автоимпорта из ~/.ssh/config
  name = name.replace(/\(\s*\.ssh\/config\s*\)/gi, "")
  // хвост-маркер дубликата tabby: " Копия", "_Copy", "копия 2" и т.п.
  name = name.replace(/(?:^|[\s_\-.!])(копия|copy|kopie|дубль|duplicate)([\s_\-]?\d*)?\s*$/i, "")
  name = name.replace(/[\s_\-]*\(\d+\)\s*$/, "")
  // имя заканчивается на хост (IP или dns) — отрезаем служебную часть
  if (host) {
    var h = String(host)
    var re = new RegExp("(?:^|[\\s_\\-.])" + h.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "$")
    if (re.test(name)) name = name.replace(re, "")
  }
  // служебные префиксы tabby: "!", "*" и пр. мусор по краям
  name = name.replace(/^[\s_\-!*.]+/, "")
  // разделители "_" в пробелы (двойные схлопываются)
  name = name.replace(/_+/g, " ").replace(/\s{2,}/g, " ").trim()
  if (name === "") name = String(raw || "").trim()
  return name
}

function keyBasename(path) {
  var p = String(path || "")
  var i = p.lastIndexOf("/")
  if (i >= 0) p = p.slice(i + 1)
  return p
}

function keyLabel(path) {
  // id_ed25519 -> ed25519; остальные имена ключей остаются как есть (basename)
  return keyBasename(path).replace(/^id_/, "")
}

function isUnixPath(k) {
  if (typeof k !== "string" || k.charAt(0) !== "/") return false
  // windows-путь в tabby в виде "/C:\Users\..." — не кандидат
  if (/^\/[A-Za-z]:/.test(k)) return false
  if (k.indexOf("\\") !== -1) return false
  return true
}

// Первый ключ записи, реально лежащий на диске. existsMap: путь -> bool (все
// кандидаты пробиты bash'ем). Без карты (первые мгновения/тесты) — оптимизм:
// предпочитаем /home/..., иначе первый кандидат; после пробы карта пересобирает
// модель и скрывает то, чего нет.
function firstExistingKey(keys, existsMap) {
  var list = keys || []
  var candidates = []
  var i, k
  for (i = 0; i < list.length; i++) {
    k = list[i]
    if (isUnixPath(k)) candidates.push(k)
  }
  if (!candidates.length) return ""
  if (!existsMap) {
    for (i = 0; i < candidates.length; i++) if (candidates[i].indexOf("/home/") === 0) return candidates[i]
    return candidates[0]
  }
  for (i = 0; i < candidates.length; i++) if (existsMap[candidates[i]] === true) return candidates[i]
  return ""
}

function folderKey(c) {
  if (c.folder) return String(c.folder)
  return c.source === "tabby-cache" ? "@cache" : "@none"
}

function sshTarget(c) {
  return (c.user ? c.user + "@" : "") + c.host
}

function sshCommand(c) {
  var parts = ["ssh"]
  if (c.key) parts.push("-i", c.key, "-o", "IdentitiesOnly=yes")
  if (c.port && c.port !== 22) parts.push("-p", String(c.port))
  parts.push(sshTarget(c))
  return parts
}

function shortUuid(u) {
  return String(u).slice(0, 8)
}

// Мягкая нейтральная палитра (catppuccin muted/приглушённые) для папок.
var PALETTE = [
  "#cba6f7", "#89dceb", "#a6e3a1", "#f9e2af", "#f5c2e7",
  "#f38ba8", "#fab387", "#94e2d5", "#b4befe", "#f2cdcd", "#a6adc8"
]

// Стабильный цвет папки по ключу (uuid) — не зависит от порядка секций.
function hueFor(key) {
  if (key === "@none" || key === "@cache") return "#7f849c"
  var s = String(key || "")
  var h = 0
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return PALETTE[h % PALETTE.length]
}

// buildModel: storeText (JSON connections.json) + folderNames config => секции.
// overrides: {deleted: [id...], edits: {id: {name?,host?,user?,port?}}} — слой
// ручных правок поверх сгенерированного store (переживает реимпорт: id
// детерминированный от полей).
function buildModel(storeText, cfg, existsMap, overrides) {
  cfg = cfg || {}
  var names = cfg.names || {}
  var order = cfg.order || []
  var fallback = cfg.fallback || { none: "Без папки", cache: "ssh config" }
  overrides = overrides || {}
  var deleted = {}
  var deletes = overrides.deleted || []
  for (var di = 0; di < deletes.length; di++) deleted[deletes[di]] = true
  var edits = overrides.edits || {}
  var store
  try { store = JSON.parse(storeText || "{}") } catch (e) { store = {} }
  var conns = Array.isArray(store.connections) ? store.connections : []

  var byKey = {}
  var visible = 0
  var hidden = 0

  function sectionFor(key) {
    if (!byKey[key]) byKey[key] = { key: key, items: [] }
    return byKey[key]
  }

  var i, c, view
  for (i = 0; i < conns.length; i++) {
    c = conns[i]
    var cid = c.id || ""
    if (cid && deleted[cid]) { hidden++; continue }
    var eff = c
    var ov = cid ? edits[cid] : undefined
    if (ov) {
      eff = { id: cid, name: ov.name !== undefined ? ov.name : c.name,
              host: ov.host !== undefined ? ov.host : c.host,
              user: ov.user !== undefined ? ov.user : (c.user || ""),
              port: ov.port !== undefined ? ov.port : (c.port || 22),
              keys: c.keys, source: c.source, folder: c.folder }
    }
    var keyPath = firstExistingKey(eff.keys, existsMap)
    if (!keyPath) { hidden++; continue }
    var rawName = eff.name || ""
    view = {
      id: cid,
      name: cleanName(rawName, eff.host),
      rawName: rawName,
      host: eff.host,
      user: eff.user || "",
      port: eff.port || 22,
      source: eff.source || "",
      folder: eff.folder || "",
      overridden: !!ov,
      key: keyPath,
      keyType: keyLabel(keyPath),
      haystack: (rawName + " " + cleanName(rawName, eff.host) + " " + eff.host + " " + (eff.user || "")).toLowerCase()
    }
    view.command = sshCommand(view)
    sectionFor(folderKey(eff)).items.push(view)
    visible++
  }

  // ---- порядок секций ----
  var finalSections = []
  var pushed = {}
  function pushSection(key) {
    if (pushed[key] || !byKey[key] || byKey[key].items.length === 0) return
    var s = byKey[key]
    s.label = labelFor(key)
    pushed[key] = true
    finalSections.push(s)
  }
  function labelFor(key) {
    if (names[key] !== undefined) return String(names[key])
    if (key === "@none") return String(fallback.none)
    if (key === "@cache") return String(fallback.cache)
    return shortUuid(key)
  }

  for (i = 0; i < order.length; i++) pushSection(String(order[i]))
  // неизвестные uuid (не в конфиге) — после явного порядка, сортированные
  var unknown = []
  for (var k in byKey) {
    if (names[k] === undefined && k.charAt(0) !== "@" && !pushed[k] && byKey[k].items.length > 0) unknown.push(k)
  }
  unknown.sort()
  for (i = 0; i < unknown.length; i++) pushSection(unknown[i])
  pushSection("@none")
  pushSection("@cache")

  for (i = 0; i < finalSections.length; i++) {
    var label = String(finalSections[i].label || "").toLowerCase()
    finalSections[i].items.sort(function (a, b) {
      var na = a.name.toLowerCase(), nb = b.name.toLowerCase()
      if (na < nb) return -1
      if (na > nb) return 1
      return a.host < b.host ? -1 : a.host > b.host ? 1 : 0
    })
    for (var ii = 0; ii < finalSections[i].items.length; ii++) {
      finalSections[i].items[ii].haystack += " " + label
    }
  }
  return { sections: finalSections, visible: visible, hidden: hidden }
}

// filterModel: query по всем полям записи; collapsed: свёрнутые секции (только
// вне поиска). Возвращает секции с открытым состоянием и плоский список rows.
function filterModel(model, query, collapsed) {
  query = String(query || "").toLowerCase().trim()
  collapsed = collapsed || {}
  var outSections = []
  var flat = []
  var total = 0
  var i, j
  for (i = 0; i < model.sections.length; i++) {
    var s = model.sections[i]
    var items = s.items
    var shown = []
    if (query === "") {
      shown = items
    } else {
      for (j = 0; j < items.length; j++) {
        if (items[j].haystack.indexOf(query) !== -1) shown.push(items[j])
      }
    }
    var closed = query === "" && collapsed[s.key] === true
    var eff = closed ? [] : shown
    for (j = 0; j < eff.length; j++) {
      eff[j].flat = flat.length
      flat.push(eff[j])
    }
    total += eff.length
    if (shown.length > 0) {
      outSections.push({ key: s.key, label: s.label, items: shown, open: !closed, count: shown.length })
    }
  }
  return { sections: outSections, flat: flat, total: total, query: query }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { cleanName: cleanName, keyLabel: keyLabel, sshCommand: sshCommand,
    buildModel: buildModel, filterModel: filterModel, firstExistingKey: firstExistingKey,
    hueFor: hueFor }
}
