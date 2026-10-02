-- jf_tracker_version.lua — версия и список изменений (Options → about).
-- Новая версия: добавить запись в начало CHANGES и поднять VERSION.
local V = {}
V.VERSION = '0.5.9'
V.DATE = '2026-10-02'
V.CHANGES = {
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
