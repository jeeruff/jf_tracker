# jf_tracker

A tracker view of REAPER with a Vim layer.

I waited for someone to build a tracker for REAPER. More than seven years later
it was time to do it myself. A tracker lets your hands leave the mouse alone
and type the notes that the keyboard can type anyway.

- **Why jf.** These are my initials and short nick, and `j` and `f` are also
  the keys under your index fingers on the home row. The tracker is meant to
  be played from the keyboard.
- **Vim is the foundation.** Modes, operators + motions (`dw`, `d3j`, `yy p`),
  counts, registers, the `.` repeat and the `:` command line drive every
  module. The mouse is optional.
- **Native REAPER.** Tracks, items, MIDI, regions, envelopes and FX stay plain
  REAPER. Close the window and the project plays on. Every edit is one undo
  step.
- **A script ecosystem tied together.** You can look natively into other
  REAPER projects and take, say, an automation curve from another one, or just
  enjoy that you can.
- **PT-mode.** A simple view without a crowd of channels. It is a tribute to the
  old-school ProTracker way, the tracker a ton of jungle and electronic music
  was written on.
- **Letters, not icons.** When a symbol is needed it comes from another
  alphabet: `Δ` is delta solo, `ø` is phase.

I am not a professional programmer. Claude helped me write this, so I see no
point in making it a commercial product. What you get here is worth at least
2500 euro of tokens and months of almost non-stop work, which I loved doing and
will keep doing. If it makes you as happy as it makes me, buy me a coffee:
<https://ko-fi.com/jeeruff>.

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
- jf_slixer: a transient slicer / pad sampler driven 1:1 from the DSP panel —
  quick-load slots, a sniper zoom of the slice edge with "spam" roll, live
  re-detect while you move the sensitivity.
- A sample map pane: every sound file of the browser folder (no limit, read
  once into an index) as groups — a graph, Chladni-figure cards, or a nebula
  galaxy with sectors; `ξ` plays a random sound, the played path and history
  stay, marked files become a lib folder or a kit. Rough loudness /
  brightness analysis from REAPER's peaks orders the groups dark to bright.
- `ξ` in the lib: a random sample like the name of its folder, back / forward
  through what came up.
- A harmonizer: chords from notes and sound, a chord lane on the master,
  negative harmony and neo-Riemannian moves, microtones in cells.
- Gain reduction of compressors / limiters in track headers, the mixer and DSP.
- CONTROL mode: the trackpad over the nearest bank of sliders.
- A macro view, step listen, a keycaster, floating project notes with
  Markdown and todo boxes, screensets and themes.
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

**With ReaPack (recommended).**

1. In REAPER, open *Extensions → ReaPack → Import repositories…* and paste
   `https://github.com/jeeruff/jf_tracker-release/raw/main/index.xml`.
2. Open *Extensions → ReaPack → Browse packages*, find `jf_tracker` and
   `jf_tracker effects`, and install both.
3. The `jf_tracker` script appears in the action list. Bind it to a key if you
   like.

Updates arrive through ReaPack's *Synchronize packages*. The zip is also on
<https://jeeruff.itch.io/jftracker>, free or pay what you want.

**By hand.**

1. Copy the `jf_tracker` folder into REAPER's `Scripts` folder. In REAPER,
   *Options → Show REAPER resource path* shows where that is.
2. Copy `effects/jf_rec.jsfx`, `effects/jf_tracker_scope.jsfx` and
   `effects/jf_tracker_trig.jsfx` into REAPER's `Effects` folder. They are the
   retro sampler, the scopes and the MIDI trigger of sample notes (note mod).
3. Open *Actions → Show action list → New action → Load ReaScript…* and pick
   `jf_tracker.lua`.

## First steps

Run the script and press `:tutorial`, or take the tour from the main module.
In short:

| Keys | What they do |
| --- | --- |
| `h j k l`, `gg` / `G`, `{ }` | Move: by cell, to the start / end, by bar. |
| `i` | INSERT: the keyboard writes notes. `q 2 w 3 e r 5 t …` write notes, `z` / `x` change the octave. |
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

