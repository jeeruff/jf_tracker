-- jf_tracker_keyhelp.lua — контекстная справка по клавишам (2 окт).
--
-- `?` (или кнопка «? help» в контроле) включает режим справки: нижняя
-- панель (место DSP) показывает клавиши того модуля, где сейчас фокус, —
-- трекер (NORMAL / INSERT), матрица, инструменты, браузер, DSP, вкладки
-- дока. Справка не перекрывает рабочие области: у неё своё место внизу.
--
-- Нажатая в модуле клавиша подсвечивает свою строку справки и рассыпает
-- вокруг неё ASCII-взрыв из точек. Фокус на самой справке (Tab или клик):
-- набор текста — fzf-поиск по всем страницам (термы через пробел, буквы
-- по порядку), стрелки влево/вправо — страница, вверх/вниз — прокрутка,
-- BS — стереть, Esc — очистить поиск, второй Esc — назад к модулю.
--
-- Без reaper.*: время приходит параметром, тестируется стабами.

local KH = {}
KH.query = ''
KH.page = 'tracker'
KH.pinned = false        -- страницу выбрали стрелками в самой справке
KH.scroll = 0
KH.flash = nil           -- { page=, i=, t0=, seed= }
KH.last = nil            -- { tok=, t= } — для двухклавишных dd / yy / gg

local LEFT, RIGHT, UP, DOWN = 1818584692, 1919379572, 30064, 1685026670

