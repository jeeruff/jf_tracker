# jf_tracker API

A short description for people (and their LLMs) who want to control jf_tracker
from outside or write their own modules. Work in progress: all of this may
change before v1.0.

Paths below are relative to the REAPER resource folder
(*Options → Show REAPER resource path*).

## 1. The bridge: external programs and LLMs

jf_tracker starts no processes and speaks no HTTP. An external program talks to
it through one ExtState key and one answer file:

| | |
| --- | --- |
| request | ExtState section `jf_tracker`, key `llm_in`, value `id\|op\|payload` |
| answer | file `Data/jf_tracker_llm_out.txt`: first line `id`, then the answer text |
| done | ExtState `jf_tracker` / `llm_ack` is set to `id` after the file is written |

The tracker reads `llm_in` once per frame while its window runs. A request is
handled once: send a new, unique `id` every time (a timestamp works). The
answer goes to a file because the REAPER web interface cuts ExtState values at
about 995 characters.

Ops:

- `state` - a text snapshot: BPM, LPB, play state, cursor (row, track,
  instrument, mode), tracks, the lib (instruments) of the cursor track, the
  slots (regions) and the pattern rows of the cursor region (cell = note,
  instrument, volume; `|` held, `...` empty). Outside a region, `payload` is the
  number of rows to show (default 32, at most 128).
- `help` - empty payload: the documented `:commands` and the list of key help
  pages; payload = a page name (`tracker`, `insert`, `matrix`, `dsp`, ...):
  that page of keys.
- `run` - steps separated by `;;`. A step is a command line (`:lpb 8`, the
  leading `:` is optional) or keys (`keys:jjj`, `keys:<esc>`). In keys, letters
  are sent as typed; `<cr> <enter> <esc> <tab> <bs> <space> <up> <down> <left>
  <right>` are special keys. The answer lists what each step reported.
  Every `:command` is its own undo step; `u` in the tracker undoes it.

Other answers: `OFF: ...` (bridge is off), `BUSY: ...` (the previous run is not
finished), `DECLINED by the user`, `unknown op ...`.

### Writing ExtState from outside

**REAPER web interface** (*Preferences → Control/OSC/web → Add → Web browser
interface*, e.g. port 8080). URL-encode the value (`|` = `%7C`, space = `%20`):

```sh
curl "http://localhost:8080/_/SET/EXTSTATE/jf_tracker/llm_in/1001%7Cstate%7C32"
curl "http://localhost:8080/_/GET/EXTSTATE/jf_tracker/llm_ack"
# -> EXTSTATE  jf_tracker  llm_ack  1001   (tab-separated) when the answer is ready
cat ~/Library/Application\ Support/REAPER/Data/jf_tracker_llm_out.txt   # macOS path
```

Keep one request under ~900 characters; split a long `run` into several.

**A ReaScript** (runs inside REAPER, so it must not block - poll with `defer`):

```lua
-- ask_jf_tracker.lua: one request, prints the answer to the console
local id = tostring(math.floor(reaper.time_precise() * 1000))
reaper.SetExtState('jf_tracker', 'llm_in', id .. '|run|:lpb 8;;keys:jjj', false)
local out, t0 = reaper.GetResourcePath() .. '/Data/jf_tracker_llm_out.txt', reaper.time_precise()
local function poll()
  if reaper.GetExtState('jf_tracker', 'llm_ack') == id then
    local f = io.open(out, 'r'); local s = f:read('a'); f:close()
    reaper.ShowConsoleMsg(s:gsub('^[^\n]*\n', '') .. '\n')
    reaper.DeleteExtState('jf_tracker', 'llm_in', false)
  elseif reaper.time_precise() - t0 < 30 then reaper.defer(poll) end
end
poll()
```

**MCP.** The author uses a small Python MCP server (three tools:
`tracker_state`, `tracker_help`, `tracker_run`) that does exactly the web
interface calls above. It is not part of the release; the protocol above is all
you need to write your own client in any language.

### Turning it on (security)

Option *options → sound and samples → LLM / MCP bridge*, default **off**:

- `off` - the bridge only answers `OFF`;
- `ask` - `state` and `help` answer at once, every `run` waits for `y` (or `n`)
  in a tracker popup that shows the steps;
- `on` - runs at once.

Anything that can write ExtState (any script, or anyone who reaches the web
interface port) can drive the tracker when the option is `on`. Use `ask` unless
you trust the whole chain.

Known limits: closing the `ask` popup with Esc instead of `y` / `n` leaves the
run pending, and later runs answer `BUSY` until jf_tracker restarts. Delete
`llm_in` after you get the answer, so a restarted tracker does not see the old
request again.

