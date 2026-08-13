## What this changes

<!-- And why. The what is usually visible in the diff; the why rarely is. -->

## How you checked it

<!--
`python3 -m unittest discover -s tests` covers the CLI, which is where the
logic lives. If you touched BarWidget.qml, say what you did in the running
shell instead -- and note that QML edits need `omarchy restart shell` to take
effect, so an untested-looking change is often an unloaded one.
-->

- [ ] `python3 -m unittest discover -s tests` passes
- [ ] Touched `BarWidget.qml`? Reloaded with `omarchy restart shell` and used it
- [ ] Behaviour changed? README says the new thing
- [ ] Touches the token, the mpv socket, or how a server address is resolved?
      Say so below — SECURITY.md may need to change with it
