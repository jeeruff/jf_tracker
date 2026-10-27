# Sources

Where an idea or code came from, under which license, and how it was used.
Every new borrowing gets a row here (and a line in NOTICE / README Credits).

| What in jf_tracker | Source | License | Used as | Checked |
|---|---|---|---|---|
| A tracker on REAPER's own timeline; the user key file (`jf_tracker_keys.lua`) | [Hackey-Trackey](https://github.com/JoepVanlier/Hackey-Trackey), Joep Vanlier | MIT | idea; no code | 2026-10-27: 4 equal lines, all plain REAPER API calls (`Undo_OnStateChange2`, `SelectAllMediaItems`, `Main_OnCommand(40289)`, `GetMediaItemTake_Source`); shared function names only `clamp delete insert round` |
| reform pane (`jf_tracker_reform.lua`) | [Reform](https://www.aqu.surf/reform) for Renoise, MOMarmalade | none stated - all rights reserved | idea only; code must not be copied | 2026-10-27: no equal lines, no shared function names |
| Parts of the editing commands | [Paketti](https://github.com/esaruoho/paketti) for Renoise, Esa Ruoho (Lackluster) | used with the author's permission | based on | permission covers the project; ask again for the PolyForm Shield terms |
| dsp big routing view | ParaNormal FX Router for REAPER, Sexan | - | idea only | own implementation |
| Orca field | [Orca](https://github.com/hundredrabbits/Orca), Hundred Rabbits | MIT | own implementation | no code copied |
| DSP module descriptions | Airwindopedia, Chris Johnson | - | read at run time from the user's install | not bundled |
| Bundled fonts (`fonts/`) | see `fonts/README.md` | OFL / MIT / others (`fonts/licenses/`) | bundled files | each keeps its license |

How the check is done: every `.lua` file of jf_tracker against the source, comments and
string contents removed, whitespace collapsed; equal lines of 30+ characters and equal
function names are listed (`tools/srccheck.py <source files>`).