## 2. Commands and keys

- `:help` (in the tracker) - the manual; `?` - the keys of the focused module.
- `:keys` writes every key page and the full list of `:commands` with their
  arguments to `Data/jf_tracker_keys.md`. `op help` lists only the documented
  commands, so give your LLM this file when it needs everything.
- `:` + Tab in the tracker completes command names.

## 3. Your own DSP modules

The DSP panel shows each plugin as a module of knobs. Your own layout wins over
the built-in one and the automatic one.

**Learn:** select a track FX block in the DSP panel and press `K` (module
learn). Turn knobs in the plugin window - they join the module. While learning:
`x` removes the selected knob, `J` moves it down, `<` `>` change the number of
columns (1-4), `X` / `Y` make it an axis of the XY pad, `R` resets to the
automatic layout, `K` or `Esc` finishes. Track FX only (not take FX or
containers).

**File:** `Data/jf_tracker/dspmods_user.txt`, one plugin per line, tab-separated:

```
name<TAB>title<TAB>cols<TAB>index:label,index:label,...[<TAB>xy:X:Y][<TAB>help:TEXT]
```

- `name` - the FX name as REAPER shows it, without the `VST: ` / `JS: ` /
  `CLAP: ` prefix, e.g. `ReaEQ (Cockos)`;
- `title` - shown title, empty = the name;
- `cols` - number of columns;
- `index:label` - plugin parameter index (0-based, as in
  `TrackFX_GetParamName`) and a short label, in display order; an empty label
  uses the plugin's own name. Labels cannot contain `,` `:` or tabs;
- `xy:X:Y` - optional: parameter indices for the X and Y axes of an XY pad
  (shown in the first column).
- `help:TEXT` - optional: the help of your module. When the module is selected
  in the DSP panel, the help pane (and `?`) shows it on top, tagged `module`,
  above the general DSP keys. `|` separates the lines; a line `key = what it
  does` becomes a key and its description, any other line is plain text. Learn
  keeps the field; edit it by hand. Say what the module is for first, then the
  knobs and keys that are not obvious:

  ```
  help:a tape echo with wow = what it is|time = delay in beats (synced)|fb = feedback; over 100 % it runs away|J K = preset (DSP keys)
  ```

The tracker does the same for its own places: in the tracker the help pane
starts with what you can do with the thing under the cursor (the wave, a note,
its volume / delay / command, an envelope, a MIDI lane), then every key.

Example:

```
ReaEQ (Cockos)	EQ	2	0:lo freq,1:lo gain,3:b2 freq,4:b2 gain	help:low shelf + one band = what it is|lo = the shelf|b2 = the band
```

The file is read when jf_tracker starts and rewritten (sorted by name) on every
learn edit. To share a module, share its line; to install one, add the line
(same name replaces) while the tracker is closed, then start it.

## 4. Custom modules (panes)

A custom module is one Lua file that becomes a pane of its own. jf_tracker loads
`modules/*.lua` (shipped with it) and `<REAPER resource>/Data/jf_tracker_modules/*.lua`
(yours) at start. `Ctrl+W c` + its letter shows and focuses it (`c f` - freesound).
The file returns a table:

```lua
local M = { id = 'hello', label = 'hello', letter = 'h', side = 'right',   -- letter: Ctrl+W c h
  about = 'one line for the hints pane',
  help = { { k = 'j k', d = 'move' }, { k = 'Esc', d = 'back to the tracker' } } }
function M.init(api) M.api = api end            -- once, when first shown
function M.draw(U, L, x, y, w, h, focused)      -- every frame while visible
  U.text(x + L.pad, y + 2, 'hello', focused and U.AMBER or U.TEXT)
end
function M.key(c, mods) return false end        -- true = the key is used
function M.typing() return false end            -- true while it takes text (keys skip Vim)
function M.paste(text) end                      -- optional: Cmd+V while typing
return M
```

`api`: `R` (reaper), `dir` (the jf_tracker folder), `TX` (UTF-8 typing helpers),
`msg(text)` (status line), `preview_file(path)`, `add_to_depot(path)` (into the lib of
the cursor track), `fit(text, px)`, `focus(id)`. `U` gives the theme colours
(`U.TEXT U.GREY U.AMBER U.GREEN U.RED U.BG U.PANEL`), `U.set(col)`, `U.text(x, y, s, col)`,
`U.measure(s)`; `L.rh` is the row height, `L.pad` the padding. Clicks: read `gfx.mouse_x`,
`gfx.mouse_y`, `gfx.mouse_cap` in `draw`. An error in a module shows in the status line
and does not stop the tracker. See `modules/freesound.lua` for a full one.