The first tracker inside REAPER was [Hackey-Trackey](https://github.com/JoepVanlier/Hackey-Trackey)
by Joep Vanlier (MIT) - it showed that a tracker can live on REAPER's own timeline. jf_tracker
follows that idea with its own code; the user key file (`jf_tracker_keys.lua`) works like its
`userkeys.lua`.

Also thanks to my brother **beast**, who showed me trackers and the demoscene in the first place.

The Orca field is an own implementation of [Orca](https://github.com/hundredrabbits/Orca)
by Hundred Rabbits (MIT), the esoteric livecoding language - no code copied.

The dsp big routing view follows the idea of Sexan's ParaNormal FX Router
for REAPER - an own implementation, no code copied.

The reform pane (time scale / curve / shift / redistribute and value ranges of the selected notes)
follows the idea of [Reform](https://www.aqu.surf/reform) for Renoise - an own implementation, no code copied.

### Ideas from other tools

Ideas only - jf_tracker has its own code for all of them. Respect to their authors:

- trackers - rows, hex, the note-vol-fx cell, F1 / F2 octaves, Esc as edit - ProTracker, FastTracker, Impulse Tracker, [Renoise](https://www.renoise.com), [Furnace](https://github.com/tildearrow/furnace), [Dirtywave M8](https://dirtywave.com)
- modes, operators and motions - [Vim](https://www.vim.org) (Bram Moolenaar)
- a menu of what a prefix key does next - [which-key.nvim](https://github.com/folke/which-key.nvim) (folke)
- marked files and folder columns in the browser, lib marks - [lf](https://github.com/gokcehan/lf) (gokcehan), ranger, Midnight Commander
- fuzzy search syntax - [fzf](https://github.com/junegunn/fzf) (Junegunn Choi)
- jumps to the most used folder (:z) - [zoxide](https://github.com/ajeetdsouza/zoxide) (Ajeet D'Souza)
- quick marks to jump back - [harpoon](https://github.com/ThePrimeagen/harpoon) (ThePrimeagen)
- panes, splits and the pane mode - [tmux](https://github.com/tmux/tmux), [zellij](https://zellij.dev)
- the pattern grid of codes A1 B2 ... - Polyend Tracker, Elektron sequencers
- clips, scenes and launching - Ableton Live (Session View), Bitwig Studio
- note keys that play patterns (patternkb), pads - Akai MPC
- spam: a moved slice edge rolls - Roland SP-404
- the sniper zoom of a slice edge - Xfer Nerve (Steve Duda)
- dense parameter groups of the slixer panel - Madrona Labs Aalto and Kaivo
- ring knobs - Nagra / Kudelski recorders
- the sample map as a graph - [Obsidian](https://obsidian.md) graph view; sample browsing by sound - Sononym
- the monome grid and arc pages - [monome](https://monome.org)
- negative harmony; P / R / L chord moves - Ernst Levy (negative harmony, popularised by Jacob Collier); Hugo Riemann and the neo-Riemannian theory
- music notation glyphs - SMuFL / Bravura (Steinberg); the score export uses [LilyPond](https://lilypond.org)

The DSP module texts use descriptions from Chris Johnson's
[Airwindopedia](https://www.airwindows.com/) when it is installed.

## License

jf_tracker is source-available under the [PolyForm Shield License 1.0.0](LICENSE):

- use it for anything, including music you sell; change it;
- share it and your changes for free, with `LICENSE` and `NOTICE` kept;
- do not use it to make a product that competes with jf_tracker - paid or free
  (a fork sold or given away as another tracker); ask the author for other terms.

Author and the ideas behind it: [NOTICE](NOTICE). It comes with no warranty, and the
author is not liable for any damage. Modules, macros and other add-ons by other people
are their authors' responsibility - install them at your own risk.

Support: <https://ko-fi.com/jeeruff>. Music: <https://jeeruff.bandcamp.com>.
