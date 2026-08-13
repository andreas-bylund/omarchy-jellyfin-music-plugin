# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's [private
vulnerability reporting][advisory] on this repository, rather than opening a
public issue.

[advisory]: https://github.com/andreas-bylund/omarchy-jellyfin-music-plugin/security/advisories/new

Expect an acknowledgement within a week. This is a spare-time project with one
maintainer, so please read that as a genuine estimate and not a service level.

## What this plugin handles

It holds a **Jellyfin access token**, which is a bearer credential: anyone who
has it can read your library and act as you on that server, until it is
revoked.

- The token lives in `~/.config/omarchy/jellyfin/config.json`, mode `0600`.
  It is written to a temporary file and moved into place, so an interrupted
  write cannot truncate it, and a config left world-readable by an older
  version is repaired on the next write.
- Your **password** is never stored. `login` exchanges it for the token and
  forgets it. Pass it on stdin (`--password-stdin`) or at the prompt —
  `--password` puts it in `argv`, which other users on the machine can read
  through `/proc`.
- `logout` asks Jellyfin to revoke the token before deleting the local copy,
  so a config file copied off the machine beforehand stops working too.
- The token appears in the query string of stream and cover-art URLs, which is
  how Jellyfin authenticates those. It therefore reaches your server's access
  log, and `status --json` prints one of those URLs — worth redacting before
  pasting output into a bug report.

## Decisions worth knowing about

**A public address is only ever tried over HTTPS.** A bare
`jellyfin.example.com` is not retried over plain HTTP if TLS fails, because
anyone able to make that attempt fail — blocking port 443 is enough — would
otherwise receive the login in clear text. Plain HTTP to a public server
remains possible, but it must be written out: `--server http://…`. Local and
private addresses do try both, since a default Jellyfin serves HTTP on 8096
and the traffic stays on your own network.

**`--insecure` disables certificate verification** for both the API calls and
mpv's streaming, and is remembered in the config. It exists for the
self-signed certificates that are normal on a home server. On anything
reachable from the internet it removes your only protection against an
impostor.

**Server discovery is unauthenticated.** Jellyfin's UDP broadcast has no way
to prove that a reply comes from your server, so anything on the network can
answer and claim to be one. Discovered servers are always presented as a list
to choose from — never filled in automatically, not even when a single server
replies — because the next thing typed into that form is a password. On a
network you do not control, check the name or type the address yourself.

**The mpv IPC socket is as good as a shell.** Whoever can connect to it can
make mpv run commands as you, and can read the stream URLs with the token in
them. It lives in `$XDG_RUNTIME_DIR/omarchy-jellyfin/`, which only you can
open. A session without `XDG_RUNTIME_DIR` — a plain SSH login, sometimes —
falls back to `$TMPDIR/omarchy-jellyfin-$UID`, and refuses to use that
directory if it turns out to belong to someone else or to be readable by them.

**The plugin is unsandboxed.** `BarWidget.qml` runs inside `omarchy-shell` and
`bin/omarchy-jellyfin` runs as your user, as is true of every Omarchy plugin.
That is why Omarchy installs plugins disabled: read the code before enabling
it.

## Out of scope

- Somebody who already has your user account. Every protection here assumes
  the attacker is not already you.
- Jellyfin server vulnerabilities — report those to
  [jellyfin/jellyfin](https://github.com/jellyfin/jellyfin).
- Anything requiring root on the machine running the plugin.
