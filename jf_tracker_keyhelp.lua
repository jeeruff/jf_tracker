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
    { k = 'Opt+1..0', d = 'instrument 1..10 of the lib' },
    { k = 'Cmd+1..0', d = 'jump to channel 1..10 (Ctrl+O - back), in INSERT too (Cmd is never a note)' },
    { k = 'Ctrl+0..9', d = 'step length 0..9 rows (0 - the cursor stays); step auto / next off' },
    { k = 'Ctrl+Shift+J K', d = 'the note under the cursor: its end a row later / earlier (a count - N rows) (not stretched; past the sample the instrument loop plays)' },
    { k = 'Shift+Opt+Cmd+J K', d = 'NORMAL: slip: the sound inside the note under the cursor a row down / up (the note stays; looped - wraps)' },
    { k = 'Ctrl+Shift+H L', d = 'the note under the cursor: its start a row earlier / later (the source offset follows, as trim)' },
    { k = 'pan column', d = 'option pan column: a pan field after the volume (l from vol); two hex digits: 00 left, 80 centre, FF right; BS - centre' },
    { k = 'Ctrl+Opt + -', d = 'continue: the command above in this column (or the volume) again with value +1 / -1, on this row, the cursor a step on' },
    { k = 'Ctrl+Enter', d = 'the note under the cursor: all its properties in a box (only this note): j k row, h l value, a letter - jumps to the row (its lighter letter), Space - its list, R reset, W the REAPER item window, Enter / Esc close; Shift+Space - listen. A double click on a note and the menu item properties open the same box' },
    { k = 'Shift+Space', d = 'play the note under the cursor (its track solo, with fx); Shift+Option+Space - at x0.5; works with the note properties open' },
    { k = 'Ctrl+`', d = 'step next on / off: the cursor goes to the next note / item / command / envelope point of the track; Ctrl - / + back to a number' },
    { k = 'Ctrl+Opt+`', d = 'step auto on / off: the cursor goes past the inserted item / slice (its length); Ctrl - / + back to a number' },
    { k = 'Ctrl+M', d = 'metronome on / off - anywhere (as in FL Studio)' },
    -- 15 окт: опция keys: renoise выключена (закомментирована в опциях)
    { k = 'gm', d = 'metronome menu: m on / off, speed, accents, pre-roll (:metro toggles too)' },
    { k = 'Ctrl - +', d = 'step down / up by one, in any mode (as in Renoise); - + alone - LPB (NORMAL; INSERT on the note field with qwerty) - with frow - = are notes while the keyboard plays and in INSERT; Cmd - + - font size' },
    { k = 'help button (main module)', t = {}, d = 'this help follows the focused module; Tab here: search all pages, left / right: pages' },
  } },
  pane = { title = 'panes (tmux / zellij)', e = {
    { k = '\\ (in a module)', d = 'quick menu of the module in focus (its main actions, letters); in it \\ - the main menu' },
    { k = 'zz', d = 'in any module (lib, browser, fx list, item, macros ...): the module on the whole window, again - back; in the tracker - the tracker alone; dsp zz - dsp big', t = { 'z' } },
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
    { k = 'Opt+H Opt+L', d = 'previous / next track' },
    { k = 'w b e', d = 'next / previous event of the track (all its columns and envelope points, like words in Vim), end of event; dw yw cw - this column' },
    { k = 'E', d = 'the end of the lowest visible event of the track (the last one that starts on screen); dE - up to there' },
    { k = 'W B', d = 'next / previous item start of the track (audio / MIDI items, not single notes or commands)' },
    { k = 'env: w b e dd y p', d = 'envelope points are events: motions, delete / yank / paste points (value + shape)', t = {} },
    { k = 'gg G', d = 'first row / last row (option gg proj/pat relative: in the pattern view - of the cursor pattern)' },
    { k = 'gp gP  gs gS', t = { 'gp', 'gP', 'gs', 'gS' }, d = 'go to the start / the last row of the pattern under the cursor, of its section; with an operator - a motion (dgP deletes to the pattern end)' },
    { k = 'Esc', d = 'smart: while playing - stop, the cursor on the play position (Space - stop and back); stopped - toggles INSERT (as the edit mode in Renoise); options Esc stops playback, Esc mode = vim - only back to NORMAL' },
    { k = 'Ctrl+O / Ctrl+I', d = 'jumps: back / forward to where you were before a jump (f label, harpoon, gg, G)' },
    { k = "'a '1..'9 '' 'd", d = "harpoon: pin the place under the cursor - a track row (tracker), a cell (matrix) or a parameter (DSP); jump to pin 1..9 (the focus goes to its module), list the pins by module (fzf), unpin; works in the tracker, the matrix and DSP; per project" },
    { k = 'gw  3gw', d = 'swap the event under the cursor with the next / the 3rd below (:sw N)' },
    { k = 'Enter  middle click', m = 'smart panel (Enter)', d = 'smart panel (as in PlayerPro): a grid of the values of the field under the cursor - notes, volume, delay, command letter then value, instrument, envelope / CC; pick with a left or middle click or h j k l + Enter; VISUAL - the whole block' },
    { k = ':xf', d = 'modifiers (15 Oct) on VISUAL / the track in the region: stretch k, reverse, rotate n, shuffle, gravity g, bounce r, fib, tuplet n, golden, vel k (also built-in macros)' },
    { k = ':mackey', d = ':mackey name x - a hotkey for the macro: @x plays it; :keys - all keys and commands as text (Data/jf_tracker_keys.md)' },
    { k = 'π (Opt+P)', t = {}, d = 'smart paste: the clipboard buffers at the cursor - a digit / Enter pastes that one, π again - the last yank (layout qwerty: with the keyboard / INSERT π is still the note p beside)' },
    { k = 'clipboard', t = {}, d = 'yank history with the wave of each buffer (w - peaks / spectral); zz - on the whole window: buttons, a big wave, the rows. Space listen, s save as a file, a add to drumrs5k, e open in the external editor, m a subproject in pm with tags; Enter / p - use it' },
    { k = 'macros tab', t = {}, d = 'as lf: folders left (recorded / saved / shared / built-in, h l - between folders and the list, j k), the macros of the folder in the middle, the editor of the picked one right (buttons = keys): Enter play, a new, e edit the body, n name, K hotkey (press the keys, Esc removes; it plays the macro anywhere), r register (@x), t description, S share (a .jfm file in Data/jf_tracker_macros), i import a shared one into saved, d delete; dblclick plays' },
    { k = ':scramble', d = 'slice notes swap their slices randomly (VISUAL, else the track in the region; button in the item tab)' },
    { k = '{ }', d = 'bar back / forward' },
    { k = 'x', d = 'delete event under cursor' },
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
    { k = 'dW', d = 'delete the whole item under the cursor' },
    { k = 'dp', d = 'delete up to the pause: the run of events of the cursor lane from the cursor down to the first empty row (like d} in Vim); on an empty row - the next run' },
    { k = 'dP', d = 'delete every item and all automation (envelope points, automation items) of the selected tracks in the whole project (no selection - the cursor track); one undo' },
    { k = 'C-A-j', d = 'repeat the part of the region above the cursor down to the region end: Ctrl+Opt+J (or Down) - this track; :repeat all - all tracks (Paketti)' },
    { k = 'S-A-j S-A-k', d = 'transpose the instrument selected in the lib -1 / +1 semitone (a count - by N)' },
    { k = 'S-A-h S-A-l', d = 'playrate of the instrument selected in the lib -0.01 / +0.01 (a count - by N)' },
    { k = ':mcmd', d = 'master column cmd = project markers on rows: Enter - edit the command of the row, ! - a REAPER action (marker !<id> - REAPER runs it when playback passes), BS / Del / x - delete; :mcmd <text> sets it, :mcmd alone deletes' },
    { k = 'dC', d = 'clear the cursor field (vol / delay / a command) in the whole track: every subcolumn, every region; the notes stay' },
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
    { k = 'za zM', d = 'fold track: wave + notes, envelopes as a thin line / all <-> open all (:fold, :unfold)' },
    { k = 'zr zR', d = 'router: the fx chain of the cursor track with its routing in place of the tracker / big router over the whole window' },
    { k = 'Ctrl+Cmd+F12', d = 'restart the tracker from its files (as :reload) - after an update, no REAPER restart' },
    { k = 'zf', d = 'DSP: modules with pages (Surge XT) - all pages in one pane (default) / one page with vertical tabs on the right of the module' },
    { k = 'zss zsm zsl', d = 'DSP: size of the drumrs5k pads - small (more rows) / medium 4 x 4 / large 4 x 4 (m > s, spectral wave, labels, group)' },
    { k = 'zC', d = 'fold track into a one-letter strip' },
    { k = 'z> z<', d = 'all tracks one field wider / narrower (as Cmd + horizontal wheel; 3z> - three steps)' },
    { k = '- +', d = 'zoom rows: LPB down / up, 1..128 (as Cmd + wheel) - a row is shorter / longer, the matrix lengths follow (16 / 32 / 64 steps)' },   -- 18 окт: зум мышью тоже вспыхивает здесь
    { k = 'z. z,', d = 'the cursor track wider / narrower (its own width)' },
    { k = ':reg', d = 'view only the region of the cursor / whole track (all | reg above the region name)' },
    { k = 'visor / cmd: dd yy p c', d = 'master columns visor and cmd: dd cut, yy copy, p put on the cursor row (move = dd j p), c / r edit the text (:vis / :mcmd), Enter - visor: pick with previews, x delete; w b e - next / previous marker', t = {} },
    { k = 'env: field 2', d = 'segment shape: INSERT letters sqr slo fas fae bez, ^A ^X cycle, :shape fas' },
    { k = 'env: Ctrl+Opt+1..6', d = 'segment shape of the point on the row, in any field and mode: 1 lin 2 sqr 3 slo 4 fas 5 fae 6 bez' },
    { k = 'i', d = 'INSERT: the keyboard writes notes (layout frow / qwerty / renoise - options)' },
    { k = 'I', d = 'INSERT from the start of the row: the note field of the track (as in Vim)' },
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
    { k = '\\ o o', t = {}, d = 'the options window (all options, also :options)' },
    { k = '\\ k', t = {}, d = 'keyboard modes: m - notes, p - patternkb (the note keys play the patterns), c - clipkb (1qaz 2wsx ... play the matrix cells); the mode word shows it (УЗОРКЛАВЪ / ОТРЫВКЛАВЪ)' },
    { k = '\\\\', d = 'the context menu: what can be done with what is under the cursor (the same as the right click)' },
    { k = '?', d = 'any REAPER action in the tracker style (fuzzy, the recent ones on top)' },
    { k = 'F1', d = 'the help (all modules): j k line by line through all sections, J K section, / search, o - the help in the browser; :tutorial - the tour' },
    { k = '^/ ⌥/ ⌘/', d = 'search: all effects / the DSP chain of the track / files' },
    { k = '\\Ps', d = 'save project (\\PS: save as)' },
    { k = 'f', d = 'hint labels: jump anywhere by two letters; the tracker first - every note, every beat row (darker dots) of each track' },
    { k = 'tt', d = 'new track after the cursor track (3tt - three)' },
    { k = 'Opt+F1 F2', d = 'transpose the selection (else the note of the row) -1 / +1; F11 F12 - an octave (as in Renoise)' },
    { k = 'h (wave)', d = 'wave column (wave mode column): h from the note goes into the wave, l back; there s - cut the note at the row, S - a stretch marker at the row start (one in the row - snapped there), x - remove it, J K - pull the hit a row down / up (3J - three); the mouse drags the amber line too' },
    { k = 'R (VISUAL)', d = 'razor edit: the selection (rows x tracks) becomes a REAPER razor area - REAPER razor actions work on it and it shows in the arrange view' },
    { k = 'rip', d = 'ripple editing (REAPER, the transport button: off / per track / all tracks): x on a note deletes it with its rows - what is below moves up (per track - this track, all - every track)' },
    { k = 'Cmd+F1 F2', d = 'microtone: the selection (else the note of the row) down / up 1/6 tone (72-EDO; marks after the octave: C-4^ C-4^^ C-4^3, v - down); MIDI - MTS sysex before the notes (MTS-ESP Master on the track before Surge XT), audio items - fractional pitch; Shift - the track' },
    { k = 'Shift+F1 F2', d = 'transpose the track in the pattern; Ctrl - the whole pattern, Shift+Ctrl - the column; F11 F12 - by octave' },
    { k = 'zt zb', d = 'the cursor row to the top / to the bottom (as in Vim)' },
    { k = 'Tf To', t = { 'T' }, m = 'take fx: add / open', d = 'T f - add a take fx to the note under the cursor, T o - its take fx chain in DSP' },
    { k = 'tT', m = 'track from template', d = 'a track from a template after the cursor track' },
    { k = 'tF', m = 'into left folder', d = 'the cursor track goes into the folder of the track to the left' },
    { k = 'R', m = 'insert last played', d = 'the last phrase you played on the armed cursor track (REAPER retro MIDI buffer - it records while armed, even stopped) goes in from the cursor row: the first note on the row, the silence before it cut; longer than the pattern - a menu: duplicate the pattern (the rest goes into the copy), the rest into the next pattern, cut, squeeze in' },
    { k = 'tw', m = 'wave column of track', d = 'the wave column of the cursor track: show / hide; again - auto (only with audio or a drumrs5k kit with samples)' },
    { k = 'g12 Enter', t = {}, m = 'go to row number', d = 'go to row 0012 (also 12gg)' },
    { k = 'Opt+W', d = 'the cursor to the master columns (∑); a folded master opens while the cursor is on it (auto / fold in its header), l from the last track - the same' },
    { k = 'zp', d = 'view: only the pattern of the cursor / the whole project (the project | pattern buttons, :reg)' },
    { k = 'zu', d = 'unfold: the folded notes (cyan line under the row, +N) of the selection / cursor row - LPB rises to the smallest one that gives each its row (up to 128); zu again - the previous LPB (:unfold)' },
    { k = 'zw', d = 'wave view: own column / in the note field / item background / off, or wave only / text only' },
    { k = 'zZ', d = 'fixed cursor on / off: the cursor row stays in the middle, the pattern scrolls under it (zz - centre once)' },
    { k = 'gt  gT', d = 'go to a module of the layout (menu by its letter: d dsp, f fx, a automation …) / REAPER project tab; 3gt - the third at once; the next tab of a module - Tab' },
    { k = ':transpose', d = 'transpose popup: -24..+24 and where - selection / column / track / pattern (also the right-click menu); :transpose N - the selection by N' },
    { k = 'td tx tp', d = 'delete (= cut, as d in Vim) / cut N tracks from the cursor track (5td - five), paste them after the cursor track; dd deletes rows (5dd - five)' },
    { k = 'ts', d = 'new track "send": the selected tracks (or the cursor track) send into it - a bus / fx return' },
    { k = 'tr', d = 'new track "source": it sends into the selected tracks (they get a receive)' },
    { k = 'tn tc', d = 'track: rename / colour (list: palette, random, default, custom dialog)' },
    { k = 'ty', d = 'duplicate the cursor track (copy right after it)' },
    { k = 'ta ti', d = 'track: rec arm / input (list); 6ta - six tracks from the cursor, t135a - tracks 1 3 5 (REAPER numbers, 0 = 10)' },
    { k = 'tA', d = 'autoarm on every track (the selected track records); again - off; the autoarm button over the row numbers too' },
    { k = 'tI', d = 'track input: the active source - play it within 0.6 s (a MIDI key -> that device and channel, else the audio input that started sounding last, stereo if its pair sounds too); your jf_smart_set_input.lua' },
    { k = 'tl tf', d = 'track: fixed lanes on / off / add fx (fzf)' },
    { k = 'tR', d = 'track routing: sends S, receives R, hw outs O (popup)' },
    { k = 'tj tk', d = 'move the track right / left (3tj - three places)' },
    { k = 'mouse', d = 'right drag: select a block (a right click without moving: the menu); left drag: move the event or the selected block under the mouse; Shift+drag: extend the block (option select block with = left swaps the buttons)' },
    { k = '2f', d = 'mixer: f on a dB mark glides the fader there in 2 bars (2,f - beats); from the next session quantize when playing, from the cursor when stopped; the mark typed in CAPITALS (Shift) dips: there in the first half, back in the second (no count - 1 bar)' },
    { k = 'Ctrl+mouse', d = 'hold Control and move the mouse: the selected params / faders change (else the one under the mouse, else the keyboard slider); up = more, Shift fine; two selected = XY. Cmd+click: add / remove, Shift+click: a range of params of one effect, Esc: clear' },
    { k = 'Ctrl+Cmd+mouse', d = 'SLIDER: a bank of up to 8 sliders nearest the mouse is framed (fx parameters in a track header, v / p of a track, a DSP device column, mixer faders, an XY pad); horizontal sliders - up / down picks, sideways changes; vertical faders - sideways picks, up / down changes; XY - both; it moves only after a clear move along its axis (Shift fine); let go - one undo' },
    { k = 'Ctrl+Opt+Cmd+mouse', m = 'reform gestures', d = 'REFORM gestures over selected notes (v / V): mouse up / down - shift by rows, two fingers up / down or a pinch - scale, two fingers sideways - curve, Shift fine; let go - kept (u - undo)' },
    { k = 'Ctrl+Opt+mouse', d = 'tracks gesture: the window width is split into one zone per track - move sideways to pick a track, then up / down moves its fader (Shift fine); clearly sideways again picks another; + Cmd: the whole window is a pan pad for that track - sideways pan / balance, up wider, middle 0, down narrower / reversed (dual pan: L and R apart up, crossed down)' },
    { k = 'Cmd+Shift+1..9', d = 'select / unselect channel N in REAPER - f on a dB mark moves all selected faders (macOS keeps Cmd+Shift+3 4 5 for screenshots unless you turn those off)' },
    { k = 'Cmd+F11', d = 'fullscreen <-> docked (quick option title: title bar on / off); F11 alone is a note (frow)' },
    { k = '`', m = 'pedal / note-off', d = 'NORMAL with the keyboard (KEYS): the sustain pedal (CC64) while you hold it; INSERT: note-off (under an ended note - stretches it here); the whole sample: Ctrl+Shift+1 (Ctrl+Shift + a slice key - from that slice)' },
    { k = 'm', d = 'KEYS on / off (the keyboard; the mode word shows KEYS): on - it has priority, 1 f1 2 f2 3 ... play notes (layout qwerty: q 2 w 3 e), [ ] octave (qwerty: z x), Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'zm', d = 'minimize the pane in focus to its tab row (any pane but the tracker; in the matrix - z then m); again, a click on its tab or focusing it - open' },
    { k = 'zx', d = 'crossfade editor of REAPER: the note under the cursor and the notes of the track overlapping it' },
    { k = 'Tab Shift+Tab', d = 'next / previous track (in the tracker); in the wave column - the next / previous hit: a stretch marker or a note start' },
    { k = 'Opt+note', d = 'chord typing on a not sliced sound (on a sliced one Option+note = the selected slice at that pitch, Option+Shift - listen): the note goes to the next subcolumn of the row (a new one if needed), the cursor follows; all chord notes ring while you type, a 1.5 s pause ends the chord (length = typing time) and the cursor goes below it' },
    { k = 'keys button', d = 'keyboard on / off (also m; quick options keys): on - it has priority, 1 f1 2 f2 3 ... play notes, [ ] octave (qwerty: q 2 w 3 e ..., z x octave), Esc / Enter - INSERT (writes them); off - plain Vim' },
    { k = 'Space', d = 'play / stop' },
    { k = 'C-⌘Space', d = 'play at x0.5 (x2 - the button under play); again or Space - stop, x1 comes back' },
    { k = '⌥⌘Space ⇧⌘Space', d = 'listen step on / off (the row the cursor lands on plays on the cursor track) / listen line on / off (the row, all tracks)' },
    { k = 'Shift+Ctrl+F', d = 'sample find for this place - into the sampler (the lib of the track + a note), not an audio item as F' },
    { k = 'Shift+Opt+F', d = 'sample find for this place: pick the database first (it is remembered), then as F' },
    { k = 'F', d = 'sample find for this place: the browser db with find - j k listen, the channel shows the wave of the picked one over its length in rows, Enter puts it here, Esc cancels (follow playhead - its button / option)' },
    { k = 'o', d = 'reveal item in REAPER' },
    { k = 'Opt+BS  C-A-M-J K', d = 'insert an empty row (no Insert key on a Mac): Option+Backspace - at the cursor, Ctrl+Option+Cmd+J - below it, K - above; Shift - all tracks; a count - N rows' },
    { k = 'BS Ins', d = 'delete / insert time in region (Shift: all tracks; option BS mode: pattern - as Renoise, a clip up to the pattern end keeps its length / track - the whole track up to =LIB), in INSERT too: BS on the note field deletes the row, everything below moves up (Del - only the event); no Insert key (Mac) - :instime N, :deltime N' },
    { k = 'fx field', d = 'two halves, as in Renoise (l / h step between them): the left one is the code - one letter is 0x (D = 0D, U = 0U), S_ and Z_ are prefixes (SI, ZT), 0D works too; then the right one - two hex digits write it. On the value half alone the digits keep the code there (or the dim one running from above: 08 under 0D10 = 0D08). h j k l start no code, so they still move; Enter - the list of codes' },
    { k = 'Opt+Tab Opt+S-Tab', d = 'focus the next / previous pane (in the tree order)' },
    { k = 'Cmd-Enter', d = 'focus the instruments (lib)' },
    { k = ':cc', t = {}, d = 'CC lane: ReaControlMIDI on the cursor track (its window opens the first time - set the CC numbers there), pick its parameter - the envelope becomes a column: hex per row, curves, automation items' },
    { k = 'S-Esc', t = {}, d = 'remove the REAPER time selection (any module)' },
    { k = 'Opt-Enter', d = 'select the instrument of the note under the cursor in the lib' },
    { k = '\\\\q \\\\Q', t = {}, d = 'context menu on a sample: q - the nearest peak onto the row grid; Q - pick the peak, j k to a row, Enter moves it there (stretch marker)' },
    { k = 'vol xx', t = {}, d = 'on any row inside a sample (INSERT, vol field): a point of its take volume envelope - ramps by values, as in Renoise; x-fade by vol writes its ramps the same way (options: x-fade by)' },
    { k = '/ in a name', d = 'renaming a track, instrument, item or region: / lists common names (your SWS auto-colour rules + kick, pad, bell, texture ...), type to filter' },
    { k = 'F1', d = 'manual' },
    { k = 'hold Shift / Ctrl / Opt / Cmd', t = {}, m = 'what a modifier does', d = 'hold a modifier (or two) half a second, no key - the help pane lists what Shift / Ctrl / Opt / Cmd + ... do here, then everywhere' },
    { k = 'F2', d = 'back to the tracker from anywhere (closes the routing diagram, big router / chain); the item tab is in the F4 circle' },
    { k = 'F3', d = 'mixer on / off (in its routing strip Option+click on a routing name or a wire removes it)' },
    { k = 'F4', d = 'the top pane: its tabs in a circle (in the lib with lib tabs - the lib tabs)' },
    { k = 'F5 F6', d = 'scopes / master; the same key again - back to the tracker' },
    { k = 'help', d = 'this panel: the help button of the main module; F1 - the whole help' },
    { k = 'Cmd+ Cmd-', d = 'bitmap scale x1 / x1.5 / x2 / x3 (font size with a font)' },
  } },
  insert = { title = 'tracker INSERT (keyboard)', e = {
    { k = '1 f1 2 f2 3 4 f4 ...', d = 'piano (layout frow, default): digits 1..0 - = white keys C..G, F1 F2 F4 F5 F6 F8 F9 F11 black; [ ] octave, { } velocity; F-key shortcuts are off while the keyboard plays; the letters stay Vim - in INSERT too (w x dd p ... act as in NORMAL, then INSERT again), digits are notes, not a count' },
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
    { k = 'qwerty: , .', t = { ',', '.' }, d = 'instrument previous / next' },
    { k = 'qwerty: ;', t = { ';' }, d = 'the whole sample at the cursor' },
    { k = 'qwerty: a', t = { 'a' }, d = 'step auto: jump past the inserted item' },
    { k = 's', d = 'select from here (visual; the edit returns to INSERT); Shift+hjkl extends' },
    { k = '⌥s', d = 'step: type rows (:step N)' },
    { k = 'd', d = 'Vim delete operator (d3w, dd), back to INSERT after' },
    { k = 'qwerty: M S', t = { 'M', 'S' }, d = 'mute / solo the cursor track - on any column, the fx column too (there lowercase s / m start the codes SI ... / 0M)' },
    { k = 'qwerty: f', t = { 'f' }, d = 'next fx field (note > fx1 > fx2 ...)' },
    { k = '` ~ C-~', d = 'note-off: ` this subcolumn, ~ (Shift+`) every track (Shift = all tracks, as Shift+BS), Ctrl+~ the whole track; :off / :off all; on the command field ` stops what runs there (dim) - 0D.. -> 0D00' },
    { k = 'Esc', d = 'back to NORMAL' },
    { k = 'F1', d = 'the whole help (with frow F1 is a note in INSERT - Esc first; ? - REAPER actions)' },
  } },
  matrix = { title = 'matrix of regions (slots)', e = {
    { k = 'h j k l', d = 'cell: track left / slot down / slot up / track right' },
    { k = 'gg G', d = 'first slot / last slot' },
    { k = 'c (clipkb)', m = 'clipkb: keys play cells', t = {}, d = 'clipkb right in the matrix: 1qaz 2wsx 3edc ... - column = track, row = a visible slot; a key - hear that cell, Shift + keys - pick cells of any patterns, let go of Shift - they play together in a loop, Enter - render them as a new pattern, Ctrl + key - silence, arrows up / down - a row, [ ] - 4 rows, left / right - tracks; every letter is a cell now (c too) - Esc - off' },
    { k = 'chain row', t = {}, d = 'the patterns pane (gt / T): the cubes of every pattern (A1 .. grey - not made yet) and the chain row under them; a click on a cube - hear it, a double click - it joins the chain; h j k l Enter Space n C there' },
    { k = 'playlist row', t = {}, d = 'over the arrangement: the section names of the song on top, the playlist (song order) under them; a click on a section above - it goes to the end of the playlist; s - keys there: h l pick, Enter adds (3 Enter - three times), x drops the last one, Space plays, Esc back; a click on a playlist word - play from it, > - play all, x - clear' },
    { k = 'f a1', m = 'hints: jump to pattern', d = 'hints: every pattern cube is labelled by its own code - f then a1, bc ... jumps to that pattern in the tracker' },
    { k = 'C', m = 'chain: type the order', d = 'chain: type the pattern order (A1 A1 B1x2 C1:16 D1-8, Tab completes); a click on the chain text - the same' },
    { k = 's', m = 'song: section row', d = 'song: the section row above the playlist (h l, Enter, 3 Enter, x, Esc)' },
    { k = 'buttons', t = {}, d = 'menu view sync trim patternkb timesel follow + live in the empty corner over the slot numbers (follow - the matrix cursor goes with the tracker cursor, on by default) (left of the track names); folded / clips - a row on top' },
    { k = 'sketch', t = {}, d = 'sketchpad: in clipkb (c) Shift + keys pick cells of any patterns, Enter - they become a sketch X1 X2 ... on the row under the buttons; a click on a sketch - hear it, Shift+click - line several up (they play one after another in a loop), p - put the line into the song after the cursor slot (P - before; each sketch a new pattern of aliases; a part - copies), x - remove; kept in the project' },
    { k = 'Ctrl+Shift+key', m = 'part of a cell', d = 'clipkb: a part of that cell for the sketch - whole, 1/2, 2/2, 1/4 ... 4/4 (it repeats to the sketch length); the part is framed in the cell' },
    { k = 'Ctrl+Space', m = 'hear the sketch', d = 'matrix: the picked sketch(es) play in a loop (= > on the sketch row); e - edit it in clipkb, Enter keeps' },
    { k = 'Ctrl+Cmd (trackpad)', t = {}, d = 'jog / scrub: slide along a slot row - the pattern loops and plays from that place (to the tracker row); another row - another pattern; let go - stop, loop and cursor as before' },
    { k = 'patterns (pane)', t = {}, d = 'its own pane over the matrix: a grid of pattern codes (row - letter, column - variant 1..F; bright - in the song, green - playing) and the chain; h j k l pick, Space hear, Enter - to it in the tracker, n note, a - append to the chain, i - insert before the chain cursor; j from the last row / Tab - the chain row: h l w b move, x dw delete, dd clear, y p P, Enter - to it, Space - play from it, C - type, k / Esc - back' },
    { k = 'c', m = 'clipkb: keys play cells', g = 'view', d = 'clipkb - the keyboard columns 1qaz 2wsx ... are the tracks, the rows the matrix rows: a key - listen to that cell (again - silence), Shift + keys - pick (render - a new pattern of them at the end, +playlist), Ctrl - silence, Esc - off' },
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
    { k = ':patternkb', m = 'patterns on note keys', d = 'MPC style (the patternkb button; = :pads): the note keys play the patterns of the song - 1 f1 2 ... = the 1st 2nd 3rd pattern, the key shows by its name; quant - seamless when the playing one ends (REAPER smooth seek), sudden - at once at the same place inside (a short gap: the render-ahead buffer refills); rec - record the order, again - write it after the song as linked repeats; off' },
    { k = ':pl', m = 'playlist as text', d = 'playlist (the playlist button - a block on top of the matrix): the order as text - A1 A1 B1x2 C1:16 D1-8 D1/2 B2+8 verse 4: pattern / section name or region number; xN repeat, :N the first N rows, /N a part, -N skip N rows, +N then its first N rows again; Tab completes names; play (seamless on whole patterns), write (after the song), new dup name del next prev - named playlists in the project' },
    { k = 'vismetro', m = 'beat count column', d = 'matrix button: the size column always shown, the playing pattern counts its beats there - 1/4 2/4 3/4 4/4' },
    { k = 'autoarm', m = 'auto-arm all tracks', d = 'button under clips (top left corner): auto-arm on every track (the selected track is armed for recording), again - off; lit when all have it' },
    { k = 'h past the first track', m = 'cursor to region name', g = 'move', d = 'the cursor goes to the region name (Enter / i - rename) and to its number < NN > (Enter - next pattern)' },
    { k = 'Ctrl+h j k l', m = 'move like hjkl', g = 'move', d = 'move like h j k l' },
    { k = 'Ctrl+Up Down', m = 'duplicate slot above / below', g = 'slot', d = 'duplicate the slot above / below, muted tracks left empty in the copy (Paketti)' },
    { k = 'M', m = 'mute cell', g = 'block', d = 'mute / unmute cell (Shift+m)' },
    { k = 'Space', m = 'play or queue slot', d = 'play from slot, or queue it while playing' },
    { k = 'F', m = 'sel: only selected tracks', g = 'view', d = 'sel: the tracker shows only the tracks of the selected cells (button sel; Cmd+click a cell adds it, Esc clears)' },
    { k = '+ N+', m = 'new region at end', g = 'slot', d = 'new region at the end (N+: N regions, one undo); n names it' },
    { k = 'v HJKL', m = 'block select', g = 'block', d = 'block select; in block: y copy, d x cut, M mute', t = { 'v', 'H', 'J', 'K', 'L' } },
    { k = '^C ^X ^V ^N', m = 'block copy / cut / paste', g = 'block', d = 'block copy / cut / paste / mute' },
    { k = 'u ⌘⇧Z', m = 'undo / redo', d = 'undo / redo' },
    { k = 'z', m = 'view menu', g = 'view', d = 'view menu (= the view button): i detail, f fill, r ruler, s s/e, b bpm column, z session (clips over the whole window)', t = { 'z' } },
    { k = 'z f', t = { 'z' }, m = 'fill: lit or empty', g = 'view', d = 'fill: cells show their content (lit) or stay an empty grid - only the view' },
    { k = 't', m = 'trim past region', g = 'slot', d = 'trim: cut items that run past their region (the button trim)' },
    { k = 'R', m = 'bar ruler on / off', g = 'view', d = 'ruler of bars on the left on / off (button ruler)' },
    { k = 'Tr', m = 'section from time selection', g = 'section', d = 'the time selection becomes a section: pick a quick name - intro verse pre-chorus chorus hook build drop break breakdown bridge solo outro, or another (:tsec name); a taken name gets a number (verse 2). The timesel button - the same and more (loop it, clear)' },
    { k = 'loop zone', t = {}, d = 'the bar ruler on the left of the slots: double-click - loop this slot (on the section strip - the whole section), drag up / down - several, Cmd+click - pick slots (the loop jumps from one to the next, seamless), Shift+click - extend; the time selection / loop shows as a [ there' },
    { k = 'Cmd+wheel', t = {}, d = 'zoom: slots taller / shorter - the rows of the pattern inside (as in the tracker; option zoom with: split - Option + wheel)' },   -- 18 окт: зум вспыхивает здесь
    { k = 'wheel', t = {}, d = 'mouse over the matrix, no focus needed: wheel - slots, horizontal wheel / Shift - tracks; zoom as in the tracker (option zoom with: cmd - Cmd + multiscroll both ways; split - Cmd horizontal, Option vertical, as in REAPER); scroll bars right and bottom' },
    { k = 'Esc Opt+Tab', m = 'back / next pane', d = 'back to the tracker / next pane' },
  } },
  reform = { title = 'reform - reshape the selected notes and automation live (gr in VISUAL; idea: Reform for Renoise, aqu.surf/reform)', e = {
    { k = 'j k', d = 'row: scale, curve, shift, redistribute, anchor (notes / selection), values on, value from / to, value curve, value mode (remap / even)' },
    { k = 'h l', d = 'value (Shift: fine); on a switch row - switch it' },
    { k = 'Space', d = 'listen: play the selection from its start (again - stop)' },
    { k = '0', d = 'the row back to its default' },
    { k = 'Enter', d = 'keep the result (u - undo)' },
    { k = 'Esc', d = 'revert - everything as it was' },
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
    { k = 'j k', d = 'instrument down / up' },
    { k = 'J K', d = 'move the sample down / up in the lib - the numbers follow (also drag a row with the mouse)' },
    { k = 'L', d = 'layer (¥): another lib instrument sounds together with this one on one note; tracks - its layers in the folder (Space listen, Enter offset / pan / random / cycle / phase); browser a y - files as layers' },
    { k = 'gg G', d = 'first / the bottom row - midi clips (G; Cmd+G from anywhere - automation); g is a prefix in most modules (not the browser, fx list, notes): gt - go to a module, gT - a project tab' },
    { k = 'h l', d = 'as in lf: l - open the instrument folder (its layers ¥ and slices) / into it, h - back / close; inside: j k, Space listen, Enter - a layer: its menu, a slice: insert, x remove, e - the slice in the item tab (Tab - the lib / tracks tab; another track - from the tracker)' },
    { k = 'Shift+click', t = {}, d = 'select several instruments: from the selected one to the clicked one (as v)' },
    { k = 'dd', d = 'cut instrument: its events on the tracks and the library item (to the register)' },
    { k = 'yy', d = 'yank instrument to the register' },
    { k = 'p P', d = 'put a copy from the register into the cursor track library (new name if taken)' },
    { k = 'yp', d = 'duplicate the instrument (copy into the library)', t = { 'yp', 'yP' } },
    { k = 'v', d = 'range from here: j k extend, d / x cut, y yank, Esc' },
    { k = 'Enter', d = 'open in the item tab (slicer)' },
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
    { k = 'c', d = 'clipkb: the keyboard columns launch clips - 1qaz the first track, 2wsx the second ... 0p;/ the tenth, top-down the 4 visible scenes; a clip - launch (playing - stop), an empty slot - record into it; Shift + keys - pick several, let go of Shift - they start together; Ctrl + key - stop the track; Backspace - stop all; Esc - clipkb off' },
    { k = 'A-Tab', d = 'next pane in the tree order (Shift - back)' },
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
    { k = 'drum (player)', t = {}, d = 'the drum button of the player: a selected file goes straight into the active drumrs5k pad - while the song plays you hear it in the groove, stopped - the pad sounds; drum off keeps the last one (one undo). Dropping a file on a pad - its sample too' },
    { k = '/ f', d = 'fzf find: ^start end$ \'exact !not' },
    { k = 't', d = 'mode: files / db / projects' },
    { k = 'p', d = 'auto preview on / off' },
    { k = 'v', d = 'show file in sample tab' },
    { k = 'w q', d = 'panel width / hide' },
    { k = "'1 '2 '3", t = { "'" }, d = "bookmark: go ('1 ... '0); the digits alone are a count: 10j 5k 3G" },
    { k = 'Shift+1..0', d = 'set bookmark 1..10 to this folder', t = { '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' } },
    { k = 'H L', d = 'folder history back / forward (< > buttons)' },
    { k = ':mkdir', t = {}, d = 'new folder here (:mkdir name)' },
    { k = 'Esc Opt+Tab', d = 'clear filter / next pane' },
  } },
  notes = { title = 'notes (left of DSP)', e = {
    { k = 'type', d = 'write; Enter new line, BS Del erase, arrows Home End move' },
    { k = 'project context', d = 'buttons: project notes / notes of the item under the cursor (track with SWS)' },
    { k = 'Esc Opt+Tab', d = 'leave (saved) / next pane; also saved a second after typing' },
  } },
  fxb = { title = 'fx list (left of DSP)', e = {
    { k = '/', d = "find (fzf): words, ^start, end$, 'exact, !not; Enter adds what is found, Esc clears" },
    { k = 'j k h l', m = 'move / tree', d = 'move in the list; h l - the tree of groups on the left (as REAPER: all, favorites, recent, instruments, types, categories, developers) and the list, Enter on the tree - that group', t = { 'j', 'k', 'h', 'l' } },
    { k = 'gt gT', d = 'go to a module / a project tab (as everywhere)' },
    { k = '*', d = 'favourite on / off' },
    { k = 'Up Down ^J ^K', d = 'move', t = { 'Up', 'Down', '^J', '^K' } },
    { k = 'Enter', d = 'add fx to the end of the cursor track chain' },
    { k = 'dblclick', d = 'add fx' },
    { k = 'drag', d = 'onto the DSP panel: insert at the amber line' },
    { k = 'BS', d = 'erase search' },
    { k = 'Esc Opt+Tab', d = 'clear search / next pane' },
  } },
  dsp = { title = 'DSP (track fx)', e = {
    { k = 'h l', d = 'fx left / right' },
    { k = 'zz', d = 'dsp big: the chain with its routing on the whole window - h l signal (l enters a container), j k parallel row, a add after the row, A add in parallel, | join / leave the row, s solo in the row, = branches to unity, b bypass, d (or x) delete, za fold a container, o window, zz / Esc back (:dsp big); mouse: drop an fx from the browser on = - parallel to that device, on + - after it; Shift+click - bypass, Opt+click - delete, dblclick - its window', t = { 'zz', 'z' } },
    { k = 'Enter (pads)', d = 'on a drumrs5k rack - pads mode (a click on a pad too): h l the next / previous note, j k a row (4 notes), x cut the pad, yy take it, yp duplicate onto the next free note, p paste on the cursor note (taken - the next free one), M mute, S solo, Enter listen, r the pad in the router, G group (grp: its pads play together), C choke group (chk: they cut each other), a letter of a sampler parameter (orange: v volume, n pan, i min vol, o root, t pitch, b bend, a attack, d decay, s sustain, e release, f note-off, u loop, w q vel lo / hi, c chance) - to it, h l change, j k next, Esc back to the pads; Esc back to the effects; KEYS (m) plays the pads, the played one flashes green' },
    { k = 'drumrs5k pads', t = {}, d = 'the 4x4 grid (a window of the note map, the cubes on the left scroll it): click - select and hear the pad, Opt+click - mute, Shift+click - solo; the selected pad: g - its group (g1: a hit on any pad of the group plays them all - a layer in the rack), cg - its choke group (c1: a hit cuts the other pads of the group, like open / closed hi-hat); both live in jf_tracker_choke first in the chain and work without the tracker; on the pads - g1 / c1; list (the button by cell) - every pad with every parameter in a table (wheel over a value changes it, click grp / chk / on - menu / bypass), zz in pads mode - the rack on the whole window; r - the pad in the router (layers in parallel: RS5K / synth / fx, containers inside), B bypass, x remove; on each pad: m mute, > listen, s solo; on the right - the sample wave with start / end and the ADSR over it' },
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
    { k = 'af', d = 'add fx (fzf)', t = { 'af' } },
    { k = '/', d = 'find in the chain: fx and params' },
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
    { k = 'S', d = 'aiming at a note: a stretch marker at the aimed point (smk); otherwise the slice menu (s too when no note of this sample is under the cursor): s smart (transients + spectrum: kick, next bright hit, dark again), t transients, 2 4 8 1 3 6 - equal 2 4 8 16 32 64, d delete slices, q quantize, z autotrim' },
    { k = 'Tab S-Tab', d = 'the wave cursor to the next / previous transient, the bit up to the next one plays (transients are found on the first Tab)' },
    { k = '$', d = 'Shift+4: 16 equal slices - the quick slicing (! @ # $ ...) takes $ first in the item tab; the slicer\'s own $ (cut a slice at the wave cursor) is hidden behind it - a key conflict' },
    { k = 'd', d = 'delete a slice: d + its key (1 f1 2 ...; qwerty 2 w 3 e), dd - the slice under the wave cursor (else the selected one)' },
    { k = '+ -', d = 'transient sensitivity up / down (with frow - is a note: only + works)' },
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
    { k = 'snap', d = 'button: stick to transients and slice markers' },
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
    { k = '[ ]', d = 'grid finer / coarser (1 row .. a bar)' },
    { k = 'zp', d = 'the whole project / back to the span (the bar at the cursor, the region, the time selection) - automation and modulation over the song' },
    { k = 'Tab  S-Tab', d = 'the active curve: the lane under the cursor, every envelope of the track, the take envelopes of the samples selected in the lib (v there) and the envelopes of their tracks, note mod slots, LFO / ACS curves; a click on the legend too' },
    { k = 'w b', d = 'next / previous point of the active curve' },
    { k = 'm e', d = 'LFO / audio follower of the active parameter on / off: it appears as its own curve (LFO · name) - the band is its swing around the automation, the thin line the predicted wave; with it active: s t q r R n shape, [ ] speed (x2, tempo sync: cycles per beat), j k strength, w b phase. A green dot while playing - the real value' },
    { k = 'P L', d = 'pages params / curves (the generator) - as everywhere in the automation tab' },
    { k = 'Esc', d = 'drop the anchor, then back to the tracker' },
  } },
  automation = { title = 'automation and modulation: params, curve, mod (LFO / follower / link of REAPER), shape generator, automation items', e = {
    { k = 'Opt+A', d = 'from anywhere: the last touched parameter (move a knob in a plugin or in DSP) becomes an envelope column on its track, the cursor goes there - type values in INSERT; a take FX parameter opens its take envelope here' },
    { k = 'L', d = 'shape: draws a shape (sin tri saw sqr, podkat) as envelope points / an automation item - beside the params when wide, a page [shape] when narrow; L again - back' },
    { k = 'M', d = 'mod: the parameter modulation of the track (REAPER LFO, audio follower, link) - the former modulation tab: a add, x remove, Enter toggle, o w windows' },
    { k = 'C', d = 'curve: the canvas - the curves of the track drawn from the keyboard (its own key page)' },
    { k = 'P', d = 'params: every parameter of the track (track envelopes + all FX params) - ENV ACT ARM PTS MOD value; also rclick on trim in a track header' },
    { k = 'params', d = 'Enter: cell, e: envelope create / show / hide, a: arm, b: active, m: modulate (LFO) - the row on the mod page (M), c: curve into it, o: FX window, w: modulation window, v: used only, M: automation mode, /: find' },
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
    { k = '< > name', t = {}, d = 'the playlists of the project: < > - previous / next, a click on the name - :pl name; new dup del' },
    { k = 'red word', t = {}, d = 'not found (no such pattern / section / number) - skipped, the status line under it says why' },
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
    { k = 'hold Shift Ctrl Opt Cmd', t = {}, d = 'hold a modifier (or two) half a second, no key - the help pane lists what it does here and everywhere' },
  } },
}
-- строка подсказок под модулем (опция hints, 2 окт): самое нужное в одну
-- строку; полное описание — справка ?. { клавиша, что делает }
KH.BARS = {
  tracker = { { 'i', 'insert' }, { 'hjkl', 'move' }, { 'x', 'del' }, { 'dd', 'rows' }, { 'yy p', 'copy' }, { 'v', 'select' },
              { '/', 'find' }, { ':', 'cmd' }, { '\\', 'menu' }, { '\\\\', 'context' }, { 'f', 'jump' }, { 'Space', 'play' }, { '?', 'actions' }, { 'F1', 'help' } },
  insert = { { 'q2w3e', 'notes' }, { 'z x', 'oct' }, { 'c C', 'vel' }, { ', .', 'inst' }, { 'a', 'step auto' },
             { 'd', 'delete' }, { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' }, { 'Esc', 'normal' }, { 'F1', 'help' } },
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
             { 'C-S-hl', 'pattern' }, { 'M', 'mute' }, { 'Space', 'play' }, { 'R', 'ruler' }, { 'F1', 'help' } },
  inst = { { 'j k', 'select' }, { 'J K', 'move' }, { 'dd', 'cut' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'v', 'range' }, { 'Enter', 'item' }, { 's', 'slice' },
           { 'Space', 'listen' }, { '/', 'find' }, { 'F1', 'help' } },
  session = { { 'c', 'clipkb' }, { 'click > x', 'launch / stop' }, { 'o', 'record' }, { 'a', 'follow' }, { 'drop', 'file' }, { 'f', 'labels' }, { 'wheel', 'scenes' } },
  clipmode = { { 'q..p a..l z..m', 'launch' }, { 'Shift', 'scene' }, { '1..0', 'stop' }, { 'Bksp', 'stop all' }, { 'arrows', 'scenes' },
               { '.', 'follow' }, { ',', 'quant' }, { '/', 'rec' }, { 'Space', 'play' }, { ';', 'labels' }, { 'Tab', 'tracker' } },
  tracks = { { 'h l', 'open / close' }, { 'Enter', 'go / pick' }, { 'Space', 'mark / listen' }, { '+ - c', 'zoom / convert' }, { 'T M S R', 'flags' }, { 'dd yy p P', 'cut copy paste' }, { '>> <<', 'in / out' }, { 'J K', 'move' }, { 'o O F', 'new / folder' }, { 'r', 'rename' }, { '/', 'filter' } },   -- 13 окт: как lf
  pm = { { 'Enter', 'open' }, { 'S+Enter', 'inside' }, { 'Space', 'listen' }, { 'T s p', 'tags status pin' }, { 'a', 'add' }, { 'b', 'big' }, { '/', 'find' } },
  browser = { { 'Enter', 'open/add' }, { 'a', 'add to' }, { 'h', 'up' }, { 'Space', 'listen' }, { '/', 'find' }, { "'1..'0", 'marks' },
              { 'H L', 'back/fwd' }, { '*', 'mkdir' }, { 'Cmd+Enter', 'replace' }, { 'F1', 'help' } },
  dsp = { { 'h l', 'fx' }, { 'j k', 'param' }, { '+ -', 'value' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'cc', 'container' },
          { 'aa', 'automate' }, { 'b', 'bypass' }, { 'o', 'window' }, { 't', 'track/take' }, { '/', 'find' }, { 'af', 'add' }, { 'zz', 'big' }, { 'F1', 'help' } },
  -- 9 окт: роутер (zR) и цепочка на всё окно (zz) — подсказки в строке статуса
  router = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a A', 'add' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' }, { 'b', 'bypass' },
             { 'd', 'delete' }, { 'o', 'window' }, { 'drag', 'slider' }, { 'dblclick', 'default' }, { 'zR Esc', 'back' } },
  dspbig = { { 'h l', 'signal' }, { 'j k', 'row' }, { 'a', 'add' }, { 'A', 'parallel' }, { '|', 'join row' }, { 's', 'solo' }, { '=', 'unity' },
             { 'b', 'bypass' }, { 'd', 'delete' }, { 'za', 'fold' }, { 'o', 'window' }, { 'zz Esc', 'back' } },
  notes = { { 'type', 'write' }, { 'Esc', 'leave' }, { 'project', 'notes' }, { 'context', 'item' } },
  fxb = { { 'type', 'search' }, { 'Up Down', 'move' }, { 'Enter', 'add' }, { 'drag', 'insert' }, { 'Esc', 'clear' } },
  nmod = { { 't', 'midi trig' }, { 'a', 'add (last touched)' }, { 'Enter', 'curve' }, { 'r', 'rate' }, { 'l', 'loop' }, { 'd', 'delete' }, { 'Esc', 'tracker' } },
  sprops = { { 'J K', 'row' }, { 'H L', 'value' }, { 'Shift', 'fine' }, { 'R', 'reset' }, { 'v', 'fit all rows' }, { 'Esc', 'tracker' } },
  visor = { { 'p', 'on' }, { 'o', 'page' }, { 'a e', 'add' }, { 'j k', 'row' }, { 'J K', 'param' }, { 'H L', 'value' }, { 'h l', 'level' }, { 'm', 'mod' }, { 'M', 'matrix' }, { '=', 'type' }, { 's', 'scene' }, { 'i', 'presets' }, { 'n N', 'preset' }, { 'zz', 'big' }, { 'F1', 'help' } },
  sample = { { 's', 'cut at aim' }, { 'S', 'smk / slices' }, { '0 t q', 'aim toggles' }, { 'Enter', 'insert sel' }, { 'v', 'view' }, { '< >', 'vol' },
             { 'n', 'normalize' }, { 'jk', 'param' }, { 'hl', 'value' }, { 'F1', 'help' } },
  automation = { { 'Opt+A', 'last touched' }, { 'C', 'canvas' }, { 'M', 'mod' }, { 'L', 'shape' }, { 'P', 'params' }, { 'g p', 'write curve' }, { 'Esc', 'back' } },
  autocanvas = { { 'hl', 'row' }, { '{ }', 'cell' }, { 'jk', 'value' }, { '0-9', 'level' }, { 'v', 'range' }, { 'f r s t q n', 'shape' }, { '[ ]', 'grid' }, { 'Tab', 'curve' }, { 'zp', 'project' }, { 'x', 'remove' }, { 'P L', 'pages' }, { 'Esc', 'back' } },
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
KH.ORDER = { 'intro', 'pane', 'ctrl', 'tracker', 'insert', 'matrix', 'playlist', 'session', 'inst', 'slices', 'tracks', 'clipboard', 'browser', 'pm', 'dsp', 'fxb', 'notes', 'undotree', 'actions', 'sample', 'sprops', 'nmod', 'automation', 'autocanvas', 'modulation', 'midi', 'grid', 'visor', 'retro', 'garden', 'orca', 'master', 'help' }

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
function KH.rows()
  local out = {}
  if KH.query == '' then
    -- 21 окт: без поиска — список страницы один раз (был новый на каждый кадр)
    local P = KH.PAGES[KH.page] or KH.PAGES.tracker
    KH.rows_c = KH.rows_c or {}
    local rc = KH.rows_c[KH.page]
    if rc and rc.n == #P.e then return rc.rows end
    for i, e in ipairs(P.e) do out[#out + 1] = { page = KH.page, i = i, e = e } end
    KH.rows_c[KH.page] = { n = #P.e, rows = out }
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
  local head = bare and '' or ('F1 help: %s'):format(P.title)
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
