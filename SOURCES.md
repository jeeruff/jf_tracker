# Sources

Where an idea or code came from, under which license, and how it was used.
Every new borrowing gets a row here (and a line in NOTICE / README Credits).

| What in jf_tracker | Source | License | Used as | Checked |
|---|---|---|---|---|
| A tracker on REAPER's own timeline; the user key file (`jf_tracker_keys.lua`) | [Hackey-Trackey](https://github.com/JoepVanlier/Hackey-Trackey), Joep Vanlier | MIT | idea; no code | 2026-10-27: 4 equal lines, all plain REAPER API calls (`Undo_OnStateChange2`, `SelectAllMediaItems`, `Main_OnCommand(40289)`, `GetMediaItemTake_Source`); shared function names only `clamp delete insert round` |
| reform pane (`jf_tracker_reform.lua`) | [Reform](https://www.aqu.surf/reform) for Renoise, MOMarmalade | none stated - all rights reserved | idea only; code must not be copied | 2026-10-27: no equal lines, no shared function names |
| Parts of the editing commands | [Paketti](https://github.com/esaruoho/paketti) for Renoise, Esa Ruoho (Lackluster) | used with the author's permission | based on | 2026-10-27: Esa allows any use; asks for his Patreon in the credits (README, NOTICE) |
| dsp big routing view | ParaNormal FX Router for REAPER, Sexan | - | idea only | own implementation |
| Orca field | [Orca](https://github.com/hundredrabbits/Orca), Hundred Rabbits | MIT | own implementation | no code copied |
| DSP module descriptions | Airwindopedia, Chris Johnson | - | read at run time from the user's install | not bundled |
| trackers - rows, hex, the note-vol-fx cell, F1 / F2 octaves, Esc as edit | ProTracker, FastTracker, Impulse Tracker, [Renoise](https://www.renoise.com), [Furnace](https://github.com/tildearrow/furnace), [Dirtywave M8](https://dirtywave.com) | - | idea only | own code |
| modes, operators and motions | [Vim](https://www.vim.org) (Bram Moolenaar) | - | idea only | own code |
| a menu of what a prefix key does next | [which-key.nvim](https://github.com/folke/which-key.nvim) (folke) | - | idea only | own code |
| marked files and folder columns in the browser, lib marks | [lf](https://github.com/gokcehan/lf) (gokcehan), ranger, Midnight Commander | - | idea only | own code |
| fuzzy search syntax | [fzf](https://github.com/junegunn/fzf) (Junegunn Choi) | - | idea only | own code |
| jumps to the most used folder (:z) | [zoxide](https://github.com/ajeetdsouza/zoxide) (Ajeet D'Souza) | - | idea only | own code |
| quick marks to jump back | [harpoon](https://github.com/ThePrimeagen/harpoon) (ThePrimeagen) | - | idea only | own code |
| panes, splits and the pane mode | [tmux](https://github.com/tmux/tmux), [zellij](https://zellij.dev) | - | idea only | own code |
| the pattern grid of codes A1 B2 ... | Polyend Tracker, Elektron sequencers | - | idea only | own code |
| clips, scenes and launching | Ableton Live (Session View), Bitwig Studio | - | idea only | own code |
| note keys that play patterns (patternkb), pads | Akai MPC | - | idea only | own code |
| spam: a moved slice edge rolls | Roland SP-404 | - | idea only | own code |
| the sniper zoom of a slice edge | Xfer Nerve (Steve Duda) | - | idea only | own code |
| dense parameter groups of the slixer panel | Madrona Labs Aalto and Kaivo | - | idea only | own code |
| ring knobs | Nagra / Kudelski recorders | - | idea only | own code |
| the sample map as a graph | [Obsidian](https://obsidian.md) graph view; sample browsing by sound - Sononym | - | idea only | own code |
| the monome grid and arc pages | [monome](https://monome.org) | - | idea only | own code |
| negative harmony; P / R / L chord moves | Ernst Levy (negative harmony, popularised by Jacob Collier); Hugo Riemann and the neo-Riemannian theory | - | idea only | own code |
| music notation glyphs | SMuFL / Bravura (Steinberg); the score export uses [LilyPond](https://lilypond.org) | - | idea only | own code |
| Bundled sample `samples/amen_8bit.mp3` (the amen pattern re-made in 8-bit, not the original recording) | ["8bit amen break" by D0tDashDialUp on Freesound](https://freesound.org/people/D0tDashDialUp/sounds/626105/) | CC0 1.0 | bundled file (Freesound HQ preview) | unchanged |
| Bundled fonts (`fonts/`) | see `fonts/README.md` | OFL / MIT / others (`fonts/licenses/`) | bundled files | each keeps its license |

How the check is done: every `.lua` file of jf_tracker against the source, comments and
string contents removed, whitespace collapsed; equal lines of 30+ characters and equal
function names are listed (`tools/srccheck.py <source files>`).
- ProTracker 2.3D command letters for PT-mode (jf_tracker_ptfx.lua): the idea of the command set only, own code.
- VHS frame "enhancer" ringing and sync wobble (jf_tracker_draw.lua D.vhs): idea from oopsyte's analog video glitch box emulator (r/videosynthesis post, Nov 2026) - the idea only, own code.
