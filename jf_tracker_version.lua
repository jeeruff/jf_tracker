-- jf_tracker_version.lua — версия и список изменений (Options → about).
-- Новая версия: добавить запись в начало CHANGES и поднять VERSION.
local V = {}
V.VERSION = '0.5.25'
V.DATE = '2026-10-02'
V.CHANGES = {
  { v = '0.5.25', d = '2026-10-02', items = {
    'live speed: hard pattern bounds (trim) take one pass over each track instead of regions x tracks x items (about 67x fewer REAPER calls per edit)',
    'live speed: pattern autosync only rewrites tracks whose content differs from the source (no delete / recreate of identical items, smaller undo steps)',
    'matrix: + no longer stops for a name prompt; N+ adds N regions in one undo step; adding a region skips the sample census and the autosync',
    'the matrix sequence reads =START / =END from the region cache instead of scanning markers every frame',
    'heartbeat shows the worst frame of the second and the duration of the last edit',
    'envelope colours follow the arrange: volume col_env2, pre-FX col_env1, pan col_env4, width / send col_env7, FX parameters col_env13..16',
    'matrix loops layer (button loops, :loops): cells show item loop periods and take digits+Enter, > < + -; :orca opens the Orca tab',
  } },
  { v = '0.5.24', d = '2026-10-02', items = {
    'theme changes and the Theme Adjuster colour controls are picked up live (palette rebuilt within a second)',
    'oscilloscopes / spectrum removed: the JSFX bridge is no longer added; :scopes only takes old bridges off the tracks; jf_grid finds the tracker by its heartbeat',
  } },
  { v = '0.5.23', d = '2026-10-02', items = {
    'notes: button in the control block opens an editor left of the DSP panel - project notes or the notes of the item under the cursor (track notes with SWS), saved on leave and a second after typing',
    'browser: *.* shows all file types, .* hidden files; Enter on MIDI / video / images inserts them at the cursor, other files open in their app',
  } },
  { v = '0.5.22', d = '2026-10-02', items = {
    'mouse: drag in the body selects a block (NORMAL and INSERT), Option+drag moves events; drag on the step numbers sets the REAPER time selection',
    'instruments: empty slots .. after the instruments - retro p / Enter puts the capture there, drop a retro / sample selection or a browser file onto them; retro selection can be dragged out',
    'envelopes use the original theme colours (as the arrange draws them, not tinted by the Theme Adjuster)',
    'automation items: thick left strip with the vertical name, bigger loop seams; Option on the end edge stretches',
    'loop seams of items and automation items are draggable: loop length, Option = stretch (playrate)',
    'fix: the wave of looped items repeats the source period instead of reading past its end',
    'the instrument finder opens next to the instruments panel',
  } },
  { v = '0.5.21', d = '2026-10-02', items = {
    'fix: matrix + shifted the whole song when =LIB stood before =END (every press moved everything after =LIB); the library now counts only after =END, a misplaced =LIB is moved behind =END when the library is needed',
    'looped items show their loop seams as cuts across the item, like automation items',
  } },
  { v = '0.5.20', d = '2026-10-02', items = {
    'envelope line is continuous and 1 px like REAPER; the segment shape shows under the point value, only when not lin',
    'automation items: colour of their curve, thicker left strip to move them, top / bottom edges = start / length, loop seams drawn as cuts',
    'envelope points: a precise click on a point drags it (rows and value) in any mode, one undo',
  } },
  { v = '0.5.19', d = '2026-10-02', items = {
    'fold (za, zM): the track keeps only the wave and note columns; envelopes stay visible as a thin line with point values; zC = the old one-letter strip',
    'envelope column: segment shape of every point (lin sqr slo fas fae bez); INSERT letters on the shape field, ^A ^X cycle, :shape',
    'region corner: all | reg view switch above the region name (reg = only the rows of the cursor region, :reg); /2 x2 dup in one row',
    'test_layout.lua: the layout is built on a gfx stub at x1 x2 x4 (catches layout crashes before the live restart)',
    'slice zone handles: triangles at the top (under the marker labels) move start / end, a strip at the bottom moves the whole slice',
    'W B jump to the next / previous event in any column (cursor follows); w b stay in their column',
    'envelope points are events: w b e W B move over them, dd d2w dw db yy p delete / yank / paste points with value and shape',
    'envelope column: NORMAL click only moves the cursor (INSERT writes a point), the wheel only scrolls',
    'DSP: ad deletes the automation of a parameter, ai adds an automation item over the item under the cursor; envelope name in the header: menu to delete the curve or clear points',
    'automation items drawn like REAPER (faint fill, frame, top band); clicking automation opens the modulation tab',
    'mouse: drag an event (any mode) to move it across rows and columns, a VISUAL block moves as a whole; item edge: drag = trim, Option = stretch, Cmd = no snap',
    'region / marker names sit at the top of their ruler lanes; folding the matrix keeps the fx list width; popups open next to what is edited, brighter frame',
    'review fixes: zC persists, field clamps after fold, envelope click fields, one point rule for shapes, :reg off, reg view clipping',
  } },
  { v = '0.5.18', d = '2026-10-02', items = {
    'DSP shows take fx of the instrument: take fx row in sample props (click / select), t or the track / take buttons switch back',
    'empty take fx: the click jumps to the fx list, Enter adds to the take; dblclick opens the REAPER take fx window',
    'every DSP block has O (window), B (bypass) and x (delete) buttons',
    'slices in the instrument tree are drawn as branches of their sample (|- `-)',
    'slice zone on the big sample: drag the handles at the bottom to move the slice start / end (all notes of that slice instrument)',
    'sample editor: snap button - selection, slice markers and the slice zone stick to transients and slice markers',
    'import REX / RX2 (REAPER decodes, slice points read from the file) and Renoise / Redux XRNI instruments with their slices: Enter in the browser',
    'review fixes: / and af add to the take in take mode, header shows the real target, range does not carry over, double-click on x deletes one fx',
  } },
  { v = '0.5.17', d = '2026-10-02', items = {
    'hydra \\P project: s save (same as :w), S save as',
  } },
  { v = '0.5.16', d = '2026-10-02', items = {
    'chords: extra notes get narrow note + velocity subcolumns, not full lanes; a lane is only a REAPER fixed lane',
    'hints option (button in the control block, on by default): one line of the main keys under every module',
    'DSP has its own keys: dd delete fx, dc unpack container, yy p P copy, cc pack into container, aa automate, ap pick parameter, af / add, v range; hints in the status bar',
  } },
  { v = '0.5.15', d = '2026-10-02', items = {
    'status bar: pending operator shows what can follow (d: d rows | w event | W whole item | t track ...)',
    'dW deletes the whole item under the cursor, dt clears the cursor track in its region',
    'samples are kept: the last item of a file deleted - the file goes to the track library (=LIB); option',
    'files from the browser are copied into the project media folder (saved projects); option',
    'browser: bookmarks 1-5, folder history < > (H L), * new folder (:mkdir), clickable full path row',
    'DSP: fx list with fzf search on the left; drag an fx onto the chain; amber line shows where a moved / new fx lands',
    'fix: sliders no longer react while a DSP block is dragged; drop works anywhere on the panel',
    'fix: options switched off came back on after a restart (saved 0 was read as on)',
  } },
  { v = '0.5.14', d = '2026-10-02', items = {
    'matrix: Vim editing of slots - o O new bar, dd delete, yy Y yank, p P put, D ^D duplicate as new pattern, x cut cell, n cc cw rename, [ ] +-bar, { } +-step',
    'context help (? or the help button): keys of the focused module at the bottom, pressed keys light up with a burst of dots, fzf search over all pages',
    'Cmd+Z undo / Cmd+Shift+Z redo everywhere in the tracker',
    'region corner: REAPER number before the name, theme region colour; buttons /2 x2 dup under the name',
    'region colour as a thin strip beside the step numbers and in the matrix',
    'time selection: bright grey, step-number background lit, bracket faces right',
    'matrix: =START / =END rows, bar ruler on the left (button ruler, R)',
    'fix: vertical track names in the matrix and ruler labels were invisible (gfx image ids above 1023); spectrogram ids moved too',
    'fix: side panel knobs no longer cover the bottom panel',
  } },
  { v = '0.5.13', d = '2026-10-02', items = {
    'fix: an =LIB marker before =END hid sequence regions from the matrix; library is now only after =LIB and =END, and =LIB is never created before =END',
    'time selection shown in the tracker: faint row tint and a bracket at the ruler edge',
    'cursor region name always visible above the row numbers (colour strip + name or #N)',
    'BPM entry shows [...] while waiting for digits',
  } },
  { v = '0.5.12', d = '2026-10-02', items = {
    'smart quantize (button quantize, Q, :quantize): loud transients to beats, soft to 16ths, length to whole bars / beats - stretch markers, one undo',
    'ruler: region and marker names as vertical text along their rows',
    'BPM: click - tempo list (take from selected item: metadata / file name / length), dblclick - type the number [..._], wheel +-1',
  } },
  { v = '0.5.11', d = '2026-10-02', items = {
    'rename: dblclick on a track name (:tname), click on the instrument name in sample properties (:iname, all its items)',
    'track header: volume on its own full-width row, pan on its own row; column captions row is optional (Options, off by default)',
    'F2 sample, F3 modulation, F4 retro, F5 garden, F6 master',
  } },
  { v = '0.5.10', d = '2026-10-02', items = {
    'Cmd+Enter in the browser replaces the sample of the selected instrument in all its items (length kept, offset 0, take named after the file, old slices removed; one undo step)',
  } },
  { v = '0.5.9', d = '2026-10-02', items = {
    'browser preview playhead also on the big wave of the sample tab',
    'file info panel right of the big wave for browser files: format, length, rate, channels, bits, size, bpm / key metadata, folder',
    'browser preview plays the whole file (the next selection stops it)',
  } },
  { v = '0.5.8', d = '2026-10-02', items = {
    'new pattern: entering a note / paste / drop on a row with no region creates a region for that bar (empty name like a new REAPER region), in the same undo step',
    'regions without a name show as #N in the matrix and Garden',
  } },
  { v = '0.5.7', d = '2026-10-02', items = {
    'fix: instruments were treated as browser files in the sample tab (no slicing keys, file hint, no properties panel)',
    'slicing buttons in the sample tab: 2 4 8 16 32 64, transients, sens- sens+, clear; s = slice at transients',
    'sample title shows name, length and slice count (no "slice:" prefix for a whole sample)',
  } },
  { v = '0.5.6', d = '2026-10-02', items = {
    'ruler left of the row numbers: region names and colours, marker names on their rows (vertical REAPER ruler); click: go to the row',
    'track header: volume and pan on one line (header is 5 rows)',
    'items are translucent and the grid dots stay faintly visible under them',
  } },
  { v = '0.5.5', d = '2026-10-02', items = {
    'browser mini player: peaks of the playing / selected file with the play position, click plays from that point',
    'browser preview volume slider (drag, wheel 1 dB, dblclick 0 dB), remembered between runs',
  } },
  { v = '0.5.4', d = '2026-10-02', items = {
    'browser search right in the list (/, f or find): folder - recursive from the current folder, open db - the db, otherwise the current list',
    'fzf syntax: words (fuzzy, all must match), ^start, end$, \'exact, !not; arrows move, Enter keeps results, Esc clears',
  } },
  { v = '0.5.3', d = '2026-10-02', items = {
    'fzf find: browser (files mode searches the whole browse root) and instruments; find buttons and / when focused; old browser filter moved to f',
    'click on any module moves the keyboard focus to it',
    'sidebar divider buttons: > folds instruments + browser to a strip, < opens, = drags the width',
  } },
  { v = '0.5.2', d = '2026-10-02', items = {
    'matrix is always shown (also with no regions, + adds the first one)',
    'divider buttons: < folds the matrix to a strip, > opens it, = drags its width (dblclick: auto)',
  } },
  { v = '0.5.1', d = '2026-10-02', items = {
    'instruments list is a tree per track: source sample, its slices / cuts indented below (no library group)',
    'sample tab: properties panel right of the wave (volume, pan, transpose, finetune, rate, keep pitch, stretch mode, loop, fades, take fx, normalize)',
    'Tab into the sample tab opens the source sample, the selected slice is shown as a zone',
    'restart helper never launches REAPER itself',
  } },
  { v = '0.5.0', d = '2026-10-02', items = {
    'Garden tab: loop grid region x track, Orca field (A-Z operators) planting notes / slices while playing',
    'loops in regions: > item to region end, N> loop period N steps (section source), < region to item end',
    'INSERT = Ableton layout: piano on the top row + digits, z/x octave, c/C velocity; Shift+note plays, Option+note beside',
    'd in INSERT is a Vim operator (d3w, dd) and returns to INSERT',
    'track header: name row, R I M S A buttons, volume and pan / width / dual pan sliders',
    'matrix shows =START..=END with free bars; items after =END are hidden',
    'Tab cycle tracker > instruments > browser > dsp > matrix > dock; Option-Tab cycles dock tabs',
    'wave column follows stretch markers; spectral peaks + stretch / loop ticks',
    'instruments: groups by track, marks @ $ * sN with status explanations, select / insert play toggles',
    'MIDI input auditions slices in the Sample tab; Options window; version + about',
  } },
  { v = '0.4.0', d = '2026-10-01', items = {
    'sample module: volume, normalize, draggable slice markers, parent sample with played zone',
    'matrix: + / :add, rename, length in steps, region length box above row numbers',
    'note on a busy row cuts the previous item (x-fade off) or crossfades (x-fade on)',
    'pool from all tracks + library after =LIB; browser tabs files / db / pm / proj',
  } },
  { v = '0.3.0', d = '2026-10-01', items = {
    'recording from MIDI and audio input (jf_rec, first transient), retro sampler tab',
    'lock to REAPER cursor, fixed cursor, beatsync =, mouse trim / move of items',
    'modulation matrix tab, DSP panel with containers, analyzer in master tab',
  } },
  { v = '0.2.0', d = '2026-09-30', items = {
    'Vim layer (NORMAL / INSERT / VISUAL / cmd), hints f, hydra \\, macros, search',
    'pattern matrix, aliases by region name, library after =LIB, monome grid module',
  } },
  { v = '0.1.0', d = '2026-09-30', items = {
    'read-only tracker view of the REAPER timeline: lanes, MIDI and audio cells, vertical waves',
  } },
}
-- строки для окна about
function V.lines()
  local out = { ('jf_tracker %s  (%s)'):format(V.VERSION, V.DATE), '' }
  for _, c in ipairs(V.CHANGES) do
    out[#out + 1] = ('%s  %s'):format(c.v, c.d)
    for _, it in ipairs(c.items) do out[#out + 1] = '  - ' .. it end
    out[#out + 1] = ''
  end
  return out
end
return V
