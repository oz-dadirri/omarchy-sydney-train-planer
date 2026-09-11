// Pure helpers for the Sydney Train Planner plugin. No QML imports here so the
// file can be unit-reasoned in isolation; all formatting that needs the shell
// locale (Qt.formatTime) is done by the caller and passed back in.
//
// Data comes from the TfNSW Trip Planner "rapidJSON" API:
//   stop_finder  -> locations[]
//   trip         -> journeys[].legs[]
//   coord        -> locations[] (nearest stops to a point)

var API_BASE = "https://api.transport.nsw.gov.au/v1/tp"

// ---- URL builders -----------------------------------------------------------

function stopFinderUrl(query) {
  return API_BASE + "/stop_finder"
    + "?outputFormat=rapidJSON"
    + "&type_sf=any"
    + "&name_sf=" + encodeURIComponent(String(query || "").trim())
    + "&coordOutputFormat=EPSG:4326"
    + "&TfNSWSF=true"
}

// A location is either a stop id ("200080") or a raw coordinate in TfNSW's
// "<lon>:<lat>:EPSG:4326" form (used for "current location"). The latter needs
// type_*=coord instead of type_*=any.
function isCoordId(id) {
  return /:EPSG:4326$/i.test(String(id || ""))
}

function coordId(lat, lon) {
  return lon + ":" + lat + ":EPSG:4326"
}

function tripUrl(originId, destinationId, yyyymmdd, hhmm) {
  var oType = isCoordId(originId) ? "coord" : "any"
  var dType = isCoordId(destinationId) ? "coord" : "any"
  return API_BASE + "/trip"
    + "?outputFormat=rapidJSON"
    + "&coordOutputFormat=EPSG:4326"
    + "&depArrMacro=dep"
    + "&itdDate=" + encodeURIComponent(yyyymmdd)
    + "&itdTime=" + encodeURIComponent(hhmm)
    + "&type_origin=" + oType + "&name_origin=" + encodeURIComponent(originId)
    + "&type_destination=" + dType + "&name_destination=" + encodeURIComponent(destinationId)
    + "&calcNumberOfTrips=6"
    + "&TfNSWTR=true"
    + "&version=10.2.1.42"
}

// ---- response-size ceiling -------------------------------------------------
//
// No shell, no PATH lookups: curl is launched directly at an absolute
// path (QProcess/Quickshell exec, not a shell interpreting a constructed
// command string), so there's nothing here for a shadow executable
// earlier in $PATH to hijack, and no shell metacharacter surface at all.
// The one binary this plugin depends on either way is verified to exist
// at this exact path before every launch (see requireCurlBinary).
var CURL_BIN = "/usr/bin/curl"

// 2 MiB is generous: a full TfNSW stop_finder/trip response and an
// ipapi.co geolocation reply are all well under 200 KB in practice.
// Enforced as a real producer-side cap by the caller (see the stdout
// StdioCollector's onRead handler in each *.qml Process using curlArgs/
// curlArgsNoAuth below): once the running byte total crosses this line,
// the caller sends curl SIGKILL directly — curl is that Process's sole,
// directly-owned child (no shell, no `head`, nothing else in between),
// so there is no descendant left holding the pipe open afterward. This
// is real enforcement against however much a compromised/MITM'd endpoint
// tries to send, not reliant on Content-Length (curl's own
// --max-filesize only works when that header is present and honest,
// which a malicious endpoint need not do).
var MAX_RESPONSE_BYTES = 2 * 1024 * 1024

// True once a response body reached (or was made to reach, by an
// oversized/malicious body cut short by the SIGKILL above) the ceiling
// — callers should treat this as a failure and skip JSON.parse entirely
// rather than parse a body that may be truncated mid-token.
function isOversizedResponse(text) {
  return String(text || "").length > MAX_RESPONSE_BYTES
}

// curl argv shared by every authenticated request (stop_finder, trip).
// `-fsS` = fail on HTTP error, silent, still show errors. Short timeouts
// keep a flaky network from wedging the UI.
//
// The API key is deliberately not a curl argument: process argv is
// world-readable via /proc/<pid>/cmdline and `ps`, so a key embedded in a
// `-H "Authorization: ..."` argument leaks to any other process on the
// machine for as long as the curl call is running. Instead `-K -` tells
// curl to read a config file from its own stdin; the caller writes the
// header there over the pipe (see authConfigStdin below), which is a
// private fd between Quickshell and the curl child, invisible to procfs
// and never appears in a process listing or a `qs log`/shell trace.
function curlArgs(url, maxSeconds) {
  return [CURL_BIN, "-fsS", "--max-time", String(maxSeconds || 8), "-K", "-", url]
}

// Same as curlArgs, for the one caller (Panel.qml's "use my location")
// that has no Authorization header to send.
function curlArgsNoAuth(url, maxSeconds) {
  return [CURL_BIN, "-fsS", "--max-time", String(maxSeconds || 8), url]
}

