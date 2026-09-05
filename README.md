# Jellyfin Music for Omarchy

Play music from your [Jellyfin](https://jellyfin.org/) server straight from the
Omarchy bar.

The plugin puts the current track in your bar, with a popup holding cover art,
a seek bar, transport and volume, a search across your whole library, and quick
picks for your playlists, favourites, a shuffle, and the queue. Audio is streamed to
a local `mpv`, which means the track also shows up on MPRIS — so your media keys
and Omarchy's own media widget control it without any extra setup.

<img width="681" height="736" alt="image" src="https://github.com/user-attachments/assets/2c397e83-23da-42d3-82b7-20739657dccc" />

Colours are not the plugin's to pick — every screenshot here is just whichever
Omarchy theme was active at the time.

Requires Omarchy 4.0 or newer (the shell plugin system) and `mpv`.

## Install

```bash
omarchy plugin add https://github.com/andreas-bylund/omarchy-jellyfin-music-plugin.git
omarchy plugin enable andreasbylund.jellyfin
```

Plugins land disabled so you can read the code before running it. Then log in
once, from a terminal:

```bash
~/.config/omarchy/plugins/andreasbylund.jellyfin/bin/omarchy-jellyfin login
```

It exchanges your credentials for a Jellyfin access token and stores it in
`~/.config/omarchy/jellyfin/config.json` with mode `0600`. Your password is
never written to disk. `omarchy-jellyfin logout` asks Jellyfin to revoke that
token before deleting the local copy, so a config file taken off this machine
beforehand stops working too.

Two things worth knowing if you handle that token: `--password` on the command
line is readable by other users through `/proc`, so prefer `--password-stdin`
or the prompt — and `status --json` prints an image URL with the token in it,
which makes it something to redact before pasting into a bug report.

## Pointing at your server

Your Jellyfin can be anywhere — this machine, a box in the next room, or a
server on the internet.

Run bare, `login` first broadcasts for Jellyfin servers on your network and
offers what it finds, so a local or LAN server usually needs no address at all:

```
$ omarchy-jellyfin login
Looking for Jellyfin servers on this network…
  1) Living room  (http://192.168.1.50:8096)
Pick a server [1-1], or type an address:
```

A server it cannot see gets typed in, with or without a scheme:

```bash
omarchy-jellyfin login --server jellyfin.example.com   # → https
omarchy-jellyfin login --server localhost:8096         # → http
omarchy-jellyfin login --server 192.168.1.50:8096      # → http
omarchy-jellyfin login --server http://nas.local:8096  # taken as written
```

Without a scheme the guess follows the address: local and private addresses get
`http` (which is what a default Jellyfin serves on 8096), public names get
`https`. For a local address, if the guess is wrong the other one is tried
automatically, so either way works.

A public name only ever gets `https`. Falling back to plain HTTP there would
mean that anyone able to break the TLS attempt — blocking port 443 is
enough — gets your password posted to them in clear text. If your server
really does serve plain HTTP over the internet, spell it out:
`--server http://jellyfin.example.com`.

For a self-signed certificate — normal on a home server — add `--insecure`.
That is remembered, and applies to mpv's streaming as well as the API calls.

```bash
omarchy-jellyfin discover   # just list servers on this network
omarchy-jellyfin server     # show which one is configured
```

Switching servers later is another `login`.

Discovery probes every network this machine is on, not just the default route,
so an active VPN does not hide a server sitting on your LAN. It still only
finds servers that answer on UDP 7359 — a Jellyfin in Docker usually publishes
only `8096/tcp`, so those need their address typed in even on the same network.

Discovery is an unauthenticated broadcast: anything on the network can answer
and claim to be a Jellyfin. So what it finds is always offered as a list to
pick from — never filled in for you, not even when a single server answers —
because the next thing you type is a password. On a network you do not trust,
check the name, or type the address yourself.

## Using it

In the bar:

| Interaction | What it does |
|---|---|
| Left click | open the popup |
| Right click | play / pause |
| Middle click | next track |
| Scroll | volume up / down |

Scroll adjusts volume rather than skipping tracks, because it is the thing you
reach for mid-song and it works without opening the popup.

The bar entry shows the icon plus the current track title, scrolling when it
does not fit.

<img src="docs/images/bar.png" width="560"
     alt="The Omarchy bar, with the music icon and the scrolling track title sitting among the other bar widgets.">

Three settings cover that, in decreasing order of how much you are likely to
care:

- **Show the track title in the bar** — off leaves just the music icon, for a
  bar that is already full or an eye that would rather not read one.
- **Scroll the title in the bar** — off holds a long title still and shortens
  it with an ellipsis instead. Motion in the corner of the eye is not for
  everyone.
- **Track title width in the bar** — how much room the title gets.

The popup carries, top to bottom: cover art with title, artist and album; a
draggable seek bar with elapsed and total time; transport and volume on one row;
a search box; then your playlists, favourites, artists, albums, a shuffle, and
the current queue. Both bars are draggable — the seek bar really does seek,
which is why it is a slider and not the plain progress line it started as.

Opening **Queue** lists what is loaded, with the current track marked; click any
row to jump to it.

<img src="docs/images/queue.png" width="340"
     alt="The queue, with the playing track marked by an arrow and lifted out of the dimmer rows around it.">

### Browsing

**Artists** and **Albums** walk the library itself, which is the way in when you
would rather look than search. An artist opens their discography, oldest first;
an album opens its tracks. Each level replaces the one before it, with the trail
back along the top.

**Artists** lists album artists — the names records are filed under. Jellyfin
also keeps every credit it could not split as an artist of its own, and on a
library of sixty bands that is two hundred more rows of `2Pac feat. Dr. Dre &
Roger Troutman`, none of them leading anywhere `2Pac` does not. The **Album
artists only** toggle in the gear hides them; turn it off to see the lot, which
also files an artist's guest spots under them when you open or play them.

One rule, no exceptions: **a row with something inside it opens, and a row that
is the thing itself plays.** The chevron tells you which you are looking at, so
artists, albums and playlists open, and tracks play.

<img src="docs/images/browsing.png" width="720"
     alt="Two levels side by side: an artist's discography, oldest first, every album carrying a chevron; and one album's tracks, carrying a note instead. Both open with a Play all row, and the trail back sits above them.">

The trail along the top is also the way back, and it shortens rather than wraps
when a name is long — `‹ …s › Meshuggah › Destroy Erase Improve`.

Every level you can open begins with **Play all**, saying how much it is about
to queue — `Play all · 13 albums`, `Play all · 9 tracks`. That is one click
more than playing an album straight off the row used to be, and it buys two
things: playing never happens by a stray click, when it throws away your queue
and the song you were on with no way back; and picking one song off an album is
now something you can do at all.

Picking a track plays the list it sits in and starts there, so choosing the
fourth song on a record leaves you with the record, not a queue of one.

A level arrives whole, so the search box turns into a filter while you are
inside one and narrows it as you type, with no round trip to the server. Very
long levels draw the first 200 rows and say how many are left; filtering is how
you reach the rest.

### Search

Type in the search box — or press `/` — and the popup lists matching artists,
albums and tracks in place of the quick picks. What you pick decides what
happens, and it is the same rule as everywhere else: artists and albums open,
tracks play — queueing the rest of the matches around themselves, so a search
is a starting point rather than a single song. Which is the answer to searching
"meshuggah" and finding one album: their records are not named after them, so
the artist is the only hit that leads anywhere, and it leads to all thirteen.

<img src="docs/images/search.png" width="340"
     alt="Search results for “miles”: the artist first, then an album, then tracks — the artist and album carrying chevrons because they open, the tracks a note because they play.">

Results come back grouped the way you would act on them: artists, then albums,
then tracks.

`Enter` acts on the top hit without leaving the box, `→` opens it once the
caret has nowhere further to go, `↓` steps into the results, and `Escape`
clears the query, then steps back out of the level you are in, then leaves the
box, then closes the popup. Opening puts the cursor on **Play all**, so typing
a name and pressing `Enter` twice still queues the lot — with a look at what
that is in between.

In the popup, `j`/`k` move, `l`/`→` opens a row, `h`/`←` goes back, `Enter`
plays or opens, `space` toggles playback, `n` and `p` skip, `f` toggles the heart on the
current track, `+`/`-` change volume, `s` shuffles the library, `/` searches, and `,` opens settings.

The gear holds the settings and the connection. Once you are connected that
part is just who you are signed in as, with **Switch server…** and **Log out** —
the address, username and password boxes only appear when there is something to
fill in.

<img src="docs/images/settings.png" width="400"
     alt="The gear panel: a Connection block naming the signed-in user and server with Switch server and Log out beside it, then toggles for album art, the bar title, and scrolling that title.">

The four toggles here are the ones worth reaching for while the music is in
front of you. The rest — the title's width, and how much `Shuffle all` pulls —
live in Omarchy's plugin settings, where you set them once.

## Volume

The popup has its own volume slider, and it is worth knowing what it controls:
mpv's software volume, on top of your system volume. mpv's own default is 100,
which is the source at full scale and lands painfully loud next to a browser,
so a fresh install starts at 70. The level is remembered between tracks,
between mpv restarts, and across reboots.

Playback also runs with `--replaygain=track`, which levels ReplayGain-tagged
files against each other so a loud remaster does not blast after a quiet album.
Files without those tags are unaffected.

## The CLI

Everything the widget does goes through `bin/omarchy-jellyfin`, which is a
useful thing on its own — bind it to a key, call it from a script, or use it
over SSH.

```bash
omarchy-jellyfin play --shuffle          # shuffle the library
omarchy-jellyfin play --favorites        # queue your favourites
omarchy-jellyfin playlists               # list playlists with their ids
omarchy-jellyfin play --playlist <id>    # queue one
omarchy-jellyfin search "kind of blue"   # artists, albums and tracks, with ids
omarchy-jellyfin artists                 # every artist, with ids
omarchy-jellyfin albums                  # every album
omarchy-jellyfin albums --artist <id>    # one artist's discography, oldest first
omarchy-jellyfin tracks --album <id>     # what is on an album
omarchy-jellyfin tracks --playlist <id>  # what is in a playlist
omarchy-jellyfin play --artist <id>      # everything an artist appears on
omarchy-jellyfin play --album <id>       # one album
omarchy-jellyfin play --search "miles"   # queue what a search matches
omarchy-jellyfin status                  # what is playing
omarchy-jellyfin queue                   # the loaded queue, current marked
omarchy-jellyfin jump 4                  # play queue position 5 (0-based)
omarchy-jellyfin seek 90                 # jump to 1:30 in the track
omarchy-jellyfin volume                  # print the level
omarchy-jellyfin volume 55               # set it
omarchy-jellyfin volume up --step 10     # or nudge it
omarchy-jellyfin toggle | next | prev | stop
omarchy-jellyfin favorite <item-id> favorite     # mark as favorite
omarchy-jellyfin favorite <item-id> unfavorite   # remove favorite
```

<img src="docs/images/cli.png" width="720"
     alt="A terminal running omarchy-jellyfin status, queue, search and albums: the playing track marked in the queue, and the listing commands printing an id, a name and a detail per row.">

Add `--json` to `status`, `volume`, `queue`, `favorite`, `playlists`, `favorites`,
`search`, `artists`, `albums`, and `tracks` for machine output. The listing commands share
one row shape — `{id, name, detail}` — because what they list differs but what
you do with it next does not.

`--album-artists-only` is the CLI side of the **Album artists only** toggle. On
`artists` and `search` it lists album artists rather than every credit; on
`albums --artist` and `play --artist` it stays with the records filed under
them rather than everything they appear on. The widget passes it whenever the
toggle is on, which it is by default.

`artists` and `albums` stop at 2000 entries and say so on stderr; a library
larger than that is one you search rather than scroll.

## How it works

```
BarWidget.qml  ──spawns──>  bin/omarchy-jellyfin  ──HTTP──>  Jellyfin server
                                     │
                                     └──JSON IPC──>  mpv  ──>  MPRIS ──> Omarchy media widget
```

The QML is a thin view. All the logic — authentication, the REST calls, queue
building, and mpv control — lives in the Python CLI, which uses only the
standard library. That keeps the part worth testing testable without a running
shell, and means cloning the repo is the entire install.

`mpv` is started once in idle mode behind a JSON IPC socket in
`$XDG_RUNTIME_DIR/omarchy-jellyfin/`, so a queue survives between commands.
That directory has to be one only you can open — whoever reaches the socket can
make mpv run commands as you, and can read the stream URLs the token is in. A
session without `XDG_RUNTIME_DIR` (plain SSH, sometimes) falls back to
`$TMPDIR/omarchy-jellyfin-$UID`, and refuses to use it if it turns out to
belong to somebody else or to be readable by them.
Tracks are direct-played from Jellyfin rather than transcoded, which is both
better quality and cheaper on the server; mpv reads the file's own tags, so
MPRIS gets a real artist and album.

## Development

```bash
python3 -m unittest discover -s tests -v
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the same ground at more length, plus
where a change belongs and what to be careful with.

Work on the checkout in place, at
`~/.config/omarchy/plugins/andreasbylund.jellyfin/`. Keeping the repo elsewhere
and symlinking it into the plugin directory does not work at all: the shell
watches that directory and does not follow the symlink. Symlink the other way
round if you want the project to appear under `~/Projects`.

**QML edits need `omarchy restart shell` to take effect.** Saving a file does
make the shell log `Local plugin changed, reloading`, and `omarchy-shell shell
rescanPlugins` logs the same — but neither replaces a bar widget that is
already mounted, so the old code keeps running and you end up debugging an
edit that was never loaded. Changes to `bin/omarchy-jellyfin` need no restart,
since the widget shells out to it afresh every time.

`journalctl --user -f` shows QML errors. Note that a widget which silently
fails to appear is usually this reload trap rather than a layout bug.

## Limitations

- Playback is local to this machine. Casting to other Jellyfin clients is not
  implemented.
- One queue holds 500 tracks. An artist or a shuffle with more behind it says
  so on stderr rather than quietly handing back a shorter library.
- Browsing walks playlists, favourites, artists and albums. Genres, years, and
  anything else Jellyfin can sort by are not entry points; those you reach by
  searching for a name.
- A level draws its first 200 rows and says how many are left. Filtering is how
  you reach the rest, not scrolling.

## Security

The plugin holds a Jellyfin access token, so a few of its decisions are
security decisions: HTTPS is never silently downgraded, discovered servers are
never filled in for you, and the mpv socket has to sit somewhere only you can
open. [SECURITY.md](SECURITY.md) explains those, and how to report a problem.

## Uninstall

```bash
~/.config/omarchy/plugins/andreasbylund.jellyfin/bin/omarchy-jellyfin logout
omarchy plugin remove andreasbylund.jellyfin
```

`logout` asks Jellyfin to revoke the access token before `remove` deletes the
plugin. Your login config lives in `~/.config/omarchy/jellyfin/` — delete that
directory too if you want no trace left.

## License

MIT. See [LICENSE](LICENSE).
