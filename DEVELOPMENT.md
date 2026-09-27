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

## Tests

```sh
python3 -m unittest discover -s tests -v
omarchy plugin validate .
```

## Screenshots

Sources live in `~/Pictures/`. Crop panel shots to the card (drop the bar);
keep `docs/bar-on.png` as the bar + tooltip crop.