// The curl config-file line carrying the Authorization header, fed over
// stdin (see curlArgs). `header` config values follow the same quoting as
// curl command-line strings: wrap in double quotes, backslash-escape any
// backslash or embedded double quote in the key itself.
function authConfigStdin(apiKey) {
  var key = String(apiKey || "").replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  return "header = \"Authorization: apikey " + key + "\"\n"
}

// ---- stop_finder ----------------------------------------------------------

// -> [{ id, name, disassembledName, type, isBest }]
function parseStopFinder(raw) {
  // Reject an overflowed (truncated-by-head-c) body outright rather than
  // feeding it to JSON.parse — see MAX_RESPONSE_BYTES.
  if (isOversizedResponse(raw)) return []
  try {
    var data = JSON.parse(String(raw || "{}"))
    var locs = data.locations || []
    var out = []
    for (var i = 0; i < locs.length; i++) {
      var l = locs[i]
      if (!l || !l.id) continue
      // Keep transit stops and places; drop bare street/address rows which
      // cannot seed a trip request.
      var t = String(l.type || "")
      if (t === "street" || t === "singlehouse" || t === "poiHierarchy") continue
      out.push({
        id: String(l.id),
        name: String(l.name || l.disassembledName || ""),
        disassembledName: String(l.disassembledName || l.name || ""),
        type: t,
        isBest: l.isBest === true,
        modes: Array.isArray(l.productClasses) ? l.productClasses.slice() : []
      })
    }
    // Best match first, then stops before coordinates/places.
    out.sort(function(a, b) {
      if (a.isBest !== b.isBest) return a.isBest ? -1 : 1
      var as = a.type === "stop" ? 0 : 1
      var bs = b.type === "stop" ? 0 : 1
      return as - bs
    })
    return out.slice(0, 8)
  } catch (e) {
    return []
  }
}

// ---- trip ---------------------------------------------------------------

var MODE_LABELS = {
  "1": "Train", "2": "Metro", "4": "Light Rail", "5": "Bus",
  "7": "Coach", "9": "Ferry", "11": "School Bus", "99": "Walk", "100": "Walk"
}

function isTransitLeg(leg) {
  if (!leg || !leg.transportation) return false
  var cls = leg.transportation.product ? leg.transportation.product.class : undefined
  return cls !== undefined && cls !== 99 && cls !== 100
}

function legTime(point, kind) {
  if (!point) return null
  var est = kind === "dep" ? point.departureTimeEstimated : point.arrivalTimeEstimated
  var plan = kind === "dep" ? point.departureTimePlanned : point.arrivalTimePlanned
  return { estimated: est || plan || null, planned: plan || est || null }
}

function minutesBetween(aIso, bIso) {
  if (!aIso || !bIso) return null
  var a = new Date(aIso).getTime()
  var b = new Date(bIso).getTime()
  if (isNaN(a) || isNaN(b)) return null
  return Math.round((b - a) / 60000)
}

function platformOf(point) {
  if (!point) return ""
  var p = point.properties || {}
  // Prefer the human name ("Platform 16") over the internal code ("CE16").
  var raw = p.plannedPlatformName || p.platformName || p.stoppingPointPlanned || ""
  var m = String(raw).match(/Platform\s+([0-9A-Za-z]+)/i)
  if (m) return m[1]
  if (raw) return String(raw)
  m = String(point.disassembledName || "").match(/Platform\s+([0-9A-Za-z]+)/i)
  return m ? m[1] : ""
}

function lineLabel(leg) {
  var tr = leg.transportation || {}
  return String(tr.disassembledName || tr.number || tr.name || "").trim()
}

function modeLabel(leg) {
  if (!isTransitLeg(leg)) return "Walk"
  var cls = leg.transportation.product ? leg.transportation.product.class : undefined
  return MODE_LABELS[String(cls)] || "Service"
}

function stopName(point) {
  if (!point) return ""
  return String(point.name || point.disassembledName || "")
}

// One row per leg of the journey (walk legs included), for the tap-to-expand
// detail view: line/mode, origin/destination stop names, platforms and
// estimated times, plus the wait between this leg's arrival and the next
// leg's departure at an interchange (null on the final leg).
function legDetails(legs) {
  var out = []
  for (var i = 0; i < legs.length; i++) {
    var leg = legs[i]
    var dep = legTime(leg.origin, "dep")
    var arr = legTime(leg.destination, "arr")
    var next = legs[i + 1]
    var waitMin = next ? minutesBetween(arr.estimated, legTime(next.origin, "dep").estimated) : null
    out.push({
      isTransit: isTransitLeg(leg),
      mode: modeLabel(leg),
      line: lineLabel(leg),
      originName: stopName(leg.origin),
      originPlatform: platformOf(leg.origin),
      depEstimated: dep.estimated,
      depPlanned: dep.planned,
      destName: stopName(leg.destination),
      destPlatform: platformOf(leg.destination),
      arrEstimated: arr.estimated,
      arrPlanned: arr.planned,
      durationMin: minutesBetween(dep.estimated, arr.estimated),
      waitMin: (waitMin !== null && waitMin >= 0) ? waitMin : null
    })
  }
  return out
}

