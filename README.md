# jf_tracker

A tracker view of REAPER with a Vim layer. Write a whole track from the keyboard
in one window: patterns, their order, sounds, slices, effects.

- **The tracker is only a view, and REAPER is the engine.** Tracks, items, MIDI,
  regions, envelopes and FX stay native. There is nothing to export and nothing
  to lose: close the window and the project plays on. Every edit is one REAPER
  undo step.
- **Vim is the foundation.** Modes, operators + motions (`dw`, `d3j`, `yy p`),
  counts, registers, the `.` repeat and the `:` command line drive every
  module. The mouse is optional.
- **Letters, not icons.** Every control is text. When a symbol is needed it
  comes from another alphabet: `Δ` is delta solo, `ø` is phase.

## Features

- Note, instrument, volume and command columns over native MIDI and audio
  items. There are envelope columns as well.
- A pattern matrix built on regions, with a live region queue.
- A sample lib per project and a file browser with preview.
- Virtual slicing on the item tab:
  - the `s` menu: `st` slices by transients, `s8` / `s4` / `s2` … into equal
    parts, `sd` removes the slices, `sq` smart-quantizes;
  - in INSERT every key of the keyboard writes a slice;
  - `:arp`, `:scramble` and slice swapping.
- A slices module with a spectrogram view of the sample.
- A DSP panel per track:
  - in / out meters, gain compensation, and delta solo on each FX;
  - REAPER presets and A/B morphing;
  - graphical views for the stock ReaPlugs (EQ, comp, multiband, gate, delay,
    verb, convolution impulse spectrogram);
  - Airwindows categories and descriptions;
  - user-editable modules with an XY-pad learn.
- A macro view, step listen, a keycaster, floating project notes with
  Markdown and todo boxes, screensets and themes.
- Optional monome grid / arc support.
- An interactive tour (`:tutorial`). `?` shows the keys of the focused module,
  and F1 opens the full help.

## Requirements

- REAPER 7 (macOS is the tested platform; Windows / Linux are untested).
- [SWS extension](https://www.sws-extension.org/), used for preview through
  `CF_Preview`.
- [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174), used for
  key state and window handling.

Both extensions are available through [ReaPack](https://reapack.com/).

## Install

**With ReaPack (recommended).** After buying you get a personal link:
`https://jeeruff.com/jf_tracker/r/<your license key>/index.xml`.

1. In REAPER, open *Extensions → ReaPack → Import repositories…* and paste the
   link.
2. Open *Extensions → ReaPack → Browse packages*, find `jf_tracker` and
   `jf_tracker effects`, and install both.
3. The `jf_tracker` script appears in the action list. Bind it to a key if you
   like.

Updates arrive through ReaPack's *Synchronize packages*.

**By hand.**

1. Copy the `jf_tracker` folder into REAPER's `Scripts` folder. In REAPER,
   *Options → Show REAPER resource path* shows where that is.
2. Copy `effects/jf_rec.jsfx` and `effects/jf_tracker_scope.jsfx` into
   REAPER's `Effects` folder. They are the retro sampler and the scopes.
3. Open *Actions → Show action list → New action → Load ReaScript…* and pick
   `jf_tracker.lua`.

## First steps

Run the script and press `:tutorial`, or take the tour from the main module.
In short:

| Keys | What they do |
| --- | --- |
| `h j k l`, `gg` / `G`, `{ }` | Move: by cell, to the start / end, by bar. |
| `i`, then `m` | INSERT, then the keyboard on. `q 2 w 3 e r 5 t …` write notes; `z` / `x` change the octave. |
| `Esc` | Toggles INSERT, as in Renoise. |
| `x`, `dw`, `yy p`, `u`, `.` | Delete, delete with a motion, copy and paste, undo, repeat. |
| `v` / `V` | Select a block / whole rows. |
| `:` | The command line. Tab completes. |
| `\` | The leader menu, or the context menu of the focused module. |
| `Space` | Play / stop. |
| `?` | The keys of the focused module. |

## Credits

Thanks to my friends and teachers, in particular **Esa Ruoho (Lackluster)**.
Parts of jf_tracker are based on his [Paketti](https://github.com/esaruoho/paketti)
for Renoise and are used with his permission. Support his work:
<https://www.patreon.com/esaruoho>.

The DSP module texts use descriptions from Chris Johnson's
[Airwindopedia](https://www.airwindows.com/) when it is installed.

## License

jf_tracker is free software under the [GNU General Public License v3](LICENSE).
It comes with no warranty.

If it is useful to you, you can support development at <https://jeeruff.com>.