-- k — как клавиша написана в справке; t — явные токены (иначе k по пробелам)
KH.PAGES = {
  -- первая страница (3 окт): что это и почему так близко к REAPER
  intro = { title = 'jf_tracker - what it is', e = {
    { k = 'idea', t = {}, d = 'build a whole track from the keyboard in one window: patterns, their order, sounds; mixing later in REAPER on the same tracks' },
    { k = 'native', t = {}, d = 'the tracker is a view, REAPER is the engine: tracks, items, MIDI, regions, envelopes, FX - no format of its own' },
    { k = 'why', t = {}, d = 'nothing to export or lose: close the window and the project plays and edits as usual; tempo map, routing, render, other scripts keep working; every edit is one REAPER undo step' },
    { k = 'lib', t = {}, d = 'the sounds you play (right panel): every audio item of the project, one entry per sound; library entries sit on their track after the =LIB marker' },
    { k = 'linked', t = {}, d = 'notes of a lib entry are linked copies: change it in the item panel and all its notes follow; a stretched note becomes unique (or apply to all)' },
    { k = 'item', t = {}, d = 'item tab (top): the selected lib entry - wave, slices, properties, preview, beatsync' },
    { k = 'macro', t = {}, d = ':macro - bird view: a row is a bar; density and first note per track, region names; j k bars (J K by 4), h l tracks, Enter / Esc back on that bar' },
    { k = 'pt', t = {}, d = ':pt - PT-mode, a dumbed-down ProTracker view: exactly 4 channels from the scroll, note / sample / vol / one command, no waves or envelopes, LPB 4, bitmap x4 (smaller if 4 do not fit), scopes on top; :pt new creates CH1..CH4 in the project; :pt again restores everything' },
    { k = 'arp', t = {}, d = ':arp [up|down|updown|random|played] [step] [octaves] [gate%] - the chord on the cursor row (notes in the subcolumns of the track) becomes an arpeggio over its length' },
    { k = 'slices', t = {}, d = 'notes (INSERT + m): a sliced sample - the key picks the slice (q 2 w 3 ... = S01 S02 ...); not sliced - the sample at that pitch. Option+note - the selected slice (or the whole item if whole is selected) at that pitch; Cmd+note - the whole item at that pitch; Ctrl+note - held note (length = how long). Select: the slice list (its keys), Cmd+J / K, the last played' },
    { k = 'Opt+J / K', d = 'previous / next instrument of the lib (samples, plugins, automation; a count jumps N)' },
    { k = 'Opt+1..0', d = 'instrument 1..10 of the lib' },
    { k = 'Cmd+1..0', d = 'jump to channel 1..10 (Ctrl+O - back); in INSERT Cmd+digit is a note' },
    { k = 'Ctrl+0..9', d = 'step length 0..9 rows (0 - the cursor stays); step auto off' },
    { k = 'Ctrl - +', d = 'step down / up by one, in any mode (as in Renoise); - + alone - LPB (NORMAL, INSERT on the note field); Cmd - + - font size' },
    { k = '? Tab', t = {}, d = 'this help follows the focused module; Tab here: search all pages, left / right: pages' },
  } },
  pane = { title = 'panes (tmux / zellij)', e = {
    { k = '\\ (in a module)', d = 'quick menu of the module in focus (its main actions, letters); in it \\ - the main menu' },
    { k = 'zz', d = 'in any module (lib, browser, fx list, item, macros ...): the module on the whole window, again - back; in the tracker - the tracker alone; matrix zz - session, dsp zz - dsp big', t = { 'z' } },
    { k = '⌘h ⌘j ⌘k ⌘l', d = 'focus the pane on the left / below / above / on the right (like dwm), from any pane' },
    { k = '⌘⇧h ⌘⇧j ⌘⇧k ⌘⇧l', d = 'move the pane there (out of its stack if it is a tab)' },
    { k = '⌥Tab', d = 'next pane in the tree order (Shift - back)' },
    { k = 'Ctrl+W', d = 'pane mode (sticky, Esc out): the keys below, the pane numbers on the borders' },
    { k = 'h j k l  H J K L', d = 'focus / move by direction' },
    { k = 'w W  1..9', d = 'next / previous pane, pane by number' },
    { k = 'g + key', d = 'go to a panel (a hidden one appears): m matrix b browser l lib n main s slices o notes f fx d dsp r rec i item a automation M midi h harmonizer c scopes S master v video V visor' },
    { k = 's v + key', d = 'split below / right with that panel (it moves here)' },
    { k = 'T + key  B', d = 'that panel into this stack (a tab) / this tab out of the stack' },
    { k = 'X + key  x', d = 'swap with that panel / with the last focused' },
    { k = '+ -  < >  =', d = 'height / width / equal in the parent' },
    { k = 'z', d = 'zoom the pane to the window, again - back (also :big for item)' },
    { k = 'c', d = 'hide the pane (g + key brings it back)' },
    { k = 'Space  u', d = 'next layout (main-left, main-right, wide, stack, tracker) / undo' },
    { k = ':pane', d = ':pane dsp with item, :pane browser hide | show | left | right, :pane matrix zoom, :pane reset, :pane wide; no argument - the layout string' },
    { k = 'mouse', t = {}, d = 'click - focus; click a title - that tab; drag the line between panes - size, dblclick - equal; right-click a title - hide' },
  } },
  tracker = { title = 'tracker NORMAL / VISUAL', e = {
    { k = 'h j k l', d = 'field left / row down / row up / field right' },
    { k = 'H L', d = 'previous / next track' },
    { k = 'w b e', d = 'next / previous event of the track (all its columns and envelope points, like words in Vim), end of event; dw yw cw - this column' },
    { k = 'W B', d = 'next / previous event in any column (cursor jumps there)' },
    { k = 'env: w b e dd y p', d = 'envelope points are events: motions, delete / yank / paste points (value + shape)', t = {} },
    { k = 'gg G', d = 'first row / last row' },
    { k = 'Esc', d = 'toggles INSERT (as the edit mode in Renoise): NORMAL -> INSERT, INSERT -> NORMAL; option Esc mode = vim - only back to NORMAL' },
    { k = "` Ctrl+O / Ctrl+I", d = "jumps: back / forward to where you were before a jump (f label, harpoon); ` - back without Control (in INSERT ` stays note-off)" },
    { k = "'a '1..'9 '' 'd", d = "harpoon: pin the place under the cursor - a track row (tracker), a cell (matrix) or a parameter (DSP); jump to pin 1..9 (the focus goes to its module), list the pins by module (fzf), unpin; works in the tracker, the matrix and DSP; per project" },
    { k = 'gw  3gw', d = 'swap the event under the cursor with the next / the 3rd below (:sw N)' },
    { k = 'gs  Ctrl+Enter  middle click', d = 'smart panel (as in PlayerPro): a grid of the values of the field under the cursor - notes, volume, delay, command letter then value, instrument, envelope / CC; pick with a left or middle click or h j k l + Enter; VISUAL - the whole block' },
    { k = ':scramble', d = 'slice notes swap their slices randomly (VISUAL, else the track in the region; button in the item tab)' },
    { k = '{ }', d = 'bar back / forward' },
    { k = 'x', d = 'delete event under cursor' },
    { k = 'd', d = 'd + motion deletes events: dw d3j dG d}; dd (NORMAL) deletes the track, in INSERT the event of the row', t = { 'd' } },
    { k = 'dd dt', d = 'delete the track / remove the time selection from the project (later items move)', t = { 'dd', 'dt' } },
    { k = 'dW', d = 'delete the whole item under the cursor' },
    { k = 'dp', d = 'delete up to the pause: the run of events of the cursor lane from the cursor down to the first empty row (like d} in Vim); on an empty row - the next run' },
    { k = 'dP', d = 'delete every item and all automation (envelope points, automation items) of the selected tracks in the whole project (no selection - the cursor track); one undo' },
    { k = 'C-A-j', d = 'repeat the part of the region above the cursor down to the region end: Ctrl+Opt+J (or Down) - this track; :repeat all - all tracks (Paketti)' },
    { k = 'S-A-j S-A-k', d = 'transpose the instrument selected in the lib -1 / +1 semitone (a count - by N)' },
    { k = 'S-A-h S-A-l', d = 'playrate of the instrument selected in the lib -0.01 / +0.01 (a count - by N)' },
    { k = ':mcmd', d = 'master column cmd = project markers on rows: Enter - edit the command of the row, ! - a REAPER action (marker !<id> - REAPER runs it when playback passes), BS / Del / x - delete; :mcmd <text> sets it, :mcmd alone deletes' },
    { k = 'dr daw', d = 'clear the track in the cursor region / all items of the track (the lib after =LIB stays)', t = { 'dr', 'daw' } },
    { k = 'yy p P', d = 'copy rows / paste after / before', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'c s', d = 'replace / split the event (mute events: select with v, then M)', t = { 'c', 's' } },
    { k = 'M S', d = 'mute / solo the cursor track (Shift+m / Shift+s)', t = { 'M', 'S' } },
    { k = '^A ^X', d = 'field value +1 / -1' },
    { k = 'r', d = 'set value of field' },
    { k = 'u ⌘⇧Z .', d = 'undo / redo / repeat last edit' },
    { k = '^R', d = 'the rec tab' },
    { k = 'F12', d = 'reload the audio device (as choosing it again; options - audio)' },
    { k = '⌥R ⌘R', d = 'record into the tracker from the cursor / a new sound into the lib; then Space keep, Enter keep + back, Esc delete' },
    { k = 'q @', d = 'record macro / play macro' },
    { k = 'v V', d = 'visual block / visual lines' },
    { k = 'H J K L', d = 'select: visual block from here, Shift+hjkl extends it (tracks: Option+h l)' },
    { k = 'za zM', d = 'fold track: wave + notes, envelopes as a thin line / all <-> open all (:fold, :unfold)' },
    { k = 'zr zR', d = 'router: the fx chain of the cursor track with its routing in place of the tracker / big router over the whole window' },
    { k = 'zC', d = 'fold track into a one-letter strip' },
    { k = 'z> z<', d = 'all tracks one field wider / narrower (as Cmd + horizontal wheel; 3z> - three steps)' },
    { k = 'z. z,', d = 'the cursor track wider / narrower (its own width)' },
    { k = ':reg', d = 'view only the region of the cursor / whole track (all | reg above the region name)' },
    { k = 'env: field 2', d = 'segment shape: INSERT letters sqr slo fas fae bez, ^A ^X cycle, :shape fas' },
    { k = 'env: Ctrl+Opt+1..6', d = 'segment shape of the point on the row, in any field and mode: 1 lin 2 sqr 3 slo 4 fas 5 fae 6 bez' },
    { k = 'i', d = 'INSERT: keyboard plays notes (Ableton layout)' },
    { k = 'a', d = 'envelope columns of all tracks on / off' },
    { k = 'A', d = 'automate: pick any parameter of the track (fzf) - envelope column, or a take envelope of the note' },
    { k = 'Opt+A', d = 'the last touched parameter (a knob you just moved, any track) - its envelope column, cursor there' },
    { k = 'ze', d = 'on an envelope column: its view - c curve, v values (like a command column), s steps (a fader on every row, as a 303 step sequencer: square points, drag across the rows with the mouse in any mode)' },
    { k = '> < N>', d = 'loop: item to region / region to item / N rows', t = { '>', '<' } },
    { k = '[ ] ( )', d = 'octave down / up, instrument previous / next' },
    { k = '/', d = 'commands at the cursor (fzf): the actions of the cell, the keys of the module, :commands - content is found with f (jump labels)' },
    { k = 'n N *', d = 'next / previous match of the last search, search the name under the cursor' },
    { k = ':', d = 'command line (Tab completes)' },
    { k = '\\', d = 'the main menu of everything (v view, P project, o options ...)' },
    { k = '\\\\', d = 'the context menu: what can be done with what is under the cursor (the same as the right click)' },
    { k = '?', d = 'any REAPER action in the tracker style (fuzzy, the recent ones on top)' },
    { k = 'F1 Shift+F1', d = 'the help (all modules, / searches it) / the tutorial' },
    { k = '^/ ⌥/ ⌘/', d = 'search: all effects / the DSP chain of the track / files' },
    { k = '\\Ps', d = 'save project (\\PS: save as)' },
    { k = 'f', d = 'hint labels: jump anywhere by two letters' },
    { k = 'tt', d = 'new track after the cursor track (3tt - three)' },
    { k = 'Opt+F1 F2', d = 'transpose the selection (else the note of the row) -1 / +1; F11 F12 - an octave (as in Renoise)' },
    { k = 'Shift+F1 F2', d = 'transpose the track in the pattern; Ctrl - the whole pattern, Shift+Ctrl - the column; F11 F12 - by octave' },
    { k = 'zt', d = 'the cursor row to the top (as in Vim)' },
    { k = 'gt  gT', d = 'module tab / REAPER project tab - a menu (Ngt, NgT - the Nth at once)' },
    { k = ':transpose', d = 'transpose popup: -24..+24 and where - selection / column / track / pattern (also the right-click menu); :transpose N - the selection by N' },
    { k = 'td tx tp', d = 'delete (= cut, as d in Vim) / cut N tracks from the cursor track (5td - five), paste them after the cursor track; dd deletes rows (5dd - five)' },
    { k = 'ts', d = 'new track "send": the selected tracks (or the cursor track) send into it - a bus / fx return' },
    { k = 'tr', d = 'new track "source": it sends into the selected tracks (they get a receive)' },
    { k = 'tn tc', d = 'track: rename / colour (list: palette, random, default, custom dialog)' },
    { k = 'ty', d = 'duplicate the cursor track (copy right after it)' },
    { k = 'ta ti', d = 'track: rec arm / input (list)' },
    { k = 'tI', d = 'track input: the active source - play it within 0.6 s (a MIDI key -> that device and channel, else the audio input that started sounding last, stereo if its pair sounds too); your jf_smart_set_input.lua' },
    { k = 'tl tf', d = 'track: fixed lanes on / off / add fx (fzf)' },
    { k = 'tR', d = 'track routing: sends S, receives R, hw outs O (popup)' },
    { k = 'tj tk', d = 'move the track right / left (3tj - three places)' },
    { k = 'mouse', d = 'right drag: select a block (a right click without moving: the menu); left drag: move the event or the selected block under the mouse; Shift+drag: extend the block (option select block with = left swaps the buttons)' },
    { k = '2f', d = 'mixer: f on a dB mark glides the fader there in 2 bars (2,f - beats); from the next session quantize when playing, from the cursor when stopped; the mark typed in CAPITALS (Shift) dips: there in the first half, back in the second (no count - 1 bar)' },
    { k = 'Ctrl+mouse', d = 'hold Control and move the mouse: the selected params / faders change (else the one under the mouse, else the keyboard slider); up = more, Shift fine; two selected = XY. Cmd+click: add / remove, Shift+click: a range of params of one effect, Esc: clear' },
    { k = 'Ctrl+Opt+mouse', d = 'tracks gesture: the window width is split into one zone per track - move sideways to pick a track, then up / down moves its fader (Shift fine); clearly sideways again picks another; + Cmd: the whole window is a pan pad for that track - sideways pan / balance, up wider, middle 0, down narrower / reversed (dual pan: L and R apart up, crossed down)' },
    { k = 'Cmd+Shift+1..9', d = 'select / unselect channel N in REAPER - f on a dB mark moves all selected faders (macOS keeps Cmd+Shift+3 4 5 for screenshots unless you turn those off)' },
    { k = 'F11', d = 'fullscreen <-> docked (quick option title: title bar on / off)' },
    { k = 'm', d = 'keyboard on / off: on - it has priority, q 2 w 3 e ... play notes, z x octave, Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'zm', d = 'mixer on / off' },
    { k = 'Tab Shift+Tab', d = 'next / previous track (in the matrix - the next / previous track column)' },
    { k = 'Opt+note', d = 'chord typing (letter keys; Option+digits pick instruments): the note goes to the next subcolumn of the row (a new one if needed), the cursor follows; all chord notes ring while you type, a 1.5 s pause ends the chord (length = typing time) and the cursor goes below it' },
    { k = 'keys button', d = 'keyboard on / off (also m; quick options keys): on - it has priority, q 2 w 3 e ... play notes, z x octave, Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'Space Enter', d = 'play / stop, move edit cursor here' },
    { k = 'F', d = 'follow playhead on / off' },
    { k = 'o', d = 'reveal item in REAPER' },
    { k = 'BS Ins', d = 'delete / insert time in region (Shift: all tracks)' },
    { k = 'Tab S-Tab', d = 'focus next / previous module; Option-Tab: dock tabs' },
    { k = 'Cmd-Enter', d = 'focus the instruments (lib)' },
    { k = ':cc', t = {}, d = 'CC lane: ReaControlMIDI on the cursor track (its window opens the first time - set the CC numbers there), pick its parameter - the envelope becomes a column: hex per row, curves, automation items' },
    { k = 'S-Esc', t = {}, d = 'remove the REAPER time selection (any module)' },
    { k = 'Opt-Enter', d = 'select the instrument of the note under the cursor in the lib' },
    { k = '\\\\q \\\\Q', t = {}, d = 'context menu on a sample: q - the nearest peak onto the row grid; Q - pick the peak, j k to a row, Enter moves it there (stretch marker)' },
    { k = 'vol xx', t = {}, d = 'on any row inside a sample (INSERT, vol field): a point of its take volume envelope - ramps by values, as in Renoise; x-fade by vol writes its ramps the same way (options: x-fade by)' },
    { k = '/ in a name', d = 'renaming a track, instrument, item or region: / lists common names (your SWS auto-colour rules + kick, pad, bell, texture ...), type to filter' },
    { k = 'F1', d = 'manual' },
    { k = 'F2', d = 'back to the tracker from anywhere (closes the routing diagram, big router / chain); the item tab is in the F3 circle' },
    { k = 'F3', d = 'modulate; again - the next tab in a circle' },
    { k = 'F4 F5 F6', d = 'midi / scopes / master; the same key again - back to the tracker' },
    { k = 'help', d = 'this panel: the help button of the main module; F1 - the whole help' },
    { k = 'Ctrl+ Ctrl-', d = 'bitmap scale x1..x4' },
  } },
  insert = { title = 'tracker INSERT (keyboard)', e = {
    { k = 'q2w3er5t6y7ui9o0p', d = 'piano: top row + digits, q = C of the octave',
      t = { 'q', '2', 'w', '3', 'e', 'r', '5', 't', '6', 'y', '7', 'u', 'i', '9', 'o', '0', 'p' } },
    { k = 'Shift+note', d = 'audition only, nothing written', t = { 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P' } },
    { k = 'Option+note', d = 'insert beside: new subcolumn, the old note keeps playing' },
    { k = 'Ctrl+note', d = 'capture (planned): sound of the channel as audio' },
    { k = 'h j k l', d = 'field / row' },
    { k = 'H L G g', d = 'track left / right, last row / first row' },
    { k = 'b n', d = 'bar back / forward' },
    { k = 'z x', d = 'octave down / up' },
    { k = 'c C', d = 'velocity -8 / +8' },
    { k = ', .', d = 'instrument previous / next' },
    { k = 'a', d = 'step auto: jump past the inserted item' },
    { k = 's', d = 'select from here (visual; the edit returns to INSERT); Shift+hjkl extends' },
    { k = '⌥s', d = 'step: type rows (:step N)' },
    { k = 'd', d = 'Vim delete operator (d3w, dd), back to INSERT after' },
    { k = 'M', d = 'mute event under cursor (Shift+m)' },
    { k = 'f', d = 'next fx field (note > fx1 > fx2 ...)' },
    { k = '` ~ C-`', d = 'note-off: ` this subcolumn, ~ (Shift+`) the whole track, Ctrl+` every track; :off / :off all' },
    { k = 'Esc', d = 'back to NORMAL' },
    { k = 'F1', d = 'the whole help' },
  } },
  matrix = { title = 'matrix of regions (slots)', e = {
    { k = 'h j k l', d = 'cell: track left / slot down / slot up / track right' },
    { k = 'gg G', d = 'first slot / last slot' },
    { k = 'w b e', m = 'next / previous slot with a pattern', d = 'next / previous slot with a pattern (free bars .. skipped) / the last bar before the next slot' },
    { k = '0 ^ $', d = 'name column / last track' },
    { k = 'D BS Del', m = 'delete the slot / cut the cell', d = 'on the slot number or name - delete the slot (like dd); on a cell - cut it (like x)' },
    { k = 'Enter', m = 'pattern number / rename', d = 'on the slot number: type the pattern number (:pat N); on the name - rename; < > - previous / next pattern' },
    { k = 'o O', d = 'new empty 1-bar slot after / before' },
    { k = 'dd', d = 'delete slot: region + its time (goes to register)', t = { 'dd', 'd' } },
    { k = 'yy', d = 'yank slot into register', t = { 'yy', 'y' } },
    { k = 'yp', m = 'duplicate: free copy, new name', d = 'duplicate: an exact copy with a new name, not linked (button cln) - like Renoise', t = { 'yp' } },
    { k = 'p P', d = 'put register after / before (cells: paste at cursor)' },
    { k = 'A', m = 'alias: linked repeat of the slot', d = 'alias: the slot repeated linked - same pattern, MIDI pooled and items grouped, edits in one change all (button als; also p of a yanked slot whose pattern still exists)' },
    { k = 'U', m = 'make unique: unlink this repeat', d = 'make unique: unlink the repeat under the cursor - new name, own MIDI pool, no group' },
    { k = 'x', d = 'cut cell (or block) to clipboard' },
    { k = 'n', d = 'rename region' },
    { k = '=', d = 'type length: N steps, Ns seconds, Nb bars' },
    { k = '[ ]', d = 'length -1 / +1 bar (later slots move)' },
    { k = '{ }', d = 'length -1 / +1 step' },
    { k = '< >', d = 'switch pattern of slot (previous / next)' },
    { k = 'h past the first track', m = 'cursor to the region name and number', d = 'the cursor goes to the region name (Enter / i - rename) and to its number < NN > (Enter - next pattern)' },
    { k = 'Ctrl+h j k l', d = 'move like h j k l' },
    { k = 'Ctrl+Up Down', m = 'duplicate the slot above / below', d = 'duplicate the slot above / below, muted tracks left empty in the copy (Paketti)' },
    { k = 'M', d = 'mute / unmute cell (Shift+m)' },
    { k = 'Space', d = 'play from slot, or queue it while playing' },
    { k = 'F', m = 'sel: only the tracks of the selected cells', d = 'sel: the tracker shows only the tracks of the selected cells (button sel; Cmd+click a cell adds it, Esc clears)' },
    { k = '+ N+', m = 'new region at the end (N+: N regions)', d = 'new region at the end (N+: N regions, one undo); n names it' },
    { k = 'v HJKL', d = 'block select; in block: y copy, d x cut, M mute', t = { 'v', 'H', 'J', 'K', 'L' } },
    { k = '^C ^X ^V ^N', d = 'block copy / cut / paste / mute' },
    { k = 'u ⌘⇧Z', d = 'undo / redo' },
    { k = 'zz zi', d = 'session: clips over the whole window / zoom detail', t = { 'z' } },
    { k = 'f', m = 'fill: lit cells or an empty grid', d = 'fill: cells show their content (lit) or stay an empty grid - only the view' },
    { k = 't', m = 'trim: cut items past their region', d = 'trim: cut items that run past their region (the button trim)' },
    { k = 'R', m = 'ruler of bars on / off', d = 'ruler of bars on the left on / off (button ruler)' },
    { k = 'wheel', t = {}, d = 'mouse over the matrix, no focus needed: wheel - slots, horizontal wheel / Shift - tracks; zoom as in the tracker (option zoom with: cmd - Cmd + multiscroll both ways; split - Cmd horizontal, Option vertical, as in REAPER); scroll bars right and bottom' },
    { k = 'Esc Tab', d = 'next module' },
  } },
  inst = { title = 'lib', e = {
    { k = '!', d = 'Shift+1 anywhere: listen to the selected instrument (its length, through the cursor track)' },
    { k = 'j k', d = 'instrument down / up' },
    { k = 'J K', d = 'move the sample down / up in the lib - the numbers follow (also drag a row with the mouse)' },
    { k = 'g G', d = 'first / the bottom row - midi clips (G; Cmd+G from anywhere - automation)' },
    { k = 'h l', d = 'track left / right' },
    { k = 'dd', d = 'cut instrument: its events on the tracks and the library item (to the register)' },
    { k = 'yy', d = 'yank instrument to the register' },
    { k = 'p P', d = 'put a copy from the register into the cursor track library (new name if taken)' },
    { k = 'yp', d = 'duplicate the instrument (copy into the library)', t = { 'yp', 'yP' } },
    { k = 'v', d = 'range from here: j k extend, d / x cut, y yank, Esc' },
    { k = 'Enter s', d = 'open in sample tab (slicer)' },
    { k = '~~', t = {}, d = 'automation: the last row - automation items of the track as one instrument (j past the last slot); the slices list shows them, a note key / MIDI note inserts the selected one, rate by the key (C-4 = x1, octave up = x2); Opt+Enter on an automation item picks it' },
    { k = 'r', t = {}, d = 'slices list: slice mode - by key / random (any slice key inserts a random slice of the sample, never the same twice) / sequence (the next one); also l in the insert menu' },
    { k = '##', t = {}, d = 'midi clips: the row under automation - MIDI items of the track (a in the slices list: the whole project); j k pick, a note key / MIDI note inserts a copy at the cursor (C-4 = as is, else transposed; the original stays), Enter / double click - go to the clip (Ctrl+O back); a click / j k previews it through its track (no transport), Space stops' },
    { k = 'Space', d = 'preview (how its note sounds: offset, rate, pitch); Esc stops' },
    { k = 'a', d = 'preview on select on / off (button preview; rclick: full / hold / first second)' },
    { k = 'bsync', d = 'header button: beatsync - the item lasts N beats at the tempo where each note sits (wheel in the item panel: N)' },
    { k = 'linked', d = 'every note of an item is linked to it: the item panel changes all of them; a stretched / offset note becomes unique - the question offers a: apply to all' },
    { k = '/', d = 'fzf find instrument' },
    { k = 'f', d = 'hint labels: jump to an instrument (focus moves here)' },
    { k = '..', d = 'empty slot: retro p / Enter puts the capture here; drop a retro / sample selection or a file' },
    { k = 'u', d = 'undo' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  session = { title = 'session: clips over the whole window (zz in the matrix)', e = {
    { k = 'h j k l', d = 'cell (scene row x track column)' },
    { k = 'Enter o', d = 'launch the clip at the next quantize boundary (its items loop in the =SESSION zone with their own phase)' },
    { k = 'O s', d = 'scene: launch every clip of the cursor row; 3s - scene 3 (a number, then s); empty cells stop their tracks' },
    { k = 'f', d = 'labels: f + letters launches that clip' },
    { k = 'F', d = 'pick several clips: labels on the clips, type them (again - unpick), Enter launches them together on the quantize boundary, Esc' },
    { k = 'x X', d = 'stop this track / all tracks at the boundary' },
    { k = 'q', d = 'quantize: bar / beat / now (:session quant ...)' },
    { k = 'Space', d = 'transport play / stop' },
    { k = 'Q', d = 'session off: transport stop, zone cleared, repeat off (:session off)' },
    { k = 'drop', t = {}, d = 'a file or a pm card dropped on a cell becomes its clip (goes into the slot of that track)' },
    { k = 'rclick', t = {}, d = 'menu: launch / scene / stop / quantize / off' },
    { k = 'zz Esc', d = 'back to the matrix - the clips keep playing' },
    { k = 'zs', d = 'tracker <-> session: clips in place of the tracker (same columns); in the session the keyboard is CLIP MODE - q..p a..l z..m launch the clip under the letter, Shift - the scene, 1..0 stop a track, ; jump labels; Option+Tab / Option+Shift+Tab - the focus around the modules' },
    { k = 'A-Tab', d = 'next pane in the tree order' },
    { k = 'zs', d = 'session (same as Tab): a clip is a 3-row block, a / A - its follow action (loop, next, previous, first, random, stop)' },
    { k = 'R', d = 'record into the clip: arms the track, the slot as the auto-punch selection, a bar of count-in, stops at the slot end' },
    { k = 'dd Del', d = 'delete the clip (its items in the slot)' },
    { k = 'item tab', t = {}, d = 'the clip under the mouse / cursor fills the wave: drag its start / end, the loop marks L; xf - loop crossfade 0 / 10 / 30 / 60 / 120 ms (off by default)' },
  } },
  pm = { title = 'pm cards (jf_pm, experimental)', e = {
    { k = 'h j k l', d = 'move over the cards (also arrows); g G - first / last' },
    { k = 'Enter o', d = 'open the project in a new REAPER tab (an open tab is just switched to); t - in this tab instead' },
    { k = 'Shift+Enter', d = 'inside the project: tracks / samples / regions / markers (Enter inserts, h - back)' },
    { k = 'Space', d = 'listen to the project preview (its _preview.wav, proxy or render); again - stop' },
    { k = 'T s p', d = 'jf_pm tags (:pmtag), status (the kanban classes), pin on top - written into jf_pm_index.json' },
    { k = 'a', d = 'add the project as a subproject at the tracker cursor (drag a card onto a track column does the same)' },
    { k = 'S d', d = 'sort: date / name / bpm / status; daw filter: all / REAPER only / other DAWs' },
    { k = 'b', d = 'big: the cards over the whole window (:pm big); Esc or b - back' },
    { k = '/ f', d = 'filter the cards: name, #tags, bpm, key, [status], daw (ableton, flstudio ...)' },
    { k = 'r', d = 'reload the jf_pm index' },
  } },
  browser = { title = 'browser', e = {
    { k = ': ↑ ↓  Ctrl+R', d = 'command line history: up / down - commands starting with what you typed (Ctrl+P / Ctrl+N too), Ctrl+R - fzf over the history' },
    { k = ':z words  :zi', d = 'zoxide: jump to the most used / recent folder matching the words (last word - in the folder name); :zi - pick from the visited folders' },
    { k = 'j k g G', d = 'move / first / last' },
    { k = 'l Enter', d = 'open folder / insert file' },
    { k = 'm M', d = 'mark the row (and step down) / clear all marks; marks stay across folders - Enter puts every marked file into the lib in marking order' },
    { k = 'h - BS', d = 'folder up' },
    { k = 'Cmd+Enter', d = 'replace sample of the selected instrument everywhere' },
    { k = 'S-dblclick', d = 'the same with the mouse: Shift + double click on a file replaces the sample of the selected instrument' },
    { k = 'Enter .rx2 .xrni', d = 'import REX / Renoise-Redux instrument with its slices' },
    { k = 'sync', d = 'button: while the project plays, a file starts on the next bar' },
    { k = '*.* .*', d = 'buttons: all file types / hidden files; Enter on MIDI / video inserts it, others open in their app' },
    { k = 'Space', d = 'preview (mini player below)' },
    { k = '/ f', d = 'fzf find: ^start end$ \'exact !not' },
    { k = 't', d = 'mode: files / db / projects' },
    { k = 'p', d = 'auto preview on / off' },
    { k = 'v', d = 'show file in sample tab' },
    { k = 'w q', d = 'panel width / hide' },
    { k = '1 2 3 4 5', d = 'bookmark: go (empty: remember this folder)' },
    { k = '! @ # $ %', d = 'Shift+1..5: set bookmark to this folder', t = { '!', '@', '#', '$', '%' } },
    { k = 'H L', d = 'folder history back / forward (< > buttons)' },
    { k = '*', d = 'new folder here (:mkdir name)' },
    { k = 'Esc Tab', d = 'clear filter / next module' },
  } },
  notes = { title = 'notes (left of DSP)', e = {
    { k = 'type', d = 'write; Enter new line, BS Del erase, arrows Home End move' },
    { k = 'project context', d = 'buttons: project notes / notes of the item under the cursor (track with SWS)' },
    { k = 'Esc Tab', d = 'leave (saved); also saved a second after typing' },
  } },
  fxb = { title = 'fx list (left of DSP)', e = {
    { k = 'type', d = "fzf search: words, ^start, end$, 'exact, !not" },
    { k = 'Up Down ^J ^K', d = 'move', t = { 'Up', 'Down', '^J', '^K' } },
    { k = 'Enter', d = 'add fx to the end of the cursor track chain' },
    { k = 'dblclick', d = 'add fx' },
    { k = 'drag', d = 'onto the DSP panel: insert at the amber line' },
    { k = 'BS', d = 'erase search' },
    { k = 'Esc Tab', d = 'clear search / next module' },
  } },
  dsp = { title = 'DSP (track fx)', e = {
    { k = 'h l', d = 'fx left / right' },
    { k = 'zz', d = 'dsp big: the chain with its routing on the whole window - h l signal (l enters a container), j k parallel row, a add after the row, A add in parallel, | join / leave the row, s solo in the row, = branches to unity, b bypass, d (or x) delete, za fold a container, o window, zz / Esc back (:dsp big)', t = { 'zz', 'z' } },
    { k = 'j k g G', d = 'parameter down / up / first / last' },
    { k = '+ - ^A ^X', d = 'value up / down (Shift: coarse)', t = { '+', '-', '=', '^A', '^X' } },
    { k = 'dd x', d = 'delete fx (v: range)', t = { 'dd', 'd', 'x' } },
    { k = 'dc', d = 'unpack container: children into the chain' },
    { k = 'yy p P', d = 'copy fx, paste after / before (any track)', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'cc', d = 'pack fx (v: range) into a new container', t = { 'cc', 'c' } },
    { k = 'rclick', d = 'container: unpack, add fx inside, presets, all serial / parallel, rename (:fxname); on a plugin inside: bypass, window, serial / parallel, move out, remove' },
    { k = 'drag', d = 'into a container: drop an fx from the list or a block onto the middle of a container (cyan frame; left half - serial, right half - parallel); the edges of a block - before / after it' },
    { k = 'aa', d = 'automate the selected parameter (envelope)', t = { 'aa', 'a' } },
    { k = 'ap A', d = 'pick a parameter to automate (fzf; also click trim in the track header, rclick trim: all parameters)', t = { 'ap', 'A' } },
    { k = 'ad', d = 'delete the automation of the selected parameter' },
    { k = 'ai', d = 'automation item over the item under the tracker cursor (track fx)' },
    { k = 'E', d = 'module learn: turn knobs in the plugin window - they join this block (saved per plugin); in learn x removes, J K move, < > columns, R resets to automatic, E / Esc done' },
    { k = 'colours', d = 'parameter strip colour = category: green gain, cyan filter, amber time, purple pitch, grey mix, red dynamics, teal stereo, orange modulation' },
    { k = 'dm da', d = 'remove the modulation (LFO / ACS / link) / the automation of the selected parameter' },
    { k = 'am', d = 'container: map the selected child parameter to a native container macro (M ...); modulate the macro natively (right-click: LFO / ACS / link)' },
    { k = 'af /', d = 'add fx (fzf)', t = { 'af', '/' } },
    { k = 'v', d = 'select a range of fx (h l extend), Esc clears' },
    { k = 'Enter b', d = 'toggle parameter / bypass fx' },
    { k = 'o', d = 'fx window (button O on the block; B bypass, x delete)' },
    { k = 't', d = 'track fx / take fx of the instrument (buttons track take)' },
    { k = 'Space', d = 'play / stop' },
    { k = 'drag title', d = 'move fx: the amber line shows where it lands' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  -- 10 окт: модуль слайсов — своя страница (клавиши и меню ПКМ — одни действия)
  slices = { title = 'slices list of the selected sample', e = {
    { k = 'j k', d = 'next / previous slice (it plays)' },
    { k = 'J K', d = 'by 8' },
    { k = 'g G', d = 'the whole sample / the last slice' },
    { k = 'Enter i', d = 'insert the slice (S00 - the whole sample) at the tracker cursor' },
    { k = 'Space', d = 'listen to the slice / stop' },
    { k = 'x d', d = 'delete the slice (its line goes)' },
    { k = 'a', d = 'insert all slices in a row' },
    { k = 's', d = 'slice menu: smart, transients, 2 4 8 16 32 64 equal' },
    { k = 'e', d = 'edit in the item tab (slicer)' },
    { k = 'X', d = 'delete all slices (asks)' },
    { k = 'r', d = 'slice pick mode: key / random ...' },
    { k = 'zz', d = 'the slices list on the whole window, again - back', t = { 'z' } },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  sprops = { title = 'properties of the item / slice', e = {
    { k = 'J K', d = 'property row down / up' },
    { k = 'H L', d = 'value less / more (Shift - fine)' },
    { k = 'R', d = 'reset the property to its default' },
    { k = 'v', d = 'fit: the pane grows until every row fits' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  nmod = { title = 'note mod: modulation started by every note of the instrument', e = {
    { k = 'a', d = 'add a slot: move a knob of an fx on the track of the instrument first - its parameter gets a curve that starts with every note' },
    { k = 'Enter', d = 'edit the curve (automation tab, the editor of its pool): one curve for all the notes; on the + row - add' },
    { k = 'r', d = 'rate: the curve runs faster for higher notes (C-4 = x1, an octave up = x2)' },
    { k = 'l', d = 'loop: the curve repeats to the end of the note; off - once, then holds its last value' },
    { k = 'd', d = 'delete the slot: the automation items of its notes go too' },
    { k = 'j k', d = 'row' },
    { k = 'mouse', d = 'click - row, double click - edit the curve, click on rate / loop - toggle' },
    { k = 'Esc', d = 'back to the tracker' },
    { k = 'how', d = 'every note of the instrument gets a pooled automation item on the envelope of the parameter: from the note start, the note length; insert, move, copy, delete a note - its automation item follows (audio notes; MIDI notes - later)' },
  } },
  visor = { title = 'visor: ReaVisor shaders from the tracker (page localhost:8080/isf)', e = {
    { k = 'p', d = 'on / off: send the picture state to the visualizer page (close reavisor.lua - two drivers fight)' },
    { k = 'o', d = 'open the page in the browser (F fullscreen, H hides its HUD); turns sending on' },
    { k = 'a e', d = 'add a shader layer (up to 8) / an effect to the chain - fzf over the ReaVisor library' },
    { k = 'Enter r', d = 'replace the shader / effect of the row; level and same-named values stay' },
    { k = 'x', d = 'remove the row' },
    { k = '< >', d = 'move the row up / down (layer order, effect order)' },
    { k = 'j k', d = 'row of the list: layers, effects, master' },
    { k = 'Space', d = 'row on / off' },
    { k = 'h l', d = 'layer level (fade) down / up' },
    { k = 'J K', d = 'parameter down / up' },
    { k = 'H L', d = 'value less / more (colour: hue)' },
    { k = '0', d = 'parameter to its default, modulation off' },
    { k = 'm', d = 'modulation: none > LFO > track peak (picks a track) > none' },
    { k = '[ ]', d = 'modulation depth' },
    { k = '{ }', d = 'LFO rate' },
    { k = 'w', d = 'LFO shape: sin tri saw sqr ramp rise fall' },
    { k = 'R', d = 'random values for the row' },
    { k = 'b', d = 'layers mix by level / add up (light)' },
    { k = 's', d = 'save everything as the scene of the cursor slot (matrix)' },
    { k = 'S', d = 'scenes follow the slot under the playhead' },
    { k = 'i', d = 'presets of ReaVisor with previews: h j k l / click pick, Enter takes it (layers, effects, values, LFOs, track routes), Esc / i back' },
    { k = 'n N', d = 'next / previous preset (the < name > buttons on top)' },
    { k = 'zz', d = 'visor on the whole window (zoom), again - back; wide, the presets show on the right' },
    { k = 'rclick', d = 'menu of the row / parameter / preset under the mouse (\\ - of the selected)' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  sample = { title = 'item tab (slicer + properties of the item)', e = {
    { k = 'dblclick', d = 'on the wave: a slice there (option slice by click: one click); on a slice line: remove it', t = {} },
    { k = 'slice labels', d = 'three rows at each slice line: its number (as in the slices list), the key that plays it, the MIDI note', t = {} },
    { k = 'Enter', d = 'apply slicing / insert selection at cursor' },
    { k = 'a', d = 'select all' },
    { k = 'v', d = 'view: peaks / spectral' },
    { k = 'q 2 w 3 e …', d = 'q - the whole sample, 2 w 3 e … - slices 1 2 3 4 … (the note keyboard, as over the wave)' },
    { k = 's', d = 'slice menu: s smart (transients + spectrum: kick, next bright hit, dark again), t transients, 2 4 8 1 3 6 - equal 2 4 8 16 32 64, d delete slices, q quantize, z autotrim' },
    { k = 'd', d = 'detect transients (with selection: to lib)' },
    { k = '+ -', d = 'transient sensitivity' },
    { k = 'x', d = 'clear slices' },
    { k = 'Q', d = 'smart quantize: strong hits to strong beats' },
    { k = 'T', d = 'autotrim: cut the silence at the start and the end (button autotrim)' },
    { k = 'Opt+D', d = 'transient detector module left of the wave: sensitivity, threshold, min gap, pre-attack - transients show live; Enter slices, s smart, x clear, Esc / Opt+D close' },
    { k = 'zz', d = 'item on the whole window (zoom), again - back', t = { 'z' } },
    { k = '< >', d = 'volume -1 / +1 dB' },
    { k = 'n', d = 'normalize' },
    { k = '[ ]', d = 'widen selection left / right' },
    { k = 'D', d = 'selection to lib' },
    { k = 'Space', d = 'preview selection' },
    { k = 'j k', t = { 'j', 'k', 'J', 'K' }, d = 'properties: row down / up' },
    { k = 'h l', t = { 'h', 'l', 'H', 'L' }, d = 'properties: value down / up' },
    { k = 'R', d = 'properties: reset value' },
    { k = '! @', t = { '!', '@', '#', '$', '%', '^', '&' }, d = 'slice: ! at transients (again - more sensitive, cycles), @ # $ % ^ & - 4 8 16 32 64 128 equal (focus in the lib or here)' },
    { k = 'Q', d = 'quantizer panel: grid, catch, max stretch, strength, sensitivity; the wave shows the plan, apply writes stretch markers' },
    { k = 'snap', d = 'button: stick to transients and slice markers' },
    { k = 'zone', d = 'slice of a big sample: top triangles = start / end, bottom strip = move it' },
    { k = 'Esc', d = 'clear selection / close' },
  } },
  grid = { title = 'monome grid / arc (jf_grid)', e = {
    { k = 'take', d = 'give the grid to the tracker module (rows 1-7: slots x tracks, row 8: transport)' },
    { k = 'grid', d = 'return the grid to the GRID mixer mod' },
    { k = 'arc', d = 'ring 1 lpb, 2 oct, 3 step, 4 inst' },
    { k = 'options', d = 'the tab can be switched off in options (grid tab) if you have no monome' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  midi = { title = 'MIDI learn (slicer from a controller)', e = {
    { k = 'j k g G', d = 'target down / up / first / last' },
    { k = 'Enter l', d = 'learn: the next CC / note becomes the binding (Esc cancels)' },
    { k = 'd x BS', d = 'clear binding' },
    { k = 'm', d = 'knob mode: abs 0..127 / rel (1..63 up, 65..127 down) / rel64 (64 +- n)' },
    { k = 'knobs', d = 'slice start / end / move, sensitivity, volume, instrument - edits land 0.5 s after the knob stops (one undo)' },
    { k = 'pads', d = 'learned note = the whole sample, next notes = slices 1 2 3 … (preview)' },
    { k = 'buttons', d = 'equal 2..32, transients, detect, clear, snap, quantize, preview, insert, to library, play' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  automation = { title = 'automation: envelopes over the song - params, curve, LFO generator, automation items', e = {
    { k = 'Opt+A', d = 'from anywhere: the last touched parameter (move a knob in a plugin or in DSP) becomes an envelope column on its track, the cursor goes there - type values in INSERT; a take FX parameter opens its take envelope here' },
    { k = 'L', d = 'curves (generator) - beside the params when wide, a page [curves] when narrow; L again - back' },
    { k = 'P', d = 'params: every parameter of the track (track envelopes + all FX params) - ENV ACT ARM PTS MOD value; also rclick on trim in a track header' },
    { k = 'params', d = 'Enter: cell, e: envelope create / show / hide, a: arm, b: active, m: modulate (LFO) - the row in the modulation tab, c: curve into it, o: FX window, w: modulation window, v: used only, M: automation mode, /: find' },
    { k = 'LFO j k h l', d = 'field / value: shape (sin tri saw+ saw- sqr rnd), period in rows, depth, center, phase, points per period' },
    { k = 'type', d = 'lfo | podkat (Anticipate: lead curve before every hit of a source track - its events or audio transients, hold, release, duck / swell) | follow (curve from another envelope or the audio level of a track: attack, release, shift = lookahead, invert)' },
    { k = 'LFO g p', d = 'g: new automation item with the curve, p: write points into the envelope - envelope at the tracker cursor (or selected in REAPER); time selection, else cursor region, else one bar' },
  } },
  modulation = { title = 'modulation: REAPER parameter modulation of the track - LFO, audio control (ACS), link; nothing is written in time', e = {
    { k = 'h j k l', d = 'cell' },
    { k = 'g G 0 $', d = 'first / last row, first / last column' },
    { k = 'Enter Space', d = 'toggle, next shape, pick link source' },
    { k = '+ - ^A ^X', d = 'value up / down', t = { '+', '-', '=', '^A', '^X' } },
    { k = '> <', d = 'value x10 up / down' },
    { k = 'a', d = 'add modulated parameter (fzf)' },
    { k = 'x BS', d = 'remove modulation of row' },
    { k = 'o w', d = 'fx window / native modulation window' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  retro = { title = 'retro capture', e = {
    { k = 'Space s', d = 'preview / stop' },
    { k = 'p Enter', d = 'put capture at cursor' },
    { k = 'P', d = 'put at cursor, keep original timing' },
    { k = 'L', d = 'looper: while playing, the last N bars (ending at the last bar line) loop from the next bar - to the region end, else 4 times' },
    { k = '1 2 4 8', d = 'looper length in bars' },
    { k = 'd', d = 'capture to lib' },
    { k = 'a', d = 'all channels' },
    { k = '+', d = 'add channel' },
    { k = 'j k', d = 'channel down / up' },
    { k = 'h l', d = 'move window' },
    { k = '[ ] { }', d = 'start / end edges' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  garden = { title = 'garden (loops in regions)', e = {
    { k = 'h j k l g G', d = 'cell / first / last region' },
    { k = 'digits Enter', d = 'loop cell with period N steps', t = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' } },
    { k = 'Enter Space', d = 'queue region / play' },
    { k = '>', d = 'loop item to region end' },
    { k = '<', d = 'region to item end' },
    { k = '+ -', d = 'period up / down the ladder', t = { '+', '=', '-' } },
    { k = 'm', d = 'mute cell' },
    { k = 'o', d = 'Orca field page' },
    { k = 'O', d = 'Orca field on / off' },
    { k = 'p x', d = 'pin / clear planted items of region' },
  } },
  orca = { title = 'Orca field', e = {
    { k = 'arrows ^hjkl', d = 'move cursor', t = { 'Left', 'Right', 'Up', 'Down' } },
    { k = 'A-Z a-z 0-9', d = 'place operator / value' },
    { k = '!', d = 'bang *' },
    { k = 'drag', d = 'drop an instrument (lib panel) on a cell: $ track inst 1 (sliced) or : track inst 4C; a region (matrix name): ; slot; a browser file: into the track library, then as an instrument - add a bang (D4)' },
    { k = '. BS Del', d = 'erase' },
    { k = 'Space', d = 'play / stop' },
    { k = 'Esc', d = 'back to garden' },
  } },
  ctrl = { title = 'main module (control)', e = {
    { k = 'h j k l', d = 'move between cells (arrows too); focus lands on BPM' },
    { k = '+ -', d = 'value up / down (like the wheel): BPM, LPB, oct, step, vel, x-fade, font...' },
    { k = 'Enter Space', d = 'press the cell (like a click); on BPM - type the number, Enter applies' },
    { k = '0-9', d = 'on BPM: start typing the tempo' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  master = { title = 'master', e = {
    { k = 'm', d = 'scope mode' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  help = { title = 'this help', e = {
    { k = 'type', d = 'fzf search over all pages' },
    { k = 'Left Right', d = 'page' },
    { k = 'Up Down', d = 'scroll' },
    { k = 'BS', d = 'erase search' },
    { k = 'Esc', d = 'clear search / back to module' },
    { k = 'F1', d = 'the whole help' },
  } },
}
-- строка подсказок под модулем (опция hints, 2 окт): самое нужное в одну
-- строку; полное описание — справка ?. { клавиша, что делает }
KH.BARS = {
  tracker = { { 'i', 'insert' }, { 'hjkl', 'move' }, { 'x', 'del' }, { 'dd', 'track' }, { 'yy p', 'copy' }, { 'v', 'select' },
              { '/', 'find' }, { ':', 'cmd' }, { '\\', 'menu' }, { '\\\\', 'context' }, { 'f', 'jump' }, { 'Space', 'play' }, { '?', 'actions' }, { 'F1', 'help' } },
  insert = { { 'q2w3e', 'notes' }, { 'z x', 'oct' }, { 'c C', 'vel' }, { ', .', 'inst' }, { 'a', 'step auto' },
             { 'd', 'delete' }, { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' }, { 'Esc', 'normal' }, { '?', 'help' } },
  matrix = { { 'o O', 'new' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'n', 'name' }, { '[ ]', 'bar' },
             { '< >', 'pattern' }, { 'M', 'mute' }, { 'Space', 'play' }, { 'R', 'ruler' }, { '?', 'help' } },
  inst = { { 'j k', 'select' }, { 'J K', 'move' }, { 'dd', 'cut' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'v', 'range' }, { 'Enter', 'item' }, { 's', 'slice' },
           { 'Space', 'listen' }, { '/', 'find' }, { '?', 'help' } },
  session = { { 'Tab', 'clip mode' }, { 'click >', 'launch' }, { 'o', 'record' }, { 'a', 'follow' }, { 'drop', 'file' }, { 'f', 'labels' }, { 'wheel', 'scenes' } },
  clipmode = { { 'q..p a..l z..m', 'launch' }, { 'Shift', 'scene' }, { '1..0', 'stop' }, { 'Bksp', 'stop all' }, { 'arrows', 'scenes' },
               { '.', 'follow' }, { ',', 'quant' }, { '/', 'rec' }, { 'Space', 'play' }, { ';', 'labels' }, { 'Tab', 'tracker' } },
  tracks = { { 'j k', 'track' }, { 'h l', 'column' }, { 'Space', 'toggle' }, { 'a', 'column all' }, { 'Enter', 'go' }, { 'z', 'fold' }, { '/', 'filter' }, { 'Esc', 'tracker' } },   -- 11 окт: Track Manager
  pm = { { 'Enter', 'open' }, { 'S+Enter', 'inside' }, { 'Space', 'listen' }, { 'T s p', 'tags status pin' }, { 'a', 'add' }, { 'b', 'big' }, { '/', 'find' } },
  browser = { { 'Enter', 'open/add' }, { 'h', 'up' }, { 'Space', 'listen' }, { '/', 'find' }, { '1-5', 'marks' },
              { 'H L', 'back/fwd' }, { '*', 'mkdir' }, { 'Cmd+Enter', 'replace' }, { '?', 'help' } },
  dsp = { { 'h l', 'fx' }, { 'j k', 'param' }, { '+ -', 'value' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'cc', 'container' },
          { 'aa', 'automate' }, { 'b', 'bypass' }, { 'o', 'window' }, { 't', 'track/take' }, { '/', 'find' }, { 'af', 'add' }, { 'zz', 'big' }, { '?', 'help' } },
  -- 9 окт: роутер (zR) и цепочка на всё окно (zz) — подсказки в строке статуса
  router = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a A', 'add' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' }, { 'b', 'bypass' },
             { 'd', 'delete' }, { 'o', 'window' }, { 'drag', 'slider' }, { 'dblclick', 'default' }, { 'zR Esc', 'back' } },
  dspbig = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a', 'add' }, { 'A', 'parallel' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' },
             { 'b', 'bypass' }, { 'd', 'delete' }, { 'za', 'fold' }, { 'o', 'window' }, { 'zz Esc', 'back' } },
  notes = { { 'type', 'write' }, { 'Esc', 'leave' }, { 'project', 'notes' }, { 'context', 'item' } },
  fxb = { { 'type', 'search' }, { 'Up Down', 'move' }, { 'Enter', 'add' }, { 'drag', 'insert' }, { 'Esc', 'clear' } },
  nmod = { { 'a', 'add (last touched)' }, { 'Enter', 'curve' }, { 'r', 'rate' }, { 'l', 'loop' }, { 'd', 'delete' }, { 'Esc', 'tracker' } },
  sprops = { { 'J K', 'row' }, { 'H L', 'value' }, { 'Shift', 'fine' }, { 'R', 'reset' }, { 'v', 'fit all rows' }, { 'Esc', 'tracker' } },
  visor = { { 'p', 'on' }, { 'o', 'page' }, { 'a e', 'add' }, { 'j k', 'row' }, { 'J K', 'param' }, { 'H L', 'value' }, { 'h l', 'level' }, { 'm', 'mod' }, { 's', 'scene' }, { 'i', 'presets' }, { 'n N', 'preset' }, { 'zz', 'big' }, { '?', 'help' } },
  sample = { { 's', 'slice menu' }, { 'Enter', 'insert sel' }, { 'v', 'view' }, { '< >', 'vol' },
             { 'n', 'normalize' }, { 'jk', 'param' }, { 'hl', 'value' }, { '?', 'help' } },
  automation = { { 'Opt+A', 'last touched' }, { 'L', 'curves' }, { 'P', 'params' }, { 'g p', 'write curve' }, { 'Esc', 'back' } },
  modulation = { { 'hjkl', 'cell' }, { 'Enter', 'toggle' }, { '+ -', 'value' }, { 'a', 'add' }, { 'x', 'remove' }, { 'o w', 'windows' } },
  retro = { { 'Space', 'listen' }, { 'L', 'loop' }, { 'p', 'put' }, { 'd', 'lib' }, { 'j k', 'channel' }, { '[ ] { }', 'edges' }, { 'h l', 'move' } },
  garden = { { 'N Enter', 'loop' }, { '> <', 'fit' }, { '+ -', 'period' }, { 'm', 'mute' }, { 'o', 'Orca' }, { 'O', 'on/off' },
             { 'p', 'pin' }, { 'x', 'clear' } },
  orca = { { 'arrows', 'move' }, { 'A-Z', 'operator' }, { '!', 'bang' }, { '.', 'erase' }, { 'Space', 'play' }, { 'Esc', 'back' } },
  grid = { { 'take', 'grid to tracker' }, { 'grid', 'back to mixer' }, { 'Esc', 'back' } },
  midi = { { 'j k', 'target' }, { 'Enter', 'learn' }, { 'd', 'clear' }, { 'm', 'abs/rel' }, { 'Esc', 'back' } },
  master = { { 'm', 'scope mode' }, { 'Esc', 'back' } },
  ctrl = { { 'hjkl', 'cell' }, { '+ -', 'value' }, { 'Enter', 'press' }, { 'F', 'follow' }, { 'Esc', 'back' } },   -- F: тоглы переехали сюда (5 окт)
  help = { { 'type', 'search' }, { 'Left Right', 'page' }, { 'Esc', 'back' } },
}
KH.ORDER = { 'intro', 'pane', 'ctrl', 'tracker', 'insert', 'matrix', 'session', 'inst', 'slices', 'browser', 'pm', 'dsp', 'fxb', 'notes', 'sample', 'nmod', 'automation', 'modulation', 'midi', 'grid', 'retro', 'orca', 'master', 'help' }

-- токены записи (кэш)
local function toks(e)
  if e._t then return e._t end
  local t = {}
  if e.t then for _, x in ipairs(e.t) do t[#t + 1] = x end
  else for x in e.k:gmatch('%S+') do t[#t + 1] = x end end
  e._t = t
  return t
end

-- код клавиши → токен справки
function KH.token(c)
  if c == 13 then return 'Enter' elseif c == 27 then return 'Esc' elseif c == 32 then return 'Space'
  elseif c == 8 then return 'BS' elseif c == 9 then return 'Tab' elseif c == 6579564 then return 'Del'
  elseif c == LEFT then return 'Left' elseif c == RIGHT then return 'Right' elseif c == UP then return 'Up' elseif c == DOWN then return 'Down'
  elseif c >= 1 and c <= 26 then return '^' .. string.char(c + 64)
  elseif c >= 33 and c <= 126 then return string.char(c) end
  return nil
end

-- индекс записи страницы для токена (сначала двухклавишная последовательность)
function KH.match(page, tok, prev)
  local P = KH.PAGES[page]
  if not P or not tok then return nil end
  local seq = prev and (prev .. tok)
  if seq then
    for i, e in ipairs(P.e) do for _, x in ipairs(toks(e)) do if x == seq then return i end end end
  end
  for i, e in ipairs(P.e) do for _, x in ipairs(toks(e)) do if x == tok then return i end end end
  return nil
end

-- клавиша нажата в модуле page — подсветить её функцию
function KH.press(page, c, now)
  local tok = KH.token(c)
  if not tok then return end
  local prev = KH.last and (now - KH.last.t) < 1.5 and #KH.last.tok == 1 and #tok == 1 and KH.last.tok or nil
  local i = KH.match(page, tok, prev)
  KH.last = { tok = tok, t = now }
  if i then
    KH.flash = { page = page, i = i, t0 = now, seed = (math.floor(now * 1000) % 9973) + i }
  end
end

-- ── fzf-фильтр ────────────────────────────────────────────────────────────
local function subseq(hay, pat)
  local j = 1
  for i = 1, #hay do
    if hay:sub(i, i) == pat:sub(j, j) then j = j + 1; if j > #pat then return true end end
  end
  return #pat == 0
end

function KH.fmatch(e, q)
  local hay = (e.k .. ' ' .. e.d):lower()
  for term in q:lower():gmatch('%S+') do
    if not hay:find(term, 1, true) and not subseq(hay, term) then return false end
  end
  return true
end

-- строки к показу: { page=, i=, e=, tag= }; с поиском — все страницы,
-- текущая первой; без поиска — только текущая
function KH.rows()
  local out = {}
  if KH.query == '' then
    local P = KH.PAGES[KH.page] or KH.PAGES.tracker
    for i, e in ipairs(P.e) do out[#out + 1] = { page = KH.page, i = i, e = e } end
    return out
  end
  local function add(pg)
    for i, e in ipairs(KH.PAGES[pg].e) do
      if KH.fmatch(e, KH.query) then out[#out + 1] = { page = pg, i = i, e = e, tag = pg ~= KH.page and pg or nil } end
    end
  end
  add(KH.page)
  for _, pg in ipairs(KH.ORDER) do if pg ~= KH.page then add(pg) end end
  return out
end

function KH.cycle(d)
  local i = 1
  for k, p in ipairs(KH.ORDER) do if p == KH.page then i = k end end
  KH.page = KH.ORDER[(i - 1 + d) % #KH.ORDER + 1]
  KH.pinned = true
  KH.scroll = 0
end

-- клавиши, когда фокус на самой справке: 'leave' — вернуть фокус модулю
function KH.key(c)
  if c == 27 then
    if KH.query ~= '' then KH.query = ''; KH.scroll = 0; return true end
    KH.pinned = false
    return 'leave'
  elseif c == 8 then KH.query = KH.query:sub(1, -2); KH.scroll = 0
  elseif c == LEFT then KH.cycle(-1)
  elseif c == RIGHT then KH.cycle(1)
  elseif c == UP then KH.scroll = math.max(0, KH.scroll - 1)
  elseif c == DOWN then KH.scroll = KH.scroll + 1
  elseif c == 13 then KH.pinned = false; return 'leave'
  elseif c >= 32 and c <= 126 then KH.query = KH.query .. string.char(c); KH.scroll = 0
  else return false end
  return true
end

-- ── отрисовка ─────────────────────────────────────────────────────────────
local FLASH_T, BOOM_T, NPART = 1.4, 0.75, 26

local function rnd(seed, k)
  local x = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
  return x - math.floor(x)
end

-- (x, y, w, h) — прямоугольник панели; now — время; focused — фокус на справке
function KH.draw(U, L, x, y, w, h, now, focused, fit)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local P = KH.PAGES[KH.page] or KH.PAGES.tracker
  -- шапка: ? HELP · страница · поиск
  local head = ('F1 help: %s'):format(P.title)
  U.text(x + L.pad, y + 3, head, U.AMBER)
  local qx = x + L.pad + U.measure(head) + 3 * L.pad
  local qs = KH.query ~= '' and ('/' .. KH.query .. (focused and '_' or '')) or (focused and 'type to search, Left/Right page, Esc back' or 'Tab here: search  |  keys you press light up')
  U.text(qx, y + 3, fit(qs, math.max(0, x + w - qx - L.pad)), KH.query ~= '' and U.TEXT or U.GREY)
  local rows = KH.rows()
  local top = y + 3 + L.rh + 2
  local nr = math.max(1, math.floor((y + h - top - 2) / L.rh))
  -- ширина колонок: ключ (до 14 знаков) + описание
  local kw = 0
  for _, r in ipairs(rows) do kw = math.max(kw, U.measure((r.tag and (r.tag .. ':') or '') .. r.e.k)) end
  kw = math.min(kw, U.measure('WWWWWWWWWWWWWW')) + 2 * L.pad
  local colw = math.max(kw + U.measure('W') * 22, math.min(kw + U.measure('W') * 46, w))
  local ncols = math.max(1, math.floor((w - L.pad) / colw))
  colw = math.floor((w - L.pad) / ncols)
  -- прокрутка: по строкам колонок; вспышка — в видимую область
  local per = nr * ncols
  local maxscroll = math.max(0, math.ceil(#rows / ncols) - nr)
  if KH.flash and KH.flash.page == KH.page and now - KH.flash.t0 < 0.05 and KH.query == '' then
    local fi = KH.flash.i
    local first, last = KH.scroll * ncols + 1, KH.scroll * ncols + per
    -- раскладка по колонкам: элемент k в колонке floor((k-1)/nrows_total)
    local nrt = math.ceil(#rows / ncols)
    local rr = (fi - 1) % math.max(1, nrt)
    if rr < KH.scroll then KH.scroll = rr elseif rr >= KH.scroll + nr then KH.scroll = rr - nr + 1 end
    local _ = first + last
  end
  if KH.scroll > maxscroll then KH.scroll = maxscroll end
  local nrt = math.max(1, math.ceil(#rows / ncols))     -- строк в колонке (до прокрутки)
  local hover
  local flash_rect
  for k, r in ipairs(rows) do
    local col = math.floor((k - 1) / nrt)
    local rr = (k - 1) % nrt - KH.scroll
    if rr >= 0 and rr < nr then
      local ex = x + L.pad + col * colw
      local ey = top + rr * L.rh
      local fl = KH.flash and KH.flash.page == r.page and KH.flash.i == r.i and (now - KH.flash.t0) < FLASH_T
      local kc, dc = U.AMBER, U.TEXT
      if fl then
        local t = now - KH.flash.t0
        local a = 1 - t / FLASH_T
        U.set(U.AMBER); gfx.a = 0.85 * a; gfx.rect(ex - 2, ey, colw - L.pad, L.rh, 1); gfx.a = 1
        if t < 0.45 then kc, dc = U.BG, U.BG end
        flash_rect = { ex, ey, colw - L.pad, L.rh }
      end
      local klabel = (r.tag and (r.tag .. ':') or '') .. r.e.k
      if r.tag then U.text(ex, ey + 1, fit(r.tag .. ':', kw), fl and kc or U.GREY); U.text(ex + U.measure(r.tag .. ':'), ey + 1, fit(r.e.k, kw - U.measure(r.tag .. ':')), kc)
      else U.text(ex, ey + 1, fit(klabel, kw - L.pad), kc) end
      U.text(ex + kw, ey + 1, fit(r.e.d, colw - kw - 2 * L.pad), dc)
      if mx >= ex and mx < ex + colw and my >= ey and my < ey + L.rh then hover = r end
    end
  end
  if maxscroll > 0 then
    U.text(x + w - L.pad - U.measure('v more'), y + 3, KH.scroll < maxscroll and 'v more' or '^', U.GREY)
  end
  -- ASCII-взрыв точками вокруг подсвеченной строки
  if flash_rect and KH.flash then
    local t = now - KH.flash.t0
    if t < BOOM_T then
      local cx = flash_rect[1] + math.min(flash_rect[3], kw) / 2
      local cy = flash_rect[2] + flash_rect[4] / 2
      local spd = U.measure('W') * 16
      local cw = U.measure('.')
      for p = 1, NPART do
        local ang = (p / NPART) * 2 * math.pi + (rnd(KH.flash.seed, p) - 0.5) * 0.5
        local v = spd * (0.45 + 0.9 * rnd(KH.flash.seed, p + 50))
        local px = cx + math.cos(ang) * v * t
        local py = cy + math.sin(ang) * v * t * 0.6 + 40 * t * t
        if px >= x and px < x + w - cw and py >= y + 2 and py < y + h - L.rh then
          local fade = t / BOOM_T
          local ch = t < 0.12 and '*' or (t < 0.4 and (p % 3 == 0 and '+' or '.') or '.')
          U.text(math.floor(px), math.floor(py - L.rh / 2), ch, U.mix(U.AMBER, U.PANEL, fade))
        end
      end
    end
  end
  return hover
end

return KH
