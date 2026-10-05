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
    { k = 'slices', t = {}, d = 'notes (INSERT + m): a sliced sample - the key picks the slice (q 2 w 3 ... = S01 S02 ...); not sliced - the sample at that pitch. Option+note - the selected slice (or the whole item if whole is selected) at that pitch; Cmd+note - the whole item at that pitch; Ctrl+note - held note (length = how long). Select: the slice list, Option+J / K, the last played' },
    { k = '? Tab', t = {}, d = 'this help follows the focused module; Tab here: search all pages, left / right: pages' },
  } },
  tracker = { title = 'tracker NORMAL / VISUAL', e = {
    { k = 'h j k l', d = 'field left / row down / row up / field right' },
    { k = 'H L', d = 'previous / next track' },
    { k = 'w b e', d = 'next / previous event in this column, end of event' },
    { k = 'W B', d = 'next / previous event in any column (cursor jumps there)' },
    { k = 'env: w b e dd y p', d = 'envelope points are events: motions, delete / yank / paste points (value + shape)', t = {} },
    { k = 'gg G', d = 'first row / last row' },
    { k = 'Esc', d = 'toggles INSERT (as the edit mode in Renoise): NORMAL -> INSERT, INSERT -> NORMAL' },
    { k = 'gw  3gw', d = 'swap the event under the cursor with the next / the 3rd below (:sw N)' },
    { k = ':scramble', d = 'slice notes swap their slices randomly (VISUAL, else the track in the region; button in the item tab)' },
    { k = '{ }', d = 'bar back / forward' },
    { k = 'x', d = 'delete event under cursor' },
    { k = 'd', d = 'd + motion deletes events: dw d3j dG d}; dd (NORMAL) deletes the track, in INSERT the event of the row', t = { 'd' } },
    { k = 'dd dt', d = 'delete the track / remove the time selection from the project (later items move)', t = { 'dd', 'dt' } },
    { k = 'dW', d = 'delete the whole item under the cursor' },
    { k = 'C-A-j S-A-j', d = 'repeat the part of the region above the cursor down to the region end: Ctrl+Opt+J (or Down) - this track, Shift+Opt+J - all tracks (Paketti)', t = {} },
    { k = 'dr daw', d = 'clear the track in the cursor region / all items of the track (the lib after =LIB stays)', t = { 'dr', 'daw' } },
    { k = 'yy p P', d = 'copy rows / paste after / before', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'c s M', d = 'replace / split / mute event (M = Shift+m)', t = { 'c', 's', 'M' } },
    { k = '^A ^X', d = 'field value +1 / -1' },
    { k = 'r', d = 'set value of field' },
    { k = 'u ^R .', d = 'undo / redo / repeat last edit' },
    { k = 'q @', d = 'record macro / play macro' },
    { k = 'v V', d = 'visual block / visual lines' },
    { k = 'za zM zR', d = 'fold track: wave + notes, envelopes as a thin line / all / open all' },
    { k = 'zC', d = 'fold track into a one-letter strip' },
    { k = ':reg', d = 'view only the region of the cursor / whole track (all | reg above the region name)' },
    { k = 'env: field 2', d = 'segment shape: INSERT letters lin sqr slo fas fae bez, ^A ^X cycle, :shape fas' },
    { k = 'i', d = 'INSERT: keyboard plays notes (Ableton layout)' },
    { k = 'a', d = 'envelope column' },
    { k = '> < N>', d = 'loop: item to region / region to item / N rows', t = { '>', '<' } },
    { k = '[ ] ( )', d = 'octave down / up, instrument previous / next' },
    { k = '/ n N *', d = 'search, next, previous, word under cursor' },
    { k = ':', d = 'command line (Tab completes)' },
    { k = '\\', d = 'hydra menu of all actions' },
    { k = '\\Ps', d = 'save project (\\PS: save as)' },
    { k = 'f', d = 'hint labels: jump anywhere by two letters' },
    { k = 'Space Enter', d = 'play / stop, move edit cursor here' },
    { k = 'F', d = 'follow playhead on / off' },
    { k = 'o', d = 'reveal item in REAPER' },
    { k = 'BS Ins', d = 'delete / insert time in region (Shift: all tracks)' },
    { k = 'Tab S-Tab', d = 'focus next / previous module; Option-Tab: dock tabs' },
    { k = 'F1 F2-F6', d = 'manual / dock tabs: sample, modulation, retro, garden, master' },
    { k = '?', d = 'this help panel on / off' },
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
    { k = 's', d = 'step: type rows (:step N)' },
    { k = 'd', d = 'Vim delete operator (d3w, dd), back to INSERT after' },
    { k = 'M', d = 'mute event under cursor (Shift+m)' },
    { k = 'f', d = 'next fx field (note > fx1 > fx2 ...)' },
    { k = '`', d = 'note-off' },
    { k = 'Esc', d = 'back to NORMAL' },
    { k = '?', d = 'help panel on / off' },
  } },
  matrix = { title = 'matrix of regions (slots)', e = {
    { k = 'h j k l', d = 'cell: track left / slot down / slot up / track right' },
    { k = 'gg G', d = 'first slot / last slot' },
    { k = 'o O', d = 'new empty 1-bar slot after / before' },
    { k = 'dd', d = 'delete slot: region + its time (goes to register)', t = { 'dd', 'd' } },
    { k = 'yy Y', d = 'yank slot into register', t = { 'yy', 'y', 'Y' } },
    { k = 'p P', d = 'put register after / before (cells: paste at cursor)' },
    { k = 'A', d = 'alias: the slot repeated linked - same pattern, MIDI pooled and items grouped, edits in one change all (button als; also p of a yanked slot whose pattern still exists)' },
    { k = 'C D ^D', d = 'clone: an exact copy with a new name, not linked (button cln) - like Renoise' },
    { k = 'U', d = 'make unique: unlink the repeat under the cursor - new name, own MIDI pool, no group' },
    { k = 'x', d = 'cut cell (or block) to clipboard' },
    { k = 'n cc cw r i', d = 'rename region', t = { 'n', 'cc', 'cw', 'c', 'r', 'i' } },
    { k = '=', d = 'type length: N steps, Ns seconds, Nb bars' },
    { k = '[ ]', d = 'length -1 / +1 bar (later slots move)' },
    { k = '{ }', d = 'length -1 / +1 step' },
    { k = '< >', d = 'switch pattern of slot (previous / next)' },
    { k = 'M Enter', d = 'mute / unmute cell (Shift+m)' },
    { k = 'Space', d = 'play from slot, or queue it while playing' },
    { k = 'F', d = 'fold the matrix: slot numbers, track names and cells only (button fold)' },
    { k = '+ N+', d = 'new region at the end (N+: N regions, one undo); n names it' },
    { k = 'v HJKL', d = 'block select; in block: y copy, d x cut, M mute', t = { 'v', 'H', 'J', 'K', 'L' } },
    { k = '^C ^X ^V ^N', d = 'block copy / cut / paste / mute' },
    { k = 'u ^R', d = 'undo / redo' },
    { k = 'z f t', d = 'zoom detail / fill / trim items to regions' },
    { k = 'R', d = 'ruler of bars on the left on / off (button ruler)' },
    { k = 'Esc Tab', d = 'next module' },
  } },
  inst = { title = 'lib', e = {
    { k = '!', d = 'Shift+1 anywhere: listen to the selected instrument (its length, through the cursor track)' },
    { k = 'j k', d = 'instrument down / up' },
    { k = 'J K', d = 'move the sample down / up in the lib - the numbers follow (also drag a row with the mouse)' },
    { k = 'g G', d = 'first / last' },
    { k = 'h l', d = 'track left / right' },
    { k = 'dd x', d = 'cut instrument: its events on the tracks and the library item (to the register)' },
    { k = 'yy', d = 'yank instrument to the register' },
    { k = 'p P', d = 'put a copy from the register into the cursor track library (new name if taken)' },
    { k = 'yp', d = 'duplicate the instrument (copy into the library)', t = { 'yp', 'yP' } },
    { k = 'v', d = 'range from here: j k extend, d / x cut, y yank, Esc' },
    { k = 'Enter s', d = 'open in sample tab (slicer)' },
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
  browser = { title = 'browser', e = {
    { k = 'j k g G', d = 'move / first / last' },
    { k = 'l Enter', d = 'open folder / insert file' },
    { k = 'h - BS', d = 'folder up' },
    { k = 'Cmd+Enter', d = 'replace sample of the selected instrument everywhere' },
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
    { k = 'j k g G', d = 'parameter down / up / first / last' },
    { k = '+ - ^A ^X', d = 'value up / down (Shift: coarse)', t = { '+', '-', '=', '^A', '^X' } },
    { k = 'dd x', d = 'delete fx (v: range)', t = { 'dd', 'd', 'x' } },
    { k = 'dc', d = 'unpack container: children into the chain' },
    { k = 'yy p P', d = 'copy fx, paste after / before (any track)', t = { 'yy', 'y', 'p', 'P' } },
    { k = 'cc', d = 'pack fx (v: range) into a new container', t = { 'cc', 'c' } },
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
  sample = { title = 'item tab (slicer + properties of the item)', e = {
    { k = 'Enter', d = 'apply slicing / insert selection at cursor' },
    { k = 'a', d = 'select all' },
    { k = 'v', d = 'view: peaks / spectral' },
    { k = 'q 2 w 3 e …', d = 'play slice 1 2 3 4 5 … (the note keyboard, as over the wave)' },
    { k = 's', d = 'slice menu: t transients, 2 4 8 1 3 6 - equal 2 4 8 16 32 64, d delete slices, q quantize, z autotrim' },
    { k = 'd', d = 'detect transients (with selection: to lib)' },
    { k = '+ -', d = 'transient sensitivity' },
    { k = 'x', d = 'clear slices' },
    { k = 'Q', d = 'smart quantize: strong hits to strong beats' },
    { k = 'z', d = 'autotrim: cut the silence at the start and the end (button autotrim)' },
    { k = '< >', d = 'volume -1 / +1 dB' },
    { k = 'n', d = 'normalize' },
    { k = '[ ]', d = 'widen selection left / right' },
    { k = 'D', d = 'selection to lib' },
    { k = 'Space', d = 'preview selection' },
    { k = 'J K', d = 'properties: row down / up' },
    { k = 'H L', d = 'properties: value down / up' },
    { k = 'R', d = 'properties: reset value' },
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
    { k = 'pads', d = 'learned note = slice 1, next notes = next slices (preview)' },
    { k = 'buttons', d = 'equal 2..32, transients, detect, clear, snap, quantize, preview, insert, to library, play' },
    { k = 'Esc', d = 'back to tracker' },
  } },
  modulation = { title = 'modulation matrix + LFO generator', e = {
    { k = 'L', d = 'curves (generator) / matrix - side by side when wide, pages [matrix] [curves] when narrow' },
    { k = 'P', d = 'params: every parameter of the track (track envelopes + all FX params) - ENV ACT ARM PTS MOD value; also rclick on trim in a track header' },
    { k = 'params', d = 'Enter: cell, e: envelope create / show / hide, a: arm, b: active, m: modulate (LFO) / to the matrix, c: curve into it, o: FX window, w: modulation window, v: used only, M: automation mode, /: find' },
    { k = 'LFO j k h l', d = 'field / value: shape (sin tri saw+ saw- sqr rnd), period in rows, depth, center, phase, points per period' },
    { k = 'type', d = 'lfo | podkat (Anticipate: lead curve before every hit of a source track - its events or audio transients, hold, release, duck / swell) | follow (curve from another envelope or the audio level of a track: attack, release, shift = lookahead, invert)' },
    { k = 'LFO g p', d = 'g: new automation item with the curve, p: write points into the envelope - envelope at the tracker cursor (or selected in REAPER); time selection, else cursor region, else one bar' },
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
    { k = '?', d = 'help off' },
  } },
}
-- строка подсказок под модулем (опция hints, 2 окт): самое нужное в одну
-- строку; полное описание — справка ?. { клавиша, что делает }
KH.BARS = {
  tracker = { { 'i', 'insert' }, { 'hjkl', 'move' }, { 'x', 'del' }, { 'dd', 'track' }, { 'yy p', 'copy' }, { 'v', 'select' },
              { '/', 'find' }, { ':', 'cmd' }, { '\\', 'menu' }, { 'f', 'jump' }, { 'Space', 'play' }, { '?', 'help' } },
  insert = { { 'q2w3e', 'notes' }, { 'z x', 'oct' }, { 'c C', 'vel' }, { ', .', 'inst' }, { 'a', 'step auto' },
             { 'd', 'delete' }, { 'Opt+note', 'beside' }, { 'Shift+note', 'listen' }, { 'Esc', 'normal' }, { '?', 'help' } },
  matrix = { { 'o O', 'new' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'D', 'dup' }, { 'n', 'name' }, { '[ ]', 'bar' },
             { '< >', 'pattern' }, { 'M', 'mute' }, { 'Space', 'play' }, { 'R', 'ruler' }, { '?', 'help' } },
  inst = { { 'j k', 'select' }, { 'J K', 'move' }, { 'dd', 'cut' }, { 'yy p', 'copy' }, { 'yp', 'dup' }, { 'v', 'range' }, { 'Enter', 'slicer' },
           { 'Space', 'listen' }, { '/', 'find' }, { '?', 'help' } },
  browser = { { 'Enter', 'open/add' }, { 'h', 'up' }, { 'Space', 'listen' }, { '/', 'find' }, { '1-5', 'marks' },
              { 'H L', 'back/fwd' }, { '*', 'mkdir' }, { 'Cmd+Enter', 'replace' }, { '?', 'help' } },
  dsp = { { 'h l', 'fx' }, { 'j k', 'param' }, { '+ -', 'value' }, { 'dd', 'delete' }, { 'yy p', 'copy' }, { 'cc', 'container' },
          { 'aa', 'automate' }, { 'b', 'bypass' }, { 'o', 'window' }, { 't', 'track/take' }, { '/', 'add' }, { '?', 'help' } },
  notes = { { 'type', 'write' }, { 'Esc', 'leave' }, { 'project', 'notes' }, { 'context', 'item' } },
  fxb = { { 'type', 'search' }, { 'Up Down', 'move' }, { 'Enter', 'add' }, { 'drag', 'insert' }, { 'Esc', 'clear' } },
  sample = { { 'Enter', 'apply' }, { '2 4 8 1 3 6', 'slices' }, { 's', 'transients' }, { 'Q', 'quantize' }, { '< >', 'vol' },
             { 'n', 'normalize' }, { 'JK HL', 'props' }, { '?', 'help' } },
  modulation = { { 'L', 'curves' }, { 'P', 'params' }, { 'hjkl', 'cell' }, { 'Enter', 'toggle' }, { '+ -', 'value' }, { 'a', 'add' }, { 'x', 'remove' }, { 'o w', 'windows' } },
  retro = { { 'Space', 'listen' }, { 'L', 'loop' }, { 'p', 'put' }, { 'd', 'lib' }, { 'j k', 'channel' }, { '[ ] { }', 'edges' }, { 'h l', 'move' } },
  garden = { { 'N Enter', 'loop' }, { '> <', 'fit' }, { '+ -', 'period' }, { 'm', 'mute' }, { 'o', 'Orca' }, { 'O', 'on/off' },
             { 'p', 'pin' }, { 'x', 'clear' } },
  orca = { { 'arrows', 'move' }, { 'A-Z', 'operator' }, { '!', 'bang' }, { '.', 'erase' }, { 'Space', 'play' }, { 'Esc', 'back' } },
  grid = { { 'take', 'grid to tracker' }, { 'grid', 'back to mixer' }, { 'Esc', 'back' } },
  midi = { { 'j k', 'target' }, { 'Enter', 'learn' }, { 'd', 'clear' }, { 'm', 'abs/rel' }, { 'Esc', 'back' } },
  master = { { 'm', 'scope mode' }, { 'Esc', 'back' } },
  ctrl = { { 'hjkl', 'cell' }, { '+ -', 'value' }, { 'Enter', 'press' }, { 'Esc', 'back' } },
  help = { { 'type', 'search' }, { 'Left Right', 'page' }, { 'Esc', 'back' } },
}
KH.ORDER = { 'intro', 'ctrl', 'tracker', 'insert', 'matrix', 'inst', 'browser', 'dsp', 'fxb', 'notes', 'sample', 'modulation', 'midi', 'grid', 'retro', 'orca', 'master', 'help' }

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
  local head = ('? help: %s'):format(P.title)
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
