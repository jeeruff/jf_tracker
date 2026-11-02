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

local TX = dofile((debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. 'jf_tracker_utf8.lua')   -- 20 окт: набор Юникодом (кириллица)
local KH = {}
KH.query = ''
KH.page = 'tracker'
KH.pinned = false        -- страницу выбрали стрелками в самой справке
KH.scroll = 0
KH.flash = nil           -- { page=, i=, t0=, seed= }
KH.last = nil            -- { tok=, t= } — для двухклавишных dd / yy / gg
KH.hist, KH.hpos = {}, nil  -- 18 окт: совершённые действия { page, i } по порядку; hpos — листаем стрелками < > (nil — живое)
KH.marks = {}             -- 18 окт: закладки 1..5 { page, scroll }
KH.sel = nil              -- { page, i } — запись, к которой вернулись стрелками (рамкой)
KH.on_marks = nil         -- main: сохранить закладки

local LEFT, RIGHT, UP, DOWN = 1818584692, 1919379572, 30064, 1685026670

-- k — как клавиша написана в справке; t — явные токены (иначе k по пробелам)
KH.PAGES = {
  -- первая страница (3 окт): что это и почему так близко к REAPER
  intro = { title = 'jf_tracker - what it is', e = {
    { k = 'idea', t = {}, d = 'build a whole track from the keyboard in one window: patterns, their order, sounds; mixing later in REAPER on the same tracks' },
    { k = 'shape', t = {}, d = 'Vim keys, Emacs build: a small core (the view of the project, one writer to REAPER, the key grammar) and modules around it - DSP, slicer, matrix, browsers, curve, harmonizer ...; each a pane with its own keys and help (F1 here: what is under the cursor); your own modules plug in (API.md)' },
    { k = 'native', t = {}, d = 'the tracker is a view, REAPER is the engine: tracks, items, MIDI, regions, envelopes, FX - no format of its own' },
    { k = 'why', t = {}, d = 'nothing to export or lose: close the window and the project plays and edits as usual; tempo map, routing, render, other scripts keep working; every edit is one REAPER undo step' },
    { k = 'lib', t = {}, d = 'the sounds you play (right panel): every audio item of the project, one entry per sound; library entries sit on their track after the =LIB marker' },
    { k = 'linked', t = {}, d = 'notes of a lib entry are linked copies: change it in the item panel and all its notes follow; a stretched note becomes unique (or apply to all)' },
    { k = 'item', t = {}, d = 'item tab (top): the selected lib entry - wave, slices, properties, preview, beatsync' },
    { k = 'help < >', t = {}, d = 'the help pane: its head shows the last action done (keys, zoom by the mouse); < > - back / forward over the actions done, past the last - live again; 1..5 - bookmarks: an empty one keeps the page and scroll, a kept one goes there, Shift+click overwrites; the wheel scrolls' },
    { k = 'macro', t = {}, d = ':macro - zoom out: a row is a beat (LPB 1); :macro again - back to the previous LPB' },
    { k = 'pt', t = {}, d = ':pt - PT-mode, a dumbed-down ProTracker view: exactly 4 channels from the scroll, note / sample / vol / one command, no waves or envelopes, LPB 4, bitmap x4 (smaller if 4 do not fit), scopes on top; :pt new creates CH1..CH4 in the project; :pt again restores everything' },
    { k = 'arp', t = {}, d = ':arp [up|down|updown|random|played] [step] [octaves] [gate%] - the chord on the cursor row (notes in the subcolumns of the track) becomes an arpeggio over its length' },
    { k = 'slices', t = {}, d = 'notes (INSERT + m): a sliced sample - the key picks the slice (1 f1 2 f2 ... = slice 01 02 ..., shown as the command 0S01 0S02 in the fx column - edit it there; the whole sample: Ctrl+Shift+1 (Ctrl+Shift + slice key - from that slice to the end); qwerty: q 2 w 3 ...); not sliced - the sample at that pitch. Shift+Option+note - the selected slice (or the whole item if whole is selected) at that pitch; Option+note - chord, as on any sample; Cmd+note - the whole item at that pitch; Ctrl+note - held note (length = how long). The selected slice: picked in the slice list, with Cmd+J / K, or the last one played' },
    { k = 'Opt+J / K', d = 'previous / next instrument of the lib (samples, plugins, automation; a count jumps N)' },
    { k = 'Ctrl+Opt+H L', d = 'playrate of the selected instrument slower / faster (a count - N steps); on an fx column - fewer / more command columns of the track' },
    { k = 'Ctrl+Cmd+F1 F2', d = 'transpose the selected instrument of the lib -1 / +1 semitone (Shift - an octave)' },
    { k = 'Opt+1..0', d = 'instrument 1..10 of the lib; plugin instruments are numbered across the project (as in REAPER, any track - any instrument): one on another track takes the cursor to that track' },
    { k = 'Cmd+1..0', d = 'jump to channel 1..10 (Ctrl+O - back), in INSERT too (Cmd is never a note)' },
    { k = 'Ctrl+0..9', d = 'step length 0..9 rows (0 - the cursor stays); step auto / next off' },
    { k = 'Ctrl+Shift+J K', d = 'the note under the cursor: its end a row later / earlier (a count - N rows) (not stretched; past the sample the instrument loop plays)' },
    { k = 'Shift+Opt+Cmd+J K', d = 'NORMAL: slip: the sound inside the note under the cursor a row down / up (the note stays; looped - wraps)' },
    { k = 'Ctrl+Shift+H L', d = 'the note under the cursor: its start a row earlier / later (the source offset follows, as trim)' },
    { k = 'pan column', d = 'option pan column: a pan field after the volume (l from vol); two hex digits: 00 left, 80 centre, FF right; BS - centre' },
    { k = 'Ctrl+Opt + -', d = 'continue: the command above in this column (or the volume) again with value +1 / -1, on this row, the cursor a step on' },
    { k = 'Ctrl+Enter', d = 'the note under the cursor: all its properties in a box (only this note; a MIDI note - note, velocity, length, delay, channel, mute): j k row, h l value, a letter - jumps to the row (its lighter letter), Space - its list, R reset, W the REAPER item window, Enter / Esc close; Shift+Space - listen. A double click on a note and the menu item properties open the same box' },
    { k = 'Shift+Space', d = 'play the note under the cursor (its track solo, with fx); Shift+Option+Space - at x0.5; works with the note properties open' },
    { k = 'Ctrl+`', d = 'step next / auto, one key toggles them: next - the cursor goes to the next note / item / command / envelope point of the track, auto - to the end of the inserted item / slice; a note that plays a sampler slice (drumrs5k pad, RS5K) - both step its slice length; Ctrl - / + or Ctrl+0..9 back to a number' },
    { k = 'Ctrl+M', d = 'metronome on / off - anywhere (as in FL Studio)' },
    -- 15 окт: опция keys: renoise выключена (закомментирована в опциях)
    { k = 'gm', d = 'metronome menu: m on / off, speed, accents, pre-roll (:metro toggles too)' },
    { k = 'gq', d = 'quantize menu: notes, OFFs, automation, item edges (= \\ Q)' },
    { k = 'gQ', d = 'input quantize of the cursor track: on / off, grid, strength, direction, note-offs (= the qtz button)' },
    { k = 'Ctrl - +', d = 'step down / up by one, in any mode (as in Renoise); - + alone - LPB (NORMAL; INSERT on the note field with qwerty) - with frow - = are notes while the keyboard plays and in INSERT; Cmd - + - font size' },
    { k = 'help button (main module)', t = {}, d = 'this help follows the focused module; Tab here: search all pages, left / right: pages' },
  } },
  pane = { title = 'panes (tmux / zellij)', e = {
    { k = '\\ (in a module)', d = 'quick menu of the module in focus (its main actions, letters); in it \\ - the main menu' },
    { k = 'zz', d = 'in any module (lib, browser, fx list, item, macros ...): the module on the whole window, again or Esc - back; in the tracker (Esc there is INSERT) - the tracker alone; dsp zz - dsp big', t = { 'z' } },
    { k = '⌘h ⌘j ⌘k ⌘l', d = 'focus the pane on the left / below / above / on the right (like dwm), from any pane' },
    { k = '⌘⇧h ⌘⇧j ⌘⇧k ⌘⇧l', d = 'move the pane there (out of its stack if it is a tab)' },
    { k = '⌥Tab', d = 'next pane in the tree order (Shift - back)' },
    { k = 'Ctrl+W', d = 'pane mode (sticky, Esc out): the keys below, the pane numbers on the borders' },
    { k = 'h j k l  H J K L', d = 'focus / move by direction' },
    { k = 'w W  1..9', d = 'next / previous pane, pane by number' },
    { k = 'g + key', d = 'go to a panel (a hidden one appears): its letter - the which-key of Ctrl+W g lists them all' },
    { k = 'Tab Shift+Tab', t = {}, m = 'next / prev tab', d = 'outside the tracker: the next / previous tab of the stack' },
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
    { k = 'arrows + mods', d = 'arrows = h j k l with any modifier: Cmd+arrows - focus the pane there (Cmd+Shift - move it), Opt+Left / Right - track, Opt+Up / Down - instrument, Shift+arrows - select (H J K L), Ctrl+arrows - as Ctrl+hjkl' },
    { k = 'Opt+H Opt+L', d = 'previous / next track' },
    { k = 'w b e', d = 'next / previous event of the track (all its columns and envelope points, like words in Vim), end of event; dw yw cw - this column' },
    { k = 'E', d = 'the end of the lowest visible event of the track (the last one that starts on screen); dE - up to there' },
    { k = 'W B', d = 'next / previous event on ANY track - a note, an item, an automation point, a lane event (w b - the cursor track only)' },
    { k = 'env: w b e dd y p', d = 'envelope points are events: motions, delete / yank / paste points (value + shape)', t = {} },
    { k = 'gg G', d = 'first row / last row (option gg proj/pat relative: in the pattern view - of the cursor pattern)' },
    { k = 'gn gN', t = { 'gn', 'gN' }, d = 'next / previous pattern, the cursor on the same row inside it (3gn - three patterns on; a shorter pattern - its last row)' },
    { k = 'gp gP  gs gS', t = { 'gp', 'gP', 'gs', 'gS' }, d = 'go to the start / the last row of the pattern under the cursor, of its section (already there - the previous / next one); with an operator - a motion (dgP deletes to the pattern end)' },
    { k = 'Esc', d = 'smart: while playing - stop, the cursor on the play position (Space - stop and back); stopped - toggles INSERT (as the edit mode in Renoise); options Esc stops playback, Esc mode = vim - only back to NORMAL' },
    { k = 'Ctrl+O / Ctrl+I', d = 'jumps: back / forward to where you were before a jump (f label, harpoon, gg, G)' },
    { k = "'b", d = "back where the cursor just was - before the last jump, click or module change (any module: tracker, matrix, DSP); 'b again - return; plain j k steps do not count" },
    { k = "'a '1..'9 '' 'd", d = "harpoon: pin the place under the cursor - a track row (tracker), a cell (matrix) or a parameter (DSP, also inside a container / pad); jump to pin 1..9 (the focus goes to its module; a DSP pin unfolds the module and opens the page of the parameter), list the pins by module (fzf), unpin; works in the tracker, the matrix and DSP; per project" },
    { k = "'A", d = "harpoon: pin the last touched fx parameter (the knob you just moved in a plugin window, DSP or a track header) - from anywhere" },
    { k = 'gw  3gw', d = 'swap the event under the cursor with the next / the 3rd below (:sw N)' },
    { k = 'Enter  middle click', m = 'smart panel (Enter)', d = 'smart panel (as in PlayerPro): a grid of the values of the field under the cursor - notes, (and a row of microtones v3 vv v 0 ^ ^^ ^3 - 1/6 tone, 72-EDO), volume, delay, command letter then value, instrument, envelope / CC; pick with a left or middle click or h j k l + Enter; VISUAL - the whole block' },
    { k = ':xf', d = 'modifiers (15 Oct) on VISUAL / the track in the region: stretch k, reverse, rotate n, shuffle, gravity g, bounce r, fib, tuplet n, golden, vel k (also built-in macros)' },
    { k = ':mackey', d = ':mackey name x - a hotkey for the macro: @x plays it; :keys - all keys and commands as text (Data/jf_tracker_keys.md)' },
    { k = 'π (Opt+P)', t = {}, d = 'smart paste: the clipboard buffers at the cursor - a digit / Enter pastes that one, π again - the last yank (layout qwerty: with the keyboard / INSERT π is still the note p beside)' },
    { k = 'clipboard', t = {}, d = 'yank history with the wave of each buffer (w - peaks / spectral); zz - on the whole window: buttons, a big wave, the rows. Space listen, s save as a file, a add to drumrs5k, e open in the external editor, m a subproject in pm with tags; Enter / p - use it' },
    { k = 'macros tab', t = {}, d = 'as lf: folders left (recorded / saved / shared / built-in, h l - between folders and the list, j k), the macros of the folder in the middle, the editor of the picked one right (buttons = keys): Enter play, a new, e edit the body, n name, K hotkey (press the keys, Esc removes; it plays the macro anywhere), r register (@x), t description, S share (a .jfm file in Data/jf_tracker_macros), i import a shared one into saved, d delete; dblclick plays' },
    { k = ':scramble', d = 'slice notes swap their slices randomly (VISUAL, else the track in the region; button in the item tab)' },
    { k = '{ }', d = 'bar back / forward' },
    { k = 'Ctrl+A  Ctrl+X', d = 'the field under the cursor +1 / -1 (3 Ctrl+A - by three): note, vol, delay, a command; a lane (CC PB PC) or an envelope - an empty row first takes the value above, the next press changes it; Ctrl+Opt+A / X - the value above +1 / -1 at once and the cursor a step down (a run of rising values); Ctrl+Shift+A / X - a big step: a note +-12 (an octave), an envelope +-1/16, vol / commands / CC +-16 (0x10)' },
    { k = 'x', d = 'delete the cell under the cursor: on the note - the event; on vol / delay / a command - only that value (the note stays; dd and dl too); nothing moves' },
    { k = 'd', d = 'd + motion deletes events: dw d3j dG d}; dd - the rows (3dd), td - the track', t = { 'd' } },
    { k = 'dae', d = 'delete all automation of the cursor track in the song (points and automation items; the lib after =LIB stays)' },
    { k = 'dal daj dak dah', d = 'delete notes of the cursor track: dal on the cursor row (every subcolumn), daj below it, dak above it, dah all but the cursor row' },
    { k = 'v v v', d = 'VISUAL: the first v - only the field under the cursor (vol, delay or a command column), v again - the whole track, again - off; in a field: y copies its values, d clears them (the notes stay), p puts them' },
    { k = 'yc', d = 'copy the field column under the cursor (vol / delay / command) of the whole pattern; p - into the notes from the cursor row' },
    { k = 'Q', d = 'VISUAL: quantize the selection to the grid - every note to its nearest row (delay 0), lengths stay' },
    { k = 'gr', d = 'VISUAL: reform - the notes and automation points of the selection: time scale / curve / shift / redistribute, value ranges with a curve; live, Enter keeps, Esc reverts' },
    { k = 'gi', d = 'VISUAL: interpolate the field - linear, log, exp or sine (up and back); the notes in between get the value, no end value - pick it' },
    { k = 'Cmd+I', d = 'interpolate: in VISUAL the values of the field under the cursor (note, vol, delay or a command) go linearly from the first event to the last (:interp)' },
    { k = 'daE daL daJ daK daH', d = 'the same on every track (Shift = wider): daE - all automation in the pattern (the cursor region), daL - the cursor row of all tracks (nothing below moves), daJ daK daH - below / above / all but the row' },
    { k = 'dd dt', d = 'delete the events of the row - nothing below moves (3dd - three rows; x - one event) / remove the time selection from the project (later items move)', t = { 'dd', 'dt' } },
    { k = 'dd dw dW di', d = 'dd - the rows out, everything below moves up (as Vim; 3dd - three rows); dw - clear the row of the track, nothing moves (3dw); dW - clear the row on all tracks; di - the whole item under the cursor' },
    { k = 'dp dP', d = 'delete from the pattern start to the cursor / from the cursor to the pattern end (the cursor track)' },
    { k = 'd Space', d = 'delete up to the pause: the run of events of the cursor lane from the cursor down to the first empty row (like d} in Vim); on an empty row - the next run' },
    { k = 'dS', d = 'delete every item and all automation (envelope points, automation items) of the selected tracks in the whole project (no selection - the cursor track); one undo' },
    { k = 'C-A-j', d = 'repeat the part of the region above the cursor down to the region end: Ctrl+Opt+J (or Down) - this track; on the first row of a pattern - the previous pattern into this one; :repeat all - all tracks (Paketti)' },
    { k = 'S-A-j S-A-k', d = 'transpose the instrument selected in the lib -1 / +1 semitone (a count - by N)' },
    { k = ':mcmd', d = 'master column cmd = project markers on rows: Enter - edit the command of the row, ! - a REAPER action (marker !<id> - REAPER runs it when playback passes), BS / Del / x - delete; :mcmd <text> sets it, :mcmd alone deletes' },
    { k = 'dw (automation)', d = 'on an envelope, a MIDI lane (CC / PB / PC) or a command field: delete the event of the cursor row (none - the next one below); 3dw - three in a row; the cursor stays, dw again - the next one' },
    { k = 'dw  d`', d = 'dw on a row inside a note - an empty step there (the note before it and after it, nothing moves); on an OFF - removes it; d` - removes the OFF of the note under the cursor (or the next OFF below): the note sounds on to the next event' },
    { k = 'dd  dD  dl', d = 'dd - rows out of the cursor subcolumn only, its events below move up (the other subcolumns stay); dD - rows out of the whole track (all subcolumns and lanes) = Backspace; dl - the row on all tracks = Shift+Backspace' },
    { k = 'd ≠ D (a..f)', d = 'INSERT on a value field (envelope, lane, vol, delay, command value): lowercase a b c d e f - NORMAL keys (b back, e end, dd dw dp dc …), then INSERT again; hex digits A-F - uppercase: DD = Shift+D twice; command codes and notes as before' },
    { k = 'dc dC', d = 'automation column: dc - every value of it (the column stays), dC - the column itself; vol / delay / command field: dc - cleared in the pattern of the cursor, dC - in the whole track (the notes stay)' },
    { k = 'z1', d = 'lock the track of the cursor to one note lane (mono: a new note cuts the sounding one, overlaps trimmed); again - free (also in the track menu)' },
    { k = '- +', t = {}, d = 'over the note field of a track: how many note subcolumns at least' },
    { k = 'dr dR dT', d = 'clear the track in the cursor region / the region on all tracks / everything on the track in all regions (the lib after =LIB stays)', t = { 'dr', 'dT' } },
    { k = 'yy p P', d = 'copy rows / paste: p replaces the note on the row (x-fade on - keeps it), P beside it in a new subcolumn', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'c s', d = 'replace / split the event (mute events: select with v, then M)', t = { 'c', 's' } },
    { k = 'M S', d = 'mute / solo the cursor track (Shift+m / Shift+s)', t = { 'M', 'S' } },
    { k = '^A ^X', d = 'field value +1 / -1; an empty command field of a note - auto capture: the command of the nearest note above, then +1 / -1' },
    { k = 'r', d = 'set value of field' },
    { k = 'u ⌘⇧Z .', d = 'undo / redo / repeat last edit' },
    { k = '^R', d = 'the rec tab' },
    { k = 'F12', d = 'reload the audio device (as choosing it again; options - audio)' },
    { k = '⌥R ⌘R', d = 'record into the tracker from the cursor / a new sound into the lib; then Space keep, Enter keep + back, Esc delete' },
    { k = 'q @', d = 'record macro (q a .. q) / play: @a register, @1..9 @A..Z saved and built-in (the @ popup lists them, same keys as \\ q), @@ the last, @/ by name (type to filter); Opt+Shift+2 - the big macros panel at the cursor; with the keyboard on Shift+2 is a note - use Opt+Shift+2 or hide the keyboard (m) for @' },
    { k = 'v V', d = 'visual block / visual lines (V is the REAPER time selection too); in VISUAL a - smart select (as Paketti; the cursor stays): first the column over the whole pattern, a wider - the bar on all tracks, half the pattern, the pattern; i narrower - the column in the bar, in the beat; Ctrl+Shift+h j k l - move the selection' },
    { k = 'H J K L', d = 'select: visual block from here, Shift+hjkl extends it (tracks: Option+h l)' },
    { k = 'zA', d = 'every track: empty columns (delay, commands), extra note subcolumns, envelopes and MIDI lanes with nothing in them - hidden; again - all back' },
    { k = 'za zF', d = 'fold track: wave + notes, envelopes as a thin line / zF all <-> open all (:fold, :unfold)' },
    { k = 'zr zR', d = 'router: the fx chain of the cursor track with its routing in place of the tracker / big router over the whole window' },
    { k = 'Ctrl+Cmd+F12', d = 'restart the tracker from its files (as :reload) - after an update, no REAPER restart' },
    { k = 'zf zF', d = 'DSP: fold the module under the cursor into a narrow strip (x B on top, its name vertically; zf again or a click on the name - unfold) / fold all modules (all folded - unfold all)' },
    { k = 'zl', d = 'DSP: the list of all modules of the chain (type to search), Enter - the cursor on it' },
    { k = 'zp', d = 'DSP: the preset list of the module under the cursor (also when its < preset > does not fit in the header)' },
    { k = 'zP', d = 'DSP: modules with pages (Surge XT and every big plugin - its sections osc filter env lfo mod fx are found in the parameter names): all sections in one pane under their titles (default) / one page with tabs (where - option DSP page tabs)' },
    { k = 'css csm csl', d = 'DSP: size of the drumrs5k pads - small (more rows) / medium 4 x 4 / large 4 x 4 (m > s, spectral wave, labels, group)' },
    { k = 'z!', d = 'fold track into a one-letter strip (was zC)' },
    { k = 'zC', d = 'monitor FX: the chain window of the monitoring FX (after the master, only to the speakers); also the MFX button in the master header' },
    { k = 'z> z<', d = 'all tracks one field wider / narrower (as Cmd + horizontal wheel; 3z> - three steps)' },
    { k = '- +  Opt+Shift+J K', d = 'zoom rows: LPB down / up, 1..128 (as Cmd + wheel); Opt+Shift+J - LPB up (opens rows), Opt+Shift+K - down (folds them), no Shift for + on a German layout; a + at the right of a note column - more notes folded into that row, LPB + shows them; a ~ there - the track has automation on that row that you do not see as a column (option mark automation rows) - a row is shorter / longer, the matrix lengths follow (16 / 32 / 64 steps)' },   -- 18 окт: зум мышью тоже вспыхивает здесь
    { k = 'z. z,  Opt+Shift+L H', d = 'the cursor track wider / narrower (its own width): its columns open / close one step at a time; a count - N steps (3 Opt+Shift+L)' },
    { k = ':reg', d = 'view only the region of the cursor / whole track (all | reg above the region name)' },
    { k = 'visor / cmd: dd yy p c', d = 'master columns visor and cmd: dd cut, yy copy, p put on the cursor row (move = dd j p), c / r edit the text (:vis / :mcmd), Enter - visor: pick with previews, x delete; w b e - next / previous marker', t = {} },
    { k = 'env: field 2', d = 'segment shape: INSERT letters sqr slo fas fae bez, ^A ^X cycle, :shape fas' },
    { k = 'env: Ctrl+Opt+1..6', d = 'segment shape of the point on the row, in any field and mode: 1 lin 2 sqr 3 slo 4 fas 5 fae 6 bez' },
    { k = 'i', d = 'INSERT: the keyboard writes notes (layout frow / qwerty / renoise - options)' },
    { k = 'I', d = 'INSERT from the start of the row: the note field of the track (as in Vim)' },
    { k = 'a', d = 'all automation of the cursor track - envelopes (fx parameters too) and MIDI lanes - shown / hidden, one press toggles; all tracks - the envs button' },
    { k = 'A', d = 'automate: pick any parameter of the track (fzf) - envelope column, or a take envelope of the note' },
    { k = 'Opt+A', d = 'the last touched parameter (a knob you just moved, any track) - its envelope column, cursor there' },
    { k = 'ze', d = 'on a note column: the window of the track instrument (slixer too; again - close it). On an envelope column: the effect and parameter it drives in the title, e - that effect window; its view - c curve, v values (like a command column), s steps (a fader on every row, as a 303 step sequencer: square points, drag across the rows with the mouse in any mode), b values and bars (the number and a line under it, longer - more, as MIDI CC). On a MIDI lane (PAT CC PB AT): b values and bars, s steps, v values, c the curve canvas' },
    { k = 'Enter (envelope selection)', m = 'curves of the selection', d = 'VISUAL on an envelope column, Enter - curves as cells with a preview (dim - now, bright - after): u ramp up, d down, e exp, g log, s s-curve, w sine, t triangle, a saw, q square, r random (in the range of the values; a flat line - from 0 to it), i invert, x reverse, m more, n less, k j up / down a step, o smooth, p 8 steps, f flat; h - draw by hand (the column as steps, drag with the mouse); u - undo' },
    { k = '> < N>', d = 'loop: item to region / region to item / N rows', t = { '>', '<' } },
    { k = '[ ] ( )', d = 'octave down / up, instrument previous / next' },
    { k = '/', d = 'commands at the cursor (fzf): the actions of the cell, the keys of the module, :commands - content is found with f (jump labels)' },
    { k = 'n N *', d = 'next / previous match of the last search, search the name under the cursor' },
    { k = ':', d = 'command line (Tab completes)' },
    { k = 'Enter', d = 'the values of the field (notes, instruments, vol, commands; on an envelope / MIDI lane - what to insert); PT-mode on the note field: inserts an empty row as Return in ProTracker (Shift - all channels)' },
    { k = '\\  \\\\', d = '\\ - the menu of what is under the cursor (note, envelope, clip ...); \\\\ - the main menu of everything (v view, P project, o options ...); in a module - its quick menu' },
    { k = '\\ o o', t = {}, d = 'the options window (all options, also :options)' },
    { k = 'tg  t}  t+ t-', t = {}, d = 'manual Euclid / polymeter by item geometry: tg glues every item of the cursor track in the pattern into one; t} on a row of it - the loop ends here, the item repeats it to the pattern end (k notes in n rows = Euclid); t+ / t- - the item rate x2 / /2' },
    { k = '\\ q', t = {}, d = 'quit REAPER (as File: Quit - it asks to save a changed project)' },
    { k = '\\ k', t = {}, d = 'keyboard modes: m - notes, p - patternkb (the note keys play the patterns); the mode word shows it (УЗОРКЛАВЪ)' },
    { k = '\\\\', d = 'the context menu: what can be done with what is under the cursor (the same as the right click)' },
    { k = '?', d = 'any REAPER action in the tracker style (fuzzy, the recent ones on top)' },
    { k = 'help', d = 'the help (all modules): the help button of the main module - j k line by line through all sections, J K section, / search, o - the help in the browser; :tutorial - the tour (no hotkey: F1 is free)' },
    { k = '^/ ⌥/ ⌘/', d = 'search: all effects / the DSP chain of the track / files' },
    { k = '\\Ps', d = 'save project (\\PS: save as)' },
    { k = 'f', d = 'hint labels: jump anywhere by two letters; the tracker first - every note, every beat row (darker dots) of each track; in INSERT too, on the note field (where f is not a note; in vol / fx it is hex F)' },
    { k = 'tt', d = 'new track after the cursor track (3tt - three)' },
    { k = 'Cmd+A', d = 'select everything you see in the module: the tracker - all columns x the rows of the view (proj / sec / pat) as a VISUAL block; the curve canvas - the whole span (sel). Ctrl+A stays +1 on the field' },
    { k = 'Cmd+C X V', d = 'copy / cut / paste in every module, as everywhere: the copy keys of the module (yy / dd / p, in VISUAL y / d; the matrix - its block); in INSERT the tracker steps out and back' },
    { k = 'T', m = 'transposer', d = 'Shift+T - the transposer dropdown: semitones, octaves, degrees of the key, to the chord of the row, just, 1/6 tones, where (selection / column / track / all tracks in what you see); listen - hear it moved; also :tr, the harmonizer button transpose' },
    { k = 'F1 F2', d = 'in the tracker: transpose the selection (else the note of the row) -1 / +1; F11 F12 - an octave (as in Renoise); F2 from another module - to the tracker' },
    { k = 'Opt+F1 F2', d = 'transpose the selection (else the note of the row) -1 / +1 from any module; Opt+F11 F12 - an octave' },
    { k = 'h (wave)', d = 'wave column (wave mode column): h from the note goes into the wave, l back; there s - cut the note at the row, S - a stretch marker at the row start (one in the row - snapped there), x - remove it, J K - pull the hit a row down / up (3J - three); the mouse drags the amber line too' },
    { k = 'R (VISUAL)', d = 'razor edit: the selection (rows x tracks) becomes a REAPER razor area - REAPER razor actions work on it and it shows in the arrange view' },
    { k = 'rip', d = 'ripple editing (REAPER, the transport button: off / per track / all tracks): x on a note deletes it with its rows - what is below moves up (per track - this track, all - every track)' },
    { k = 'Cmd+F1 F2', d = 'microtone: the selection (else the note of the row) down / up 1/6 tone (72-EDO; marks after the octave: C-4^ C-4^^ C-4^3, v - down); MIDI - MPE: the note on its own channel 2..16 with a pitch bend (range 48; the synth in MPE mode - Surge XT is switched on by itself), audio items - fractional pitch; Shift - the track' },
    { k = 'Shift+F1 F2', d = 'transpose the track in the pattern -1 / +1; Shift+F11 F12 - by octave' },
    { k = 'Ctrl+F1 F2', d = 'transpose the whole pattern (every track) -1 / +1; Ctrl+F11 F12 - by octave' },
    { k = 'Ctrl+Shift+F1 F2', d = 'transpose the column (subcolumn) in the pattern -1 / +1; + F11 F12 - by octave' },
    { k = 'zt zb', d = 'the cursor row to the top / to the bottom (as in Vim)' },
    { k = 'Opt+T f / o', t = { 'T' }, m = 'take fx: add / open', d = 'Opt+T f - add a take fx to the note under the cursor, Opt+T o - its take fx chain in DSP' },
    { k = 'tT', m = 'track from template', d = 'a track from a template after the cursor track' },
    { k = 'tF', m = 'into left folder', d = 'the cursor track goes into the folder of the track to the left' },
    { k = 'Opt+Shift+R', m = 'last played as a phrase', d = 'as R, but what you played becomes a new phrase (p1, p2 ... in the phrases pane) and its trigger note goes on the cursor row; edit the phrase once - every use follows' },
    { k = 'X', m = 'cut the row of all tracks', d = 'the cursor row on every track into the register (3X - three rows); p puts it back, rows below stay where they are' },
    { k = 'R', m = 'insert last played', d = 'the last phrase you played on the armed cursor track (REAPER retro MIDI buffer - it records while armed, even stopped) goes in from the cursor row; played while the transport ran - where it was played: the first note on the row, the silence before it cut; longer than the pattern - a menu: duplicate the pattern (the rest goes into the copy), the rest into the next pattern, cut, squeeze in' },
    { k = 'tm  t23m t23s', m = 'mute / solo tracks', d = 'tm - mute the cursor track; t + track numbers + m / s - mute / solo those tracks (0 = 10), as t135a arms them; the numbers can go first too: 135tm = t135m' },
    { k = 'Opt+- =  Ctrl+Opt+- =', t = {}, d = 'Opt - note subcolumns of the cursor lane - / + (Option lights the - + over the note field); Ctrl+Opt - the fields of the cursor track one by one: vol, delay, command 1..4 (vol and delay count as effect columns; - back down to the note); Opt+Shift+L / H - the whole width step (strip .. note subcolumns) (on a command field it continues the command -1 / +1); in INSERT with the keyboard on the note field Option+key is a chord' },
    { k = 'tu', m = 'unsolo / unmute all', d = 'every track: solo and mute off' },
    { k = ':key', m = 'key of the song', d = 'key of the song from the MIDI notes of every track (not kits, by length): D dorian, A minor ...; :key Am / :key D dorian - set it; :key mark - notes out of the key are red (on by default); :key snap - typing in the key (a key off the scale gives the nearest degree; not kits / slices); :key off - no key' },
    { k = ':prog', m = 'progression', d = ':prog I V vi IV or :prog Am 2 | F 2 | G7 1 (lengths in bars) - from the bar of the cursor into the chord lane of the master (ch: markers); :prog notes ... - also the chords as notes on the cursor track, voice-led (the nearest inversion to the chord before)' },
    { k = ':chord hear', m = 'chords by ear', d = ':chord hear [beat] - chords from the sound of the cursor track (its audio items, before its FX; chroma like jf_chorddetect, no external tools): the V selection, else the whole song, into the chord lane of the master; MIDI tracks - :chord read' },
    { k = ':transcribe', m = 'audio -> MIDI', d = ':transcribe - the audio item on the cursor row becomes MIDI: selects it and opens jf_transcribe (aubionotes runs from there, on this command only); Transcribe, tune the cleanup, Apply - a new MIDI track under it' },
    { k = ':harmonize', m = 'harmonize a melody', d = ':harmonize [beat|half] - the melody of the cursor track (the V selection, else the pattern) gets the best chord of the key (:key) on every bar (beat / half bar) in the chord lane of the master; the message shows the next best in brackets; Enter on the chord column - other chords of the key' },
    { k = ':voice2', m = 'second voice', d = ':voice2 3 | 6 | -3 | -6 - a second voice in the key for the notes of the selection (else the row): a third / sixth above or below' },
    { k = ':neg', m = 'negative harmony', d = ':neg - the notes of the selection (else the cursor row, all tracks) mirrored around the axis of the key (C: between Eb and E - C<->G, E<->Eb, F<->D: C becomes Cm, G7 - Dm7b5), the octave kept; again - back. In the harmonizer - n or the button try neg' },
    { k = 'harmonizer is / try', t = {}, d = 'under the degrees: 12 chroma bars (C ... B) of what sounds - the selection, the cursor row of all tracks, the chord lane, else the sound of the cursor track (a beat from the row); the best chord - cyan bars, its root amber; a microtone (72-EDO, C-4^) - a pink line in its bar: middle - in tune, left - lower, right - higher (the edge - half a semitone). is - chord candidates with weight (click - into the chord column of the master); try - neg (the notes mirrored, n), P R L (neo-Riemannian: parallel, relative, leading-tone), tt (tritone substitution) - click writes that chord on the row; hover - the staff shows it' },
    { k = ':bass', m = 'bass from chords', d = ':bass [fifth] - a bass line on the cursor track from the chord lane (the pattern or the V selection): the root of every chord (the /bass note if given), two octaves below the input octave; fifth - root, then the fifth' },
    { k = ':chord lead', m = 'voice leading', d = 'chords written by :chord Cm7 / the harmonizer degrees / :prog notes: on - the inversion nearest to the previous chord of the track (default), off - root position stacks' },
    { k = 'Opt+Shift+F1 F2', m = 'transpose by degrees', g = 'transpose', d = 'transpose the selection (else the note of the row) one degree of the key (:key) down / up - C E G in C major goes to D F A; a note off the key goes to the nearest degree first' },
    { k = ':chord read', m = 'chords from the notes', d = 'chords of the song by bar (:chord read beat - by beat) from the MIDI notes -> the chord column of the master (markers ch:); chordfollow tracks follow it' },
    { k = 'chord column', t = {}, d = 'master column chord (:chord lane): Enter - chords of the key by degree (1..7, Shift - sevenths), c - type a name, x - remove, dd yy p - move / copy' },
    { k = 'tw', m = 'wave column of track', d = 'the wave column of the cursor track: show / hide; again - auto (only with audio or a drumrs5k kit with samples)' },
    { k = 'g12 Enter', t = {}, m = 'go to row number', d = 'go to row 0012 (also 12gg)' },
    { k = 'Opt+Space', m = 'close the gap', d = 'the empty rows from the cursor to the next note of the subcolumn go out, the note (and the rest of the pattern below) comes up; on a note - the gap after it' },
    { k = 'Cmd+H Cmd+L (curve)', m = 'canvas <-> curve list', d = 'automation curve page: Cmd+H from the canvas - into the list of curves (track folders, on its left), Cmd+L - back; again Cmd+H - the pane on the left; in the list j k rows, l / Enter open a folder or take a curve (Enter - back to the canvas), h close the folder' },
    { k = 'Opt+w Opt+b', m = 'next / previous note', d = 'the next / previous note of this subcolumn only - past OFFs, commands and the other subcolumns (w / b - the whole track); 3 Opt+w - three notes' },
    { k = 'Opt+W', d = 'the cursor to the master columns (Shift+Opt+w); a folded master opens while the cursor is on it (auto / fold in its header), l from the last track - the same' },
    { k = 'zs', d = 'view: only the section of the cursor (intro, hook ...) / the whole project (the sec button); transpose (F1 F2 ...) takes what you see' },
    { k = 'zp', d = 'view: only the pattern of the cursor / the whole project (the project | pattern buttons, :reg)' },
    { k = 'zu', d = 'unfold: the folded notes (cyan line under the row, +N) of the selection / cursor row - LPB rises to the smallest one that gives each its row (up to 128); zu again - the previous LPB (:unfold)' },
    { k = 'zvw', d = 'wave view: own column / in the note field / item background / off, or wave only / text only' },
    { k = 'zW', d = 'zoom on the item under the cursor: only its rows, LPB to fit the screen; again - back' },
    { k = 'zw', d = 'width: all tracks the same width, the widest at which all fit (button W next to autozoom); again - slim: each track only as many command columns as its notes use, empty tracks compact' },
    { k = 'zl', d = 'LPB presets of the view: straight (4 16ths, 8 32nds ...), T triplets (3 6 12 ...), D quintuplets (5 10 20); the LPB cell shows T / D too' },
    { k = 'zh', d = 'height: what the view shows (pattern / section / project) fits the screen - the finest LPB at which it does (button H); again - slim: the coarsest LPB where every note still sits on a row' },
    { k = 'zZ', d = 'fixed cursor on / off: the cursor row stays in the middle, the pattern scrolls under it (zz - centre once)' },
    { k = 'gt  gT', d = 'go to a module of the layout (menu by its letter: d dsp, f fx, a automation …) / REAPER project tab; 3gt - the third at once; the next tab of a module - Tab' },
    { k = ':transpose', d = 'transpose popup: -24..+24 and where - selection / column / track / pattern (also the right-click menu); :transpose N - the selection by N; :transpose dN - by N degrees of the key' },
    { k = 'td tx tp', d = 'delete (= cut, as d in Vim) / cut N tracks from the cursor track (5td - five), paste them after the cursor track; dd deletes rows (5dd - five)' },
    { k = 'ts', d = 'new track "send": the selected tracks (or the cursor track) send into it - a bus / fx return' },
    { k = 'tr', d = 'new track "source": it sends into the selected tracks (they get a receive)' },
    { k = 'tn tc', d = 'track: rename / colour (list: palette, random, default, custom dialog)' },
    { k = 'ty', d = 'duplicate the cursor track (copy right after it)' },
    { k = 'ta ti', d = 'track: rec arm / input (list); 6ta - six tracks from the cursor, t135a - tracks 1 3 5 (REAPER numbers, 0 = 10)' },
    { k = 'tA', d = 'autoarm on every track, new ones too - the track under the cursor records (= option rec follows selection); again - off; the autoarm all button over the row numbers too' },
    { k = 'tI', d = 'track input: the active source - play it within 0.6 s (a MIDI key -> that device and channel, else the audio input that started sounding last, stereo if its pair sounds too); your jf_smart_set_input.lua' },
    { k = 'tl tf', d = 'track: fixed lanes on / off / add fx (fzf)' },
    { k = 'tR', d = 'track routing: sends S, receives R, hw outs O (popup)' },
    { k = 'tj tk', d = 'move the track right / left (3tj - three places)' },
    { k = 'mouse', d = 'right drag: select a block (a right click without moving: the menu); left drag: move the event or the selected block under the mouse; Shift+drag: extend the block (option select block with = left swaps the buttons)' },
    { k = '2f', d = 'mixer: f on a dB mark glides the fader there in 2 bars (2,f - beats); from the next bar when playing, from the cursor when stopped; the mark typed in CAPITALS (Shift) dips: there in the first half, back in the second (no count - 1 bar)' },
    { k = 'Ctrl+mouse', d = 'hold Control and move the mouse: the selected params / faders change (else the one under the mouse, else the keyboard slider); up = more, Shift fine; two selected = XY. Cmd+click: add / remove, Shift+click: a range of params of one effect, Esc: clear' },
    { k = 'Ctrl+Opt+mouse', d = 'CONTROL (starts after a small mouse move, so Ctrl+Opt+keys do not open it): a bank of up to 8 sliders nearest the mouse is framed (fx parameters in a track header, v / p of a track, a DSP device column, mixer faders, an XY pad); horizontal sliders - up / down picks, sideways changes; vertical faders - sideways picks, up / down changes; XY - both; it moves only after a clear move along its axis (Shift fine); let go - one undo' },
    { k = 'Ctrl+Opt (automation)', d = 'the tracker cursor on an envelope / PB / CC lane: CONTROL is one big slider of the value of the cursor row (sideways, Shift fine); let go - written' },
    { k = 'Ctrl+Opt+Shift (automation)', d = 'JOG on the lane under the tracker cursor: up / down - the step (row), sideways - its value; the pen carries the value to the next steps; let go - all written, one undo' },
    { k = 'Ctrl+Opt+Cmd+mouse', m = 'reform gestures', d = 'REFORM gestures over selected notes (v / V): mouse up / down - shift by rows, two fingers up / down or a pinch - scale, two fingers sideways - curve, Shift fine; let go - kept (u - undo)' },
    { k = 'Opt+Cmd+mouse', d = 'tracks gesture: the window width is split into one zone per track - move sideways to pick a track, then up / down moves its fader (Shift fine); clearly sideways again picks another' },
    { k = 'Cmd+Shift+1..9', d = 'select / unselect channel N in REAPER - f on a dB mark moves all selected faders (macOS keeps Cmd+Shift+3 4 5 for screenshots unless you turn those off)' },
    { k = 'Cmd+F11', d = 'fullscreen <-> docked (quick option title: title bar on / off); F11 alone is a note (frow)' },
    { k = '`', m = 'pedal / note-off', d = 'NORMAL with the keyboard (KEYS): the sustain pedal (CC64) while you hold it; INSERT: note-off (under an ended note - stretches it here); the whole sample: Ctrl+Shift+1 (Ctrl+Shift + a slice key - from that slice)' },
    { k = 'm', d = 'KEYS on / off (the keyboard; the mode word shows KEYS): on - it has priority, 1 f1 2 f2 3 ... play notes (layout qwerty: q 2 w 3 e), [ ] octave (qwerty: z x), Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'z_', d = 'minimize the pane in focus to its tab row (any pane but the tracker; in the matrix - z then _; was zm); again, a click on its tab or focusing it - open' },
    { k = 'zm', d = 'the mixer on / off (= F3)' },
    { k = 'zM', d = 'master properties: fx chain, monitor FX and its bypass, mono, routing, visible in REAPER, tempo envelope, 0 dB (also the i button in the master header)' },
    { k = 'zx', d = 'crossfade editor of REAPER: the note under the cursor and the notes of the track overlapping it' },
    { k = ':pitch', d = 'pitch of the sample under the cursor (audio note on the row, or the lib sample): a take marker per slice - the note (A3, +cents) or, for a chord, its name (Am); again - replaced. No processes (YIN / chroma)' },
    { k = 'zX', d = 'the mixer pane x1.5 taller than the canonical size (the size of the dsp), again - back' },
    { k = 'Tab Shift+Tab', d = 'next / previous track (in the tracker); in the wave column - the next / previous hit: a stretch marker or a note start' },
    { k = 'Opt+note', d = 'chord typing on a not sliced sound (on a sliced one Option+note = the selected slice at that pitch, Option+Shift - listen): the note goes to the next subcolumn of the row (a new one if needed), the cursor follows; all chord notes ring while you type, a 1.5 s pause ends the chord (length = typing time) and the cursor goes below it' },
    { k = 'keys button', d = 'keyboard on / off (also m; quick options keys): on - it has priority, 1 f1 2 f2 3 ... play notes, [ ] octave (qwerty: q 2 w 3 e ..., z x octave), Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'Space', d = 'play / stop' },
    { k = 'Shift+Ctrl+Space', m = 'play at /2', d = 'play at x0.5 (x2 - the button under play); again or Space - stop, x1 comes back' },
    { k = '⌥⌘Space ⇧⌘Space', d = 'listen step on / off (the row the cursor lands on plays on the cursor track) / listen line on / off (the row, all tracks)' },
    { k = 'Shift+Ctrl+F', d = 'sample find for this place: pick the database first (it is remembered), then as Shift+F' },
    { k = 'Shift+Opt+F', d = 'sample find for this place - into the sampler (the lib of the track + a note); Shift+F - an audio item' },
    { k = 'F', d = 'sample find for this place: the browser db with find - j k listen, the channel shows the wave of the picked one over its length in rows, Enter puts it here, Esc cancels (follow playhead - its button / option)' },
    { k = 'o', d = 'reveal item in REAPER' },
    { k = 'Opt+BS  C-A-M-J K', d = 'insert an empty row (no Insert key on a Mac): Option+Backspace - at the cursor, Ctrl+Option+Cmd+J - below it, K - above; Shift - all tracks; a count - N rows' },
    { k = 'BS Ins', d = 'delete / insert time in region (Shift: all tracks; option BS mode: pattern - as Renoise, a clip up to the pattern end keeps its length / track - the whole track up to =LIB), in INSERT too: BS on the note field deletes the row, everything below moves up (Del - only the event); no Insert key (Mac) - :instime N, :deltime N' },
    { k = 'Enter on fx field', m = 'command or parameter (fzf)', d = 'Enter on a command field (a selection too) - fzf: on top the parameter selected in DSP, the one touched last in REAPER and the recent ones of the track, then the note commands (0S start offset ...), then every parameter of the track (● - its envelope shown); a command - its values, a parameter - its envelope column next to the track, the cursor (and the selection) on it' },
    { k = 'fx field', d = 'two halves, as in Renoise (l / h step between them): the left one is the code - one letter is 0x (D = 0D, U = 0U), S_ and Z_ are prefixes (SI, ZT), 0D works too; then the right one - two hex digits write it. On the value half alone the digits keep the code there (or the dim one running from above: 08 under 0D10 = 0D08). h j k l start no code, so they still move; Enter - the list of codes' },
    { k = 'Opt+Tab Opt+S-Tab', d = 'the next / previous own tab of the module in focus (browser: files db pm proj libs presets; lib sections; automation pages); a module without them - the tabs of its pane stack; one tab - the next pane' },
    { k = 'Cmd-Enter', d = 'focus the instruments (lib)' },
    { k = ':cc', t = {}, d = 'CC lane: ReaControlMIDI on the cursor track (its window opens the first time - set the CC numbers there), pick its parameter - the envelope becomes a column: hex per row, curves, automation items' },
    { k = 'S-Esc', t = {}, d = 'remove the REAPER time selection (any module)' },
    { k = 'Opt-Enter', d = 'select the instrument of the note under the cursor in the lib' },
    { k = '\\\\q \\\\Q', t = {}, d = 'context menu on a sample: q - the nearest peak onto the row grid; Q - pick the peak, j k to a row, Enter moves it there (stretch marker)' },
    { k = 'vol xx', t = {}, d = 'on any row inside a sample (INSERT, vol field): a point of its take volume envelope - ramps by values, as in Renoise; x-fade by vol writes its ramps the same way (options: x-fade by)' },
    { k = '/ in a name', d = 'renaming a track, instrument, item or region: / lists common names (your SWS auto-colour rules + kick, pad, bell, texture ...), type to filter' },
    { k = 'hold Shift / Ctrl / Opt / Cmd', t = {}, m = 'what a modifier does', d = 'hold a modifier (or two) half a second, no key - the help pane lists what Shift / Ctrl / Opt / Cmd + ... do here, then everywhere' },
    { k = 'F2', d = 'back to the tracker from anywhere (closes the routing diagram, big router / chain); the item tab is in the F4 circle' },
    { k = 'F3', d = 'mixer on / off (in its routing strip Option+click on a routing name or a wire removes it)' },
    { k = 'F4', d = 'the top pane: its tabs in a circle (in the lib with lib tabs - the lib tabs)' },
    { k = 'F5 F6', d = 'scopes / master; the same key again - back to the tracker' },
    { k = 'help', d = 'this panel: the help button of the main module - the whole help' },
    { k = 'Cmd+ Cmd-', d = 'bitmap scale x1 / x2 / x3; a vector font also has x1.5' },
  } },
  insert = { title = 'tracker INSERT (keyboard)', e = {
    { k = '1 f1 2 f2 3 4 f4 ...', d = 'piano (layout frow, default): digits 1..0 white keys C..E, F1 F2 F4 F5 F6 F8 F9 black (17 keys; - = F10 F11 F12 free); [ ] octave, { } velocity; F-key shortcuts are off while the keyboard plays; the letters stay Vim - in INSERT too (w x dd p ... act as in NORMAL, then INSERT again), digits are notes, not a count' },
    { k = 'q2w3er5t6y7ui9o0p', d = 'piano (layout qwerty, options): top row + digits, q = C of the octave',
      t = { 'q', '2', 'w', '3', 'e', 'r', '5', 't', '6', 'y', '7', 'u', 'i', '9', 'o', '0', 'p' } },
    { k = 'Shift+note', d = 'with the option Shift+keys preview: listen only, nothing written (off by default - leave INSERT to listen, the keyboard plays in KEYS)', t = { 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P' } },
    { k = 'Option+note', d = 'sliced: the selected slice at that pitch (option slice pitch from: 1 or 6); not sliced - beside: a new subcolumn, the old note keeps playing; Option+Shift - listen' },
    { k = 'Ctrl+Shift+note', d = 'sliced: that slice to the end of the sample (Ctrl+Shift+1 - the whole sample); Ctrl+digit itself is the step' },
    { k = 'frow: letters', t = {}, d = 'with frow every letter is a NORMAL command (h j k l w x dd p ...), then back to INSERT; [ ] octave, { } velocity, ( ) or Opt+J / K instrument; the qwerty: lines below are for the qwerty layout' },
    { k = 'h j k l', d = 'field / row' },
    { k = 'qwerty: G g', t = { 'G', 'g' }, d = 'last row / first row (Shift+H J K L - a selection)' },
    { k = 'qwerty: b n', t = { 'b', 'n' }, d = 'bar back / forward' },
    { k = 'qwerty: z x', t = { 'z', 'x' }, d = 'octave down / up' },
    { k = 'vel  human', d = 'under the keyboard: vel - a slider of the inserted velocity (drag); in the step block human - every inserted note a little different: timing +-10 ms, pitch +-8 cents, velocity +-12 / volume +-1 dB at 100 % (click: 0 / 25 / 50 / 100 %)' },
    { k = 'qwerty: c C', t = { 'c', 'C' }, d = 'velocity -8 / +8' },
    { k = '.', d = 'repeat the last edit (as in NORMAL); the instrument - Opt+J / K' },
    { k = 'qwerty: ;', t = { ';' }, d = 'the whole sample at the cursor' },
    { k = 'qwerty: a', t = { 'a' }, d = 'step auto: jump past the inserted item' },
    { k = 's', d = 'select from here (visual; the edit returns to INSERT); Shift+hjkl extends' },
    { k = '⌥s', d = 'step: type rows (:step N)' },
    { k = 'd', d = 'Vim delete operator (d3w, dd), back to INSERT after' },
    { k = 'qwerty: M S', t = { 'M', 'S' }, d = 'mute / solo the cursor track - on any column, the fx column too (there lowercase s / m start the codes SI ... / 0M)' },
    { k = 'qwerty: f', t = { 'f' }, d = 'next fx field (note > fx1 > fx2 ...)' },
    { k = '^', d = 'note cut ^^^: the sound stops at once, no release (MIDI - CC120 all sound off on the channel, audio - the item ends with no fade); ` is the note end === (it releases: the synth envelope, audio - the OFF release fade); a free OFF (nothing sounds) shows OFF. Glyphs: options end of note / free OFF' },   -- 2 ноя
    { k = '` ~ C-~', d = 'note-off: ` this subcolumn, ~ (Shift+`) every track (Shift = all tracks, as Shift+BS), Ctrl+~ the whole track; :off / :off all; on the command field ` stops what runs there (dim) - 0D.. -> 0D00' },
    { k = 'Esc', d = 'back to NORMAL' },
    { k = 'Opt+F1 F2', m = 'transpose selection', g = 'transpose', d = 'transpose the selection (else the note of the row) -1 / +1 semitone; Opt+F11 F12 - an octave (as in Renoise)' },
    { k = 'Shift+F1 F2', m = 'transpose track', g = 'transpose', d = 'transpose the track in the pattern -1 / +1; Shift+F11 F12 - an octave' },
    { k = 'Ctrl+F1 F2', m = 'transpose pattern', g = 'transpose', d = 'transpose the whole pattern (every track) -1 / +1; Ctrl+F11 F12 - an octave' },
    { k = 'Ctrl+Shift+F1 F2', m = 'transpose column', g = 'transpose', d = 'transpose the column (subcolumn) in the pattern -1 / +1; + F11 F12 - an octave' },
    { k = 'Cmd+F1 F2', m = 'microtone', g = 'transpose', d = 'microtone 1/6 tone down / up: the selection (else the note of the row); Cmd+Shift - the track' },
    { k = ':transpose', m = 'transpose popup', g = 'transpose', d = 'popup -24..+24 and where (selection / column / track / pattern); :transpose N - the selection by N; :transpose dN - by N degrees of the key' },
    { k = 'BS', m = 'delete note / row', d = 'INSERT, the note field: on a note - delete the note; on an empty row - delete the row (below moves up; Shift - all tracks)' },
  } },
  matrix = { title = 'matrix of regions (slots)', e = {
    { k = 'h j k l', d = 'cell: track left / slot down / slot up / track right' },
    { k = 'gg G', d = 'first slot / last slot' },
    { k = 'chain row', t = {}, d = 'the patterns pane (gt / T): the cubes of every pattern (A1 .. grey - not made yet) and the chain row under them; a click on a cube - hear it, a double click - it joins the chain; h j k l Enter Space n C there' },
    { k = 'playlist row', t = {}, d = 'over the arrangement: the section names of the song on top, the playlist (song order) under them; a click on a section above - it goes to the end of the playlist; s - keys there: h l pick, Enter adds (3 Enter - three times), x drops the last one, Space plays, Esc back; a click on a playlist word - play from it, > - play all, x - clear' },
    { k = 'f a1', m = 'hints: jump to pattern', d = 'hints: every pattern cube is labelled by its own code - f then a1, bc ... jumps to that pattern in the tracker' },
    { k = 'C', m = 'seq: type the order', d = 'seq: opens the arranger pane and types the pattern order (A1 A1 B1x2 C1:16 D1-8, Tab completes)' },
    { k = 'amber corners', t = {}, d = 'a note crosses the pattern edge: bottom right - it runs into the next pattern, top left - it came from the previous one; deleting a pattern trims such audio notes, no tails left' },
    { k = 's', m = 'section menu', d = 'section menu of the cursor slot: new (from selected slots / time selection), duplicate, linked, launch, show, loop, rename, remove' },
    { k = 'S', m = 'song: section row', d = 'song: the section row above the playlist (h l, Enter, 3 Enter, x, Space, Esc; any other key - back to the matrix)' },
    { k = 'buttons', t = {}, d = 'menu view sync trim patternkb timesel follow + live in the empty corner over the slot numbers (follow - the matrix cursor goes with the tracker cursor, on by default) (left of the track names); folded - a row on top' },
    { k = 'Ctrl+Cmd (trackpad)', t = {}, d = 'jog / scrub: slide along a slot row - the pattern loops and plays from that place (to the tracker row); another row - another pattern; let go - stop, loop and cursor as before' },
    { k = 'patterns (pane)', t = {}, d = 'its own pane over the matrix: a grid of pattern codes (row - letter, column - variant 1..F; bright - in the song, green - playing) and the chain; h j k l pick, Space hear, Enter - to it in the tracker, n note, a - append to the chain, i - insert before the chain cursor; j from the last row / Tab - the chain row: h l w b move, x dw delete, dd clear, y p P, Enter - to it, Space - play from it, C - type, k / Esc - back' },
    { k = 'patterns: several', t = {}, d = 'the patterns pane: Shift+arrows grow the selection, Shift+click / v - one in or out (cyan), Esc - none; the row on top: menu glue split copy name; m / rclick - the menu (listen, go, glue, split, copy, rename, note, chain, remove from the song, select all / in the song / unused)' },
    { k = 'J (patterns)', m = 'glue patterns', d = 'the selected patterns become one where they play right after each other in the song (A1 A2 -> E1; the same chain - one code); u - undo' },
    { k = 's (patterns)', m = 'split pattern', d = 'split the selected patterns in half / 3 / 4 / by bars / at the tracker cursor, in every place of the song: the first part keeps the name, the rest - next variants (A1 -> A1 A5); items are cut at the edges' },
    { k = 'r (patterns)', m = 'rename pattern', d = 'rename the pattern - every place of it' },
    { k = 'm (patterns)', m = 'patterns menu', d = 'the menu of the selected patterns (also rclick on a cube, the menu button)' },
    { k = 'h (on the name)', m = 'select the section', g = 'move', d = 'onto the section strip: the whole section in a frame; Enter - its menu (duplicate - new patterns / linked, launch, loop, rename, remove; also a right click or a drag: Opt - duplicate, Cmd - linked), c - change the name, x - remove the section (patterns stay), Space - launch, j k - other slots, l / Esc - back' },
    { k = 'w b e', m = 'next / previous pattern', g = 'move', d = 'next / previous slot with a pattern (free bars .. skipped) / the last bar before the next slot' },
    { k = '0 ^ $', m = 'name column / last track', g = 'move', d = 'name column / last track' },
    { k = 'D BS Del', m = 'delete slot / cut cell', g = 'slot', d = 'on the slot number or name - delete the slot (like dd); on a cell - cut it (like x)' },
    { k = 'Enter', m = 'pattern list / rename', g = 'slot', d = 'on the slot number: the list of patterns - pick one for the slot (on a free bar - a linked repeat of it; :pat N types it); on the name - rename; Ctrl+Shift+H / L - previous / next pattern; a click on the arrangement name - the list of arrangements' },
    { k = 'o O', m = 'new slot after / before', g = 'slot', d = 'new empty 1-bar slot after / before' },
    { k = 'dd', m = 'delete slot', g = 'slot', d = 'delete slot: region + its time (goes to register)', t = { 'dd', 'd' } },
    { k = 'yy', m = 'yank slot', g = 'slot', d = 'yank slot into register', t = { 'yy', 'y' } },
    { k = 'yp', m = 'duplicate: free copy', g = 'slot', d = 'duplicate: an exact copy with a new name, not linked (button cln) - like Renoise', t = { 'yp' } },
    { k = 'p P', m = 'put after / before', g = 'slot', d = 'put register after / before (cells: paste at cursor)' },
    { k = 'A', m = 'alias: linked repeat', g = 'slot', d = 'alias: the slot repeated linked - same pattern, MIDI pooled and items grouped, edits in one change all (button als; also p of a yanked slot whose pattern still exists)' },
    { k = 'U', m = 'unique: unlink repeat', g = 'slot', d = 'make unique: unlink the repeat under the cursor - new name, own MIDI pool, no group' },
    { k = 'x', m = 'cut cell', g = 'block', d = 'cut cell (or block) to clipboard' },
    { k = 'n', m = 'rename region', g = 'slot', d = 'rename region' },
    { k = '=', m = 'type length', g = 'slot', d = 'type length: N steps, Ns seconds, Nb bars' },
    { k = '[ ]', m = 'length -1 / +1 bar', g = 'slot', d = 'length -1 / +1 bar (later slots move)' },
    { k = '{ }', m = 'length -1 / +1 step', g = 'slot', d = 'length -1 / +1 step' },
    { k = 'C-S-h C-S-l', m = 'previous / next pattern', d = 'pattern of the slot: previous / next (as Ctrl+Left / Right in Renoise)', t = {} },
    { k = ':patternkb', m = 'patterns on note keys', d = 'MPC style (the patternkb button; = :pads): the note keys play the patterns of the song - 1 f1 2 ... = the 1st 2nd 3rd pattern, the key shows by its name; MIDI notes too - C1 (36) the 1st, then by semitones (another note: MIDI learn pattern pads in the midi tab - works without patternkb); quant - seamless when the playing one ends (REAPER smooth seek), sudden - at once at the same place inside (a short gap: the render-ahead buffer refills); rec - record the order, again - write it after the song as linked repeats; off' },
    { k = ':pl', m = 'playlist as text', d = 'playlist (the playlist button - a block on top of the matrix): the order as text - A1 A1 B1x2 C1:16 D1-8 D1/2 B2+8 verse 4: pattern / section name or region number; xN repeat, :N the first N rows, /N a part, -N skip N rows, +N then its first N rows again; Tab completes names; play (seamless on whole patterns), write (after the song), new dup name del next prev - named playlists in the project' },
    { k = 'autoarm', m = 'auto-arm all tracks', d = 'button in the top left corner: auto-arm on every track (the selected track is armed for recording), again - off; lit when all have it' },
    { k = 'h past the first track', m = 'cursor to region name', g = 'move', d = 'the cursor goes to the region name (Enter / i - rename) and to its number < NN > (Enter - next pattern)' },
    { k = 'Ctrl+h j k l', m = 'move like hjkl', g = 'move', d = 'move like h j k l' },
    { k = 'Ctrl+Up Down', m = 'duplicate slot above / below', g = 'slot', d = 'duplicate the slot above / below, muted tracks left empty in the copy (Paketti)' },
    { k = 'M', m = 'mute cell', g = 'block', d = 'mute / unmute cell (Shift+m)' },
    { k = 'Space', m = 'play or queue slot', d = 'button space: cue - play from the slot, or queue it while playing (it starts when the playing one ends); space: play - play / stop, as in the tracker' },
    { k = 'F', m = 'sel: only selected tracks', g = 'view', d = 'sel: the tracker shows only the tracks of the selected cells (button sel; Cmd+click a cell adds it, Esc clears)' },
    { k = '+ N+', m = 'new region at end', g = 'slot', d = 'new region at the end (N+: N regions, one undo); n names it' },
    { k = 'v HJKL', m = 'block select', g = 'block', d = 'block select; in block: y copy, d x cut, M mute', t = { 'v', 'H', 'J', 'K', 'L' } },
    { k = '^C ^X ^V ^N', m = 'block copy / cut / paste', g = 'block', d = 'block copy / cut / paste / mute' },
    { k = 'u ⌘⇧Z', m = 'undo / redo', d = 'undo / redo' },
    { k = 'z', m = 'view menu', g = 'view', d = 'view menu (= the view button): i detail, f fill, r ruler, s s/e, b bpm column', t = { 'z' } },
    { k = 'z f', t = { 'z' }, m = 'fill: lit or empty', g = 'view', d = 'fill: cells show their content (lit) or stay an empty grid - only the view' },
    { k = 't', m = 'trim past region', g = 'slot', d = 'trim: cut items that run past their region (the button trim)' },
    { k = 'R', m = 'bar ruler on / off', g = 'view', d = 'ruler of bars on the left on / off (button ruler)' },
    { k = 'Tr', m = 'section from time selection', g = 'section', d = 'the time selection becomes a section: pick a quick name - intro verse pre-chorus chorus hook build drop break breakdown bridge solo outro, or another (:tsec name); a taken name gets a number (verse 2). The timesel button - the same and more (loop it, clear)' },
    { k = 'loop zone', t = {}, d = 'the bar ruler on the left of the slots: double-click - loop this slot (on the section strip - the whole section), drag up / down - several, Cmd+click - pick slots (the loop jumps from one to the next, seamless), Shift+click - extend; the time selection / loop shows as a [ there' },
    { k = 'Cmd+wheel', t = {}, d = 'zoom: slots taller / shorter - the rows of the pattern inside (as in the tracker; option zoom with: split - Option + wheel)' },   -- 18 окт: зум вспыхивает здесь
    { k = 'wheel', t = {}, d = 'mouse over the matrix, no focus needed: wheel - slots, horizontal wheel / Shift - tracks; zoom as in the tracker (option zoom with: cmd - Cmd + multiscroll both ways; split - Cmd horizontal, Option vertical, as in REAPER); scroll bars right and bottom' },
    { k = 'Esc Opt+Tab', m = 'back / next tab', d = 'back to the tracker / next tab (one tab - next pane)' },
  } },
  reform = { title = 'reform - reshape the selected notes and automation live (gr in VISUAL; idea: Reform for Renoise, aqu.surf/reform)', e = {
    { k = 'j k', d = 'row: scale, curve, shift, redistribute, anchor (notes / selection), values on, value from / to, value curve, value mode (remap / even)' },
    { k = 'h l', d = 'value (Shift: fine); on a switch row - switch it' },
    { k = 'Space', d = 'listen: play the selection from its start (again - stop)' },
    { k = '0', d = 'the row back to its default' },
    { k = 'Enter', d = 'keep the result (u - undo)' },
    { k = 'Esc', d = 'revert - everything as it was' },
  } },
  arranger = { title = 'arranger - the order of the song (Ctrl+W g C; C in the matrix)', e = {
    { k = 'C  i', d = 'seq: type the pattern order right in its row (A1 A1 B1x2 C1:16 D1-8), Tab completes, Enter keeps, Esc - as it was; a click on the seq text - the same' },
    { k = 'h l  Enter', d = 'a section of the sections row; Enter adds it to the song playlist (3 Enter - three times)' },
    { k = 'x', d = 'the last section off the playlist' },
    { k = 'Space', d = 'play the playlist' },
    { k = '< >', d = 'the previous / next arrangement (a named set of the lanes that play)' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  phrases = { title = 'phrases - a piece of a track as one note (Ctrl+W g F)', e = {
    { k = 'j k  g G', d = 'the phrase' },
    { k = 'Enter', d = 'the phrase at the tracker cursor, on the cursor track: one trigger note C-4 (another note transposes it, velocity scales it, its length cuts it)' },
    { k = 'e', d = 'edit the phrase in the tracker: only its track and its pattern (the source in the library), PHRASE in the mode word; everything the tracker does edits the source - every instance follows; e again (:phedit) - back to the song, the view and the cursor come back' },
    { k = 'n', d = 'a new phrase from the V block (else the pattern of the cursor) on the cursor track (= :phrase)' },
    { k = 'r', d = 'rename (the source and every trigger)' },
    { k = 'x x', d = 'delete: the source, its items and every trigger' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  lfogen = { title = 'lfogen - the curve generator into the envelope at the cursor (Ctrl+W g G)', e = {
    { k = 'j k', d = 'field: type (lfo / podkat / follow), shape, period, depth, center, phase, points, buttons' },
    { k = 'h l', d = 'value (Shift: fine); the mouse - click a button, drag a slider, wheel' },
    { k = 'g', d = 'auto-item: the curve as an automation item on the envelope at the cursor (the bar / region)' },
    { k = 'p', d = 'write points: the curve as envelope points' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  humanizer = { title = 'humanizer - every note a little different (Ctrl+W g H)', e = {
    { k = 'j k', d = 'row: amount, the ranges (at 100 %) of time, velocity, volume, pitch, speed, pan, attack, length; then the dsp variation points' },
    { k = 'h l', d = 'value / range (Shift: fine)' },
    { k = 'Space', d = 'this row on / off (on amount: human on insert on / off)' },
    { k = 'i', d = 'human on insert on / off (amount % - every inserted note)' },
    { k = 'a', d = 'add the parameter selected in DSP as a variation point: on every step with a note it moves a little (automation, a step shape)' },
    { k = 'x', d = 'remove the variation point under the cursor' },
    { k = 'Enter', d = 'apply: the notes (as :human) and the dsp points - to the selection, else the cursor track in the region (u - undo)' },
    { k = '0', d = 'the ranges back to the defaults' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  renderer = { title = 'bouncer - notes to audio, an instrument to a sampler (Ctrl+W g B)', e = {
    { k = 'Space', d = 'what: notes -> audio (the selection, else the note at the cursor, else the track in the region) / instrument -> sampler' },
    { k = 'j k', d = 'row: tail, mute source; sampler - notes from / to, every N semitones, velocity layers, note length, note-offs' },
    { k = 'h l', d = 'value (notes: an octave; Shift - fine / a semitone)' },
    { k = 'Enter', d = 'bounce: notes - through the track FX onto a new track "<track> bounce"; sampler - one file, a new track "<instrument> sampled" with an RS5K per note zone and velocity layer (RS5K: Minimum / Maximum velocity)' },
    { k = '0', d = 'the defaults' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  perf = { title = 'performance - what takes the time (REAPER and the tracker)', e = {
    { k = 't', d = 'jftop <-> performance: the tracker frame by parts (ms, max, %) / REAPER - audio, latency, tracks and their FX' },
    { k = 'n', d = 'the REAPER performance meter window' },
    { k = 'r', d = 'jftop: reset the max values' },
    { k = 'j k', d = 'scroll' },
    { k = 'Esc', d = 'back to the tracker (:jftop / the performance option again - hide the pane)' },
  } },
  undotree = { title = 'undo - the undo tree (as undotree in Vim)', e = {
    { k = 'j k  g G', d = 'move over the nodes (newest on top); the status says what the node is' },
    { k = 'Enter / dblclick', d = 'go there: on the current line - plain REAPER undo / redo steps; on another branch - its snapshot is restored (one new undo step, u - back)' },
    { k = 'the tree', d = 'every REAPER undo step is a node; undo and then a new edit makes a branch - the old line stays in the tree (its states were snapshotted when you left them); filled square - on the REAPER history, hollow - another branch, dim - no snapshot' },
    { k = 'zz', d = 'the whole window: every branch in its own colour, the time of each step and the gap since the one before (+5m - amber: a pause), a timeline below - each step a mark on the lane of its branch; click a mark - select, double click - go; zz - back' },
    { k = 'file', d = 'the tree lives next to the project: Name.jf-undo (only appended); an unsaved project keeps it in memory until the first save' },
  } },
  actions = { title = 'actions - the REAPER actions, wider than its Actions window (Ctrl+W g A)', e = {
    { k = 'j k  g G  C-d C-u', d = 'move; h l - the groups on the left / the list (as lf)' },
    { k = '/', d = 'find: letters in order, words in any order (pnc finds Pan Centre); whole words and word starts go first; Esc clears' },
    { k = 'Enter / dblclick', d = 'run the action (main; the MIDI editor sections - in the last MIDI editor); it goes to recent (shared with \\ a)' },
    { k = '[ ]', d = 'section: main, midi editor, event list, inline midi, media explorer (also the tabs on top)' },
    { k = 'groups', d = 'all, favourites, recent, then by the word before the colon (Script, Item, Track, SWS ...) - the biggest first' },
    { k = 'f', d = 'favourite on / off (* before the name)' },
    { k = 'a  x', d = 'add a shortcut (the REAPER dialog) / remove the first one (asks)' },
    { k = 'y', d = 'copy the command id (_RS... for scripts - survives a restart; a number for native ones)' },
    { k = 'the row', d = 'green square - a toggle that is on, hollow - off; the shortcuts of REAPER on the right in cyan' },
    { k = 'r', d = 'reload the list (after installing scripts)' },
  } },
  clipboard = { title = 'clipboard: the history of yanks (the newest on top)', e = {
    { k = 'j k  g G', d = 'move' },
    { k = 'Enter', d = 'make it the register - p in the tracker pastes it (click too)' },
    { k = 'p P', d = 'paste it at the tracker cursor at once (p replaces, P beside)' },
    { k = 'd x', d = 'remove from the history' },
    { k = 'Space', d = 'listen to the buffer' },
    { k = 'w', d = 'its wave: peaks / spectral' },
    { k = 's', d = 'save it as a file' },
    { k = 'a', d = 'add it to drumrs5k (a pad)' },
    { k = 'e', d = 'open it in the external editor' },
    { k = 'm', d = 'a subproject in pm with tags' },
    { k = 'zz', d = 'the clipboard on the whole window (buttons, a big wave, the rows), again - back', t = { 'z' } },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  inst = { title = 'lib', e = {
    { k = 'c', d = 'convert: l slices to the lib, s slice to drumrs5k (a pad per slice), w the whole sample in RS5K, p with a loop, m a list of samples in one RS5K' },
    { k = '!', d = 'Shift+1 anywhere: listen to the selected instrument (its length, through the cursor track); in the lib and the item tab ! slices at transients instead' },
    { k = 'm  Cmd+click', d = 'mark / unmark an instrument (several, not in a row; Shift+click - a range): dd / x cut the marked, yy yanks them, u unmarks' },
    { k = 'j k', d = 'instrument down / up (and onto the name of a lib folder: h / l / Enter - fold / open)' },
    { k = 'R [ ]  Opt+Shift+H L', t = {}, d = 'ξ - a random sample for the selected instrument (Opt+Shift+L - forward, past the end a new one; Opt+Shift+H - back): like the name of its lib folder (kick), else the first word of its name, from the map index (open the map pane once on your samples); [ ] - back / forward through what came up (back from the first - the original sound); also the < ξ > buttons on the row' },
    { k = 'm u r (lf)', t = {}, d = 'as in lf: m - mark the instrument and go down (amber), u - unmark all (no marks - u is undo), dd / x - cut the marked, yy - yank them, r - rename' },
    { k = 'h l (folders)', t = {}, d = 'lib folders (option lib folders): the cursor in a folder - h folds it (only >kicks 5 is left, j k skip it), l opens it; a click on the folder row - the same; the lib menu: save this folder as a lib, load a lib into the folder (its samples join the folder whatever their names)' },
    { k = 'J K', d = 'move the sample down / up in the lib - the numbers follow (also drag a row with the mouse)' },
    { k = 'L', d = 'layer (¥): another lib instrument sounds together with this one on one note; tracks - its layers in the folder (Space listen, Enter offset / pan / random / cycle / phase); browser a y - files as layers' },
    { k = 'gg G', d = 'first / the bottom row - midi clips (G; Cmd+G from anywhere - automation); g is a prefix in most modules (not the browser, fx list, notes): gt - go to a module, gT - a project tab' },
    { k = 'h l', d = 'as in lf: l - open the instrument folder (its layers ¥ and slices) / into it, h - back / close; inside: j k, Space listen, Enter - a layer: its menu, a slice: insert, x remove, e - the slice in the item tab (Tab - the lib / tracks tab; another track - from the tracker)' },
    { k = 'Shift+click', t = {}, d = 'select several instruments: from the selected one to the clicked one (as v)' },
    { k = 'dd x', d = 'cut instrument: its events on the tracks and the library item (to the register); x - the same' },
    { k = 'yy', d = 'yank instrument to the register' },
    { k = 'p P', d = 'put a copy from the register into the cursor track library (new name if taken)' },
    { k = 'yp', d = 'duplicate the instrument (copy into the library)', t = { 'yp', 'yP' } },
    { k = 'v', d = 'range from here: j k extend, d / x cut, y yank, Esc' },
    { k = 'Opt+V', d = 'smart selection of the column under the cursor: to the end of the sub-beat, again - of the beat, the bar, the pattern (a level that adds nothing is skipped)' },
    { k = 'Enter', d = 'the sound menu of the sample: Enter again - open in the item tab (slicer); s similar, b brighter, d darker, t shorter, g longer, a sharper, o softer, n noisier, c tonal, u louder, q quieter - the pick swaps the sound of the instrument' },
    { k = 's', d = 'slice menu' },
    { k = '~~', t = {}, d = 'automation: the last row - automation items of the track as one instrument (j past the last slot); the slices list shows them, a note key / MIDI note inserts the selected one, rate by the key (C-4 = x1, octave up = x2); Opt+Enter on an automation item picks it' },
    { k = 'r', t = {}, d = 'slices list: slice mode - by key / random (any slice key inserts a random slice of the sample, never the same twice) / sequence (the next one); also l in the insert menu' },
    { k = 'µ', t = {}, d = 'midi clips (µ; in the lib: @ audio, & files kit, N$ sliced, # drumrs5k, ~ automation): the row under automation - MIDI items of the track (a in the slices list: the whole project); j k pick, a note key / MIDI note inserts a copy at the cursor (C-4 = as is, else transposed; the original stays), Enter / double click - go to the clip (Ctrl+O back); a click / j k previews it through its track (no transport), Space stops' },
    { k = 'Space', d = 'preview (how its note sounds: offset, rate, pitch); Esc stops' },
    { k = 'a', d = 'preview on select on / off (button preview; rclick: full / hold / first second)' },
    { k = 'bsync', d = 'header button: beatsync - the item lasts N beats at the tempo where each note sits (wheel in the item panel: N)' },
    { k = 'beatsync to', t = {}, d = 'item panel row (click v / h l): the pattern x/4../x4, n until the next note (each copy), s the row selection, t the first transient on the next beat, T on the next note' },
    { k = 'linked', d = 'every note of an item is linked to it: the item panel changes all of them; a stretched / offset note becomes unique - the question offers a: apply to all' },
    { k = '/', d = 'fzf find instrument' },
    { k = 'f', d = 'hint labels: jump to an instrument (focus moves here)' },
    { k = '..', d = 'empty slot: retro p / Enter puts the capture here; drop a retro / sample selection or a file' },
    { k = 'u', d = 'undo' },
    { k = 'Esc', d = 'back to tracker' },
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
    { k = '/', d = 'filter the cards: name, #tags, bpm, key, [status], daw (ableton, flstudio ...)' },
    { k = 'r', d = 'reload the jf_pm index' },
  } },
  map = { title = 'map - the sample map', e = {
    { k = 's', d = 'the sound menu of the sample under the mouse (else the last played): similar, brighter / darker, shorter / longer, sharper / softer, noisier / tonal, louder / quieter - same class, from the fingerprints (:fprint); Enter - into the lib' },
    { k = 'j k l h Enter', d = 'the mini lf on the left: folders of the browser folder (the map shows what the browser has open)' },
    { k = 'v', d = 'next view: graph (rings of groups) > cards (a grid of sectors) > nebula (one galaxy, groups as rectangular sectors; Shift+click on a sector - its system, galaxy / Esc - back)' },
    { k = 'Shift+click  Cmd+click', t = {}, d = 'on a group: Shift+click - into it (its system in the nebula, a closer zoom in the other views), Esc - back; Cmd+click - its files marked; a plain click only names it' },
    { k = 'r', t = {}, d = 'ξ - a random file: from the group under the mouse, else from all; plays at once' },
    { k = 't', d = 'the next source: files / db / proj / pm' },
    { k = '+ - 0', d = 'zoom in / out / reset (also the wheel; drag - move)' },
    { k = 'history', t = {}, d = 'the right panel, top: the files played from the map, newest on top (a click plays again); the dot just played is bright, then dark for 10 plays, then brightens back - a line joins them (options > modules > map)' },
    { k = 'drag', t = {}, d = 'hold the mouse on a dot and move: every file the mouse passes plays and lands in the history (a path)' },
    { k = 'print p', t = {}, d = 'history: the last played files into the tracker - each on its own new track / one after another / all at once on the cursor track' },
    { k = 'Cmd+h j k l', t = {}, d = 'inside the map pane: mini lf / map / history / marked first (j k there play the row, Enter - mark / into the lib), past the edge - the next pane' },
    { k = 'samples midi rex auto tpl', t = {}, d = 'bottom left: which kinds of files the map lays out; far out the labels get shorter (main words), dense groups become one disk; cards: + - size, wheel scrolls' },
    { k = 'marked', t = {}, d = 'the right panel, bottom: the marked files (m in the browser); a double click on a file of the map or the history marks it; on a marked one (under the mouse / clicked): double click or Enter - into the lib, Opt+Enter - into a lib folder, x / dd - unmark, clear - all; lib - into the lib, save - into the lib and save it as a set (:libsave); the ship in the corner - an option (modules > map)' },
  } },
  browser = { title = 'browser', e = {
    { k = 'Opt+Enter', d = 'the marked files (else the file under the cursor) into the lib as a folder: pick one of the lib folders or + new (:libdir name)' },
    { k = ': ↑ ↓  Ctrl+R', d = 'command line history: up / down - commands starting with what you typed (Ctrl+P / Ctrl+N too), Ctrl+R - fzf over the history' },
    { k = 'browser columns', t = {}, d = 'a wide browser (zoomed) in files shows columns like lf: the parent folder (yours lit - click goes there) | the folder | what is under the cursor (a folder - its files, click goes in; a file - a big wave, length, type); h - up, the cursor lands on the folder you left; the player gets taller' },
    { k = 'browser map', t = {}, d = 'tab map (and the lower half of the third column in a wide browser; the button graph / nebula - groups in even sectors, dots float inside without links): the files of the folder and its subfolders (300 max) as a graph, like Obsidian - a dot is a file (bigger - bigger file), a ring is a group (kick snare hat bass loop fx vox synth ... by the words of the names, else the subfolder); the proj tab has a map / list button - the sources of the project as such a map (groups by name, else by track); click a dot - hear it, click a group - mark its files (Space plays them in a row, Enter - into the lib), wheel - zoom, drag the empty place - move' },
    { k = 'recent / playlist', t = {}, d = 'browser tab zoxide (was recent) - on top the 15 folders you go to most and lately (Enter - into it, tab files), below what you heard (over 0.5 s or started twice), newest on top, the last 50; a wide browser shows the marked files right of the player wave (click - hear it, the playing one amber); m marks files (any folders), Space with 2+ marked - they play one after another in the order marked, Space again - stop; playing something else stops the playlist' },
    { k = 'Opt+`', d = 'held note key in INSERT: hold (the note lasts as long as you hold, an OFF where you let go) / roll (a drum roll: while you hold, the same note on every next row at the speed of the rows, no OFF); the hold / roll button right of LPB' },
    { k = 'Ctrl+A X (roll)', t = {}, d = 'option step a/x (roll): with roll on (Opt+`) Ctrl+A / Ctrl+X copy the event of the cursor row a step lower and change it there +1 / -1, the cursor follows - press again for the next step of the ramp' },
    { k = ':z words  :zi', d = 'zoxide: jump to the most used / recent folder matching the words (last word - in the folder name); :zi - pick from the visited folders' },
    { k = 'z i  z o  z z  z _', t = {}, d = 'z menu of the browser: zi - zoxide folders (fzf, = :zi), zo - the zoxide tab, zz - the browser on the whole window, zm - minimize the pane (in keys mode z is a note)' },
    { k = 'j k g G', d = 'move / first / last' },
    { k = 'l Enter', d = 'open folder / insert file' },
    { k = 'find words', d = 'in the search: words in any order, -drum - without it, >2s / <0.5s - by the file length, ^start, end$, \'exact' },
    { k = 'Cmd / Shift+click', d = 'mark one row / mark the rows from the cursor to it (as m); Enter puts every marked file into the lib' },
    { k = 'm u', d = 'mark the row (and step down) / unmark all (u, as in lf); marks stay across folders - Enter puts every marked file into the lib in marking order' },
    { k = 'presets', t = {}, d = 'browser tab presets (t cycles to it): instrument presets as REAPER track templates in TrackTemplates/presets/<pad bass lead keys ...>; Enter - its fx chain on the cursor track (any synth, the items stay), n - save the cursor track there (folder, then name), h - back' },
    { k = 'a', d = 'add the marked files (or the one under the cursor) to: l the lib, d drumrs5k (a pad per file), s an RS5K per file, m one RS5K list, c slices of the selected instrument; drag a file onto a pad - its sample, onto all / the empty grid - a new pad' },
    { k = 'h - BS', d = 'folder up' },
    { k = 'Cmd+Enter', d = 'replace sample of the selected instrument everywhere' },
    { k = 'S-dblclick', d = 'the same with the mouse: Shift + double click on a file replaces the sample of the selected instrument' },
    { k = 'Enter .rx2 .xrni', d = 'import REX / Renoise-Redux instrument with its slices' },
    { k = 'sync', d = 'button: while the project plays, a file starts on the next bar' },
    { k = '*.* .*', d = 'buttons: all file types / hidden files; Enter on MIDI / video inserts it, others open in their app' },
    { k = 'Space', d = 'preview (mini player below)' },
    { k = 'cell (player)', t = {}, d = 'the cell button of the player: a selected file goes straight into the active drumrs5k pad - while the song plays you hear it in the groove, stopped - the pad sounds; drum off keeps the last one (one undo). Dropping a file on a pad - its sample too' },
    { k = '/', d = 'fzf find: ^start end$ \'exact !not (f - jump by hints, as in every module)' },
    { k = 't', d = 'mode: files / db / projects' },
    { k = 'p', d = 'auto preview on / off' },
    { k = 'v', d = 'show file in sample tab' },
    { k = 'w q', d = 'panel width / hide' },
    { k = "'1 '2 '3", t = { "'" }, d = "bookmark: go ('1 ... '0); the digits alone are a count: 10j 5k 3G" },
    { k = 'Shift+1..0', d = 'set bookmark 1..10 to this folder', t = { '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' } },
    { k = 'H L', d = 'folder history back / forward (< > buttons)' },
    { k = ':mkdir', t = {}, d = 'new folder here (:mkdir name)' },
    { k = 'Esc Opt+Tab', d = 'clear filter / next tab' },
  } },
  notes = { title = 'notes (left of DSP)', e = {
    { k = 'type', d = 'write; Enter new line, BS Del erase, arrows Home End move' },
    { k = 'project context', d = 'buttons: project notes / notes of the item under the cursor (track with SWS)' },
    { k = 'Esc Opt+Tab', d = 'leave (saved) / next tab; also saved a second after typing' },
  } },
  fxb = { title = 'fx list (left of DSP)', e = {
    { k = 'a A n', d = 'add the effect: a - to the cursor track (= Enter), A - to the selected tracks (Shift - the selected), n - on a new track' },
    { k = 'Space v  Cmd+click  Shift+click', d = 'mark several effects (numbered in the order of marking; Shift+click - a range); Enter / a adds them all in that order, one undo; Esc - unmark' },
    { k = '/', d = "find (fzf): words, ^start, end$, 'exact, !not; Enter adds what is found, Esc clears; under the plugins - presets N: your saved presets and the factory ones REAPER has seen (~), Enter - the plugin with that preset" },
    { k = 'j k h l', m = 'move / tree', d = 'move in the list; h l - the tree of groups on the left (as REAPER: all, favorites, recent, instruments, types, categories, developers) and the list, Enter on the tree - that group', t = { 'j', 'k', 'h', 'l' } },
    { k = 'Tab', d = 'the next zone: find (/) - the list on the right - the folders on the left - find; Shift+Tab back' },
    { k = 'gt gT', d = 'go to a module / a project tab (as everywhere)' },
    { k = '*', d = 'favourite on / off' },
    { k = 'x', d = 'exclude from search: on a plugin - it, on a folder of the tree (developer, category, type) - all of it; x again - back (x before the name, dim; in its own folder it stays)' },
    { k = 'Up Down ^J ^K', d = 'move', t = { 'Up', 'Down', '^J', '^K' } },
    { k = 'Enter', d = 'add fx to the end of the cursor track chain' },
    { k = 'dblclick', d = 'add fx' },
    { k = 'drag', d = 'onto the DSP panel: insert at the amber line' },
    { k = 'BS', d = 'erase search' },
    { k = 'Esc Opt+Tab', d = 'clear search / next tab' },
  } },
  dsp = { title = 'DSP (track fx)', e = {
    { k = 'N + -  N j k  N Enter', m = 'numbers on a param', d = 'on a parameter (slider): 20 + / - - step x20 (h l stay for moving between effects), 23 j / k - 23 params down / up, 23 Enter - set it to 23 in its units (Hz, dB, %), 023 Enter - 0.23; Esc - cancel the number. The same on the rows of reform / humanizer / bouncer (a number + Enter sets the row, Enter alone - keep / apply / bounce)' },
    { k = 'h l', d = 'fx left / right' },
    { k = 'w W', d = 'the next / previous module (around the chain; 3w - three; from a parameter slider too)' },
    { k = 'Z', d = 'the menu of the selected module (the same as a right click on it)' },
    { k = 'Opt+J K', d = 'the preset of the module: next / previous (as < > in its header)' },
    { k = 'Opt+H L', d = 'the main preset folder: previous / next (Surge: Bass, Keys ... - its first patch)' },
    { k = 'snapshots', d = 'mixer, empty place on the left, tab snapshots - as the SWS Snapshots window: new (the next free of 12), prev / next (recall), up / down (move the current), sws (its window); the table # / name / date / time - click recalls, Cmd+click saves over, Alt+click deletes, right click - menu (rename); the SWS filter: full track mix / current visibility / custom + pan volume mute fx chain solo sends vis selection, filter on recall, save / recall selected tracks only, prompt for name (low mixer - the filter button)' },
    { k = 'mixer xy', d = 'mixer, tab xy - a quick snapshot pad: 4 corners keep the volume and pan of every track (click an empty corner - save, a filled one - recall, Shift - overwrite), drag the puck - morph between them; one undo per drag' },
    { k = 'mod · auto', d = 'in the track block of DSP: two vertical buttons at its right edge - auto (top) and mod (bottom); either opens the panel (the block doubles in width): automation on top (curves over the song), modulation below (L LFO, A ACS, K link, P premod; LFO drawn as its wave) - click goes to the parameter, right click - its modulation menu; for the parameter selected in DSP - tabs lfo / acs / link / env / premod with editors: on, shape, sync, sliders (base, rate, depth, phase, att, rel, min, max, scale, offs - drag), in 3/4 and side (follows the audio of another track), link source, the envelope curve; env tab - follow: the parameter follows another track (audio) or an envelope via the automation generator' },
    { k = 'premod', d = 'a curve that runs BEFORE every note of the track and ends on it (like automation clips in FL) - pooled automation items on the parameter envelope, they follow the notes after every edit; the curve editor right in the panel (drag a diamond, double click - add, right click - remove; all instances follow), a vertical piano with the incoming MIDI note and a velocity meter; pre - length, key - keytrack (higher notes: shorter, faster), vel - velocity scales it, hum - humanize timing, depth and shape, test - play the curve on the parameter now, then back; premod off/on - the first button' },
    { k = 'Opt+click (param)', d = 'a parameter with automation: its envelope is removed (u - undo)' },
    { k = 'macros', d = 'Macro 1..8 of a plugin (Surge M1..M8, Vital, Serum ...) - the MACRO column on the left of its module, horizontal sliders; a click on MACRO folds it into a strip (click again - open); Opt+Cmd CONTROL over the module takes them first' },
    { k = 'XY presets', d = 'under the track block (option slim DSP track header off): 4 corners 1..4 - snapshots of every fx parameter of the track; click an empty corner - save, a filled one - recall, Shift+click - overwrite, right click - save / recall / clear; drag the pad - morph between the corners (one undo)' },
    { k = 'XY in INSERT', d = 'INSERT (red cursor): let the puck go or click a filled corner - the preset is written as automation at the cursor row (a point on the envelope of every parameter the corners differ in; envelopes made as needed, one undo); move the cursor and morph again - the next point' },
    { k = 'Ctrl+Enter', d = 'the dropdown of the parameter: a note (note lo / hi, root) - a keyboard of all octaves (h l semitone, j k octave, type D5 / C#3, Enter keep, Esc back), a switch - the list of its values (a click on it - the same)' },
    { k = '^ $ N|', d = 'the first / last module, module N (3| - the third), as columns in Vim; Cmd+1..0 - a track, as in the tracker' },
    { k = 'dw db', d = 'delete modules: d3w - three from the cursor forward, db - the one before, d2b - two before (3dw too)' },
    { k = 'Shift / Cmd+click', d = 'on a module (its name or empty space): Shift - pick from the selected one to it, Cmd - add / remove it (apart is fine); then x delete, b bypass, cc pack (side by side), zf fold, Esc - drop the pick' },
    { k = 'i', d = 'INSERT the parameter: it and the module frame go red - type a number (023 = 0.23) or the start of a value (hp, saw, off), Enter sets, Esc cancels, BS erases, up / down - another parameter; outside it digits and letters play notes (KEYS)' },
    { k = '[] (track block)', d = 'contain: every effect of the track into one container (REAPER 7); one container on the track - unpack it; also cc on a range, dc unpacks' },
    { k = 'cb', d = 'DSP: the effect into 3 / 4 / 5 frequency bands (also ÷ in the module header and the module menu: split into bands) - a container ÷N bands of parallel chains low / mid / high, each starts with a native N-Band Splitter passing only its band; the effect goes into low. In DSP: the bands as rows high ... low (click - its fx follow the container as full modules, band > name), crossover under them (one edit sets every band); af / drop - into the selected band' },
    { k = 'drop on a pad', d = 'drag an effect from the fx list onto a drumrs5k pad - it goes into that pad (its own container: sampler, its fx, this one)' },
    { k = 'bands', d = 'router: a REAPER band splitter ... joiner (3 / 4 / 5 band) is drawn as band rows (low < 200 Hz, mid, high) - every effect between them sits in the band of its pins; a on a band - an effect into it (pins set to its channels), zb on an effect - wrap it into 3 / 4 / 5 bands (it stays in low); all native: pins / routing windows show the same' },
    { k = 'Opt+letter (slixer)', t = {}, d = 'DSP, slixer: the letters on its buttons work with Option - Opt+D detect, Opt+T transient, Opt+C classify, Opt+A auto, Opt+X clear, Opt+Z undo, Opt+E midi, Opt+N names, Opt+S sync, Opt+Q q, Opt+B arp, Opt+H thru, Opt+O out; bare letters stay DSP keys (d - delete ...); Opt+J K - preset' },
    { k = 'slixer slots', t = {}, d = 'DSP, slixer: the head of the module shows its 8 quick slots (mini wave + name) - click loads that sample; store / clear them in the slixer window (Shift+click / Alt+click a slot). spam (the button on the wave): while you drag a slice edge (also in the sniper zoom) it rolls from the edge, let go - its slice plays' },
    { k = 'ze', d = 'DSP: the window of the track instrument (slixer too), again - close it; e - the window of the module under the cursor' },
    { k = 'zz', d = 'the effects on the whole window with the mixer above them (strips of every track); again - back', t = { 'zz', 'z' } },
    { k = '★ links', t = {}, d = 'a container header holds real parameters, no macro knobs: rclick a parameter of a module inside - ★ Pin (P) puts it in the header (native: mapped to the container - automate, MIDI learn); Follows … (F) - it follows another parameter of the container with +/- amount (native link), shown under CHAINS as LINKS: the row and a graph, click - amount / unlink; two chains - A<>B (click: the mix of the first crossfades them, 100 % A / 0 % B; lit when on, click again - off); rclick a ★ - unpin' },
    { k = 'container', t = {}, d = 'a container is a rack: on the left its header (name, in / out, + e ∆ on x, the ★ parameters - P on a parameter inside - and an XY on the first two; sections side by side with their titles on top: MACRO N (the knobs, + / -, what is on which), XY (open from the start; a click on a title folds the section), then CHAINS - a table of chains: chain (click - the DSP cursor on its module), mix (its Wet: click / drag left - right), m off, s only it, in the middle the modules inside at full size on the container colour (| serial, = parallel), on the right at the end the rack closes, then a + slot (click - an fx into the end of the container, drop an fx there too); one frame over all three and a bracket under it; a container inside - the same, its colour deeper, its bracket a step higher; parallel branches (= in the header) - each its own colour: a bracket of that colour under the module or the container of the branch; click a folded module inside - it opens, the others in the container fold (Shift+click - only open it; zf - fold); 2-5 small effects (up to 6 parameters) - one packed block; zv - wrap / pack / list / auto; empty - a nest: drop an fx or a container' },
    { k = 'cf', d = 'DSP: fold the container under the cursor (or the one the module is in) - with everything inside, a strip; cf again - unfold' },
    { k = 'cv', d = 'drumrs5k rack or any container: switch the pad grid (columns) / the list of pads (chains: | serial, = parallel, fx count, wet, on) (in place of the grid; the parameters of the selected pad stay on the right); the list / pads button in the rack header does the same; in the list of chains: key / vel / chain - zones of the chains (drag the edges, the fades - upper half, the whole zone; chain - the amber select in the ruler)', t = { 'z' } },
    { k = 'z Tab', d = 'swap the mixer and dsp in the zz view (dsp on top / below); remembered for the next zz', t = { 'z' } },
    { k = 'zw', d = 'wide: dsp across the whole width at the bottom, the side modules (left and right stacks) move up; again - the panes as before', t = { 'z' } },
    { k = 'zx', d = 'dsp x1.5 taller than its canonical size (tabs + track row + 250 px of modules; the line above it moves up); again - back. Dragging the line snaps to the canonical size, the mixer too', t = { 'z' } },
    { k = 'macro / xy tabs', t = {}, d = 'a module with macros (Surge, Vital ...): on its left two vertical tabs - macro N opens the macro sliders, xy opens an XY pad on macros 1 and 2 (drag - both); click a tab again - it folds' },
    { k = 'zr', d = 'router: the chain with its routing - h l signal (l enters a container), j k parallel row, a add after the row, A add in parallel, | join / leave the row, s solo in the row, = branches to unity, b bypass, d (or x) delete, za fold a container, o window, zr / Esc back (:dsp big); mouse: drop an fx from the browser on = - parallel to that device, on + - after it; Shift+click - bypass, Opt+click - delete, dblclick - its window', t = { 'z' } },
    { k = 'new kit  < ξ >', d = 'drumrs5k: new kit (rack header) - a random sample of the same class (kick, snare, hat ... by the file name) for all pads / the selected pad / the 16 visible, one undo; the pad header - its class (~hat: by its sound, the name has none), sim shows / hides < ξ > of the pad and of the rack (rack header: every pad at once, one undo): ξ a random one like it, > the next nearest like it, < back (back from the first - the original); [ ] in pads = < >. Like it = the same class, the nearest fingerprint (:fprint fingerprints the sample index in the background)' },
    { k = 'midi out', d = 'drumrs5k rack header: MIDI-only sends of the track to other tracks (a picker; again - remove one): pads and the pattern notes play there too (a synth layered on the drums); lit with the number of sends' },
    { k = 'Enter (pads)', m = 'drumrs5k rack: pads by keys (hjkl pad, letters - its sampler)', d = 'on a drumrs5k rack - pads mode (a click on a pad too): h l the next / previous note, j k a row (4 notes), x cut the pad, yy take it, yp duplicate onto the next free note, p paste on the cursor note (taken - the next free one), M mute, S solo, Enter listen, r the pad in the router, G group (grp: its pads play together), C choke group (chk: they cut each other), a letter of a sampler parameter (orange: v volume, n pan, i min vol, o root, t pitch, b bend, a attack, d decay, s sustain, e release, f note-off, u loop, w q vel lo / hi, c chance) - to it, h l change, j k next, Esc back to the pads; Esc back to the effects; KEYS (m) plays the pads, the played one flashes green' },
    { k = 'drumrs5k pads', t = {}, d = 'the 4x4 grid (a window of the note map, the cubes on the left scroll it): click - select and hear the pad, Opt+click - mute, Shift+click - solo; the selected pad: g - its group (g1: a hit on any pad of the group plays them all - a layer in the rack), cg - its choke group (c1: a hit cuts the other pads of the group, like open / closed hi-hat); an OFF in the tracker on a one-shot pad puts it into cg off (OFF cuts it, without OFF it rings to its next hit; also in the cg menu); both live in jf_tracker_choke first in the chain and work without the tracker; on the pads - g1 / c1; list (the button by cell) - every pad with every parameter in a table (wheel over a value changes it, click grp / chk / on - menu / bypass), zz in pads mode - the rack on the whole window; r - the pad in the router (layers in parallel: RS5K / synth / fx, containers inside), on / off - bypass, x remove; on each pad: m mute, > listen, s solo; on the right - the sample wave with start / end and the ADSR over it' },
    { k = 'j k g G', d = 'parameter down / up / first / last' },
    { k = '+ - ^A ^X', d = 'value up / down (Shift: coarse)', t = { '+', '-', '=', '^A', '^X' } },
    { k = 'dd x', d = 'delete fx (v: range)', t = { 'dd', 'd', 'x' } },
    { k = 'cu', d = 'unpack container: children into the chain' },
    { k = 'yy p P', d = 'copy fx, paste after / before (any track)', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'cc', d = 'pack fx (v: range) into a new container', t = { 'cc', 'c' } },
    { k = 'cn', d = 'an empty container after the selected module (empty chain: at the end); it says what goes in: drop an fx or another container into it, [] in a container header - an empty container inside it, and so on' },
    { k = 'gui  :gui', t = {}, d = 'the gui button in the fx head (or :gui): the native window of the plugin sits right over its DSP block, frameless, and follows it; the block off the screen - the window closes; again - back to the tracker view' },
    { k = 'r', d = 'replace the selected fx: a fzf list right here (the focus stays in DSP), the new one takes its place, on / off kept, the old one removed - one undo' },
    { k = 'rclick', d = 'container: unpack, add fx inside, presets, all serial / parallel, rename (:fxname); on a plugin inside: bypass, window, serial / parallel, move out, remove' },
    { k = 'drag', d = 'drop an fx from the list or a block: between modules a small slot opens - its upper half | serial, lower half = parallel to the previous (the chain of the track and inside a container); onto the middle of a container - into it (top serial / bottom parallel); the field at the end of a container (while dragging) - into its end' },
    { k = 'route', t = {}, d = 'track header in DSP: the third vertical button under auto / mod - a mini router in a dark window: the chain as small boxes named by consonants (serial - to the right, = parallel - stacked under the previous, [ ] - a container), the selected one amber; click - the DSP cursor on that module; drag a box onto another - left half before it, right half after it, below it = parallel to it (modules of the track chain; inside a container - in DSP). Slots 1 2 3 4 on top - the whole fx chain of the track to compare: empty - save, full - recall (u - undo), Shift - save over, Opt - clear' },
    { k = 'container XY', t = {}, d = 'the container header switches CHAINS | ROUTE | XY (one at a time, the whole height): ROUTE - the map of the modules inside; XY - an XY pad - its 4 corners are snapshots of every module inside (click an empty corner - save, a full one - recall, Shift - overwrite), drag the puck - morph; in INSERT it writes automation on the cursor row' },
    { k = 'c= c|', d = 'DSP: the selected module parallel to the previous one (=) / serial after it (|); also in the right click menu' },
    { k = 'aa', d = 'automate or show the envelope of the selected parameter: none - it is made; then the tracker cursor goes to its column', t = { 'aa', 'a' } },
    { k = 'ap A', d = 'pick a parameter to automate (fzf; also click trim in the track header, rclick trim: all parameters)', t = { 'ap', 'A' } },
    { k = 'ad', d = 'delete the automation of the selected parameter' },
    { k = 'ai', d = 'automation item of the selected parameter: as long as the item under the tracker cursor (none - the item of the DSP track at the cursor row, else a bar); its curve opens at once' },
    { k = 'K', mk = 'L', d = 'module learn (knobs): turn knobs in the plugin window - they join this block (saved per plugin); in learn x removes, J K move, < > columns, R resets to automatic, E / Esc done' },
    { k = 'I', d = 'in / out: the pin matrix of the module (also the button right of its name, 2 in 2/6 out, and the menu); h j k l, Space, + -, r, Esc' },
    { k = 'pins', t = {}, d = 'the button right of a module name (2 in 2/6 out, as REAPER): a click - its pins (as the REAPER pin connector): track channels in rows, the plugin inputs (left) and outputs (right) in columns; click / Space a cell - connect, h j k l move, + - the track channels, r reset (pin N - channel N), Esc close' },
    { k = 'cursor frame', t = {}, d = 'the parameter under the tracker cursor has a contrasting frame in DSP: an envelope column - its fx parameter; a note command - the sampler parameter it moves (0M 0I 0O volume, 0P pan, 0U 0D 0G SF pitch, 0S start; drumrs5k rack or RS5K)' },
    { k = 'colours', d = 'parameter strip colour = category: green gain, cyan filter, amber time, purple pitch, grey mix, red dynamics, teal stereo, orange modulation' },
    { k = 'dm da', d = 'remove the modulation (LFO / ACS / link) / the automation of the selected parameter' },
    { k = 'am', d = 'container: map the selected child parameter to a native container macro (M ...); modulate the macro natively (right-click: LFO / ACS / link)' },
    { k = 'af', d = 'add fx (fzf)', t = { 'af' } },
    { k = '/', d = 'find in the chain: fx and params' },
    { k = 'v', d = 'select a range of fx (h l extend), Esc clears' },
    { k = 'Enter b', d = 'toggle parameter / bypass fx' },
    { k = 'e', d = 'edit: the fx window (button e on the block, as in Cubase; on / off - bypass, x delete)' },
    { k = 'u  Ctrl+R', d = 'undo / redo here too (the status says what was undone)' },
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
  tracks = { title = 'tracks: what is on every track, like the lf file manager - track / its instruments / their slices and loop variants / its automation; lib - instruments not used yet', e = {
    { k = 'j k  g G', d = 'row down / up, first / last' },
    { k = 'h l', d = 'h - close (a track: its contents, then its REAPER folder) / to the parent row; l - open / into it; on an instrument without children, a slice, an automation item - pick it' },
    { k = 'Enter', d = 'track - go to it in the tracker; instrument - pick it (the cursor goes to its track); automation item - the automation instrument with this item' },
    { k = 'Space on an instrument', d = 'pick and listen' },
    { k = 'slices', d = 'inside a sliced instrument: key  Sxx  length - the key of the octave at the cursor plays the slice (C-4 = whole, shown at the instrument); Enter / l - select it and hear it. The slices module is off (19 окт): slices and layers live in the lib as a folder (l opens it)' },
    { k = '+ -  zoom  c', d = 'slices taller with their wave (x1..x3; the zoom button - x1 / x2); c on a sliced instrument or a slice - convert: every slice its own lib instrument / slice to drumrs5k (a pad per slice)' },
    { k = 'µ midi clips', d = 'the MIDI clips of the track - Enter on a clip: the midi instrument with this clip, a note key inserts it' },
    { k = 'dd yy p P on an instrument', d = 'as in the lib: cut / yank the instrument, put a copy after / before' },
    { k = 'Space  v  u', d = 'mark the track (and down) / invert the marks / clear them; the commands below work on the marked tracks, else on the cursor' },
    { k = 'T M S R', d = 'shown in the tracker / mute / solo / record arm' },
    { k = 'dd  yy  p P', d = 'cut / copy the track with its children; paste after / before the cursor (at its level)' },
    { k = '>>  <<', d = 'into the folder above (the track above becomes one) / out of the folder' },
    { k = 'J K', d = 'move down / up among the tracks of the same folder (a folder moves whole)' },
    { k = 'o O  F', d = 'new track after / before; F - a new folder around the marked tracks' },
    { k = 'r  z  /', d = 'rename; fold the folder; filter by name (Esc clears)' },
    { k = 'Esc', d = 'clear the filter, then the marks, then back to the tracker' },
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
    { k = 't', d = 'midi trig on / off: every note of the sample sends a note-on to its track (bus 1, channel 16) - MIDI modulators already on the track (counters, key trackers, envelopes in plugins) react to sample notes' },
    { k = 'Enter', d = 'edit the curve (automation tab, the editor of its pool): one curve for all the notes; on the + row - add, on the midi row - trig' },
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
    { k = '=', d = 'type a number: the selected parameter, or the matrix cell (M) - :vzset N' },
    { k = 'save', d = 'button: save the look as a preset (:vzsave name) - layers, effects, values, LFOs, the matrix' },
    { k = 'M', d = 'keys to the modulation matrix (always shown under the parameters) and back: h j k l cell, + - depth, 1..9 0.1..0.9, ~ sign, x clear' },
    { k = 'rclick', d = 'menu of the row / parameter / preset under the mouse (\\ - of the selected)' },
    { k = 'Esc', d = 'back to the tracker' },
  } },
  sample = { title = 'item tab (slicer + properties of the item)', e = {
    { k = 'dblclick', d = 'on the wave: a slice there (option slice by click: one click); on a slice line: remove it', t = {} },
    { k = 'slice labels', d = 'three rows at each slice line: its number (as in the slices list), the key that plays it, the MIDI note', t = {} },
    { k = 'Enter', d = 'apply slicing / insert selection at cursor' },
    { k = 'a', d = 'select all' },
    { k = 'v', d = 'view: peaks / spectral' },
    { k = '1 f1 2 f2 …', d = '1 f1 2 f2 … - slices 1 2 3 4 …, ` - the whole sample (qwerty: q - the whole sample, 2 w 3 e … - slices; the note keyboard, as over the wave)' },
    { k = 'aim', d = 'while aiming the aim buttons show their keys: s cut, S smk, Q squant, 0 / t / q toggle 0-cross / t-snap / quant (with the aim on top the buttons sit on it). The cursor note: the aim (edge zoom) shows the sound at the tracker cursor row when that note is this sample; { } move it 1 ms (or drag in the aim); s cuts only that note right there (not on the row)' },
    { k = 'S', d = 'snap on / off: selection edges, slice markers and the zone stick to transients and slice markers (a stretch marker at the aimed point - s m)' },
    { k = 'Tab S-Tab', d = 'the wave cursor to the next / previous transient, the bit up to the next one plays (transients are found on the first Tab)' },
    { k = '$', d = 'Shift+4: 16 equal slices - the quick slicing (! @ # $ ...) takes $ first in the item tab; the slicer\'s own $ (cut a slice at the wave cursor) is hidden behind it - a key conflict' },
    { k = 'd', d = 'delete a slice: d + its key (1 f1 2 ...; qwerty 2 w 3 e), dd - the slice under the wave cursor (else the selected one)' },
    { k = 'x', d = 'clear slices' },
    { k = 'T', d = 'autotrim: cut the silence at the start and the end (button autotrim)' },
    { k = 'Opt+D', d = 'transient detector module left of the wave: sensitivity, threshold, min gap, pre-attack - transients show live; Enter slices, s smart, x clear, Esc / Opt+D close' },
    { k = 'zz', d = 'item on the whole window (zoom), again - back', t = { 'z' } },
    { k = '< >', d = 'volume -1 / +1 dB' },
    { k = 'n', d = 'normalize' },
    { k = 'g{ g}', d = 'give back the file before / after the sample (the cyan < 3.21s / 10.27s > tags at the wave edges say how much is there; a click on a tag does the same)' },
    { k = '1 f1 2 f2', d = 'listen: 1 f1 2 f2 ... - slices 1 2 3 4, ` - the whole sample (qwerty: q - the whole sample, 2 w 3 e ... - slices)' },
    { k = 'gw', d = 'go to a hex position on the wave: gw, the frame as on the ruler above the wave (hex, from the sample start), Enter - the wave cursor at the nearest transient, Shift+Enter - exactly there; g[ g] then set the sample start / end at it' },
    { k = 'g[ g]', d = 'sample start / end (was [ ] - it fought the octave keys of frow): at the edge of the span dragged on the wave, else at the wave cursor (gw), else at the marker of the selected slice ([ - the sample starts there, ] - it ends there: the slice before it is the last) - cuts it for all notes of the instrument (as the blue ia / ib handles)' },
    { k = 'D', d = 'selection to lib' },
    { k = 'Space', d = 'preview selection' },
    { k = 'j k', t = { 'j', 'k', 'J', 'K' }, d = 'properties: row down / up' },
    { k = 'h l', t = { 'h', 'l', 'H', 'L' }, d = 'properties: value down / up' },
    { k = 'R', d = 'properties: reset value' },
    { k = '! @', t = { '!', '@', '#', '$', '%', '^', '&' }, d = 'slice: ! at transients (again - more sensitive, cycles), @ # $ % ^ & - 4 8 16 32 64 128 equal (focus in the lib or here)' },
    { k = 'Q', d = 'quantizer panel: grid, catch, max stretch, strength, sensitivity; the wave shows the plan, apply writes stretch markers' },
    { k = 'zone', d = 'slice of a big sample: top triangles = start / end, bottom strip = move it' },
    { k = 'Esc', d = 'clear selection / close' },
  } },
  grid = { title = 'monome grid / arc (jf_grid)', e = {
    { k = 'take', d = 'give the grid to the tracker module (rows 1-7: slots x tracks, row 8: transport)' },
    { k = 'grid', d = 'return the grid to the GRID mixer mod' },
    { k = 'arc', d = '4 rings = 4 parameters of the effect picked in DSP (stays when you leave DSP); click a ring in this tab - pick its parameter, remembered for every instance of that effect; :arcforget - follow the DSP cursor again; nothing picked - 1 lpb, 2 oct, 3 step, 4 inst' },
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
  autocanvas = { title = 'curve: the automation canvas - curves of the track over the bar / region / time selection, drawn from the keyboard', e = {
    { k = 'h l  { }', d = 'row (= the tracker cursor) / a grid cell; g G - the edges of the span' },
    { k = 'j k  J K', d = 'the value of the active curve at the row: -/+ 1/16, Shift - 1/128 (a point is written)' },
    { k = '0..9', d = 'level 0 %..90 % at the row' },
    { k = 'x  BS', d = 'remove the points of the row (with v - of the range)' },
    { k = 'v', d = 'anchor: the range from here to the cursor; Esc - off' },
    { k = 'f r R s t q n', d = 'fill the range (or the grid cell under the cursor) with a shape per cell: flat, ramp up, ramp down, sine, triangle, square, noise; the height - the curve value at the cursor (0 - full); n again - another noise' },
    { k = '[ ]', d = 'grid finer / coarser (1/8 row .. a bar; finer than a row - points between the rows of an envelope)' },
    { k = 'Opt+drag (mouse)', d = 'between two points of an envelope: bend the segment - up / down makes it curve above / below the straight line (Shift - fine); Opt+double click - straight again; one undo' },
    { k = 'Ctrl+Opt (draw / line / erase)', d = 'CONTROL on the canvas: the finger on the trackpad draws the stroke from the canvas cursor (Shift - fine); let Ctrl+Opt go - written, one undo' },
    { k = 'dd dw  yy y  p', d = 'as in the tracker: dd / dw delete the point (with v - every point in it; an empty row - the next one), yy / v … y copy, p paste from the cursor' },
    { k = 'i  D  E', d = 'mouse tools (also buttons in the header): i draw - a pencil, drag draws freely; D line - drag from a point to a point; E erase - drag removes; the same key again - back to cur (a click moves the cursor). Written on release, one undo' },
    { k = 'c', d = 'shape tool: drag over the canvas - the span, up / down - the height; the shape repeats every cycle (the button ~1/4 - the list; Opt while dragging - up / down changes the frequency freely): tri, saw+, saw-, sin, exp, log, sqr - the buttons next to the tools. On a MIDI lane every row of the span is rewritten' },
    { k = '/  Shift+click', d = 'the list of curves on the left: / add - fuzzy search over every parameter of the track (its envelope is made, it joins the canvas); Shift+click in the list - stacked lanes, one above the other (a click on a lane - it is edited); double click - to DSP, the cursor on that parameter' },
    { k = 'Enter (tracker)', d = 'on an envelope / MIDI lane (PB CC PC AT) of the tracker - its curve on this canvas' },
    { k = 'delay', d = 'the cursor on the delay field of a note column - the delays of its notes as a curve; each note also gets a tail from the row start to where it really sounds and a tick there (the groove); line / shape (sin - a swing) / hum / sel change the delays' },
    { k = 'vel', d = 'the cursor on the vel field of a note column - the canvas shows the velocities of its notes as a curve: draw / line / shape / sel / hum change the velocity of the notes under the stroke (no new notes), j k - nudge, 0-9 - level' },
    { k = 'T', d = 'sel - select and transform: drag - rows; diamonds on the frame: corners tilt the top / bottom, the middles of the sides stretch in time (left / right) or scale the values (top / bottom), inside - move; written on release, one undo; Esc - off' },
    { k = 'hum', d = 'the button in the header: humanize - the values of the selection (sel) or of the cell under the cursor +-8 % at random; again - another spread' },
    { k = 'S', d = 'snap: the stroke goes by grid cells (on) or by rows (off); the grid - [ ] or the buttons [ 1/4 ] in the header (a click on the value - the list)' },
    { k = 'Space (list)', d = 'in the curve list (Cmd+H): the curve into the stack - the canvas splits into lanes, one per marked curve under the active one (4-5 fit); Space again - out; Shift+click does the same. Other curves are not drawn behind (option curves behind)' },   -- 2 ноя
    { k = 'z, z.', d = 'grid finer / coarser (as [ ])' },
    { k = 'wheel  z0', d = 'zoom the canvas at the mouse (trackpad pinch / scroll), sideways - scroll; a frame on the envelope column in the tracker shows the visible part; z0 - the whole span (option curve zoom)' },
    { k = 'H L  drag', d = 'select rows from the cursor (Shift+h / l, or drag with cur on empty space); then d y p, Esc drops it' },
    { k = 'zg', d = 'the grid list: even (1/192 .. 1/2) or uneven - p = a cell per pattern, s = per section; { } go cell to cell, [ ] back to even' },
    { k = 'zp', d = 'the whole project / back to the span (the bar at the cursor, the region, the time selection) - automation and modulation over the song' },
    { k = 'Tab  S-Tab', d = 'the active curve: the lane under the cursor, every envelope of the track, the take envelopes of the samples selected in the lib (v there) and the envelopes of their tracks, note mod slots, LFO / ACS curves; a click on the legend too' },
    { k = 'w b', d = 'next / previous point of the active curve' },
    { k = 'm e', d = 'LFO / audio follower of the active parameter on / off: it appears as its own curve (LFO · name) - the band is its swing around the automation, the thin line the predicted wave; with it active: s t q r R n shape, [ ] speed (x2, tempo sync: cycles per beat), j k strength, w b phase. A green dot while playing - the real value' },
    { k = 'P L', d = 'pages params / curves (the generator) - as everywhere in the automation tab' },
    { k = 'Esc', d = 'drop the anchor, then back to the tracker' },
  } },
  automation = { title = 'automation and modulation: params, curve, mod (LFO / follower / link of REAPER), shape generator, automation items', e = {
    { k = 'Opt+A', d = 'from anywhere: the last touched parameter (move a knob in a plugin or in DSP) becomes an envelope column on its track, the cursor goes there - type values in INSERT; a take FX parameter opens its take envelope here' },
    { k = 'L', d = 'shape: draws a shape (sin tri saw sqr, premod) as envelope points / an automation item - beside the params when wide, a page [shape] when narrow; L again - back' },
    { k = 'M', d = 'mod: the parameter modulation of the track (REAPER LFO, audio follower, link) - the former modulation tab: a add, x remove, Enter toggle, o w windows' },
    { k = 'C', d = 'curve: the canvas - the curves of the track drawn from the keyboard (its own key page)' },
    { k = 'P', d = 'params: every parameter of the track (track envelopes + all FX params) - ENV ACT ARM PTS MOD value; also rclick on trim in a track header' },
    { k = 'params', d = 'Enter: cell, e: envelope create / show / hide, a: arm, b: active, m: modulate (LFO) - the row on the mod page (M), c: curve into it, o: FX window, w: modulation window, v: used only, M: automation mode, /: find' },
    { k = 'LFO j k h l', d = 'field / value: shape (sin tri saw+ saw- sqr rnd), period in rows, depth, center, phase, points per period' },
    { k = 'type', d = 'lfo | premod (Anticipate: lead curve before every hit of a source track - its events or audio transients, hold, release, duck / swell) | follow (curve from another envelope or the audio level of a track: attack, release, shift = lookahead, invert)' },
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
  playlist = { title = 'chain: patterns in a row as text (the chain button of the matrix, :ch; was playlist)', e = {   -- 18 окт
    { k = 'what', t = {}, d = 'words in a row, one per step: the song plays them in this order; named playlists are kept in the project, the song itself stays as it is' },
    { k = 'A1', t = {}, d = 'a pattern by its name (any case)' },
    { k = 'verse', t = {}, d = 'a section by its name - all its patterns in order' },
    { k = '4', t = {}, d = 'a region by its REAPER number' },
    { k = 'x2  *2', t = {}, d = 'repeat: A1x2 = A1 A1 (a section too: versex2)' },
    { k = ':16', t = {}, d = 'only the first 16 rows of the pattern' },
    { k = '/2', t = {}, d = 'only a part: /2 - the first half, /4 - a quarter' },
    { k = '-8', t = {}, d = 'skip the first 8 rows (start later)' },
    { k = '+8', t = {}, d = 'after the pattern, its first 8 rows once more' },
    { k = 'A1-8:8x2', t = {}, d = 'together: rows 8..15 of A1, twice' },
    { k = ', ; |', t = {}, d = 'separators like spaces' },
    { k = 'Tab', t = {}, d = 'in :pl - completes the word with a pattern / section name (again - the next one)' },
    { k = 'play', t = {}, d = 'plays the list: whole patterns follow seamlessly, shortened / skipped ones jump (a short gap); the list ends - stop' },
    { k = 'write', t = {}, d = 'writes the list after the song: whole patterns as linked repeats, shortened ones as their own pattern; u - back' },
    { k = 'print jumps', t = {}, d = 'the song as the tracker plays it with its ZB (break) / ZJ (jump) commands is written after the song as the section printed - REAPER then renders the jumps too (:pj)' },
    { k = '< > name', t = {}, d = 'the playlists of the project: < > - previous / next, a click on the name - :pl name; new dup del' },
    { k = 'red word', t = {}, d = 'not found (no such pattern / section / number) - skipped, the status line under it says why' },
  } },
  ctrl = { title = 'main module (control)', e = {
    { k = 'h j k l', d = 'move between cells (arrows too); focus lands on BPM' },
    { k = '+ -', d = 'value up / down (like the wheel): BPM, LPB, oct, step, vel, x-fade, font...' },
    { k = 'Enter Space', d = 'press the cell (like a click); on BPM - type the number, Enter applies' },
    { k = '0-9', d = 'on BPM: start typing the tempo; Enter - the project tempo, Opt+Enter - a tempo change point at the tracker cursor row' },
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
    { k = 'hold Shift Ctrl Opt Cmd', t = {}, d = 'hold a modifier (or two) half a second, no key - the help pane lists what it does here and everywhere' },
  } },
}
-- строка подсказок под модулем (опция hints, 2 окт): самое нужное в одну
-- строку; полное описание — справка ?. { клавиша, что делает }
KH.BARS = {
  -- 21 окт: строки клавиш панелей humanizer / reform / bouncer
  arranger = { { 'C', 'seq' }, { 'h l', 'section' }, { 'Enter', 'add' }, { 'x', 'last off' }, { 'Space', 'play' }, { '< >', 'arrangement' }, { 'Esc', 'back' } },
  phrases = { { 'Enter', 'at cursor' }, { 'e', 'source' }, { 'n', 'new' }, { 'r', 'rename' }, { 'x x', 'delete' }, { 'Esc', 'back' } },
  lfogen = { { 'j k', 'field' }, { 'h l', 'value' }, { 'g', 'auto-item' }, { 'p', 'points' }, { 'Esc', 'back' } },
  humanizer = { { 'letter', 'row' }, { 'j k', 'row' }, { 'h l', 'value' }, { 'H L', 'fine' }, { 'N Enter', 'set N' }, { 'Space', 'on/off' }, { '0', 'reset' }, { 'a', 'add dsp param' }, { 'x', 'remove' }, { 'Enter', 'apply' }, { 'f', 'jump' } },
  reform = { { 'letter', 'row' }, { 'j k', 'row' }, { 'h l', 'value' }, { 'H L', 'fine' }, { 'N Enter', 'set N' }, { '0', 'reset' }, { 'Space', 'listen' }, { 'Enter', 'keep' }, { 'Esc', 'revert' }, { 'f', 'jump' } },
  renderer = { { 'letter', 'row' }, { 'j k', 'row' }, { 'h l', 'value' }, { 'H L', 'fine' }, { 'N Enter', 'set N' }, { 'Space', 'toggle' }, { '0', 'defaults' }, { 'Enter', 'bounce' }, { 'Esc', 'back' }, { 'f', 'jump' } },
  tracker = { { 'i', 'insert' }, { 'hjkl', 'move' }, { 'x', 'del' }, { 'dd', 'rows' }, { 'yy p', 'copy' }, { 'v', 'select' },
              { '/', 'find' }, { ':', 'cmd' }, { '\\', 'menu' }, { '\\\\', 'context' }, { 'f', 'jump' }, { 'Space', 'play' }, { '?', 'actions' } },
  insert = { { 'q2w3e', 'notes' }, { 'z x', 'oct' }, { 'c C', 'vel' }, { '.', 'repeat' }, { 'Opt+J K', 'inst' }, { 'a', 'step auto' },
             { 'd', 'delete' }, { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' }, { 'Esc', 'normal' } },
  -- 14 окт: keys renoise — ноты двумя рядами, октава [ ], громкость { } (z x c — ноты)
  -- 16 окт: раскладка frow — ноты цифрами и F-рядом, октава [ ], громкость { }
  -- 17 окт: в INSERT с frow буквы — команды NORMAL; F1 — нота, поэтому ? (действия) вместо help
  insert_fr = { { '1 f1 2', 'notes' }, { '[ ]', 'oct' }, { '{ }', 'vel' }, { '( )', 'inst' }, { 'x dd p', 'vim' },
             { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' }, { 'Esc', 'normal' }, { '?', 'actions' } },
  insert_rn = { { 'zsx q2w', 'notes' }, { '[ ]', 'oct' }, { '{ }', 'vel' }, { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' },
             { 'arrows', 'move' }, { 'Esc', 'normal' }, { '?', 'actions' } },
  actions = { { 'j k', 'move' }, { 'h l', 'groups / list' }, { '/', 'find' }, { 'Enter', 'run' }, { '[ ]', 'section' }, { 'f', 'favourite' }, { 'a x', 'shortcut' }, { 'y', 'copy id' }, { 'Esc', 'tracker' } },
  perf = { { 't', 'jftop / perf' }, { 'n', 'REAPER meter' }, { 'r', 'reset' }, { 'j k', 'scroll' }, { 'Esc', 'tracker' } },
  undotree = { { 'j k', 'node' }, { 'Enter', 'go there' }, { 'zz', 'big + timeline' }, { 'dblclick', 'go' }, { 'u C-r', 'undo / redo' }, { 'Esc', 'tracker' } },
  matrix = { { 'o O', 'new' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'n', 'name' }, { '[ ]', 'bar' },
             { 'C-S-hl', 'pattern' }, { 'M', 'mute' }, { 'Space', 'play' }, { 'R', 'ruler' } },
  inst = { { 'j k', 'select' }, { 'J K', 'move' }, { 'dd', 'cut' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'v', 'range' }, { 'Enter', 'item' }, { 's', 'slice' },
           { 'Space', 'listen' }, { '/', 'find' }, { 'R', 'ξ random' }, { '[ ]', 'ξ back / fwd' } },
  tracks = { { 'h l', 'open / close' }, { 'Enter', 'go / pick' }, { 'Space', 'mark / listen' }, { '+ - c', 'zoom / convert' }, { 'T M S R', 'flags' }, { 'dd yy p P', 'cut copy paste' }, { '>> <<', 'in / out' }, { 'J K', 'move' }, { 'o O F', 'new / folder' }, { 'r', 'rename' }, { '/', 'filter' } },   -- 13 окт: как lf
  pm = { { 'Enter', 'open' }, { 'S+Enter', 'inside' }, { 'Space', 'listen' }, { 'T s p', 'tags status pin' }, { 'a', 'add' }, { 'b', 'big' }, { '/', 'find' } },
  browser = { { 'Enter', 'open/add' }, { 'a', 'add to' }, { 'h', 'up' }, { 'Space', 'listen' }, { '/', 'find' }, { "'1..'0", 'marks' },
              { 'H L', 'back/fwd' }, { '*', 'mkdir' }, { 'Cmd+Enter', 'replace' } },
  dsp = { { 'h l', 'fx' }, { 'j k', 'param' }, { '+ -', 'value' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'cc', 'container' },
          { 'aa', 'automate' }, { 'b', 'bypass' }, { 'o', 'window' }, { 't', 'track/take' }, { '/', 'find' }, { 'af', 'add' }, { 'zz', 'big' } },
  -- 9 окт: роутер (zR) и цепочка на всё окно (zz) — подсказки в строке статуса
  router = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a A', 'add' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' }, { 'b', 'bypass' },
             { 'd', 'delete' }, { 'o', 'window' }, { 'drag', 'slider' }, { 'dblclick', 'default' }, { 'zR Esc', 'back' } },
  dspbig = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a', 'add' }, { 'A', 'parallel' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' },
             { 'b', 'bypass' }, { 'd', 'delete' }, { 'za', 'fold' }, { 'o', 'window' }, { 'zz Esc', 'back' } },
  notes = { { 'type', 'write' }, { 'Esc', 'leave' }, { 'project', 'notes' }, { 'context', 'item' } },
  fxb = { { 'type', 'search' }, { 'Up Down', 'move' }, { 'Enter', 'add' }, { 'drag', 'insert' }, { 'Esc', 'clear' } },
  nmod = { { 't', 'midi trig' }, { 'a', 'add (last touched)' }, { 'Enter', 'curve' }, { 'r', 'rate' }, { 'l', 'loop' }, { 'd', 'delete' }, { 'Esc', 'tracker' } },
  sprops = { { 'J K', 'row' }, { 'H L', 'value' }, { 'Shift', 'fine' }, { 'R', 'reset' }, { 'v', 'fit all rows' }, { 'Esc', 'tracker' } },
  visor = { { 'p', 'on' }, { 'o', 'page' }, { 'a e', 'add' }, { 'j k', 'row' }, { 'J K', 'param' }, { 'H L', 'value' }, { 'h l', 'level' }, { 'm', 'mod' }, { 'M', 'matrix' }, { '=', 'type' }, { 's', 'scene' }, { 'i', 'presets' }, { 'n N', 'preset' }, { 'zz', 'big' } },
  sample = { { 's', 'cut at aim' }, { 'S', 'smk / slices' }, { '0 t q', 'aim toggles' }, { 'Enter', 'insert sel' }, { 'v', 'view' }, { '< >', 'vol' },
             { 'n', 'normalize' }, { 'jk', 'param' }, { 'hl', 'value' } },
  automation = { { 'Opt+A', 'last touched' }, { 'C', 'canvas' }, { 'M', 'mod' }, { 'L', 'shape' }, { 'P', 'params' }, { 'g p', 'write curve' }, { 'Esc', 'back' } },
  autocanvas = { { 'hl', 'row' }, { '{ }', 'cell' }, { 'jk', 'value' }, { '0-9', 'level' }, { 'v', 'range' }, { 'f r s t q n', 'shape' }, { '[ ]', 'grid' }, { 'Tab', 'curve' }, { 'zp', 'project' }, { 'x', 'remove' }, { 'd D c E', 'draw line shape erase' }, { 'T', 'transform' }, { 'S', 'snap' }, { 'P L', 'pages' }, { 'Esc', 'back' } },
  modulation = { { 'hjkl', 'cell' }, { 'Enter', 'toggle' }, { '+ -', 'value' }, { 'a', 'add' }, { 'x', 'remove' }, { 'o w', 'windows' } },
  retro = { { 'Space', 'listen' }, { 'L', 'loop' }, { 'p', 'put' }, { 'd', 'lib' }, { 'bb', 'beatbox -> MIDI' }, { 'j k', 'channel' }, { '[ ] { }', 'edges' }, { 'h l', 'move' } },
  garden = { { 'N Enter', 'loop' }, { '> <', 'fit' }, { '+ -', 'period' }, { 'm', 'mute' }, { 'o', 'Orca' }, { 'O', 'on/off' },
             { 'p', 'pin' }, { 'x', 'clear' } },
  orca = { { 'arrows', 'move' }, { 'A-Z', 'operator' }, { '!', 'bang' }, { '.', 'erase' }, { 'Space', 'play' }, { 'Esc', 'back' } },
  grid = { { 'take', 'grid to tracker' }, { 'grid', 'back to mixer' }, { 'Esc', 'back' } },
  midi = { { 'j k', 'target' }, { 'Enter', 'learn' }, { 'd', 'clear' }, { 'm', 'abs/rel' }, { 'Esc', 'back' } },
  master = { { 'm', 'scope mode' }, { 'Esc', 'back' } },
  ctrl = { { 'hjkl', 'cell' }, { '+ -', 'value' }, { 'Enter', 'press' }, { 'F', 'follow' }, { 'Esc', 'back' } },   -- F: тоглы переехали сюда (5 окт)
  help = { { 'type', 'search' }, { 'Left Right', 'page' }, { 'Esc', 'back' } },
}
-- 28 окт: курсор DSP на slixer / контейнере — своя страница справки и своя строка клавиш (записи берутся из dsp)
do
  local function from_dsp(ks)
    local out, by = {}, {}
    for _, e in ipairs(KH.PAGES.dsp.e) do by[e.k] = e end
    for _, k in ipairs(ks) do if type(k) == 'table' then out[#out + 1] = k elseif by[k] then out[#out + 1] = by[k] end end
    return out
  end
  KH.PAGES.slixer = { title = 'DSP: slixer (slicer sampler)', e = from_dsp({
    { k = 'slixer', t = {}, d = 'the sampler of the tracker: a sample cut into slices, every slice a note (C-3 up); the module shows the wave with the slices, its buttons on top and the MIDI row below. Notes of the track play the slices; 0Sxx picks a slice, 0Rxy retriggers it' },
    'Opt+letter (slixer)', 'slixer slots', 'ze', 'Opt+J K',
    { k = 'drag a slice edge', t = {}, d = 'on the wave: move the edge of a slice (spam on - it rolls while you drag, let go - the slice plays); click a slice - select and hear it' },
    'h l', 'w W', 'j k g G', '+ - ^A ^X', 'i', 'Z' }) }
  KH.PAGES.container = { title = 'DSP: container (rack)', e = from_dsp({
    'container', 'container XY',
    { k = 'chain keys', t = {}, d = 'CHAINS of a container: click a chain name - its keys: j k chain (the DSP cursor on its module), h l mix -/+ 5 % (H L 1 %), m off, s solo, dd delete the chain, a add an fx at the end of the container, Esc back to DSP' },
    { k = 'route keys', t = {}, d = 'the mini router (under the XY of the track block; route on the left under take fx shows it; 4 letters a box, serial to the right, parallel below; into / out of a container too): click a box - select it, double click or Enter - to it in DSP; keys: j k module, x lift, then j k where and p / Enter after, P before, = parallel to it; without a lifted one: = parallel to the one before, + serial, dd delete, a add an fx after it, b bypass; Esc puts down / leaves' },
    { k = 'variants 1..5', t = {}, d = 'next to CHAINS: slots of the whole container - every parameter of the modules inside, chain mix / on, the XY corners and the puck; an empty slot: click saves, a full one: click recalls (u - undo), Shift+click overwrites, Opt+click clears. ROUTE / XY - the switch under the chain list, the lower half shows the one that is lit' },
    { k = 'A<>B', t = {}, d = 'container with two chains: the A<>B button links their mix - one fades in while the other fades out (a crossfade of the chains); lit while the link is on, click - on / off' },
    '★ links', 'c= c|', 'cc', '[] (track block)', 'cf', 'cv', 'cb', 'zr',
    { k = 'drag a module', t = {}, d = 'in CHAINS / ROUTE: drag a module onto another chain or between modules - it moves there (onto = parallel)' },
    { k = 'chain colour', t = {}, d = 'the module menu (\\ or right click) of a module in a chain: Chain colour - a palette of squares with an index (type xx), # - your own hex (:chcol rrggbb), reset - the colour of the lane number' },
    'h l', 'w W', 'dw db', 'Z' }) }
end
KH.PAGES.console = { title = 'console (Strudel patterns)', e = {
  { k = 't2: n("c e g b")', t = {}, d = 'a line = a channel: notes into the pattern at the cursor on track 2 (REAPER track number, as t135m); no tN: - the cursor track. A cycle is a bar: a pattern of 4 bars gets cycles 0..3' },
  { k = 'mini-notation', t = {}, d = 'space - steps, [ ] subdivide, , chord, < > one per cycle, *n faster, /n slower, !n repeat, @n weight, ? sometimes, (k,n,r) euclid, ~ rest; notes c e g, f#3, bb2, numbers = steps from C-4' },
  { k = '.fast .slow .rev .every .add .oct', t = {}, d = 'transform the pattern: .fast(2) .slow(2) .rev() .every(4, "rev") .add(7) .oct(-1)' },
  { k = 's() .vel() .cmd() .i()', t = {}, d = 's("1 3 ~ 5") - slices (slixer: its base note + n - 1); .vel("1 0.5") - velocity by steps; .cmd("0R42") - a tracker command on every note (a pattern too: "0D20 ~"); .i(3) - instrument 3 of the lib' },
  { k = 'Enter', t = {}, d = 'evaluate the line under the cursor: the track in the pattern is rewritten (the notes there before are replaced)' },
  { k = 'Cmd+Enter', t = {}, d = 'evaluate every line' },
  { k = 'Shift+Enter', t = {}, d = 'a new line' },
  { k = 'Up Down', t = {}, d = 'on an empty line: the history of evaluated lines' },
  { k = 't2: ~  hush', t = {}, d = 'clear the channel / every channel the console wrote, in this pattern' },
  { k = 'Esc', t = {}, d = 'back to the tracker' },
  { k = ':console  \\ E', t = {}, d = 'open the console (again - focus, then hide)' },
} }
KH.BARS.console = { { 'Enter', 'line' }, { 'Cmd+Enter', 'all' }, { 'S+Enter', 'new line' }, { 'Up Down', 'history' }, { 'Esc', 'back' } }
KH.BARS.dsp_slixer = { { 'Opt+D', 'detect' }, { 'Opt+T', 'transient' }, { 'Opt+C', 'classify' }, { 'Opt+X', 'clear' }, { 'Opt+Z', 'undo' },
  { 'Opt+E', 'midi' }, { 'Opt+N', 'names' }, { 'Opt+B', 'arp' }, { 'Opt+J K', 'preset' }, { 'ze', 'window' }, { 'h l', 'fx' } }
KH.BARS.dsp_container = { { 'h l', 'fx' }, { 'c= c|', 'parallel / serial' }, { 'cc', 'pack' }, { 'cf', 'fold' }, { 'cv', 'grid / list' },
  { 'cb', 'bands' }, { 'zr', 'router' }, { 'P', 'pin ★' }, { 'Z', 'menu' }, { 'dd', 'delete' } }
KH.ORDER = { 'intro', 'pane', 'ctrl', 'tracker', 'insert', 'matrix', 'playlist', 'inst', 'slices', 'tracks', 'clipboard', 'browser', 'map', 'pm', 'dsp', 'slixer', 'container', 'console', 'fxb', 'notes', 'undotree', 'actions', 'sample', 'sprops', 'nmod', 'automation', 'autocanvas', 'modulation', 'midi', 'grid', 'visor', 'retro', 'garden', 'orca', 'master', 'help' }

-- токены записи (кэш)
local function toks(e)
  if e._t then return e._t end
  local t = {}
  if e.t then for _, x in ipairs(e.t) do t[#t + 1] = x end
  elseif not e.k:match('^[%w /]+:%s') then for x in e.k:gmatch('%S+') do t[#t + 1] = x end end   -- 18 окт: «env: field 2» — запись контекста, не клавиша 2
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

-- 18 окт: действие не с клавиатуры (зум мышью) — вспыхнуть записью с этой клавишей, как при нажатии
function KH.flash_key(page, key, now)
  local P = KH.PAGES[page]
  if not P then return end
  for i, e in ipairs(P.e) do
    if e.k == key then KH.flash = { page = page, i = i, t0 = now, seed = (math.floor(now * 1000) % 9973) + i }; KH.remember(page, i); return true end
  end
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
    KH.remember(page, i)
  end
end
-- 18 окт: история совершённых действий (повтор того же подряд — одна запись); новое действие — снова живое
function KH.remember(page, i)
  local h = KH.hist
  local last = h[#h]
  if not (last and last.page == page and last.i == i) then h[#h + 1] = { page = page, i = i }; if #h > 60 then table.remove(h, 1) end end
  KH.hpos, KH.sel = nil, nil
end
-- стрелки < >: назад / вперёд по истории; за последним — снова живое (страница следует за модулем)
function KH.step(d)
  local h = KH.hist
  if #h == 0 then return end
  local p = (KH.hpos or (#h + 1)) + d
  if p > #h then KH.hpos, KH.sel, KH.pinned = nil, nil, false; return end
  p = math.max(1, p)
  KH.hpos = p
  local e = h[p]
  KH.page, KH.pinned, KH.query = e.page, true, ''
  KH.sel, KH.want = { page = e.page, i = e.i }, e.i
end
-- закладка n: пустая (или Shift) — запомнить страницу и прокрутку, есть — перейти
function KH.mark(n, save)
  if save or not KH.marks[n] then
    KH.marks[n] = { page = KH.page, scroll = KH.scroll }
    if KH.on_marks then KH.on_marks() end
    return 'saved'
  end
  local m = KH.marks[n]
  if KH.PAGES[m.page] then KH.page, KH.scroll, KH.pinned, KH.query, KH.sel = m.page, m.scroll or 0, true, '', nil end
  return 'go'
end
function KH.marks_str()
  local o = {}
  for n = 1, 5 do local m = KH.marks[n]; o[#o + 1] = m and (m.page .. ':' .. (m.scroll or 0)) or '' end
  return table.concat(o, ',')
end
function KH.marks_load(s)
  local n = 0
  for part in ((s or '') .. ','):gmatch('([^,]*),') do
    n = n + 1
    local pg, sc = part:match('^([%w_]+):(%d+)$')
    KH.marks[n] = pg and { page = pg, scroll = tonumber(sc) } or nil
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

-- 21 окт: справка модификаторов — держишь Shift / Ctrl / Opt / Cmd (или сочетание) без клавиши — у фокуса
-- список того, что они дают здесь. Записи справки пишут модификаторы по-разному: Ctrl+ ^ C- / Opt+ ⌥ A- /
-- Cmd+ ⌘ M- / Shift+ ⇧ S-; одиночная заглавная (A, U, M) — это Shift + буква (как в Vim).
local MODP = {
  { 'Shift+', 'shift' }, { 'Shift-', 'shift' }, { '⇧', 'shift' }, { 'S-', 'shift' },
  { 'Ctrl+', 'ctrl' }, { 'Ctrl-', 'ctrl' }, { 'C-', 'ctrl' },
  { 'Option+', 'opt' }, { 'Opt+', 'opt' }, { 'Opt-', 'opt' }, { 'Alt+', 'opt' }, { '⌥', 'opt' }, { 'A-', 'opt' },
  { 'Cmd+', 'cmd' }, { 'Cmd-', 'cmd' }, { '⌘', 'cmd' }, { 'M-', 'cmd' },
}
-- токен → набор модификаторов { shift, ctrl, opt, cmd } и сама клавиша; без модификаторов — nil
function KH.mods_of(tok)
  local m, rest, any = {}, tok, false
  local again = true
  while again do
    again = false
    for _, mp in ipairs(MODP) do
      local pre = mp[1]
      if rest:sub(1, #pre) == pre and #rest > #pre then m[mp[2]] = true; rest = rest:sub(#pre + 1); any = true; again = true; break end
      if rest == pre and pre:sub(-1) == '+' then m[mp[2]] = true; rest = '+'; any = true; break end   -- «Cmd+» — Cmd и +
    end
    if not again and rest:sub(1, 1) == '^' and #rest > 1 then m.ctrl = true; rest = rest:sub(2); any = true; again = true end
  end
  if not any and rest:match('^%u$') then return { shift = true }, rest, true end   -- заглавная — Shift + буква
  if not any then return nil, tok end
  return m, rest
end
local function same(a, b) return (a.shift or false) == (b.shift or false) and (a.ctrl or false) == (b.ctrl or false) and (a.opt or false) == (b.opt or false) and (a.cmd or false) == (b.cmd or false) end
-- короткая подпись записи: m, иначе описание до скобки / «;» / « - »
function KH.short(e)
  if e.m then return e.m end
  local d = e.d:gsub(' %(.*$', ''):gsub('; .*$', '')
  if #d > 44 then d = d:gsub(' %- .*$', '') end
  return d
end
-- pages — список страниц (первая — фокуса); held — { shift, ctrl, opt, cmd } → { { key, text, page } … }
-- клавиши без модификатора после клавиши с ним — те же модификаторы (Ctrl+h j k l, Opt+F1 F2)
function KH.mod_entries(pages, held)
  local out, seen = {}, {}
  for _, pg in ipairs(pages) do
    local P = KH.PAGES[pg]
    for _, e in ipairs(P and P.e or {}) do
      local keys, last = {}, nil
      for tok in e.k:gsub(' / ', ' '):gmatch('%S+') do
        local m, rest, caps = KH.mods_of(tok)
        if m and not caps then last = m
        elseif last and #tok <= 6 then m = last end          -- Ctrl+Shift+H L — L тоже с Ctrl+Shift (не просто Shift)
        if m and same(m, held) then keys[#keys + 1] = tok end
      end
      if #keys > 0 then
        local kk = table.concat(keys, ' ')
        if not seen[kk] then seen[kk] = true; out[#out + 1] = { key = kk, text = KH.short(e), page = pg } end
      end
    end
  end
  return out
end
function KH.mods_name(h)
  local t = {}
  if h.ctrl then t[#t + 1] = 'Ctrl' end
  if h.opt then t[#t + 1] = 'Opt' end
  if h.shift then t[#t + 1] = 'Shift' end
  if h.cmd then t[#t + 1] = 'Cmd' end
  return table.concat(t, '+')
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
-- 2 ноя: «где я» — сверху страницы то, что можно сделать с тем, что под курсором (main кладёт KH.here: ключ KH.HERE
-- или таблицу { title, e } — справка своего DSP-модуля, поле help: в dspmods_user.txt); строки помечены именем места
KH.HERE = {
  wave = { title = 'the wave of an audio note', e = {
    { k = 'S Enter', d = 'a stretch marker at the start of the row (one already in the row - snapped onto the row)' },
    { k = 'x', d = 'remove the stretch marker of the row' },
    { k = 'J K', d = 'pull the hit of the row a row down / up (3J - three): the audio stretches between the markers' },
    { k = 's', d = 'cut the note at the row (two items, the slice keeps playing)' },
    { k = 'Tab Shift+Tab', d = 'next / previous hit: a stretch marker or a note start' },
    { k = '\\q \\Q', d = 'q - the nearest peak onto the row grid; Q - pick a peak, j k to a row, Enter moves it there' },
    { k = 'l', d = 'back to the note field' },
    { k = 'zW', d = 'zoom on this item: only its rows, LPB to fit; again - back' },
    { k = 'zvw', d = 'wave view: own column / in the note field / item background / off' } } },
  note = { title = 'a note', e = {
    { k = 'i', d = 'INSERT: type notes (q2w3e ...), the step moves the cursor' },
    { k = 'x  dd', d = 'delete the note / the row (the rows below move up)' },
    { k = 'Enter', d = 'the smart panel: notes, chords, microtones of the field' },
    { k = 'Ctrl+A Ctrl+X', d = 'the note +1 / -1 semitone' },
    { k = 'Cmd+F1 F2', d = 'microtone down / up 1/6 tone (MPE for MIDI, fractional pitch for audio)' },
    { k = 'Shift+T', d = 'the transposer: semitones, octaves, degrees, to the chord, just intonation' },
    { k = 's', d = 'split the note at the row' },
    { k = 'h', d = 'audio note: into its wave (stretch markers)' },
    { k = 'ze', d = 'the window of the instrument of the track' },
    { k = 'yy p', d = 'copy rows / paste' } } },
  inst = { title = 'the instrument of a note', e = {
    { k = 'Enter', d = 'the instruments of the lib to pick from' },
    { k = '( )', d = 'instrument previous / next' },
    { k = 'Ctrl+A Ctrl+X', d = 'the next / previous instrument' } } },
  vol = { title = 'the volume of a note', e = {
    { k = 'Ctrl+A Ctrl+X', d = 'volume +1 / -1 (3 Ctrl+A - by three)' },
    { k = 'x', d = 'clear the value - the note stays' },
    { k = 'v', d = 'VISUAL on this field only; Cmd+I interpolates from the first value to the last' },
    { k = 'yc', d = 'copy this column of the pattern; p - into the notes from the cursor' },
    { k = 'dc', d = 'clear this column in the pattern' } } },
  pan = { title = 'the pan of an audio note', e = {
    { k = 'Ctrl+A Ctrl+X', d = 'pan right / left (00 left, 80 centre, FF right)' },
    { k = 'x', d = 'centre' } } },
  delay = { title = 'the delay of a note (a 256th of a row)', e = {
    { k = 'Ctrl+A Ctrl+X', d = 'later / earlier' },
    { k = 'x', d = 'delay 0 - onto the row' },
    { k = 'Q', d = 'VISUAL: quantize - every note onto its nearest row' },
    { k = 'v Cmd+I', d = 'VISUAL on this field, interpolate (a strum, a swing ramp)' } } },
  cmd = { title = 'a command of a note (0M volume, 0P pan, 0R retrig, 09 offset ...)', e = {
    { k = 'Enter', d = 'the commands to pick from (fzf), on top - the parameter selected in DSP' },
    { k = 'Ctrl+A Ctrl+X', d = 'the value +1 / -1' },
    { k = 'x  dw', d = 'remove the command of the row' },
    { k = ':fxcmd', d = 'your own command: XX drives a parameter of an effect of the track' },
    { k = 'Ctrl+Opt+- =', d = 'fewer / more command columns' } } },
  env = { title = 'automation (an envelope column)', e = {
    { k = 'i', d = 'INSERT: type values (00..FF), the point lands on the row' },
    { k = 'Enter', d = 'what to insert: a value, a shape, curves of the selection (VISUAL)' },
    { k = 'w b e', d = 'next / previous point' },
    { k = 'x  dw', d = 'remove the point of the row' },
    { k = 'dc dC', d = 'clear the column / remove the column itself' },
    { k = 'Ctrl+A Ctrl+X', d = 'the value +1 / -1' },
    { k = 'l (shape field)', d = 'the shape of the segment: lin sqr slo fas fae bez' },
    { k = 'Ctrl+Opt', d = 'CONTROL: one big slider of the value of the row' },
    { k = 'ze', d = 'the effect and the parameter this envelope drives' },
    { k = 'A  Opt+A', d = 'another parameter / the last touched one as a column' } } },
  lane = { title = 'a MIDI lane (CC / pitch bend / program change)', e = {
    { k = 'i', d = 'INSERT: type the value of the row' },
    { k = 'Enter', d = 'what to insert' },
    { k = 'x  dw', d = 'remove the event of the row' },
    { k = 'Ctrl+A Ctrl+X', d = 'the value +1 / -1 (an empty row gets the value above first)' },
    { k = 'Ctrl+Opt', d = 'CONTROL: one big slider of the value' } } },
}
function KH.rows()
  local out = {}
  if KH.query == '' then
    -- 21 окт: без поиска — список страницы один раз (был новый на каждый кадр)
    local P = KH.PAGES[KH.page] or KH.PAGES.tracker
    local H = type(KH.here) == 'table' and KH.here or KH.HERE[KH.here or '']
    local key = KH.page .. '@' .. tostring(H and (H.title or '') or '')
    KH.rows_c = KH.rows_c or {}
    local rc = KH.rows_c[key]
    if rc and rc.n == #P.e and rc.h == H then return rc.rows end
    if H then
      local tag = type(KH.here) == 'string' and KH.here or 'module'
      out[1] = { page = 'here', i = 0, e = { k = 'here', d = H.title }, tag = tag }
      for i, e in ipairs(H.e) do out[#out + 1] = { page = 'here', i = i, e = e, tag = tag } end
    end
    for i, e in ipairs(P.e) do out[#out + 1] = { page = KH.page, i = i, e = e } end
    KH.rows_c[key] = { n = #P.e, rows = out, h = H }
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
  elseif c == 8 then KH.query = TX.bs(KH.query); KH.scroll = 0
  elseif c == LEFT then KH.cycle(-1)
  elseif c == RIGHT then KH.cycle(1)
  elseif c == UP then KH.scroll = math.max(0, KH.scroll - 1)
  elseif c == DOWN then KH.scroll = KH.scroll + 1
  elseif c == 13 then KH.pinned = false; return 'leave'
  elseif TX.char(c) then KH.query = KH.query .. TX.char(c); KH.scroll = 0   -- 20 окт: и кириллица
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
-- 17 окт: цвет остывающей искры f = 0..1: горячий (ярче янтаря подсказки) → янтарь → уголь → фон
function KH.ember(U, f)
  local hot = U.mix(U.AMBER, { 1, 0.97, 0.82 }, 0.65)
  local coal = U.mix(U.mix(U.RED, U.AMBER, 0.35), U.PANEL, 0.35)
  if f < 0.2 then return U.mix(hot, U.AMBER, f / 0.2) end
  if f < 0.55 then return U.mix(U.AMBER, coal, (f - 0.2) / 0.35) end
  return U.mix(coal, U.PANEL, (f - 0.55) / 0.45)
end
-- 18 окт: < > (история совершённых действий) и закладки 1..5 справа в строке y; → левый край кнопок
function KH.buttons(U, L, x, y, w)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local down = gfx.mouse_cap & 1 == 1
  local press = down and not KH.mdown
  KH.mdown = down
  local bx = x + w - L.pad
  local function hbtn(label, on, dim)
    local bw = U.measure(label) + 4
    bx = bx - bw - 1
    local hot = mx >= bx and mx < bx + bw and my >= y and my < y + L.rh
    U.set(hot and U.tint(U.AMBER, 0.3) or U.PANEL); gfx.rect(bx, y, bw, L.rh, 1)
    U.set(on and U.AMBER or U.LINE); gfx.rect(bx, y, bw, L.rh, 0)
    U.text(bx + 2, y + 1, label, hot and U.AMBER or (on and U.TEXT or (dim and U.DIM or U.GREY)))
    return hot and press
  end
  for n = 5, 1, -1 do
    if hbtn(tostring(n), KH.marks[n] and KH.marks[n].page == KH.page, not KH.marks[n]) then KH.mark(n, gfx.mouse_cap & 8 == 8) end
  end
  bx = bx - L.pad
  if hbtn('>', KH.hpos ~= nil, KH.hpos == nil) then KH.step(1) end
  if hbtn('<', false, #KH.hist == 0) then KH.step(-1) end
  return bx
end
-- bare (18 окт, панель help): без «F1 help: страница» (заголовок раздела уже выше) и без кнопок (они в его строке)
function KH.draw(U, L, x, y, w, h, now, focused, fit, bare)
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local P = KH.PAGES[KH.page] or KH.PAGES.tracker
  -- шапка: ? HELP · страница · поиск
  local head = bare and '' or ('help: %s'):format(P.title)
  if not bare then U.text(x + L.pad, y + 3, head, U.AMBER) end
  local qx = bare and (x + L.pad) or (x + L.pad + U.measure(head) + 3 * L.pad)
  local qend = x + w - L.pad
  if not bare and w > U.measure(head) + 12 * (U.measure('W') + 2) then qend = KH.buttons(U, L, x, y + 2, w) - L.pad end
  local qs, qc
  if KH.query ~= '' then qs, qc = '/' .. KH.query .. (focused and '_' or ''), U.TEXT
  else
    -- последнее совершённое действие (или то, к которому вернулись стрелками)
    local h = KH.hist[KH.hpos or #KH.hist]
    local he = h and KH.PAGES[h.page] and KH.PAGES[h.page].e[h.i]
    if he then qs, qc = '[' .. (KH.hpos and ('%d/%d: '):format(KH.hpos, #KH.hist) or 'last used: ') .. he.k .. ' - ' .. he.d .. ']', U.GREY   -- 18 окт: скобками, тише строк справки
    else qs, qc = focused and 'type to search, Left/Right page, Esc back' or 'Tab here: search  |  keys you press light up  |  hold Shift / Ctrl / Opt / Cmd: what they do here', U.GREY end
  end
  U.text(qx, y + 3, fit(qs, math.max(0, qend - qx)), qc)
  local rows = KH.rows()
  -- 21 окт: держат модификатор — его сочетания здесь и везде (main кладёт KH.mod_view = { title, lines })
  local mv = KH.mod_view
  if mv then
    rows = {}
    for _, ln in ipairs(mv.lines) do rows[#rows + 1] = { page = '', i = 0, e = { k = ln.key, d = ln.text } } end
    U.set(U.BG); gfx.rect(qx, y + 2, math.max(0, qend - qx), L.rh, 1)
    U.text(qx, y + 3, fit(mv.title, math.max(0, qend - qx)), U.AMBER)
  end
  local keep_scroll = KH.scroll
  if mv then KH.scroll = 0 end
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
  if KH.want and KH.query == '' then
    local rr = (KH.want - 1) % math.max(1, math.ceil(#rows / ncols))
    if rr < KH.scroll then KH.scroll = rr elseif rr >= KH.scroll + nr then KH.scroll = rr - nr + 1 end
    KH.want = nil
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
      if not focused then kc, dc = U.mix(U.AMBER, U.PANEL, 0.15), U.GREY end   -- 18 окт: модуль не в фокусе — чуть тише
      if fl then
        local t = now - KH.flash.t0
        local a = 1 - t / FLASH_T
        U.set(U.AMBER); gfx.a = 0.85 * a; gfx.rect(ex - 2, ey, colw - L.pad, L.rh, 1); gfx.a = 1
        if t < 0.45 then kc, dc = U.BG, U.BG end
        flash_rect = { ex, ey, colw - L.pad, L.rh }
      end
      if KH.sel and KH.sel.page == r.page and KH.sel.i == r.i then U.set(U.AMBER); gfx.rect(ex - 2, ey, colw - L.pad, L.rh, 0) end   -- 18 окт: вернулись стрелками
      local klabel = (r.tag and (r.tag .. ':') or '') .. r.e.k
      if r.tag then U.text(ex, ey + 1, fit(r.tag .. ':', kw), fl and kc or U.GREY); U.text(ex + U.measure(r.tag .. ':'), ey + 1, fit(r.e.k, kw - U.measure(r.tag .. ':')), kc)
      else U.text(ex, ey + 1, fit(klabel, kw - L.pad), kc) end
      U.text(ex + kw, ey + 1, fit(r.e.d, colw - kw - 2 * L.pad), dc)
      if mx >= ex and mx < ex + colw and my >= ey and my < ey + L.rh then hover = r end
    end
  end
  if U.vbar then U.vbar('keyhelp', x, top, w, nr * L.rh, KH.scroll, nr, nrt) end   -- 15 окт: полоса вместо «v more»
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
          -- 17 окт: искра остывает — вспышка ярче подсказки (почти белая) → янтарь → тёмный уголь → гаснет в фон;
          -- у каждой своя скорость (гаснут не разом)
          local fade = math.min(1, t / BOOM_T * (0.75 + 0.5 * rnd(KH.flash.seed, p + 90)))
          local ch = t < 0.12 and '*' or (t < 0.4 and (p % 3 == 0 and '+' or '.') or '.')
          U.text(math.floor(px), math.floor(py - L.rh / 2), ch, KH.ember(U, fade))
        end
      end
    end
  end
  if mv then KH.scroll = keep_scroll; hover = nil end
  return hover
end

return KH
