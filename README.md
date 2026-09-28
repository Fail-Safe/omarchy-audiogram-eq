# Audiogram EQ

[![Built for Omarchy: Plugin](https://raw.githubusercontent.com/tcballard/omarchy-badges/75975e5b5bf75e7ede3764bcd2950046f7abfe2c/badges/v1/omarchy-plugin.svg)](https://github.com/tcballard/omarchy-badges)
[![Supported Omarchy versions: 4.x](https://raw.githubusercontent.com/tcballard/omarchy-badges/8b0189738018961c1bd275d903dd37ceed6bf6ae/badges/v1/compatibility/omarchy-4.x.svg)](#compatibility)

Listener-compensating equalizer for Omarchy. Enter clinical audiogram
thresholds and get **headphones** / **speakers** presets shaped for *your*
hearing — not a measurement of whether the laptop sounds “flat.”

This is **assistive desktop audio**, not a hearing aid or medical device.

![Audiogram EQ — speakers / averaged response curve](preview.png)

![Headphones with per-ear L/R gains](docs/headphones-lr.png)

![Audiogram editor (dB HL thresholds)](docs/editor.png)

![Bar tooltip when compensation is on](docs/bar-on.png)

## Install

```sh
omarchy plugin add https://github.com/Fail-Safe/omarchy-audiogram-eq.git --enable
```

Open the ear / hearing glyph on the bar, enter your audiogram, then turn
compensation **ON**. Pick **Auto**, **Headphones**, or **Speakers**.

Middle-click the bar icon to toggle ON/OFF.

## Entering your audiogram

New installs ship a blank **custom** profile (all thresholds `0` dB HL).
Enabling EQ does nothing useful until you enter a chart.

1. Open the panel → **AUDIOGRAM (dB HL)** → **Edit**
2. Fill left/right thresholds at 250 / 500 / 1k / 2k / 3k / 4k / 6k / 8k
3. **Save audiogram**
4. Enable compensation, then adjust **tonal correction strength** while listening
   to familiar audio. Both headphones and speakers start at **30%**. Because
   personal hearing curves and audio preferences vary, you will very likely want
   to adjust the strength **after entering your audiogram figures**. Treat 30% as
   a starting point, not a target; each mode saves its own setting.

Leave unused bands at `0` if your clinic chart omits them. Saves go to
`~/.config/omarchy/audiogram-eq/profiles/` (never into the plugin tree).

## How it works

One half-gain style curve from the audiogram. Speakers and headphones share
the same mapping; only tonal correction strength (and optional per-ear L/R) differ.

```
gain = clamp(0, 12, 0.5 * max(0, threshold − 20)) × (strength / 100)
```

| Mode | Default tonal correction strength | Default per-ear L/R |
|---|---:|:---:|
| Headphones | 30% | On |
| Speakers | 30% | Off |

Strength controls how strongly the audiogram shapes the tonal balance, not the
overall playback volume. Higher strength also increases preamp attenuation, so
less-boosted frequencies can become quieter. Existing saved strengths are preserved
when updating; the 30% defaults apply to new or unset preferences.

- **Per-ear on:** left and right thresholds drive separate dual-mono chains
  (FL → `l_*`, FR → `r_*`).
- **Per-ear off:** both ears get the averaged curve.
- **Auto:** picks headphones vs speakers from the current sink, then applies
  that mode’s saved strength and per-ear setting. While enabled, the widget
  checks for output changes every four seconds, including with the panel closed.

The preamp applies broadband attenuation equal to the largest prescribed band
boost. Overlapping filters can still produce higher peaks; this is not a limiter.
OFF makes the graph flat and persists that bypass across service restarts.
Disabling or removing the widget in Omarchy does not itself undo the audio graph;
use OFF to bypass it, or follow **Remove** below to remove it completely.

## Bar icon colors

Default is fixed green/red for clear ON/OFF. Theme-particular users can
follow Omarchy colors instead:

```sh
omarchy bar set failsafe.audiogram-eq iconColors theme    # accent / muted
omarchy bar set failsafe.audiogram-eq iconColors status   # green / urgent (default)
```

## CLI

The CLI command for tonal correction strength remains `intensity`.

From the installed plugin directory (or a local checkout):

```sh
backend/agc status --json
backend/agc enable
backend/agc disable
backend/agc mode auto|headphones|speakers
backend/agc intensity 75
backend/agc per-ear on|off|toggle
backend/agc profile-save < /path/to/private-profile.json
backend/agc preview --json
backend/agc apply
backend/agc doctor --json
backend/agc reset
```

`profile-save` reads a JSON object with `label`, `left`, and `right` threshold
maps from **stdin**. The panel also sends saves through a private stdin pipe;
labels and hearing thresholds never go in its process arguments. The former
`profile-save '<JSON>'` form is no longer supported. For CLI saves, keep the
input file private (for example, mode `600`) and use input redirection as above.

## Profile format

See `profiles/custom.json` (blank starter). Prefer the panel editor; you can
also drop JSON into `~/.config/omarchy/audiogram-eq/profiles/` (user files
override bundled ones with the same id).

## Coexistence

- **Speaker Calibrator** corrects the *machine*. This plugin shapes output
  for the *listener*. Stacking both can over-boost highs — try one at a
  time first.
- **ParvvOK Equalizer** is a manual six-band EQ. Prefer one EQ graph at a
  time so smart sinks do not nest awkwardly.

## Update

```sh
omarchy plugin update failsafe.audiogram-eq
```

Version 1.0.3 replaces the old low-shelf preamp with broadband gain. The first
apply migrates an older graph with one user WirePlumber restart, which can briefly
interrupt audio. The widget migrates an existing older graph automatically; a CLI-only
installation can run `backend/agc apply` after updating.

## Remove

Clean up the audio path **while the plugin is still installed**, then remove it:

```sh
# 1. Remove the WirePlumber fragment and restart WirePlumber
~/.config/omarchy/plugins/failsafe.audiogram-eq/backend/agc reset

# 2. Remove the plugin
omarchy plugin remove failsafe.audiogram-eq --yes
```

`agc reset` deletes `~/.config/wireplumber/wireplumber.conf.d/omarchy-audiogram-eq.conf`,
clears plugin state under `~/.config/omarchy/audiogram-eq/`, and restarts the
user WirePlumber service so the EQ sink disappears.

If you skip step 1 and only remove the plugin, that fragment can keep shaping
audio, including after a reboot. Recovery without the plugin installed:

```sh
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
rm -f "$config_dir/wireplumber/wireplumber.conf.d/omarchy-audiogram-eq.conf"
systemctl --user restart wireplumber.service
# optional: drop saved strength / mode state
rm -f "$config_dir/omarchy/audiogram-eq/state.json"
```

Saved audiogram profiles under `~/.config/omarchy/audiogram-eq/profiles/` are
left alone so a reinstall can pick them up again.

Backend config and profile paths shown above use the default `~/.config` root.
If `XDG_CONFIG_HOME` is set, the backend uses that root instead. Omarchy's plugin
installation path remains `~/.config/omarchy/plugins/`.

## Compatibility

- Supported Omarchy versions: **4.x** (stable 4.0.0 up to, but excluding, 5.0.0).
- Last tested: Omarchy **4.0.3** (`try-omarchy-runtime`) on aarch64 Linux.
- Checks performed: `omarchy plugin validate .`, unit tests, panel enable/disable,
  headphones vs speakers auto-detect, WirePlumber fragment apply/reset, and
  tonal-correction strength while listening.
- Known limitations: needs the host PipeWire / WirePlumber stack; first migrate
  from the pre-1.0.3 low-shelf preamp restarts user WirePlumber once (brief audio
  interrupt). Compatibility badges are maintainer-declared support, not certification.

## Important safety note

**Not a medical device.** Assistive desktop EQ from published thresholds —
not a hearing aid, not a substitute for clinical fitting, and not for
treatment decisions. Follow your clinician’s guidance.

## License

MIT
