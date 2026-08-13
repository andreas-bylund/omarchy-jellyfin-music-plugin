# Contributing

Thanks for looking. This is a spare-time project with one maintainer, so an
issue describing the problem is worth as much as a patch, and often more.

## Getting set up

Work on the checkout **in place**, at
`~/.config/omarchy/plugins/andreasbylund.jellyfin/`. Keeping the repo elsewhere
and symlinking it into the plugin directory does not work at all: the shell
watches that directory and does not follow the symlink. Symlink the other way
round if you want the project to appear under `~/Projects`.

```bash
git clone https://github.com/andreas-bylund/omarchy-jellyfin-music-plugin.git \
  ~/.config/omarchy/plugins/andreasbylund.jellyfin
omarchy plugin enable andreasbylund.jellyfin
ln -s ~/.config/omarchy/plugins/andreasbylund.jellyfin ~/Projects/omarchy-jellyfin-music-plugin
```

You need Omarchy 4.0 or newer, `mpv`, and a Jellyfin server to point at.

## The one trap

**QML edits need `omarchy restart shell` to take effect.** Saving a file does
make the shell log `Local plugin changed, reloading`, and `omarchy-shell shell
rescanPlugins` logs the same — but neither replaces a bar widget that is already
mounted. The old code keeps running, and you end up debugging an edit that was
never loaded. A widget that silently fails to appear is usually this, not a
layout bug.

Changes to `bin/omarchy-jellyfin` need no restart; the widget shells out to it
afresh every time. `journalctl --user -f` shows QML errors.

## The blinking desktop

Working in place puts the repo inside the directory the shell watches, and that
watch is recursive with nothing filtered out. So `.git` counts: a plain `git
status` writes `.git/index.lock`, and the shell reads the event as the plugin
having changed. Running the tests counts too, through the `__pycache__/`
directories they leave behind.

Every one of those reloads all plugins, and the teardown takes Omarchy's own
background renderer with it — `omarchy.background` is a shell plugin like any
other. The wallpaper and the bar blink. An editor or agent that polls `git
status` on a timer hands you that blink on its interval, which is unnerving
until you know what it is.

It is the development setup, not the plugin. Nothing the widget writes at
runtime lands in the plugin directory: the config goes to
`~/.config/omarchy/jellyfin/`, the queue and the mpv socket to
`$XDG_RUNTIME_DIR`, and `__pycache__/` only appears when something imports the
CLI as a module, which only the tests do. An installed copy sits still.

## Where things go

```
BarWidget.qml  ──spawns──>  bin/omarchy-jellyfin  ──HTTP──>  Jellyfin server
                                     │
                                     └──JSON IPC──>  mpv  ──>  MPRIS
```

The QML is a thin view. Authentication, the REST calls, queue building and mpv
control live in the Python CLI, which uses **only the standard library** — no
dependencies, so cloning the repo is the entire install. Please keep that split:
logic that lands in the QML is logic that cannot be tested without a running
shell, and it stops the CLI being useful on its own.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

CI runs these plus a manifest check on every push and pull request. New
behaviour in the CLI should arrive with a test; the suite is fast and has no
network in it, so keep it that way — mock the HTTP rather than reaching a real
server.

There is no automated coverage of the QML. Say in the pull request what you
actually clicked.

## Style

Match what is already there. The code comments explain *why* a thing is the way
it is, not what the line does — a decision that took thought is worth a
sentence, and a line that reads plainly needs none.

## Things to be careful with

This plugin holds a Jellyfin access token, so some changes are security changes
even when they do not look like it. [SECURITY.md](SECURITY.md) sets out the
reasoning behind the ones already made — HTTPS is never silently downgraded,
discovered servers are never filled in for you, the mpv socket has to sit
somewhere only you can open, and the token must not reach a log or a bug report.
If your change touches any of those, say so, and expect the review to be slower.

Report vulnerabilities privately through [a security advisory][advisory], not a
public issue.

[advisory]: https://github.com/andreas-bylund/omarchy-jellyfin-music-plugin/security/advisories/new

## Pull requests

Open one against `main`. Small and focused beats large and complete; if a change
is big, an issue first will save us both the work of a rewrite. By contributing
you agree your work is licensed under the [MIT License](LICENSE).
