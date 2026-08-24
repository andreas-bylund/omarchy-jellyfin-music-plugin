import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for Jellyfin music. All the real work lives in
// bin/omarchy-jellyfin; this is a view over it, so the plugin stays usable
// from a terminal and the QML has nothing to get subtly wrong about HTTP.
Panel {
  id: root
  moduleName: "andreasbylund.jellyfin"
  ipcTarget: "andreasbylund.jellyfin"

  // The CLI ships inside the plugin, so cloning the repo is the whole install.
  // Qt.resolvedUrl percent-encodes the path, which has to be undone before it
  // can be executed: a home directory with an å in it would otherwise arrive
  // as %C3%A5 and nothing would run at all.
  readonly property string cli: decodeURIComponent(
    Qt.resolvedUrl("bin/omarchy-jellyfin").toString().replace(/^file:\/\//, ""))

  // The bar entry is the icon plus the current track title. The title is a
  // setting rather than a given because Omarchy's own omarchy.media widget
  // already shows it over MPRIS, where mpv publishes -- run both and the bar
  // says the same thing twice, so anyone who does turns this one off.
  // Both dimensions follow the button, which sizes itself from whichever of
  // the two it is currently drawing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyphMusic: String.fromCodePoint(0xF075A)
  readonly property string glyphPlay: String.fromCodePoint(0xF040A)
  readonly property string glyphPause: String.fromCodePoint(0xF03E4)
  readonly property string glyphNext: String.fromCodePoint(0xF04AD)
  readonly property string glyphPrev: String.fromCodePoint(0xF04AE)
  readonly property string glyphShuffle: String.fromCodePoint(0xF049D)
  readonly property string glyphHeart: String.fromCodePoint(0xF02D1)
  readonly property string glyphPlaylist: String.fromCodePoint(0xF0CB9)
  // Chevrons point the way through the library rather than folding a section
  // open in place: right goes a level in, left comes back out.
  readonly property string glyphOpen: String.fromCodePoint(0xF0142)
  readonly property string glyphBack: String.fromCodePoint(0xF0141)
  readonly property string glyphCog: String.fromCodePoint(0xF0493)
  readonly property string glyphVolume: String.fromCodePoint(0xF057E)
  readonly property string glyphVolumeLow: String.fromCodePoint(0xF057F)
  readonly property string glyphVolumeOff: String.fromCodePoint(0xF0581)
  readonly property string glyphQueue: String.fromCodePoint(0xF0279)
  readonly property string glyphArtist: String.fromCodePoint(0xF0803)
  readonly property string glyphAlbum: String.fromCodePoint(0xF0025)
  readonly property string glyphTrack: String.fromCodePoint(0xF0387)

  property var playback: ({ running: false, playing: false, paused: false, track: null, queue: 0 })
  property var account: ({ configured: false, server: "", userName: "" })
  // Whatever the CLI last complained about. It already phrases its errors for
  // a human ("Wrong username or password."), so it is shown verbatim.
  property string notice: ""
  // Where in the library you are standing. Empty at the quick picks, then one
  // entry per level opened -- {kind, key, label} -- of which the last is the
  // one `rows` holds. A stack rather than the single open section this was:
  // artists lead to albums lead to tracks, and three levels of indentation in
  // a panel this size is not something you can read.
  property var path: []
  readonly property var level: path.length > 0 ? path[path.length - 1] : null
  property var rows: []
  // A level opened while the one before it was still loading.
  property var pendingLevel: null
  property int queueIndex: -1
  property bool loadingRows: false
  property bool settingsOpen: false
  property bool switchingServer: false
  property bool loggingIn: false
  property bool searching: false
  property bool cursorActive: false
  property int rowIndex: 0
  // What answered the discovery broadcast. Shown as a list to pick from,
  // never filled in on your behalf -- see discoverProc.
  property var discovered: []

  // Library search. The query lives here rather than being read off the field
  // so everything downstream -- the rows, the play command, the placeholder --
  // has one source.
  property string queryText: ""
  property var results: []
  // Which query the results in hand answer. Anything else means a search is
  // still coming, including the quiet before the debounce fires -- without it
  // a fresh query reads "nothing matched" for a quarter second before it has
  // even been asked.
  property string resultsQuery: ""
  // A single letter matches a good third of a library, which is a slow query
  // that tells you nothing. Two is where names like U2 start, so that is the
  // floor.
  readonly property int searchMinimum: 2
  readonly property bool searchMode: queryText.trim() !== ""
  // The library search you drilled in from. One box does both jobs -- it
  // searches the library at the top level and filters the list you are inside
  // anywhere below -- so the query that got you here is set aside on the way
  // in and handed back when you come out, rather than narrowing the level you
  // just opened to nothing.
  property string rootQuery: ""
  // How many rows of a level are drawn. A library runs to thousands of
  // artists; the whole list is held so filtering stays instant, but building a
  // delegate per artist is a stutter you would feel, and scrolling that far is
  // not how anyone finds anything. The rest is a keystroke away in the box.
  readonly property int browseRowCap: 200

  // While the slider is being dragged, the 1s status poll must not yank the
  // knob back to the level mpv had a moment ago.
  property int volumeOverride: -1
  // The level still waiting to be written out. Kept apart from volumeOverride,
  // which a status poll is free to clear at any moment: the write timer used
  // to read that one when it fired, so a poll landing in the gap turned the
  // pending write into "volume -1" -- which the CLI clamped to 0 and muted the
  // music for no reason anybody could see.
  property int pendingVolume: -1
  readonly property int volume: volumeOverride >= 0
    ? volumeOverride
    : (playback && playback.volume !== undefined ? playback.volume : 70)

  readonly property bool barVertical: bar ? bar.vertical === true : false
  // Title only. Appending the artist doubles the width of a bar that already
  // carries nine other widgets; the artist is a hover away in the tooltip.
  readonly property string barTitle: track ? track.title : ""

  readonly property var track: playback && playback.track ? playback.track : null
  readonly property bool playing: playback ? playback.playing === true : false
  readonly property bool paused: playback ? playback.paused === true : false
  readonly property bool loggedIn: account && account.configured === true
  readonly property bool showArt: setting("showAlbumArt", true)
  readonly property bool showBarTitle: setting("showBarTitle", true)
  readonly property bool scrollTitle: setting("scrollBarTitle", true)

  readonly property string tooltip: {
    if (!loggedIn) return "Jellyfin Music — not connected"
    if (!track) return "Jellyfin Music — scroll to set volume (" + volume + "%)"
    var artist = track.artist ? track.artist + " — " : ""
    return (paused ? "Paused: " : "") + artist + track.title + "  ·  " + volume + "%"
  }

  function kindGlyph(kind) {
    if (kind === "artist") return glyphArtist
    if (kind === "album") return glyphAlbum
    if (kind === "playlist") return glyphPlaylist
    return glyphTrack
  }

  // Whether a row has something inside it worth opening. These are the rows
  // that carry a chevron, and the only ones the right arrow does anything on.
  function isOpenable(row) {
    if (!row) return false
    return row.kind === "section" || row.kind === "artist"
      || row.kind === "album" || row.kind === "playlist"
  }

  // What a level lists. The type of a browsed row comes from the level it was
  // found in rather than from the row itself, which is why the CLI hands back
  // one shape for all of them.
  function childKind(entry) {
    if (!entry) return "track"
    if (entry.kind === "playlists") return "playlist"
    if (entry.kind === "artists") return "artist"
    if (entry.kind === "albums" || entry.kind === "artist") return "album"
    if (entry.kind === "queue") return "queued"
    return "track"
  }

  // What the CLI is asked for to fill a level.
  function levelCommand(entry) {
    if (entry.kind === "artist") return ["albums", "--artist", entry.key, "--json"]
    if (entry.kind === "album") return ["tracks", "--album", entry.key, "--json"]
    if (entry.kind === "playlist") return ["tracks", "--playlist", entry.key, "--json"]
    return [entry.kind, "--json"]
  }

  // Which list a track should be queued inside, so picking a song out of an
  // album leaves you with the album rather than a one-track queue.
  function levelSource(entry) {
    if (!entry) return null
    if (entry.kind === "favorites") return ["--favorites"]
    if (entry.kind === "album") return ["--album", entry.key]
    if (entry.kind === "playlist") return ["--playlist", entry.key]
    return null
  }

  function sameLevel(a, b) {
    return !!a && !!b && a.kind === b.kind && a.key === b.key
  }

  // What a query turns up: artists, then albums, then tracks, the order the
  // CLI returns them in. A hit carries the same kind as the row it would have
  // been found as by browsing, so both behave alike from here on.
  readonly property var resultRows: {
    if (queryText.trim().length < searchMinimum)
      return [{ kind: "note", key: "short", label: "Keep typing…", glyph: "" }]
    if (resultsQuery !== queryText.trim())
      return [{ kind: "note", key: "loading", label: "Searching…", glyph: "" }]
    if (results.length === 0)
      return [{ kind: "note", key: "empty", label: "Nothing matched", glyph: "" }]
    return results.map(function(entry) {
      return {
        kind: entry.type,
        key: entry.id,
        label: entry.name,
        detail: entry.detail || "",
        glyph: root.kindGlyph(entry.type)
      }
    })
  }

  // The rows of the level you are standing in, narrowed by whatever is in the
  // box. Filtering happens here rather than at the server: the level is
  // already in hand, so it costs nothing and answers before you finish typing.
  readonly property var browseRows: {
    if (path.length === 0) return []
    var entry = path[path.length - 1]
    var kind = childKind(entry)
    var source = levelSource(entry)
    var filter = queryText.trim().toLowerCase()
    var matched = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      // Browse listings share one shape; favorites and the queue predate it
      // and still arrive as raw tracks.
      var label = row.name !== undefined ? row.name : (row.title || "")
      var detail = row.detail !== undefined ? row.detail : (row.artist || "")
      if (filter !== "" && (label + " " + detail).toLowerCase().indexOf(filter) < 0)
        continue
      matched.push({
        kind: kind,
        // A queue row is played by position, and that position is the one it
        // holds in the queue -- not the one it holds after filtering.
        key: kind === "queued" ? String(i) : row.id,
        label: label,
        detail: detail,
        source: source,
        glyph: kind === "queued"
          ? (i === queueIndex ? glyphPlay : "")
          : root.kindGlyph(kind)
      })
    }
    if (matched.length <= browseRowCap) return matched
    var hidden = matched.length - browseRowCap
    return matched.slice(0, browseRowCap).concat([{
      kind: "note",
      key: "capped",
      label: "… " + hidden + " more · " + (filter === "" ? "type to filter" : "keep typing"),
      glyph: ""
    }])
  }

  // One flat list, so the keyboard cursor never needs to know what it is
  // walking through.
  readonly property var navRows: {
    if (path.length > 0) {
      // The way back is a row rather than a header: it is the thing you reach
      // for most in here, and as a row the cursor can land on it.
      var trail = [{
        kind: "back",
        key: "back",
        label: path.map(function(entry) { return entry.label }).join("  ›  "),
        glyph: glyphBack
      }]
      if (loadingRows)
        return trail.concat([{ kind: "note", key: "loading", label: "Loading…", glyph: "" }])
      // The way to play the whole of what you have opened, now that its own
      // row opens instead. It says how much it is about to queue, which is
      // more than the row it replaced ever did -- and it is where the cursor
      // lands, so a name typed into the box is still two keys from playing.
      //
      // Not while the list is filtered: a filter narrows what you are looking
      // at, and this is not part of that -- leaving it in would put the cursor
      // on "everything" when you had just typed the name of one song.
      var playAll = levelPlayAll(level)
      if (playAll && !searchMode && browseRows.length > 0) {
        var unit = level.kind === "artist" ? " album" : " track"
        trail.push({
          kind: "action",
          key: "play-all",
          label: "Play all",
          detail: rows.length + unit + (rows.length === 1 ? "" : "s"),
          glyph: glyphPlay,
          command: playAll
        })
      }
      if (browseRows.length === 0)
        return trail.concat([{
          kind: "note",
          key: "empty",
          label: searchMode ? "Nothing matched" : "Nothing here",
          glyph: ""
        }])
      return trail.concat(browseRows)
    }

    // A query replaces the picks rather than pushing them down: the picks are
    // the way in when you do not know what you want, and reading past them to
    // reach your own results would be the wrong way round.
    if (searchMode) return resultRows

    var list = [
      { kind: "section", key: "playlists", label: "Playlists", glyph: glyphPlaylist },
      { kind: "section", key: "favorites", label: "Favorites", glyph: glyphHeart },
      { kind: "section", key: "artists", label: "Artists", glyph: glyphArtist },
      { kind: "section", key: "albums", label: "Albums", glyph: glyphAlbum },
      {
        kind: "action",
        key: "shuffle",
        label: "Shuffle all",
        glyph: glyphShuffle,
        command: ["play", "--shuffle", "--limit", String(setting("shuffleLimit", 200))]
      }
    ]
    // The queue only exists once something is playing. Its counter used to sit
    // beside the clock, hinting at a list you could not open.
    if ((playback.queue || 0) > 0) {
      list.push({
        kind: "section",
        key: "queue",
        label: "Queue",
        detail: ((playback.index || 0) + 1) + " / " + playback.queue,
        glyph: glyphQueue
      })
    }
    return list
  }

  // Filtering can shorten the list under a cursor that is already past its
  // end, and a level you step out of is shorter than the one you were in.
  onNavRowsChanged: clampCursor()

  function clampCursor() {
    if (rowIndex >= navRows.length) rowIndex = Math.max(0, navRows.length - 1)
    if (rowIndex < 0) rowIndex = 0
  }

  // The first press shows the cursor where it already is rather than moving
  // it, so nothing jumps under a key you pressed to find your place.
  function moveCursor(step) {
    if (!cursorActive) { cursorActive = true; return }
    rowIndex += step
    clampCursor()
  }

  // What a track queues -- and it is never the one track on its own, but the
  // list it was found in, started at the song you picked. Artists, albums and
  // playlists do not come through here: they open, and the Play all row inside
  // them carries their command.
  function playCommand(row) {
    // A track found by searching has no list around it but the search itself.
    var source = row.source || ["--search", queryText.trim()]
    return ["play"].concat(source).concat(["--start", row.key])
  }

  // The command behind a level's Play all row, or null for a level that is not
  // a thing you play -- the queue, or the lists of everything.
  function levelPlayAll(entry) {
    if (!entry) return null
    if (entry.kind === "artist") return ["play", "--artist", entry.key]
    if (entry.kind === "album") return ["play", "--album", entry.key]
    if (entry.kind === "playlist") return ["play", "--playlist", entry.key]
    if (entry.kind === "favorites") return ["play", "--favorites"]
    return null
  }

  // One rule, no exceptions: a row with something inside it opens, and a row
  // that is the thing itself plays. The chevron says which you are looking at.
  //
  // Playing is what replaces the queue and the song you were on, with no way
  // back, so it is never what the whole width of a row does by accident.
  // Opening costs an Escape to undo. Every level you can open starts with a
  // Play all that says how much it is about to queue, so nothing is buried --
  // it is one more click than it was, spent on knowing what you are getting.
  function activateRow(row) {
    if (!row) return
    if (row.kind === "back") popLevel()
    else if (isOpenable(row)) openRow(row)
    else if (row.kind === "note") return
    else if (row.kind === "action") send(row.command)
    else if (row.kind === "queued") send(["jump", row.key])
    else send(playCommand(row))
  }

  function openRow(row) {
    if (!isOpenable(row)) return
    // A section is a level in its own right; anything else is a level named
    // after the thing you opened.
    pushLevel(row.kind === "section"
      ? { kind: row.key, key: "", label: row.label }
      : { kind: row.kind, key: row.key, label: row.label })
  }

  function pushLevel(entry) {
    if (path.length === 0 && searchMode) rootQuery = queryText.trim()
    clearSearch()
    path = path.concat([entry])
    // Onto the first row of the new level rather than the way back out.
    rowIndex = 1
    // Shown rather than left implicit: you have just navigated, so where the
    // cursor sits is the answer to what Enter is about to do -- and on an
    // artist what it is about to do is queue the lot.
    cursorActive = true
    loadLevel(entry)
  }

  function popLevel() {
    if (path.length === 0) return
    clearSearch()
    var remaining = path.slice(0, path.length - 1)
    path = remaining
    rows = []
    queueIndex = -1
    rowIndex = 0
    cursorActive = true
    if (remaining.length > 0) {
      loadLevel(remaining[remaining.length - 1])
    } else if (rootQuery !== "") {
      searchField.text = rootQuery
      rootQuery = ""
    }
    clampCursor()
  }

  function popToRoot() {
    if (path.length === 0) return
    clearSearch()
    path = []
    rows = []
    queueIndex = -1
    rowIndex = 0
    pendingLevel = null
    rootQuery = ""
  }

  // A command that arrived while another was still running. Two quick presses
  // on next used to lose the second one; now the last one in waits its turn,
  // which for a skip is the press you actually meant. Only the last is kept:
  // holding the key down should land you further along, not queue up a dozen
  // skips to sit through.
  property var queuedSend: null

  function send(args) {
    if (actionProc.running) { queuedSend = args; return }
    notice = ""
    actionProc.command = [cli].concat(args)
    actionProc.running = true
  }

  function loadLevel(entry) {
    loadingRows = true
    rows = []
    queueIndex = -1
    // Opening two levels quickly is one keypress after another, so the second
    // one waits rather than being dropped -- which is what the panel standing
    // empty on a level you just opened used to be.
    if (listProc.running) { pendingLevel = entry; return }
    pendingLevel = null
    listProc.level = entry
    listProc.command = [cli].concat(levelCommand(entry))
    listProc.running = true
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Searching as you type means one process per keystroke unless it is held
  // back, so the query waits for a short quiet. Only ever one search in
  // flight: a slow one that finished late would otherwise overwrite the
  // results of the query you have already moved on to.
  function runSearch() {
    // Inside a level the box filters what is already listed, and asking the
    // server for the same word would answer a question nobody asked.
    if (path.length > 0) return
    var query = queryText.trim()
    if (query.length < searchMinimum) {
      results = []
      resultsQuery = query
      return
    }
    if (searchProc.running) { searchDebounce.restart(); return }
    notice = ""
    searchProc.query = query
    searchProc.command = [cli, "search", query, "--json"]
    searchProc.running = true
  }

  function clearSearch() {
    searchDebounce.stop()
    searchField.text = ""
    results = []
    resultsQuery = ""
  }

  // Volume changes arrive far faster than a process can be spawned per pixel
  // of drag, so the level is shown immediately and written out on a short
  // debounce.
  function setVolume(level) {
    volumeOverride = Math.max(0, Math.min(100, Math.round(level)))
    pendingVolume = volumeOverride
    volumeWriteTimer.restart()
    volumeReleaseTimer.restart()
  }

  function stepVolume(direction) {
    setVolume(volume + direction * 5)
  }

  function refreshAccount() {
    if (!accountProc.running) accountProc.running = true
  }

  function logIn() {
    if (loginProc.running) return
    if (serverField.text.trim() === "" || userField.text.trim() === "") {
      notice = "Server and username are required."
      return
    }
    notice = ""
    loggingIn = true
    loginProc.secret = passwordField.text
    loginProc.command = [cli, "login", "--server", serverField.text.trim(),
                         "--user", userField.text.trim(), "--password-stdin", "--json"]
    loginProc.running = true
  }

  function beginSwitchServer() {
    switchingServer = true
    notice = ""
    discovered = []
    // The old server is a sensible starting point for editing, but the old
    // account is not: signing in as someone else is half of why you are here.
    serverField.text = account.server || ""
    userField.text = ""
    passwordField.text = ""
    // The field is only just becoming visible; focusing it in the same pass
    // would land on an item that is not on screen yet.
    Qt.callLater(function() { userField.forceActiveFocus() })
  }

  function cancelSwitchServer() {
    switchingServer = false
    notice = ""
    discovered = []
    passwordField.text = ""
    serverField.text = account.server || ""
  }

  function searchNetwork() {
    if (discoverProc.running) return
    notice = ""
    discovered = []
    searching = true
    discoverProc.running = true
  }

  // Widget settings live in shell.json, which the shell owns; `omarchy bar set`
  // is the supported way in, and the change comes back to us as `settings`.
  function persist(key, value) {
    if (!bar) return
    bar.run("omarchy bar set " + moduleName + " " + key + " " + value + " --json")
  }

  function cleanError(text) {
    return String(text || "").replace("omarchy-jellyfin: ", "").trim()
  }

  Process {
    id: statusProc
    running: false
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.playback = JSON.parse(String(statusOut.text || "").trim())
      } catch (e) {
        // A malformed status is not worth surfacing; the next poll will do.
      }
    }
  }

  Process {
    id: accountProc
    running: false
    command: [root.cli, "server", "--json"]
    stdout: StdioCollector { id: accountOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.account = JSON.parse(String(accountOut.text || "").trim())
        if (root.account.server && serverField.text === "") serverField.text = root.account.server
        // With no account there is nothing else the panel can usefully show,
        // so it opens straight into the form rather than an empty shell.
        if (!root.loggedIn && root.opened) root.settingsOpen = true
      } catch (e) {
      }
    }
  }

  Process {
    id: loginProc
    running: false
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      // Anything that can read /proc sees argv, so the password goes here.
      write(secret + "\n")
      secret = ""
    }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loggingIn = false
      passwordField.text = ""
      if (exitCode !== 0) {
        root.notice = root.cleanError(loginErr.text)
        return
      }
      root.notice = ""
      root.settingsOpen = false
      root.switchingServer = false
      root.refreshAccount()
    }
  }

  Process {
    id: discoverProc
    running: false
    command: [root.cli, "discover", "--json"]
    stdout: StdioCollector { id: discoverOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.searching = false
      var found = []
      try {
        found = JSON.parse(String(discoverOut.text || "").trim()) || []
      } catch (e) {
      }
      // Deliberately not filled in for you, not even when only one server
      // answered. Discovery is an unauthenticated broadcast: anything on the
      // network can claim to be a Jellyfin, and the next thing typed into
      // this form is a password. So the replies are listed with their names
      // and picking one is a decision you make.
      root.discovered = found
      if (found.length === 0)
        root.notice = "No servers answered on this network. Type the address instead."
    }
  }

  Process {
    id: actionProc
    running: false
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.notice = root.cleanError(actionErr.text)
      // Playback state lags the command by a moment, so nudge the poll along.
      settleTimer.restart()
      // Logging out is the one action that changes who is signed in, and only
      // now has it actually happened -- asking while it was still running,
      // which the button used to, read the old config and left "Signed in
      // as ..." standing until the panel was reopened.
      if (actionProc.command.indexOf("logout") !== -1) root.refreshAccount()
      if (root.queuedSend) {
        var next = root.queuedSend
        root.queuedSend = null
        // Deferred rather than sent from inside the handler: this process is
        // only finished once the handler returns, and send() would take that
        // for another one still running and queue it right back.
        Qt.callLater(function() { root.send(next) })
      }
    }
  }

  Process {
    id: listProc
    running: false
    // The level this run answers, so a slow reply is never credited to the
    // one opened after it.
    property var level: null
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.loadingRows = false
      if (root.pendingLevel) {
        var next = root.pendingLevel
        root.pendingLevel = null
        // Deferred rather than started from inside the handler: this process
        // counts as running until the handler returns, and loadLevel would
        // take that for a busy one and queue the level right back.
        Qt.callLater(function() { root.loadLevel(next) })
        return
      }
      if (!root.sameLevel(listProc.level, root.level)) return
      if (exitCode !== 0) {
        root.notice = root.cleanError(listErr.text)
        root.rows = []
        return
      }
      try {
        var data = JSON.parse(String(listOut.text || "").trim())
        // The queue reports which entry is current alongside the list; the
        // other listings are plain arrays.
        if (listProc.level.kind === "queue") {
          root.queueIndex = data && data.index !== undefined ? data.index : -1
          root.rows = (data && data.tracks) || []
        } else {
          root.rows = data || []
        }
      } catch (e) {
        root.rows = []
      }
      root.clampCursor()
    }
  }

  Process {
    id: searchProc
    running: false
    // The query this run answers, so a reply is never credited to the one
    // typed after it.
    property string query: ""
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    stderr: StdioCollector { id: searchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.resultsQuery = searchProc.query
      if (exitCode !== 0) {
        root.notice = root.cleanError(searchErr.text)
        root.results = []
        return
      }
      try {
        root.results = JSON.parse(String(searchOut.text || "").trim()) || []
      } catch (e) {
        root.results = []
      }
      root.clampCursor()
    }
  }

  Timer {
    id: searchDebounce
    interval: 250
    repeat: false
    onTriggered: root.runSearch()
  }

  Process {
    id: volumeProc
    running: false
    onExited: root.refresh()
  }

  Timer {
    id: volumeWriteTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (root.pendingVolume < 0) return
      if (volumeProc.running) { volumeWriteTimer.restart(); return }
      volumeProc.command = [root.cli, "volume", String(root.pendingVolume)]
      root.pendingVolume = -1
      volumeProc.running = true
    }
  }

  Timer {
    // Safety net: normally the override is dropped as soon as a poll reports
    // the level we asked for, but a failed write must not freeze the slider.
    id: volumeReleaseTimer
    interval: 3000
    repeat: false
    onTriggered: root.volumeOverride = -1
  }

  onPlaybackChanged: {
    if (volumeOverride >= 0 && playback && playback.volume === volumeOverride) {
      volumeOverride = -1
      volumeReleaseTimer.stop()
    }
  }

  Timer {
    id: settleTimer
    interval: 350
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // Every poll is a process spawn, and this timer runs for as long as the
    // session does, so the rate follows how much there is to learn. Open, the
    // seek bar wants a second. Closed with something playing, the bar only
    // needs a fresh title. Closed with nothing playing, nothing can change
    // except from a terminal -- and signed out, not even that. MPRIS drives
    // Omarchy's own media widget regardless.
    interval: root.opened ? 1000
      : (root.playback.running ? 5000 : (root.loggedIn ? 15000 : 60000))
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refreshAccount()

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      refresh()
      refreshAccount()
    } else {
      path = []
      rows = []
      pendingLevel = null
      rootQuery = ""
      queueIndex = -1
      notice = ""
      settingsOpen = false
      switchingServer = false
      discovered = []
      passwordField.text = ""
      // Opening the panel again is usually a glance at what is playing, not a
      // return to the search you left behind.
      clearSearch()
    }
  }

  // Icon plus the running title, the way omarchy.media does it. Built on
  // WidgetButton rather than BarIconButton because that one is fixed to a
  // single icon slot and cannot carry a label.
  WidgetButton {
    id: button
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.playing
    tooltipText: root.tooltip
    // A vertical bar has no room for a label, so it falls back to icon-only.
    fixedWidth: root.barVertical ? -1 : barContent.implicitWidth + Style.space(12)
    fixedHeight: root.barVertical ? Style.bar.iconSlot : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.send(["toggle"])
      else if (buttonCode === Qt.MiddleButton) root.send(["next"])
      else root.toggle()
    }
    // Scroll adjusts volume rather than skipping tracks: it is the thing you
    // reach for mid-song, and it works without opening the panel. Skipping
    // lives on middle-click, the panel buttons, and n/p.
    onWheelMoved: function(delta) { root.stepVolume(delta > 0 ? 1 : -1) }

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: barLabelClip.visible ? Style.space(6) : 0

      Text {
        id: barGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphMusic
        color: button.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Item {
        id: barLabelClip
        anchors.verticalCenter: parent.verticalCenter
        // A vertical bar has no room, and a width of 0 from an older config
        // still means off even though the toggle owns that now.
        visible: root.showBarTitle && !root.barVertical && root.barTitle !== ""
          && root.setting("barTitleWidth", 110) > 0
        width: Math.min(Style.space(root.setting("barTitleWidth", 110)), barLabel.implicitWidth)
        height: barGlyph.height
        clip: true

        Text {
          id: barLabel
          anchors.verticalCenter: parent.verticalCenter
          text: root.barTitle
          color: button.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          // Standing still, a long title is cut off mid-word unless it is
          // given a width to elide against.
          width: scrolling ? implicitWidth : barLabelClip.width
          elide: scrolling ? Text.ElideNone : Text.ElideRight

          readonly property bool needsScroll: implicitWidth > barLabelClip.width
          // Motion in the corner of the eye is not for everyone, so it is a
          // setting. It also pauses while the panel is open, where the full
          // title is already on screen.
          readonly property bool scrolling: needsScroll && root.scrollTitle
            && !root.opened && !root.barVertical

          // The animation writes x directly, so stopping it leaves the label
          // wherever it happened to be. Put it back.
          onScrollingChanged: if (!scrolling) x = 0

          NumberAnimation on x {
            running: barLabel.scrolling
            loops: Animation.Infinite
            duration: Math.max(6000, barLabel.implicitWidth * 25)
            from: barLabelClip.width
            to: -barLabel.implicitWidth
            easing.type: Easing.Linear
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A text field owns the keyboard while it has focus, or typing a
      // password -- or a band name -- would trigger playback shortcuts.
      blocked: root.settingsOpen || searchField.activeFocus
      // Sideways walks the library the way the chevrons do: right opens what
      // the cursor is on, left steps back out of the level you are in.
      onMoveRequested: function(dx, dy) {
        if (dx > 0) {
          // Same courtesy the first j or k gets: show the cursor where it
          // already is rather than opening whatever it happened to rest on.
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.openRow(root.navRows[root.rowIndex])
        } else if (dx < 0) {
          root.popLevel()
        } else {
          root.moveCursor(dy)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateRow(root.navRows[root.rowIndex])
      // A ladder out, so Escape never throws away more than you meant.
      onCloseRequested: if (root.path.length > 0) root.popLevel(); else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " ") root.send(["toggle"])
        else if (t === "n") root.send(["next"])
        else if (t === "p") root.send(["prev"])
        else if (t === "f" && root.track) root.send(["favorite", root.track.id, root.track.favorite ? "unfavorite" : "favorite"])
        else if (t === "s") root.send(["play", "--shuffle", "--limit", String(root.setting("shuffleLimit", 200))])
        else if (t === "+" || t === "=") root.stepVolume(1)
        else if (t === "-" || t === "_") root.stepVolume(-1)
        // "/" for search, the way a pager or a browser does it.
        else if (t === "/") searchField.forceActiveFocus()
        // "," for settings, the way most apps do it.
        else if (t === ",") { root.settingsOpen = !root.settingsOpen; root.notice = "" }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          // The gear rides in the top-right of whichever block is showing,
          // rather than owning a header row of its own. The connection details
          // it used to sit next to are plumbing you need once, so they moved
          // inside the settings block.
          Component {
            id: cogButton

            Text {
              text: root.glyphCog
              color: (root.settingsOpen || cogArea.containsMouse) ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                id: cogArea
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.settingsOpen = !root.settingsOpen
                  root.notice = ""
                }
              }
            }
          }

          // Settings. Replaces the body rather than folding out below it:
          // nothing in the playback half is worth looking at while you are
          // deciding which server to talk to.
          Column {
            width: parent.width
            visible: root.settingsOpen
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(settingsHeading.implicitHeight, settingsCog.implicitHeight)

              Column {
                id: settingsHeading
                anchors.left: parent.left
                anchors.right: settingsCog.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: root.loggedIn ? "Connection" : "Connect to Jellyfin"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  width: parent.width
                  visible: root.loggedIn
                  text: root.loggedIn
                    ? "Signed in as " + root.account.userName + " · "
                      + root.account.server.replace(/^https?:\/\//, "")
                    : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Loader {
                id: settingsCog
                anchors.right: parent.right
                anchors.top: parent.top
                sourceComponent: cogButton
              }
            }

            // The form appears only when it can actually do something. Under a
            // live connection an empty username and password box is noise, and
            // the button above them could only ever fail on the empty fields.
            Column {
              width: parent.width
              visible: !root.loggedIn || root.switchingServer
              spacing: Style.space(8)

              TextField {
                id: serverField
                width: parent.width
                foreground: root.foreground
                placeholderText: "192.168.1.50:8096 or jellyfin.example.com"
                onAccepted: userField.forceActiveFocus()
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.searching ? "Searching…" : "Search network"
                  enabled: !root.searching
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.searchNetwork()
                }
              }

              // What answered the broadcast. Anything on the network can
              // answer, so the name is shown next to the address and the
              // choice stays with the person about to type a password.
              Column {
                width: parent.width
                visible: root.discovered.length > 0
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: "Answered on this network — check the name before picking one:"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.discovered

                  Item {
                    required property var modelData
                    width: parent.width
                    implicitHeight: Style.space(20)

                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: -Style.space(2)
                      radius: Style.space(4)
                      visible: foundArea.containsMouse
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                    }

                    Text {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name + "  ·  " + modelData.address
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      id: foundArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        serverField.text = modelData.address
                        root.discovered = []
                        userField.forceActiveFocus()
                      }
                    }
                  }
                }
              }

              TextField {
                id: userField
                width: parent.width
                foreground: root.foreground
                placeholderText: "Username"
                onAccepted: passwordField.forceActiveFocus()
              }

              TextField {
                id: passwordField
                width: parent.width
                foreground: root.foreground
                password: true
                placeholderText: "Password"
                onAccepted: root.logIn()
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.loggingIn ? "Connecting…" : "Log in"
                  enabled: !root.loggingIn
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.logIn()
                }

                Button {
                  visible: root.switchingServer
                  text: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.cancelSwitchServer()
                }
              }
            }

            // Connected: the two things you might actually want, and nothing
            // to fill in.
            Row {
              width: parent.width
              visible: root.loggedIn && !root.switchingServer
              spacing: Style.space(8)

              Button {
                text: "Switch server…"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.beginSwitchServer()
              }

              Button {
                text: "Log out"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                // The account refresh happens when the logout has finished,
                // from actionProc.onExited -- not here, where it would race
                // the revocation call and read the config it is deleting.
                onClicked: root.send(["logout"])
              }
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
            }

            Toggle {
              width: parent.width
              label: "Show album art"
              description: "Cover image next to the current track"
              checked: root.showArt
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showAlbumArt", root.showArt ? "false" : "true")
            }

            Toggle {
              width: parent.width
              label: "Show the track title in the bar"
              description: "Off leaves just the music icon"
              checked: root.showBarTitle
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("showBarTitle", root.showBarTitle ? "false" : "true")
            }

            Toggle {
              width: parent.width
              // Nothing to scroll when there is no title, so the choice is
              // hidden rather than left there doing nothing.
              visible: root.showBarTitle
              label: "Scroll the title in the bar"
              description: "Off holds a long title still and shortens it instead"
              checked: root.scrollTitle
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.persist("scrollBarTitle", root.scrollTitle ? "false" : "true")
            }
          }

          // Now playing. The gear rides top-right here so the connection
          // details no longer take the line your eye lands on first.
          Item {
            width: parent.width
            visible: !root.settingsOpen
            implicitHeight: Math.max(artFrame.height, nowInfo.implicitHeight)

            Rectangle {
              id: artFrame
              anchors.left: parent.left
              anchors.top: parent.top
              visible: root.showArt && root.track !== null
              width: visible ? Style.space(64) : 0
              height: visible ? Style.space(64) : 0
              radius: Style.space(3)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              clip: true

              Image {
                id: artImage
                anchors.fill: parent
                source: root.showArt && root.playback.art ? root.playback.art : ""
                sourceSize.width: 192
                sourceSize.height: 192
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                visible: status === Image.Ready
              }

              // A library without cover art should not leave a hole.
              Text {
                anchors.centerIn: parent
                visible: !artImage.visible
                text: root.glyphMusic
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            Loader {
              id: bodyCog
              anchors.right: parent.right
              anchors.top: parent.top
              sourceComponent: cogButton
            }

            Column {
              id: nowInfo
              anchors.left: artFrame.visible ? artFrame.right : parent.left
              anchors.leftMargin: artFrame.visible ? Style.space(10) : 0
              anchors.right: bodyCog.left
              anchors.rightMargin: Style.space(8)
              anchors.top: parent.top
              spacing: Style.space(2)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: titleText
                  width: parent.width - (root.track ? favoriteButton.implicitWidth + parent.spacing : 0)
                  text: root.track ? root.track.title : (root.loggedIn ? "Nothing playing" : "Connect a server to start")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }

                Text {
                  id: favoriteButton
                  visible: root.track !== null
                  text: root.track && root.track.favorite ? root.glyphHeart : "\u2665"
                  color: favoriteArea.containsMouse || (root.track && root.track.favorite)
                    ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body

                  MouseArea {
                    id: favoriteArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.send(["favorite", root.track.id, root.track.favorite ? "unfavorite" : "favorite"])
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.track && root.track.artist !== ""
                text: root.track ? root.track.artist : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                visible: root.track && root.track.album !== ""
                text: root.track ? root.track.album : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          // Seek. A slider rather than a plain bar, because it sits right
          // above the volume slider and looking identical while behaving
          // differently is the sort of thing that teaches people not to trust
          // a control.
          Item {
            width: parent.width
            visible: root.track !== null && !root.settingsOpen
            implicitHeight: seekSlider.implicitHeight + elapsedLabel.implicitHeight + Style.space(2)

            PanelSlider {
              id: seekSlider
              bar: root.bar
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              minimum: 0
              maximum: Math.max(1, root.playback.duration || 1)
              step: 1
              integer: true
              value: root.playback.elapsed || 0
              onReleased: function(position) { root.send(["seek", String(Math.round(position))]) }
            }

            Text {
              id: elapsedLabel
              anchors.left: parent.left
              anchors.top: seekSlider.bottom
              anchors.topMargin: Style.space(2)
              text: root.playback.elapsedText || "0:00"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              anchors.top: seekSlider.bottom
              anchors.topMargin: Style.space(2)
              text: root.playback.durationText || "0:00"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Transport and volume share a row: four stacked control bands made
          // the player half taller than the library half for no good reason.
          Item {
            width: parent.width
            visible: !root.settingsOpen
            implicitHeight: Math.max(transport.implicitHeight, volumeSlider.implicitHeight)

            Row {
              id: transport
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Repeater {
                model: [
                  { glyph: root.glyphPrev, action: "prev" },
                  { glyph: root.playing ? root.glyphPause : root.glyphPlay, action: "toggle" },
                  { glyph: root.glyphNext, action: "next" }
                ]

                Text {
                  required property var modelData
                  required property int index
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.glyph
                  color: transportArea.containsMouse ? root.foreground
                    : (index === 1 ? root.foreground : root.dim)
                  font.family: root.fontFamily
                  // Play/pause is the primary action, so it carries more weight
                  // than the two it sits between.
                  font.pixelSize: index === 1 ? Style.font.display : Style.font.icon

                  MouseArea {
                    id: transportArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.send([parent.modelData.action])
                  }
                }
              }
            }

            Text {
              id: volumeValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.volume + "%"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              // Fixed width so the slider does not twitch as the number grows.
              horizontalAlignment: Text.AlignRight
              width: Style.space(30)
            }

            PanelSlider {
              id: volumeSlider
              bar: root.bar
              anchors.left: transport.right
              anchors.right: volumeValue.left
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 100
              step: 5
              integer: true
              value: root.volume
              onMoved: function(level) { root.setVolume(level) }
              onReleased: function(level) { root.setVolume(level) }
            }
          }

          Rectangle {
            width: parent.width
            visible: !root.settingsOpen
            height: Style.spacing.hairline
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
          }

          // Search. Above the quick picks because it is the way into a library
          // too large to ever be listed; the picks below are the shortcuts for
          // when you already know what you are in the mood for.
          Item {
            width: parent.width
            visible: root.loggedIn && !root.settingsOpen
            implicitHeight: searchField.implicitHeight

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.right: clearSearchButton.left
              anchors.rightMargin: Style.space(6)
              foreground: root.foreground
              // One box, two jobs, decided by where you are standing: at the
              // picks there is a library to search, and inside a level there
              // is a list in front of you to narrow.
              placeholderText: root.level
                ? "Filter " + root.level.label
                : "Search artists, albums and tracks"

              onTextChanged: {
                root.queryText = text
                // The cursor belongs on the top hit of the new query, not on
                // whatever row it happened to be resting on. Inside a level
                // row zero is the way back, so the first match is row one.
                root.rowIndex = root.path.length > 0 ? 1 : 0
                // Filtering needs no process and no waiting; searching does.
                if (root.path.length === 0) searchDebounce.restart()
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  // A ladder out: the query first, then the level, then the
                  // field, then the panel -- so Escape never throws away more
                  // than you meant.
                  if (searchField.text !== "") root.clearSearch()
                  else if (root.path.length > 0) root.popLevel()
                  else keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Down) {
                  root.moveCursor(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.moveCursor(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Right
                           && searchField.cursorPosition === searchField.text.length) {
                  // Only once the caret has nowhere left to go, where the key
                  // would otherwise do nothing: that is what makes it free to
                  // mean "open this" without ever costing you an edit. It is
                  // the whole point of typing a band name -- right to see the
                  // albums, Enter to just play them.
                  root.openRow(root.navRows[root.rowIndex])
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  // Enter plays the top hit, so the common case is type and
                  // go without ever leaving the field.
                  root.activateRow(root.navRows[root.rowIndex])
                  event.accepted = true
                }
              }
            }

            Text {
              id: clearSearchButton
              anchors.right: parent.right
              anchors.verticalCenter: searchField.verticalCenter
              // Kept in the layout with nothing to clear, so the field does
              // not resize out from under the first letter typed.
              opacity: root.searchMode ? 1 : 0
              text: "✕"
              color: clearSearchArea.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              MouseArea {
                id: clearSearchArea
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                enabled: root.searchMode
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.clearSearch()
                  searchField.forceActiveFocus()
                }
              }
            }
          }

          // Quick picks, plus whichever section is folded open.
          Column {
            width: parent.width
            visible: !root.settingsOpen
            spacing: Style.space(1)

            Repeater {
              model: root.navRows

              Item {
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: Style.space(22)
                readonly property bool isCurrent: modelData.kind === "queued"
                  && modelData.glyph !== ""
                readonly property bool hasCursor: root.cursorActive && root.rowIndex === index
                readonly property bool opens: root.isOpenable(modelData)

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -Style.space(2)
                  radius: Style.space(4)
                  visible: hasCursor || rowArea.containsMouse
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                }

                Text {
                  id: rowGlyph
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  // Queue rows keep the column even when empty, so titles line
                  // up instead of stepping right for the one that is playing.
                  visible: modelData.glyph !== "" || modelData.kind === "queued"
                  width: modelData.kind === "queued" ? Style.space(11) : implicitWidth
                  text: modelData.glyph
                  color: isCurrent ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: modelData.kind === "queued" ? Style.font.caption : Style.font.body
                }

                Text {
                  anchors.left: rowGlyph.visible ? rowGlyph.right : parent.left
                  anchors.leftMargin: rowGlyph.visible ? Style.space(8) : 0
                  anchors.right: chevron.visible ? chevron.left : parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  // Deliberately a block, not the one-line ternary this was.
                  // As an optimised single-expression binding it gets
                  // evaluated once before the Repeater has injected
                  // modelData, resolves to undefined, and logs "Unable to
                  // assign [undefined] to QString" -- once per row per
                  // rebuild, and the model rebuilds on every status poll. The
                  // row rendered fine either way; the journal did not.
                  text: {
                    var label = modelData && modelData.label !== undefined ? modelData.label : ""
                    var detail = modelData ? modelData.detail : ""
                    return detail ? label + "  ·  " + detail : label
                  }
                  // In the queue only the track playing carries full weight;
                  // the rest is context you scan past -- as is the trail back,
                  // which says where you are rather than offering anything.
                  color: modelData.kind === "note" || modelData.kind === "back" ? root.dim
                    : (modelData.kind === "queued" && !isCurrent ? root.dim : root.foreground)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  // A trail too long for the panel loses its head rather than
                  // its tail: where you are is the part worth keeping.
                  elide: modelData.kind === "back" ? Text.ElideLeft : Text.ElideRight
                }

                Text {
                  id: chevron
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  // Above the row's own click area, so opening something and
                  // playing it are two targets rather than one guess.
                  z: 1
                  visible: opens
                  text: root.glyphOpen
                  color: chevronArea.containsMouse ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  MouseArea {
                    id: chevronArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    enabled: opens
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursorActive = false
                      root.openRow(modelData)
                    }
                  }
                }

                MouseArea {
                  id: rowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: modelData.kind !== "note"
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.cursorActive = false
                    root.activateRow(modelData)
                  }
                }
              }
            }
          }

          // Errors from the CLI, which already phrases them for a human.
          Text {
            width: parent.width
            visible: root.notice !== ""
            text: root.notice
            color: bar ? bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