// -> [{ depEstimated, depPlanned, arrEstimated, arrPlanned, durationMin,
//       delayMin, changes, platform, lines:[..], modes:[..],
//       originName, destName, legs:[..] }]
function parseTrip(raw) {
  // Reject an overflowed (truncated-by-head-c) body outright rather than
  // feeding it to JSON.parse — see MAX_RESPONSE_BYTES.
  if (isOversizedResponse(raw)) return []
  try {
    var data = JSON.parse(String(raw || "{}"))
    var journeys = data.journeys || []
    var out = []
    for (var i = 0; i < journeys.length; i++) {
      var legs = (journeys[i] && journeys[i].legs) || []
      if (!legs.length) continue

      var transit = legs.filter(isTransitLeg)
      var first = transit.length ? transit[0] : legs[0]
      var last = transit.length ? transit[transit.length - 1] : legs[legs.length - 1]

      var dep = legTime(first.origin, "dep")
      var arr = legTime(last.destination, "arr")

      var lines = []
      var modes = []
      for (var j = 0; j < transit.length; j++) {
        var lbl = lineLabel(transit[j])
        if (lbl) lines.push(lbl)
        var cls = transit[j].transportation.product ? transit[j].transportation.product.class : undefined
        var ml = MODE_LABELS[String(cls)] || "Service"
        if (modes.indexOf(ml) === -1) modes.push(ml)
      }

      if (!transit.length && !modes.length) modes.push("Walk")

      out.push({
        depEstimated: dep.estimated,
        depPlanned: dep.planned,
        arrEstimated: arr.estimated,
        arrPlanned: arr.planned,
        durationMin: minutesBetween(dep.estimated, arr.estimated),
        delayMin: minutesBetween(dep.planned, dep.estimated) || 0,
        changes: Math.max(0, transit.length - 1),
        platform: platformOf(first.origin),
        lines: lines,
        modes: modes,
        originName: String((first.origin && (first.origin.name || first.origin.disassembledName)) || ""),
        destName: String((last.destination && (last.destination.name || last.destination.disassembledName)) || ""),
        legs: legDetails(legs)
      })
    }
    // API usually returns them ordered, but be defensive.
    out.sort(function(a, b) {
      return new Date(a.depEstimated).getTime() - new Date(b.depEstimated).getTime()
    })
    return out
  } catch (e) {
    return []
  }
}

// ---- bar pill ---------------------------------------------------------------

// Compact "leaves in N" string for the next journey, relative to `now`.
function countdownLabel(trip, now) {
  if (!trip || !trip.depEstimated) return ""
  var mins = Math.round((new Date(trip.depEstimated).getTime() - now.getTime()) / 60000)
  if (mins < 0) return "now"
  if (mins === 0) return "now"
  if (mins < 60) return mins + "′"          // 6′
  var h = Math.floor(mins / 60)
  return h + "h" + (mins % 60) + "′"
}

function delayLabel(trip) {
  if (!trip || !trip.delayMin) return ""
  if (trip.delayMin > 0) return "+" + trip.delayMin
  return String(trip.delayMin)
}

// "on-time" | "late" | "early" | "unknown" — drives the pill colour.
function punctuality(trip) {
  if (!trip || trip.delayMin === null || trip.delayMin === undefined) return "unknown"
  if (trip.delayMin >= 2) return "late"
  if (trip.delayMin <= -2) return "early"
  return "on-time"
}

// ---- config file ----------------------------------------------------------

function normalizeConfig(obj) {
  var c = (obj && typeof obj === "object") ? obj : {}
  return {
    apiKey: String(c.apiKey || ""),
    origin: {
      id: String((c.origin && c.origin.id) || ""),
      name: String((c.origin && c.origin.name) || "")
    },
    destination: {
      id: String((c.destination && c.destination.id) || ""),
      name: String((c.destination && c.destination.name) || "")
    }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    stopFinderUrl: stopFinderUrl, tripUrl: tripUrl,
    isCoordId: isCoordId, coordId: coordId,
    curlArgs: curlArgs, curlArgsNoAuth: curlArgsNoAuth, authConfigStdin: authConfigStdin,
    isOversizedResponse: isOversizedResponse, MAX_RESPONSE_BYTES: MAX_RESPONSE_BYTES,
    parseStopFinder: parseStopFinder,
    parseTrip: parseTrip,
    countdownLabel: countdownLabel, delayLabel: delayLabel,
    punctuality: punctuality, normalizeConfig: normalizeConfig,
    minutesBetween: minutesBetween
  }
}
