# Development notes

## Local install (dev)

`install.sh` / `uninstall.sh` stay on disk for local symlinking but are
**gitignored** — they are not part of the published tree. Marketplace
install is:

```sh
omarchy plugin add https://github.com/Fail-Safe/omarchy-audiogram-eq.git --enable
```

For a working-tree checkout:

```sh
./install.sh
# or:
omarchy plugin add "$PWD" --enable
```

Local `./uninstall.sh` runs `backend/agc reset` **before** unlinking so the
WirePlumber fragment is cleared while the checkout is still available.

## Tests

```sh
python3 -m unittest discover -s tests -v
omarchy plugin validate .
```

The suite isolates user profiles/config and mocks audio mutations; it does not
restart your audio service. Qt regression tests use `qmltestrunner` (from Qt
Declarative), with an offscreen software renderer. They execute the production
text blocks without launching the shell and skip if Qt's runner is unavailable.
Keep these tests enabled when preparing a marketplace release.

When `qs` is installed, the suite also runs a temporary offscreen Quickshell
instance to check queued profile saves over stdin and inspect child command lines.
It does not load the desktop shell or invoke the audio backend.

To also load the generated graph and verify live control readback against a
private PipeWire server (temporary config/socket, no hardware or WirePlumber):

```sh
AUDIOGRAM_PIPEWIRE_TEST=1 python3 -m unittest discover -s tests -p test_pipewire_integration.py -v
```

This opt-in test requires `pipewire`, `pw-cli`, `pw-dump`, and permission to bind
a local Unix socket. It never connects to the desktop's PipeWire socket.

External strings must use `textFormat: Text.PlainText` at each QML `Text` sink.
Do not escape labels in storage: literal angle brackets and Unicode must round-trip.
Keep audiogram JSON on stdin, never in process arguments, environment variables,
or shell command strings. CLI saves use `backend/agc profile-save < private.json`.

## Screenshots

Sources live in `~/Pictures/`. Crop panel shots to the card (drop the bar);
keep `docs/bar-on.png` as the bar + tooltip crop.
