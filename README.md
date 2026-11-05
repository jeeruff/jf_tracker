# jf_tracker

A tracker for REAPER. Vim keys, built like Emacs: a small core and a bunch of
modules around it.

This is my first big release. The whole thing is hugely experimental and made
for me - I'm sharing it because why not.

[README по-русски](README.ru.md)

## How it started

I just wanted to slice items in REAPER. REAPER on its own is already a great
sampler - not even RS5K, just REAPER itself. What it was missing was a fast way
to sequence those items. So that's the heart of it: the slicer cuts items and
changes their pitch, stretch and the other things REAPER can do with an item,
and a bit more.

Then I thought: using the stock effects is great. Take RS5K and make drumrs5k
out of it. Yes, that's a nod to Drum Rack, on purpose - it's damn handy.

Then I went further and made my own sampler, jf_slixer, part of the tracker
too, because that's where I found how I want to play, especially with
aftertouch. I'll show that in videos on my channel:
<https://www.youtube.com/@jeerufff>

I vibe-coded all of it with an AI assistant for myself and I'm not afraid to
say it. I'm a pro-level musician, I play in an orchestra, there's no time to
learn programming, and programmers wouldn't really build what I kept asking
for. I wanted my own experimental workflow and the features I'm used to and
think are cool, and I put them everywhere I could. Hundreds of hours. If you
like it too and making music from muscle memory is fun for you - I'll be really
happy. And it's a nod to chmaha, whose plugins were removed from the
repository.

## What's in it

- **Modules you can write yourself.** I wanted to open the gates early for
  people who want to add their own stuff. There's an API ([API.md](API.md)):
  paste it into your LLM and build what you need for this tracker.
- **Things the way I want them.** Some ideas exist elsewhere but are scattered
  or locked inside another ecosystem. Like an XY pad that remembers synth
  parameters - way nicer than two parameters on an XY pad that nobody ever
  touches.
- **Letters, not icons.** I'm against made-up symbols here. Letters and signs
  you can type are enough, and anyone who went to school gets them: Σ on the
  master is the sum, ξ in the sampler is random. More graphics may come later,
  but simple stays.
- **Vim all the way.** Modes, `dw`, `d3j`, `yy p`, counts, registers, the `.`
  repeat, the `:` command line. The mouse is optional.
- **Plain REAPER underneath.** Tracks, items, MIDI, regions, envelopes, FX.
  Close the window and the project plays on. Every edit is one undo.
- **PT-mode** for the old ProTracker feeling - the tracker a ton of jungle was
  made on.
- And a lot more: a pattern matrix, a sample lib and browser, a sample map,
  a DSP panel with containers and an XY morph, a harmonizer, 72-EDO microtones
  (MPE), a curve canvas for automation, panes like tmux.

It's still an experiment in progress, but I made it for myself the way I wanted
it to be, so I decided to share it with whoever is interested.

Big up - make music and send me what you made with this tracker. Videos, clips,
anything. That would be awesome.

If it makes you as happy as it makes me, buy me a coffee:
<https://ko-fi.com/jeeruff>

## Requirements

- REAPER 7 (macOS is the tested platform; Windows / Linux are untested).
- [SWS extension](https://www.sws-extension.org/), used for preview through
  `CF_Preview`.
- [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174), used for
  key state and window handling.

Both extensions are available through [ReaPack](https://reapack.com/).

## Install

Through ReaPack: *Extensions → ReaPack → Import repositories…*, paste

    https://jeeruff.com/jf_tracker/r/open/index.xml

then *Browse packages → jf_tracker → Install*. New versions come with
*Synchronize packages*.

One REAPER setting: turn off *FX: Auto-float new FX windows* (type `:autofloat`
in the tracker). Otherwise every new effect opens its window, and that window
takes the keyboard away from the tracker.

By hand instead of ReaPack:

1. Copy the `jf_tracker` folder into REAPER's `Scripts` folder. In REAPER,
   *Options → Show REAPER resource path* shows where that is.
2. Copy every file of `effects/` into REAPER's `Effects` folder. The tracker
   puts them on tracks by itself when a feature needs them:
   - `jf_rec` - the retro sampler (what you played, caught after the fact);
   - `jf_tracker_scope` - the oscilloscope / spectrum of the scopes;
   - `jf_tracker_trig` - a note-on when a sample item starts (note mod);
   - `jf_tracker_probe` - a level meter between effects (gain staging in the router);
   - `jf_tracker_zone` - key / velocity / chain zones of a rack, as in Ableton;
   - `jf_tracker_choke` - pad groups and choke groups of the drum rack;
   - `jf_tracker_chordfollow` - notes of a track follow the chord lane.
3. Open *Actions → Show action list → New action → Load ReaScript…* and pick
   `jf_tracker.lua`.

## First steps

Run the script and press `:tutorial`, or take the tour from the main module.
In short:

| Keys | What they do |
| --- | --- |
| `h j k l`, `gg` / `G`, `{ }` | Move: by cell, to the start / end, by bar. |
| `i` | INSERT, as in Vim: the keyboard writes notes. `q 2 w 3 e r 5 t …` write notes, `z` / `x` change the octave. |
| `Esc` | Leaves INSERT. It also enters it - a habit kept from Renoise (with the keyboard on, `i` is a note, so `Esc` is the way in). |
| `x`, `dw`, `yy p`, `u`, `.` | Delete, delete with a motion, copy and paste, undo, repeat. |
| `v` / `V` | Select a block / whole rows. |
| `:` | The command line. Tab completes. |
| `\` | The leader menu, or the context menu of the focused module. |
| `Space` | Play / stop. |
| `?` | The keys of the focused module. |

To drive the tracker from other programs or LLMs, or to write your own DSP
modules, see [API.md](API.md).

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

PT-mode is ProTracker on the Amiga as a rule, not a skin: four channels, 31 samples, 64-row patterns, one
command per cell, a big font. Igor Stravinsky (*Poetics of Music*): the more narrowly I limit my field of
action, the freer I am - I am free only when I am limited.

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

All product and company names above are trademarks of their respective owners. They are named
only to say where an idea came from; jf_tracker is not affiliated with or endorsed by any of them,
and uses none of their graphics or sounds; the only code taken from others is listed with its
license in [SOURCES.md](SOURCES.md) (for example the Airwindows ports, MIT).

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
