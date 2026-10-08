-- jf_tracker_version.lua — версия и список изменений (Options → about).
-- Новая версия: добавить запись в начало CHANGES и поднять VERSION.
local V = {}
V.VERSION = '0.8.0'
V.DATE = '2026-10-06'
V.CHANGES = {
  { v = '0.8.0', d = '2026-10-06', items = {
    'dev notes (debug on): a third tab of the notes editor - CHECK.md of the tracker folder, the list of what to check; it reloads when the file changes outside; also P n d',
    'DSP: dragging a parameter no longer lags (no model rebuild per frame, only on release)',
    'DSP: f on a parameter (or a click) - h l change its value (H L coarse), j k next parameter, Esc - back to moving between effects',
    'harmonizer tab (next to midi): key (< > tonic, major / minor, auto from the track notes), the seven degree chords and their sevenths - click / 1..7 (Shift - seventh) writes one at the cursor row; the chord at the cursor and the chords of the track in the pattern; chord lane button (:chord)',
    'chords: :chord - the cursor track as one chord lane (names from its notes: A#m, G#6, Cmaj7/E; ¦ while they sound, OFF); :chord Cm7 - a harmonizer: the chord written at the cursor row (replaces the notes starting there; length as theirs, else up to the next notes, at most a bar)',
    'matrix: the playing pattern shows a moving playhead (progress line + tick) in one-row view too',
    'narrow track v / p button: opening it (click or f) takes the keyboard - h l change, Esc closes',
    'effects row: track separators like in the body',
    'param button next to effects in the header corner (one place; p when narrow)',
    'project tabs: a thin row of the open REAPER projects on top of the main module (click - switch, * - unsaved; option project tabs)',
    'pm: open a project in this tab (t) besides a new tab (o)',
    'mixer above or under the tracker: ^ v at the quick option mixer; a click on a fader takes the keyboard (k j volume, h l pan), the strip gets an amber frame',
    'slices list under the instruments (slices = split) always shown, an empty slot says so',
    'input list: with no audio inputs on the device (0 now) the audio inputs 1..8 are still listed, plus audio device settings',
    'fader glide: a count before f - 2f + a dB mark moves the fader there in 2 bars (2,f - beats) as volume envelope points (created if missing; linear, holds after); playing - starts at the next session quantize, stopped - at the cursor row',
    'Option+1..9 selects / unselects track N in REAPER (cyan frame on the name); f on a dB mark (jump or glide) moves all selected tracks',
    'F11 fullscreen (again - docked); quick option title - the title bar of the floating window on / off (off: no frame, js_ReaScriptAPI); with REAPER in its own fullscreen the window stays under its black menu-bar cover',
    'mixer fader: the same size on every track, pan above it; a dark box with dB marks (+6 0 -6 -12 -24 -48, labels never overlap), the track peak meter L R inside, a [-] handle; peak hold __ (1.5 s); the max peak in digits on top and clip (red ==) are the native REAPER peak hold - the same as in its mixer, click the number to reset both; console taper (top stretched); keyboard: f on the fader - k j volume, h l pan (Shift fine), 0 reset; f on a dB mark - the fader jumps to it',
    'library = the muted track LIB: every instrument on its own fixed lane from 0 (no overlaps, the project does not grow, master render stays clean), lane named after it, owner track in P_EXT:jf_home; the =LIB marker is gone; library patterns are the regions after =END',
    'mixer (quick option): the track headers unfold - a vertical fader (16 rows), pan / width above it, the fx with their TCP parameters beside it when short names fit (else under it); tight fx names shortened to consonants (ReaVerbate - RVrbt); the effects row is part of it; param button in the corner',
    'ø (phase invert) button in every track header, next to R I M S',
    'item tab: a clip is shown only when selected (click / clip-mode cursor) and while the focus is on the clips or the item tab; leaving restores the instrument; hovering does not switch it; clip zone lines only on the wave of the clip file',
    'measure: s - PNG of the measured box (or the window) next to the system screenshots, named like them + _jftracker (path + report in the debug log); own PNG encoder, no external programs',
    'right click on an fx or a parameter (effects row, param sliders, router, DSP): the fx / parameter menu - LFO, ACS, link, modulation window, automation envelope, show in the track header (TCP), default; bypass, window, show in DSP, rename, remove',
    'parameter default: the native param.X.default_value first (REAPER 7), a temporary instance only as a fallback; TCP parameters read with CountTCPFXParms / GetTCPFXParm',
    'lib zone: samples and library patterns share one tail - a pattern sent to the lib goes after all samples, a new sample after all lib patterns (a region lay over the samples)',
    'smart slice (s s in the item tab): transients + the brightness of each hit - a slice only on a contrasting hit (kick, then the next bright one - hat / snare / perc, then dark again), repeats merge',
    'slice preview plays to the end: stops by the position of the preview itself, not by a timer from the key press; with slice playthru on it plays to the end of the sample',
    'slices list: own Sxx column (key | Sxx | name | length)',
    'keyboard in the transport strip only with hints on, always minimal (a key per letter)',
    'param (a button on the effects row, next to fx): the parameters shown in the REAPER track controls (TCP) under their fx in the effects row - thin horizontal sliders (drag, wheel, dblclick: default); a click on the fx name opens its window',
    'router in the DSP panel: a scrolled graph stays inside the module (drawn into its own buffer), nodes outside it do not catch the mouse or f labels',
    'top panel above DSP is as wide as the tracker; with the browser on the right the matrix runs down to the fx list',
    'matrix without an =END marker is long: 512 free bars from =START',
    'effects row: wide track - fx in a line; when they do not all fit - stacked, one per line (the row grows to the longest stack, up to 6)',
    'the automation tab selects the automation row of the lib: the slices module lists the automation items of the track; leaving the tab goes back to the slices',
    'browser on the left: the matrix / browser split is dragged with the mouse (dblclick: auto); the matrix hint bar sits above the split, not on the browser',
    'narrow window: clips stay inside their module, the cells at the edge are cut like tracker columns',
    'scene buttons show the region number',
    'f jump labels are drawn above every module: clips and scene buttons show their labels; labels on the item parameters (volume, pan, transpose ...) jump to the parameter',
    'the rec / item / automation panel sits above DSP by default (options: top panel position); with the browser on the left it starts right of it',
    'slices list is always shown for the selected instrument (at least the whole sample); browser Opt+Enter appends the file to the selected instrument as a new slice (glued into one sample), Enter - a new instrument as before',
    'clips per lane: a track with fixed lanes gets a clip column per lane, two clips play on one track at once (the lane is set to play together with the others); a row above each clip for the jump labels and the clip-mode letter, > / o left of a 2-row wave',
    'popups without an anchor (a hydra from the item tab) open at the focused module, not in the corner of the window',
    'whichkey (quick option, on): after a prefix (d y c g z r q @, z in DSP) a popup at the cursor lists the next keys',
    'browser left (option): lib + browser in the left column above the matrix, no sidebar on the right; the fx list becomes the fx tab of the browser',
    'session: a clips module under the track headers (30 rows by default, drag its bottom edge), the tracker stays under it; a clip is 3 rows with > (launch) in its corner, the first empty slot under the last clip of a track has a red o (record into it) (Tab): CLIP MODE - the keyboard launches clips, a letter in every cell; option header info - the track header lists its instruments, inserts and sends (click, dblclick window, f jump labels)',
    'router lives in the DSP FX panel (names and cables, zr / router button / quick option); zR - big router under the track headers with the automation tab on top; Option+Tab cycles the focus, Ctrl+Tab the top tabs',
    'fixes: inserting slices in INSERT jumped to another instrument; ReaEQ presets with any band count',
    'big router (zR): the fx chain with its routing over the whole window, every fx is a device with its parameter sliders (drag, wheel, dblclick - default); ReaEQ bands come from the plugin itself - any number and type (an 11-band preset shows all 11, cuts and notches on the curve)',
    'session in the tracker body at the tracker scale: the same rows with dots and column widths, a clip is a 3-row block (wave, name), track meters rise from the bottom; follow actions per clip - the letter right of the name (L loop, N next, P previous, F first, R random, S stop): click or a / A',
    'matrix: folded by default, the fold button is called zoom (old zoom - detail); no clips view in the matrix and no clips tab on top - zs in the tracker; zr - router, zR - big router (zM toggles fold all / unfold all)',
    'DSP: double click on a parameter resets it to the plugin default (read once per plugin type from a fresh hidden instance, one undo step)',
    'DSP: router button next to take fx opens dsp big; ReaEQ shows only its curve with draggable band points (x frequency, y gain, wheel width), P in its header switches to the parameters only (option reaeq graph only)',
    'dsp big (zz in DSP, :dsp big): the fx chain with its routing in place of the tracker (headers + rows; the matrix, top, DSP and browser stay); option router see-through - half transparent over the tracks - parallel rows with split / sum buses, containers as frames with their plugins inside; h l j k walk the signal, a / A add after / in parallel, | joins or leaves a row, s solo in a row, = branches to unity, b x za o',
    'swing is the REAPER project grid swing: a swing button on the transport opens its menu (on / off, amounts with triplet 33 %, grid 1/4..1/32, custom), wheel +-1 %, :swing; new notes, slices, envelope points, the automation item editor and the quantizer follow it; every item has swing on by default (item tab row, item menu)',
    'envelope lanes: - in a lane header hides it, + (and a+ on a track without lanes) adds one from the parameter picker; overlapping automation items get their own narrow handles; automation item points shown on the lanes (option); VISUAL selects the REAPER items and envelope points like the right-drag marquee',
    'envelope lanes in INSERT: h j k l move, + / - one value step, x y p, dw / dd delete; segment shape by Ctrl+Opt+1..6 anywhere on the lane; values as midi 0..127 (default) or hex (option values) for envelope points and CC / PC lanes',
    'automation item editor: Opt+click / drag erases, Cmd+drag draws free hand, REAPER cursors show the mode, pools stacked as lanes; grid to 1/128; tabs item / params / matrix',
    'w / b move over the events of the whole track - every column and the envelope points, like words in Vim',
    'fx commands stay on the note row in their fx columns (more columns with -+); on an occupied column digits change the value, another command after deleting it',
    'slices are anchored to the waveform: changing the rate no longer shifts them (old slicings recover their rate); slice labels never overlap',
    'performance view (REAPER API only, no external processes) and :jftop - the tracker frame part by part; option debug writes keys, clicks and errors to jf_tracker_debug.log',
    'quick options are configurable: right click an option name in Options adds / removes it (a faint dot marks it); option sync track header size; quick option columns sized by their words',
    'security: no shell or helper scripts, the browser opens only documents with the default app, XRNI unzip takes only the instrument and samples',
    ':logo, about: youtube and e-mail; keycaster shows Cmd+letter as cmd; text transport buttons centred; many smaller fixes',
    'F1 is the whole help inside the tracker (sections on the left, / finds anything, n N hits), Shift+F1 the tutorial; ? picks any REAPER action (recent first); \\ is the main menu, \\\\ the context menu of what is under the cursor; arrows work as h j k l everywhere, with Shift too',
    'transpose and rate of an item or slice are heard while dragging; slice playthru - a slice plays on into the next slices until the next note (item tab row pthru)',
    'session - clips like Ableton on the REAPER timeline: the matrix as scenes x tracks (button clips, or the clips tab after item, or zz - over the whole window); Enter launches a clip at the quantize boundary (bar / beat / now) into the =SESSION loop zone behind =END, O / F launch a scene, f labels, x / X stop, Q off; drop a file from the browser, the Media Explorer or the Finder onto a cell - it becomes the clip (audio with beatsync by default); :session',
    'polymeter: clips of different lengths (a 4/4 slot next to a 5/4 one) keep their own cycle - the session zone grows to their common length, and while clips play the tracker rows show the zone with an L line where each clip starts its cycle',
    'clips in the tracker body (zs, quick option clips) with live track headers; R records audio or MIDI right into the clip slot; dd deletes a clip; the clip under the mouse fills the item tab with draggable start / end and loop marks L, loop crossfade xf (off by default)',
    'notes sound on top of the instrument transpose: C-4 is the instrument as it sounds in the lib (q, slices, inserted notes, previews agreed)',
    'DSP: every plugin inside a container frame has its own B / x',
    'DSP: a container is a frame with a column per plugin inside (collapses to a list when narrow); drop an fx from the list or a block onto it (left half serial, right half parallel); right click: unpack, add inside, presets, serial / parallel, rename (:fxname), move a plugin out; option dsp track block (off by default); blocks squeeze to fit the panel, a long chain scrolls to the selected block with <N / N> for the hidden ones',
    'four new logos: tall cyan, thin box, glitch tiles and a marquee; :logo name shows any of them',
    'experimental (dev): pm cards - the browser pm tab as a grid of jf_pm project cards with thumbnails, big view over the whole window',
  } },
  { v = '0.7.0', d = '2026-10-05', items = {
    'first public release - GNU GPL v3; English help (F1)',
    'the transport moved into the strip under the tracker (always there, the keyboard on its left by m); the main module is windows and quick options, laid out by screen position; option big BPM',
    'time signature: sig column in the matrix, :sig N/D for the whole project or one pattern - a longer bar can get its new beats empty or with the last beat repeated',
    'loop seams like in REAPER, the wave follows a dragged seam; option stretch markers; about: the story, links to itch.io, github, bandcamp and ko-fi',
    'the keyboard is INSERT: no separate keys mode - in INSERT the top row writes notes, NORMAL is Vim; m shows / hides the keyboard strip (shown by default), with the INSERT rows described next to it (hints option) and optionally the status line inside it (status bar: keyboard)',
    'f jump labels work again and never overlap; the tour starts with why jf, hjkl and f, and moves the focus to each step itself',
    'mouse: a plain click keeps the keyboard focus, Option+click moves it (option focus by mouse); lib: double click drops the sample onto the track at the cursor',
    'item tab: drag the selection onto a track or the lib - the whole sample goes into the lib with the selection as a slice (on a track the slice is written into the row)',
    'browser: play (auto-preview, on by default) and keys (the note keys play the selected file at their pitch) on the player line',
    'item boxes are drawn under the wave and the text; the focus frame is closed on all sides; Airwindows descriptions in the status bar',
  } },
  { v = '0.6.37', d = '2026-10-05', items = {
    'context menus in the tracker style: a hydra at the mouse with mnemonic letters, clickable; \\ opens the same menu for the selected thing in DSP, the matrix, the lib and the fx list',
    'the instrument number is a cursor field (l from the note, hex in INSERT, ^A / ^X); a click on a slice line selects the slice; the zone strip slips the selected slice; DSP: open the fx window after adding (toggle), option dsp meters; thin meters',
  } },
  { v = '0.6.36', d = '2026-10-05', items = {
    'spectrogram: the item tab view sgram - a real time x frequency heat map (Hann 1024, native FFT, log frequency, -90..0 dB), computed a little each frame into a picture; works with the wave zoom',
    'ReaVerb in DSP: the spectrogram of the impulse file; Amigo module; the user module learn assigns XY pad axes (X / Y)',
  } },
  { v = '0.6.35', d = '2026-10-04', items = {
    'DSP blocks for the REAPER fx: ReaEQ curve, ReaComp transfer curve, ReaXcomp bands, ReaDelay repeats, ReaVerbate room, ReaGate / ReaLimit level scale, ReaPitch shift - a picture in the first column, the parameters next to it',
    'Airwindows plugins: the category (coloured) and a one-line description from the Airwindopedia under the name - every block tells what it is at a glance',
  } },
  { v = '0.6.34', d = '2026-10-04', items = {
    'arp from slices: :arp live on a sliced sample - hold several slice keys, they take turns at the step (up / down / updown / random / played), each a step long',
    'step listen: the row under the moving cursor plays while the transport is stopped (quick toggle listen); option slices - its own module or the lower half of the lib',
  } },
  { v = '0.6.33', d = '2026-10-04', items = {
    'slices module: a full-height column between the tracker and the lib while the instrument is sliced - the slice list with a scrollbar, in the Tab cycle before the lib, j k / J K / g G, click selects',
    'item tab: the sample settings left of the wave (option sample settings: left / right); Esc toggles INSERT; text only greys the options it overrides',
  } },
  { v = '0.6.32', d = '2026-10-04', items = {
    'notes and slices: a key = the slice of a sliced sample (else the sample at that pitch); Option+key - the selected slice (or the whole item) at that pitch; Cmd+key - the whole item at that pitch; Ctrl+key - held note; r + note follows the same rules; the selection is the slice list / Option+J K / the last played',
    'keyboard note input only with m (INSERT + m); without m only MIDI writes (; too)',
  } },
  { v = '0.6.31', d = '2026-10-04', items = {
    'slices are Sxx again: the note shows the pitch (C-4, D-4 with Option + key), the Sxx command - which slice; keys q 2 w 3 ... still pick slices, Option + key - the pitch of the last slice; r + note sets the pitch',
    'item tab: the slices of the instrument as a list on the right next to the lib (whole, key + Sxx + length), the properties moved left and edit the selected slice; Option+J / K step through the slices (and play them), click selects',
  } },
  { v = '0.6.30', d = '2026-10-04', items = {
    'DSP presets: < name > in the fx block header - < > previous / next, click - a list of factory and own presets (REAPER presets files), loaded by name',
    'stepped parameters by choice: the plugin value names in a row (sine tri saw ...), the current one lit, click picks it',
    'slice notes are lowercase (c-4 c#4), the whole item uppercase (C-4); keycaster; module lines are dragged directly (no < > = knobs); helper fx open no windows',
  } },
  { v = '0.6.29', d = '2026-10-04', items = {
    'm is the keyboard (Vim + Ableton), in NORMAL and INSERT: NORMAL + m - the top row plays; INSERT + m - writes notes; INSERT without m - only controls (hjkl, d, z x ...), note keys do nothing; NORMAL + m: Enter goes to INSERT (i is a note there); the mode shows -- KEYS -- / -- INSERT KEYS --',
    'preview on an armed track with input monitoring off goes to the master (it was silent); key log in ExtState keylog',
  } },
  { v = '0.6.28', d = '2026-10-04', items = {
    'item tab keys: q 2 w 3 e r 5 t ... play slices like the labels over the wave (the old q..p and the slicing digits fought); slicing is the s menu: s t - transients, s 2 4 8 1 3 6 - equal 2 4 8 16 32 64, s d delete slices, s q quantize, s z autotrim',
    'no ghost notes: a note key that comes again without being released (macOS key repeat) is dropped in INSERT, the piano layer and the item tab',
    'the slice labels over the wave follow the chromatic keyboard; the DSP track block is compact (no name row, out and sends in one row)',
  } },
  { v = '0.6.27', d = '2026-10-04', items = {
    'main module without empty space: the transport right under the window buttons, below it 15 quick on / off toggles (dsp, browser, matrix, envs, scopes, hints, wave, meters, ruler, names, colours, input, preview, =END stop, captions); notes and screensets are popups at their buttons',
  } },
  { v = '0.6.26', d = '2026-10-04', items = {
    'letters the bitmap lacks (cyrillic, Δ, ø) - BigBlueTermPlus, bigger; spaces between such words no longer vanish',
    'main module: help / about / options / notes / tutorial / screensets are framed buttons - the open window has an orange background, the rest grey text; no ? before help',
    'notes: - + in the header set the text size of the notes',
    'screensets menu: p pt-mode, b big sample editor, m macro view; z x c - user1..3 (empty slot saves the current view)',
    'auto modules: Macro N first, more parameters, no empty column; DSP rec: wave across the block',
  } },
  { v = '0.6.25', d = '2026-10-04', items = {
    'DSP module rec for jf_rec: the ring buffer of the track right in its fx block - wave (old left, head right), drag selects, all / play / stop / put / lib, status (length, rec / paused, selection); the same selection and actions as the rec tab',
    'the depot button of the rec tab works again (it sent lib, the handler waited for depot)',
  } },
  { v = '0.6.24', d = '2026-10-04', items = {
    'notes understand markdown: # / ## headings, - [ ] / - [x] todos, - and 1. lists, > quotes, `code`, **bold** - coloured, the text stays plain; a todo box is clickable ([ ] <-> [x], saved at once)',
    'the cursor cell is drawn on top of the background wave',
  } },
  { v = '0.6.23', d = '2026-10-04', items = {
    'faster response: after a key or a click the frame is drawn again in the same tick (the result was on screen one tick later, ~30 ms)',
    'scramble (after Paketti): :scramble and the scramble button in the item tab - slice notes keep their places and swap their slices randomly, within each sample; VISUAL - the selection, else the cursor track in the cursor region; a note never gets longer',
    'swap: gw swaps the event under the cursor with the next one below, 3gw - with the third (:sw 3); the cursor follows',
  } },
  { v = '0.6.22', d = '2026-10-04', items = {
    'no icons, only letters: the delta solo button of an fx is the real letter Δ, the phase button is the letter ø (was a drawn circle); the rule is in about and in the help',
  } },
  { v = '0.6.21', d = '2026-10-04', items = {
    'DSP: an input meter on the left (in - the record input of an armed track, pre - the items before the fx while playing) and the output after all fx on the right (out); under it comp - gain compensation (JS Volume Adjustment "gain comp" last in the chain follows the level before the fx; click again freezes, right click removes); every fx block has delta solo (native REAPER :delta); smart input moved from the track header into the DSP track block',
    'lib: the slice zone on the mini wave is inverted (wave-coloured background, the wave in the background colour), no frame',
  } },
  { v = '0.6.20', d = '2026-10-04', items = {
    'a slice is a note, as in Renoise: slice k shows as the note C-4 + k - 1 (C-4, C#4, D-4 ...) and the command column is free (no more S01 / T06); the normal MIDI keyboard q 2 w 3 e r 5 t ... writes slices 1 2 3 4 5 6 7 8 (17 per octave, z / x by 12); MIDI keys and the item tab label use the same mapping',
    'Option + key on a sliced sample: the last used slice at that pitch (q = original, shown as Pxx); ; in INSERT - the whole sample (mother item); r + note on a slice note picks another slice',
    'insert by command and menu: :note C-4 [rows], :sl N [rows] [+semis], :whole [rows]; \\ i - insert menu: n note, w whole, s slices (each with its note, length in rows and a mini wave; a - all slices in a row, stitched), e automation (ramp, fade, curves, pick a parameter); the instrument list moved to \\ I',
    'the wave is always drawn under the text (the background wave covered the green instrument number)',
  } },
  { v = '0.6.19', d = '2026-10-04', items = {
    'screensets: the screensets cell under options in the main module - s saves the whole view under a name (every option of the options window + module layout: top panel and tab, DSP, browser, matrix, widths, font, theme ...), 1..0 load a saved one, d deletes; also :ssave name / :sload name; kept in REAPER Data/jf_tracker_screensets.txt',
  } },
  { v = '0.6.18', d = '2026-10-04', items = {
    'item tab: the slice zone triangles sit at the top edge of the wave, and the MIDI note of that slice is shown next to them (C4, C#4 ... - the learned pads note + slice, else from C4)',
    'lib: the zone of the playing slice is an underline and a frame on the mini wave - the wave of row 01 was hidden under the fill',
    'meters: options -> meter style blocks (pseudographic) / pt (the earlier see-through ProTracker bars); PT-mode switches to pt',
  } },
  { v = '0.6.17', d = '2026-10-04', items = { 'a track folded to a one-character strip shows its name vertically down the header' } },
  { v = '0.6.16', d = '2026-10-04', items = {
    'repeat above the cursor (from Paketti by Esa Ruoho): Ctrl+Opt+J or Ctrl+Opt+Down - what the cursor track has from the region start to the cursor is repeated from the cursor down to the region end (the last copy cut at the end, what was there replaced); Shift+Opt+J - on all tracks; audio items and MIDI notes, one undo step; outside a region =START..=END',
  } },
  { v = '0.6.15', d = '2026-10-04', items = {
    'tutorial is an interactive tour: 10 steps, each bubble sits on the module it explains and the step counts when you do it (move with hjkl, enter INSERT and Esc, pick a sound, open the item tab, edit, select, :, \\, Space, ?); < > x in the main module; :tutorial text - the old text page',
    'main module: the bitmap / meters / caps / hints row moved to the options window; its place is the active zone (the tour now, later the monome grid)',
  } },
  { v = '0.6.14', d = '2026-10-04', items = { 'Option+h / Option+l jump to the track on the left / right in any keyboard layout (the physical key is read; in the Russian layout Option+h gave another character)' } },
  { v = '0.6.13', d = '2026-10-04', items = {
    'tutorial: a cell in the main module (next to help / about / options) and :tutorial - jf_tracker in ten steps (move, write notes, pick a sound, slice, edit, select, commands, leader menu, play, help)',
    'about: a link to jeeruff.com right under the logo (clickable); the description says Vim is the foundation of the tracker',
  } },
  { v = '0.6.12', d = '2026-10-04', items = { ':kitsave is now :libsave (the save button in the lib asks it)' } },
  { v = '0.6.11', d = '2026-10-04', items = { 'about: the Patreon link is clickable (underlined, lit under the mouse) - opens in the system browser' } },
  { v = '0.6.10', d = '2026-10-04', items = { 'theme screamtracker removed' } },
  { v = '0.6.9', d = '2026-10-04', items = {
    'themes impulse (Impulse Tracker: black field, blue-grey DOS panels, yellow highlight) and screamtracker (Scream Tracker 3: dark blue panels, light text, yellow accent); \\ v a opens about',
  } },
  { v = '0.6.8', d = '2026-10-04', items = {
    'options in the leader menu: \\ v o opens the options window; \\ o - every option as a quick switch with its own key (\\ o t - theme list, w wave, c cursor line, h header colour, r ruler ...): toggles flip at once, choices open their values, numbers + / -; the window and the menu are built from one list',
    'theme protracker: the ProTracker 2 look - black pattern field, grey panels, light grey text, yellow accent, blue, crimson',
  } },
  { v = '0.6.7', d = '2026-10-04', items = {
    ':interp (from Paketti by Esa Ruoho) - in VISUAL each column gets the values between its first and last event filled in linearly by rows: vol, delay, note or a command (the field under the cursor or :interp vol|delay|note|S); one undo step',
  } },
  { v = '0.6.6', d = '2026-10-04', items = {
    'kits: the save button in the lib header (:kitsave name) writes all lib samples - with slicing, marks, take FX - as a native REAPER track template TrackTemplates/jf_kits/<name>.RTrackTemplate (REAPER itself opens it with Insert track from template); the browser tab kits lists them, Enter puts a kit into the lib of the cursor track',
    'about: a short description under the logo and thanks to friends and teachers - Esa Ruoho (Lackluster), parts based on his Paketti, with a link to his Patreon',
  } },
  { v = '0.6.5', d = '2026-10-04', items = {
    'keys: dd (NORMAL) deletes the cursor track (in INSERT dd still deletes the event of the row); dt removes the time selection from the whole project (native Remove contents of time selection, later items move); dr / daw as before',
    'piano strip: with the piano layer (m) a keyboard strip appears above the status - one and a half octaves of the top row (white q..p, black 2 3 5 6 7 9 0) with the letters on the keys, held keys lit amber, the last played dimly, the octave on the left; no letters when the keys are too narrow',
  } },
  { v = '0.6.4', d = '2026-10-04', items = {
    'thin scrollbars in the matrix, the lib and the browser (thinnest): drag the thumb, click beside it - a page; the lists follow the cursor only when it moves, so scrolling by the bar stays',
  } },
  { v = '0.6.3', d = '2026-10-04', items = {
    'keys: dt deletes the cursor track (with its FX, one undo); dr clears the track in the cursor region (the old dt); daw deletes all items of the track in the song (the lib after =LIB stays)',
  } },
  { v = '0.6.2', d = '2026-10-03', items = {
    'legato (:legato): every audio note of the cursor track (or the VISUAL rows) stretches to the start of the next note - no gaps between slices; stretched by rate with the pitch kept, so it follows the tempo (slower - longer, faster - shorter); the note keeps its own length (P_EXT:jf_nat): repeating does not pile up, :legato off restores; :legato auto - the track stays legato while you insert',
  } },
  { v = '0.6.1', d = '2026-10-03', items = {
    'jf_pm from the tracker: in the pm tab T edits the project tags (:pmtag words, shown as #tags), s picks its jf_pm status (the kanban classes; x clears back to STATUS of the .rpp); written into jf_pm_index.json by the jf_pm core, the previous index kept as .bak',
  } },
  { v = '0.6.0', d = '2026-10-03', items = {
    'PT-mode is now the dumbed-down ProTracker view it was meant to be: exactly 4 channels (from the track scroll), each note / sample / volume / one command, no wave column, no envelopes, no folds, LPB 4, bitmap x4 (the largest scale where 4 channels fit: x4 -> x3 -> x2), scopes of the 4 channels on top; :pt new creates the channels CH1..CH4 in the project (one undo) and enters the mode; :pt again restores every setting',
  } },
  { v = '0.5.99', d = '2026-10-03', items = {
    'jf_pm in the browser: each project shows its tempo, keys, tags (#Finder and own) and status next to the name, and the list search finds them (find 160bpm, Bm, #tag, [джем]); o opens the project in REAPER - switches to its tab if it is open, otherwise asks and opens a new tab (REAPER stops scripts on project open, the tracker starts itself again there)',
  } },
  { v = '0.5.98', d = '2026-10-03', items = {
    'big sample editor: :big or the big button in the item tab - the tab takes the whole window height; the wave zooms with the wheel at the mouse, sideways / Shift+wheel scrolls (also in the normal tab); slices, zone, selection, transients and the playhead follow the zoom; zoom out fully - whole sample',
  } },
  { v = '0.5.97', d = '2026-10-03', items = {
    'live arpeggiator (:arp live): in INSERT or the piano layer hold notes - the tracker writes the arpeggio of the held chord at the tempo, one note per step (:step), order and octaves from the last :arp (played = in the order pressed); press more keys to add them, release all to stop; :arp live again turns it off',
  } },
  { v = '0.5.96', d = '2026-10-03', items = {
    'macro view (:macro): bird view over the tracker body - a row is a bar, per track the event density as blocks and the first note of the bar, region names at their bars; j k bars, J K by 4, g G, h l tracks, Enter / Esc back to the tracker on that bar',
  } },
  { v = '0.5.95', d = '2026-10-03', items = {
    'PT-mode (:pt): a ProTracker view - only the tracker and, on top, the scopes tab with the scopes of the tracks visible in it; matrix, lib / browser, DSP hidden, cursor fixed in the centre, meters on; :pt again restores the layout (quitting in PT-mode saves the layout from before it)',
  } },
  { v = '0.5.94', d = '2026-10-03', items = {
    'arpeggiator :arp [up|down|updown|random|played] [step] [octaves] [gate%] - a chord on the cursor row (notes in the subcolumns of the track) becomes an arpeggio over the chord length: MIDI notes, or copies of the audio notes at the arp pitch; options are remembered (:arp alone repeats), one undo step',
  } },
  { v = '0.5.93', d = '2026-10-03', items = {
    'meters (main module: meters on) are pseudographic: two columns L R a character wide at the left of each track, made of row cells with a 1 px gap like text blocks, the top cell filled in eighths; green / amber / red by height, see-through over the notes',
  } },
  { v = '0.5.92', d = '2026-10-03', items = {
    'lib: swap button - the selected sample plays the audio file selected in the browser in all its notes, slices too (offsets, lengths, slicing stay, as sample replace in Renoise); lit while swapped, click again - back to the original file; one undo step each',
  } },
  { v = '0.5.91', d = '2026-10-03', items = {
    'lib order is yours: drag a sample row up / down (amber insert line) or J / K in the lib - the numbers follow the position everywhere (lib, cells); stored as P_EXT:jf_ord on the sample and its notes, one undo step; samples without a place go after',
  } },
  { v = '0.5.90', d = '2026-10-03', items = {
    'wave: new mode back - the wave across the whole item width as a dim background under the text of the rows (options -> wave, :wave back)',
  } },
  { v = '0.5.89', d = '2026-10-03', items = {
    'lib: no @ / $ marks and legend; the mini wave of a sliced sample shows its slice boundaries and lights the zone of the slice in play (selected or under the cursor)',
    'item tab: with the cursor on a slice note it shows the parent sample with that slice zone and the slice properties',
  } },
  { v = '0.5.88', d = '2026-10-03', items = {
    'cleanup: dead code removed - unused ctx entries (browser_find, ctrl_held, inst_preview_pos, depot, set_fontface + the TTF font list, retro_put / retro_loop wrappers), edit fx_value / depot_items / item_set / take_set, keyhelp animating, draw ai_colour, cmds tk_time, slicer fft; profile checked: a frame draws in ~4.6 ms (scopes tab open), worst ~9 ms, of a ~30 ms tick',
  } },
  { v = '0.5.87', d = '2026-10-03', items = {
    'scopes at removed: no scope on the cursor row and no scope row in the track header - track scopes live in the scopes tab (and master)',
  } },
  { v = '0.5.86', d = '2026-10-03', items = {
    'slices are nested in their sample: the lib lists and numbers only source samples (01, 02 ...), a slice note shows the number of its sample and Sxx in the command column = the slice index (Sxx typed on a slice note picks that slice); no more 15 numbers per sliced break',
    'Shift+Enter (NORMAL): what is under the cursor - instrument number, name, slice or whole sample, file, offset, piece length, rate',
  } },
  { v = '0.5.85', d = '2026-10-03', items = {
    'new top tab scopes (before master): a scope for every track in a grid - analyzer (scope / spec / sgram buttons), L R meters, track name; click a cell - cursor to that track; scopes off - one click puts the bridges on',
    'curscope removed (the cursor line as an oscilloscope did not follow playback); cursor line is top / bottom / off again',
  } },
  { v = '0.5.84', d = '2026-10-03', items = {
    'fix: slices of a sample with stretch markers (after smart quantize) all played its start - the copies kept the markers of the whole sample, and REAPER maps markers from the start of the file, ignoring the offset; a slice copy now gets its own piece of the source (offset and rate from the marker map, pitch kept) without the markers; same for a selection dragged out of the item tab',
    ':fixslices repairs slice notes inserted before this fix (one undo step)',
    'fix: the wave of an item with stretch markers showed only part of the file (marker source positions are in units at the playrate)',
  } },
  { v = '0.5.83', d = '2026-10-03', items = {
    'options: every description shortened to one line - it fits the bottom line of the window',
  } },
  { v = '0.5.82', d = '2026-10-03', items = {
    'fix: the wave column no longer darkens when the cursor is on the note - only the wave inside the note field (wave: note) follows the cursor highlight',
  } },
  { v = '0.5.81', d = '2026-10-03', items = {
    'cursor lead: while playing the playhead row is drawn 15 ms ahead (options -> cursor lead, 0..60 ms) - the frame reaches the screen later than the position is read, the cursor trailed the sound; logic (Orca, jumps, queue, =END) still uses the real position',
    'item frame option: item (border around the whole item) / wave (only around the wave column) / off',
  } },
  { v = '0.5.80', d = '2026-10-03', items = {
    'step next: after an entry the cursor jumps to the next object of the track - note, item, command, envelope point (any subcolumn; in an envelope column the next point); click the step cell to go number -> auto -> next, or :step next',
  } },
  { v = '0.5.79', d = '2026-10-03', items = {
    'curscope reworked: not a line through the middle of the row - the bright green REAPER cursor line itself scatters into dots, each track column shows its oscilloscope as points around the line (they may reach the neighbour rows); the amber cursor line stays as a plain top line',
  } },
  { v = '0.5.78', d = '2026-10-03', items = {
    'curscope: cursor line = scope - the amber cursor line itself becomes the oscilloscope, through the middle of the cursor row: inside each track column its signal, between columns a straight line; the cursor is fixed in the centre while it is on (fixed comes back as it was when you leave); options -> cursor line: scope, or :curscope',
  } },
  { v = '0.5.77', d = '2026-10-03', items = {
    'options window: no dropdowns - every choice shows all its values as buttons in a row (the current one lit), click a button to set it; descriptions moved to the bottom line and follow the mouse',
  } },
  { v = '0.5.76', d = '2026-10-03', items = {
    'track header: input row - i <input> (click: the list of inputs by fzf under it - none, mono, stereo pairs, MIDI all and each MIDI device; click again closes) and a smart button (jf_smart_set_input on this track); options -> input row',
    'DSP track block: the sends row opens a send panel above it - each send with a volume slider, m (mute), x (remove); + send picks the target track by fzf; routing opens the REAPER window; the in row opens the same input list',
  } },
  { v = '0.5.75', d = '2026-10-03', items = {
    'track scopes moved onto the cursor row strip: each track oscilloscope runs right along the cursor row in its column, muted, under the notes; the header lost its scope row; options -> scopes at: cursor / header (the old row)',
  } },
  { v = '0.5.74', d = '2026-10-03', items = {
    'track scrollbar under the tracker body: the thumb is the visible tracks out of all; drag it, click beside it for a page; the trackpad sideways scrolls tracks too',
    'Cmd + trackpad sideways: width zoom - as set per track / all compact (note + wave) / all strips; Cmd + wheel: LPB zoom (up - more rows per beat)',
  } },
  { v = '0.5.73', d = '2026-10-03', items = {
    'experimental: main module position is its own option - top (top left above the matrix), mid (bottom of the left column above the DSP panel), bottom (left in the DSP band, the fx list moves right); same as the top panel position - inside the top panel, as before; the top panel tabs then start at the left edge',
    'options window: numbers are sliders like in DSP (click / drag), choices open a list under the cell (click a value; click the cell again or Esc closes); keys h l still step',
  } },
  { v = '0.5.72', d = '2026-10-03', items = {
    'narrow track header: a slider with no room left (track under three characters) folds into its letter button - v, p, w, L, R; click opens the slider in a popup under it (drag, dblclick resets), click again or anywhere else closes; the letter is brighter when the value is not the default',
    'options: the browser sidebar row is gone (the > knob at the tracker edge and :side fold it)',
  } },
  { v = '0.5.71', d = '2026-10-03', items = {
    'item preview is the same every time: it loops like the item (an item longer than its file plays the start again), the edit view draws the same peaks as the plain view, one title and footer - a double click no longer changes the picture or the sound',
    'trim menu opens right under the button; a second click on trim closes it',
    'pan / volume sliders (track header and DSP track block): fixed room for the value, right-aligned - the pan centre no longer jumps when C becomes L37 or R100',
  } },
  { v = '0.5.70', d = '2026-10-03', items = {
    'trim in the track header: click - find a parameter of the track and its FX (fzf, containers too, the ones with an envelope on top with a dot) and show its envelope; Shift+click - envelopes in the tracker on / off (the old click); rclick - the params page',
    'modulation tab, new page params (P): every parameter of the track in one table - track envelopes and all FX params; ENV (create / show / hide), ACT, ARM, PTS, MOD (L E K), value; header: automation mode, all / used, in tracker, find, native envelopes window; m modulates (or jumps to the matrix row), c sends the curves generator to that envelope',
  } },
  { v = '0.5.69', d = '2026-10-03', items = {
    'M in NORMAL: piano layer (like M in Ableton) - the top row and digits play notes, other keys stay Vim commands; M or Esc turns it off',
    'Cmd+note (INSERT and the piano layer): the note lasts as long as the key is held, growing at the project tempo; j / down add a step while holding, Esc cancels; Cmd+Shift+note stretches the sample to that length (keeps pitch, becomes unique); slices too',
    'Cmd+digit in INSERT / piano layer is now a held black key; slot selection stays on Cmd+digit in NORMAL, Cmd+HJKL and , . everywhere',
    'step auto with slices stitches exactly: the next slice starts at the very end of the previous one (row + delay xx/256), the cursor goes to the row where it ended - qwerty in a row rebuilds the break without gaps (rounding to whole rows left gaps)',
    'track header: the A button is now trim, at the right of the buttons',
    'keys: m is the piano layer (NORMAL), mute moved to M (Shift+m) - tracker NORMAL / VISUAL / INSERT and the matrix, help and menus follow',
    'the item offset shows as Sxx, as in Renoise (offset or slice, one command to learn); 9xx is still accepted; an Sxx offset on a linked note makes it unique like a stretch',
    'cursor on the item name row: the highlight is the note field wide, not the whole name',
    'rec is its own tab again, the first one, in the record button colour (purple); the [rec] buttons in the item tab are gone',
    'fix: audio-in recording (INSERT + armed track + jf_rec) no longer fires while the project plays - jf_rec heard the playback of the track itself and printed it as recorded pieces (space / play)',
    'wave in options, three modes: column (own column, spectral peaks), note (inside the note field on the item rows - the old off), off (no wave at all, faster); :wave column|note|off; the wv cell left the main module',
    'items: option item colours (off - neutral grey) and a fill opacity slider (0..60 %); in mono the item border is brighter',
    'a slice (q..p) on a row that already has a note or slice overwrites it, like a note (it used to open a new lane); held notes overwrite too, at commit',
    'cells: the instrument number sits on the note row, as in Renoise (C-4 01 80); the item name is on the second row - option item names',
    'lib: the sort button is gone - a header row # / name / len / preview sorts by clicking (# again: marks); sort by name added',
    'slicer: slice markers and the selection stay inside the wave (they ran over the item properties)',
    'lib: a duration column before the mini wave (the slice rows no longer carry it in the name)',
    'options: no items that are cells of the main module; an x in the top-right corner closes the window; track header: lane -/+ above the note field, fx columns -/+ at the right end (the fx cell is gone)',
    'R is purple like the REAPER arm button, track fx green like the channel FX button - in every theme, mono too',
    'DSP: the track name (in the channel header colour) stands before track fx / take fx; the first, pinned block of the DSP row is the track itself - name, R I M S, phase, FX on / off, volume, pan, input (menu), master send, sends, routing (the REAPER routing window), on the track colour',
    'track scopes are back (options: track scopes, :scopes): an oscilloscope row in every track header, the master tab analyzer works again; turning them on puts jf_tracker_scope on every track and the master, off removes it',
    'DSP: the parameter category colour moved from a strip at the name (it stuck to the first letter) to the slider fill; buttons track fx / take fx',
    'about: logos that move - marquee, shimmering lines, dripping blood (:about name opens one)',
  } },
  { v = '0.5.68', d = '2026-10-03', items = {
    'themes (options, :theme): reaper - native colours of the REAPER theme (default); modus vivendi, modus operandi, gruvbox, catppuccin - full-screen palettes; mono - everything grey except the cursor cell',
    'timeline ruler moved left of the row numbers (between the region lanes and the numbers); the cursor line starts at the lanes edge and runs through the ruler; the green mark right of the row number is gone',
    'strict borders: the hint rows no longer draw their own bit of the module border (it made small corners sticking out); the matrix | tracker border runs the whole tracker module - body, status, hints',
    'mono theme: darkest text a bit brighter (it vanished), the INSERT frame and the INSERT word in the status bar stay red, track colours stay in the headers',
    'Shift in INSERT only plays, never writes: the MIDI keyboard with Shift sounds through the track monitoring; audio-in recording (jf_rec) ignores the tracker preview sound (it goes through the track FX) and Shift - it printed previewed notes into the track',
    'main module: help / about / options / notes on top, a thin line, the view options, a thin line, transport and input at the bottom; notes open in the main module (between the options and the transport), the fx list stays in place',
    'playback stops at =END (option stop at =END, on): only when it started before =END - playing the library after it is not stopped, recording never',
    'the hint row of the top panel tabs no longer covers the main module border (small corner above it)',
    'track header colour: off - no track colour at all (every theme), then line / header / full',
    'playhead on the item wave for every preview: Shift+note on the keyboard, the MIDI keyboard, slices (q..p) - matched by the source file, so it shows on the sample and on its slices; the note preview plays at the item rate like the note',
    'timeline ruler right of the row numbers (options: off / beats / time / both): REAPER ruler labels on every beat, bar brighter, native formats; the line right of the row numbers is gone',
    'about: 20 logos, real ANSI text with colour codes, box drawing, dots; native logos take the palette roles (text / accent / line) and follow the theme',
  } },
  { v = '0.5.67', d = '2026-10-03', items = {
    'items no longer multiply: every insert carries the instrument mark P_EXT:jf_iid (slice k: id#k, a cut: id@offs+len); notes cut by the next note, pitched or with their own volume stay ONE instrument; unmarked items group by file + offset + rate without the length (a cut is not a new item); the library item or the longest copy represents the instrument',
    'item panel edits the whole instrument: all its notes follow - volume by ratio, pitch and pan by difference (the notes keep their own), fades / loop / stretch mode / keep pitch set to all, rate scales every copy',
    'beatsync is a property of the item (items header button bsync, row beatsync in the item panel; wheel: beats): the item lasts N beats at the tempo where each note sits, tempo changes followed; slices of a beatsynced sample go at the same tempo',
    'preview: the select button is now preview - click on / off, rclick: mode full (to the end of the item, Esc stops) / hold (while the mouse button is held on the row) / first second; the instrument plays as its note sounds (offset, rate, pitch, volume) and the item wave shows a playhead',
    'track headers take the REAPER TCP colour (col_tr1_bg, selected: col_seltrack) with the track colour mixed like REAPER does; header text contrast follows',
    'items header: sort was drawn over find (only its d showed) - sort, find and bsync now each have their place',
    'a stretched (=, Txx, Option+edge) or offset (9xx, start trim) note becomes unique at once; a question offers u: keep it unique (Enter) or a: apply the same offset / rate to all linked notes',
    'module borders 2 px (lines inside modules stay 1 px); missing verticals drawn: fx list | DSP, and between the hint rows of neighbour modules (they showed black gaps); the cursor line runs through the region / marker lanes up to the row numbers',
    'the items module is now lib (and depot is lib everywhere: retro button, slicer and browser hints); help ? opens with a short page on what the tracker is, why it stays native to REAPER and what lib is; F1 help: philosophy updated (lib, linked notes, bitmap only)',
    'browser: sync button - while the project plays, a file starts on the next bar (native measure align)',
    'ruler markers without their own colour take the REAPER theme marker colour, as on the timeline (=START was amber)',
    'matrix | tracker border visible: region and marker lanes start 2 px after it; the green edit-cursor mark moved next to the row number (it sat on the border and looked like it reached into the matrix); option cursor line: top / bottom / off',
  } },
  { v = '0.5.66', d = '2026-10-03', items = {
    'tracks selected in REAPER are shown: their column (header and body) is slightly lighter; polled every frame, so it follows clicks in the TCP at once',
    'track header colour, three modes (options, main module cell hdr, click / wheel): line - a colour strip under the name (as before), header - the name row filled, full - the whole header filled, dimmer below the name; toned to the panel like REAPER tints the TCP, the name turns dark on light colours',
    'main module: cells caps (column captions on / off) and hdr (track header colour)',
    'the instruments module is now called items (header, help page, status texts)',
  } },
  { v = '0.5.65', d = '2026-10-03', items = {
    'module borders: the file browser drew its own 2 px edge next to the sidebar line (double line) - removed; the top panel in mid / bottom position draws its border on top, so it is separated from the DSP panel and the fx list (was merged), and no longer doubles the DSP line',
    'about moved to the main module (cell next to help / hints, :about) and opens on its own; Esc closes it',
    'about logo: the generated graffiti styles are gone - five hand-made JFTRACKER logos instead, a different one each time; drawn on a character grid by the tracker itself (blocks, shades, diagonals), so the block art stays aligned in the bitmap-only UI and shrinks to the window width',
    'about logos in ANSI / CGA colours on a black plate, stepped by rows; the shades are real pixel dithering, drawn once into a picture; a sixth text logo (rubble) coloured after the user reference - grey top, brown bottom, yellow dither',
  } },
  { v = '0.5.64', d = '2026-10-03', items = {
    'TTF fonts and Nerd icons removed: the tracker is bitmap only (REAPER pixel font, x1..x3); non-ASCII text (Cyrillic names) falls back to the system mono font at the bitmap height; :font / :nerd / :fontface / :hybrid / :icons only say so',
  } },
  { v = '0.5.63', d = '2026-10-03', items = {
    'fonts: TTF size 10..32 (options, control cell, :font); options get text font (bitmap / ttf), ttf size and ttf face (the Nerd font list)',
    'about: a JFTRACKER graffiti logo on top, a new style every time - pouet ASCII (figlet), block, oldskool with a shadow, bubble, metal (italic, spikes, drips), 3D, chrome',
  } },
  { v = '0.5.62', d = '2026-10-03', items = {
    'module borders made uniform: the extra frames from 0.5.61 sat next to the old separators (double lines) - removed; every module separator is now one 1 px dim line, the focus frame stays bright',
  } },
  { v = '0.5.61', d = '2026-10-03', items = {
    'every visible module has a thin dim frame (main module, fx list, tabs, tracker, matrix, instruments, browser, DSP) - the focus frame stays bright on top',
    'options: frame rate max / 30 / 25 / 24 - the lower rates draw into a buffer that is shown on every tick, so nothing flickers; 60 / 120 are not possible for a script (REAPER runs defer ~30 times a second)',
  } },
  { v = '0.5.60', d = '2026-10-03', items = {
    'fix: the window flickered when idle - skipping frames is switched off (a skipped gfx frame does not keep the previous picture); the tracker draws every frame again',
  } },
  { v = '0.5.59', d = '2026-10-03', items = {
    'matrix naming like Renoise: alias (als next to the region name, A) is the linked repeat - same pattern, MIDI pooled, items grouped; clone (cln, C, D, ^D) is a free copy with a new name; make unique (U, region menu) unlinks a repeat - new name, own MIDI pool, no group',
  } },
  { v = '0.5.58', d = '2026-10-03', items = {
    'speed: the FX chains are cached by a cheap signature (count, GUIDs, bypass, container contents) - a project snapshot rebuild after an edit went from 5.8 to 0.6 ms on the test project; parameter values are still read live',
    'heartbeat shows the last snapshot rebuild and its parts (env / pool / mod / fx)',
  } },
  { v = '0.5.57', d = '2026-10-03', items = {
    'matrix names swapped (clearer): clone (cln, C) is the linked repeat - same pattern, MIDI pooled, items grouped; dup (D, ^D) is a free copy with a new name',
    'reliability: an error inside a frame no longer closes the tracker - it is logged with its traceback (ExtState err) and shown in the status, the tracker keeps running; it quits only if the error repeats for ~3 s',
    'speed: when idle (1.5 s without mouse, keys or project changes, not playing, no preview) the tracker draws every third frame (~10 fps); any action brings 33 fps back at once',
  } },
  { v = '0.5.56', d = '2026-10-03', items = {
    'fx list opens over the whole left column (matrix and main module under it) whenever it has the focus - click or Tab - and closes when the focus leaves; drawn last, so the status bar no longer cuts it',
    'fx list: right-click an effect - native menu: add to the cursor track / take, to selected tracks, on a new track, favourite, native FX browser',
    'Garden is gone: the Orca tab shows only the Orca field (header: orca on/off, frame); its help page is out of the help order',
  } },
  { v = '0.5.55', d = '2026-10-03', items = {
    'main module (control block) takes the keyboard focus: Tab or a click puts a frame around it, the cursor lands on BPM; h j k l / arrows move between cells, + - change the value, Enter / Space press it (BPM: type the tempo), Esc back',
  } },
  { v = '0.5.54', d = '2026-10-03', items = {
    'pattern repeats are linked natively: a repeated region (dup / D / ^D, p of a yanked slot whose pattern exists, autosync, slot -> pattern, append) puts its MIDI items into a shared pool and each item with its copies into one item group - editing in the arrange view (notes, move, trim, mute) changes all repeats, not only edits made in the tracker',
    'clone (button cln next to the region name, C in the matrix): an exact copy with a new name, not linked - own MIDI pool, no group',
  } },
  { v = '0.5.53', d = '2026-10-03', items = {
    'fx list: folders like the native browser - all, fav (REAPER Favorites + your own, * toggles), dev / type / cat with group headers (reaper-fxtags.ini), rec (recently added); favourites marked * everywhere',
    'curve generator: the make AI button is called auto-item (an automation item with the curve)',
    'fx list: folder buttons wrap to a second row when the column is narrow',
    'fx list: drag its right edge to resize (dblclick: auto); typing opens it as a popup of a comfortable size over the panels (amber frame), Esc clears and shrinks it',
  } },
  { v = '0.5.52', d = '2026-10-03', items = {
    'fix: the folded matrix could not be resized (it ignored the dragged width) - fold has its own width now: drag the = grip, double-click = compact again; the unfolded width is kept separately',
  } },
  { v = '0.5.51', d = '2026-10-03', items = {
    'bitmap font scale goes up to x3 (control cell, Ctrl +/-, :scale, options); x4 is kept for the future PT-mode, a saved x4 becomes x3',
  } },
  { v = '0.5.50', d = '2026-10-03', items = {
    'matrix fold (button fold, F): only slot numbers, track names and cells - no region names, lengths or ruler, the matrix gets narrow; the state is remembered',
  } },
  { v = '0.5.49', d = '2026-10-03', items = {
    'status bar in the tracker module starts under the tracks (from the matrix edge), not under the matrix',
  } },
  { v = '0.5.48', d = '2026-10-03', items = {
    '[rec] is red and sits in the left corner of the item tab (start of the slice button row, also for browser files and an empty track); in the recording mode it is the first, lit button of the ring row and takes you back',
  } },
  { v = '0.5.47', d = '2026-10-03', items = {
    'options: top panel position - top (above the tracker), mid (above the DSP panel), bottom (below the DSP panel); in mid / bottom its upper edge drags the height',
    'options: status bar - bottom (window bottom) or tracker (a line under the tracker body, the sidebar then reaches the window bottom)',
  } },
  { v = '0.5.46', d = '2026-10-03', items = {
    'DSP: dm removes the modulation of the selected parameter, da its automation (ad still works)',
    'retro is no longer a tab: [rec] on the tab bar of the item tab switches it between editing the item and recording into an item (the jf_rec ring - select, listen, put, loop, to library); :tab retro / :retro still work',
    'the wave in the tracker cells is continuous without spectral peaks: a solid axis inside the item bounds, peaks on top - no dashes on silence or offline items',
  } },
  { v = '0.5.45', d = '2026-10-03', items = {
    'curve generator: numbers are horizontal sliders, choices are buttons (shape sin tri saw+ saw- sqr rnd, type, hits, dir, from), toggles are buttons; the panel is wider when there is room',
    'modulation matrix: a strip under the table for the selected row - L1 / ENV / LNK toggles, LFO shape buttons, sliders for BASE and the numbers of the cursor group (one undo per drag)',
    ':tab sample removed - :tab item; :tab orca opens the Orca tab',
  } },
  { v = '0.5.44', d = '2026-10-03', items = {
    'the sample tab is called item (REAPER terms: it edits the selected instrument item); :tab item works, :tab sample still too',
  } },
  { v = '0.5.43', d = '2026-10-03', items = {
    'REAPER actions from the tracker, kept apart from tracker commands: \\ a or :!text opens fzf over every Main action (native list incl. scripts and custom actions), recently run ones on top (scripts remembered by name)',
  } },
  { v = '0.5.42', d = '2026-10-03', items = {
    'Orca: drag and drop onto field cells - an instrument from the instruments panel writes $ track inst 1 (sliced) or : track inst 4C, a region dragged by its matrix name writes ; slot, a browser file goes into the track library first and then lands as an instrument; the bang is yours (D4 next to it)',
  } },
  { v = '0.5.41', d = '2026-10-03', items = {
    'any effect becomes a DSP module: parameters are classified by units and name (gain, filter, time, pitch, mix, dynamics, stereo, modulation, switches) with a colour strip, sub-groups are read from names (amp1attack, f1cutoff, Osc 2 Pitch, ampAttack), service parameters dropped, the most important first, up to 24 in up to 3 columns; computed once per plugin type',
    'module learn (E in the DSP panel): knobs touched in the plugin window join the block; x / J K / < > / R edit it; saved per plugin in Data/jf_tracker/dspmods_user.txt; user module > curated registry > automatic',
  } },
  { v = '0.5.40', d = '2026-10-02', items = {
    'modulation inside DSP containers, native first: the modulate matrix and the parameter picker see FX inside containers (0x2000000 addresses, nested); container blocks show their native macros (M ...) first; am maps the selected child parameter to a new container macro (container_map) - the macro takes native LFO / ACS / link like any parameter',
  } },
  { v = '0.5.39', d = '2026-10-02', items = {
    'one modulate tab: the native modulation matrix and the curve generator (lfo / podkat = Anticipate / follow) - side by side when the panel is wide, pages [matrix] [curves] when narrow (L switches); before, the generator was hidden in a narrow top panel',
  } },
  { v = '0.5.38', d = '2026-10-02', items = {
    'DSP: granulator module (jf_grgrain) - live cloud from its gmem (16 wave columns, grain dots, zoom window, grain position, record head); click / drag on it sets the native Position parameter; size, density, spray, pitch, jitters, reverse, shape, drift, spread, freeze, feedback, filter, zoom, record, mix',
    'DSP: slixer module in three columns with arp gate, pre-roll, playthrough, timeline lock, bend range, Q by transients, pitch sensitivity, capture length',
  } },
  { v = '0.5.37', d = '2026-10-02', items = {
    'retro looper: while playing, L (or the loop button) takes the last N bars just played from the jf_rec ring (ending at the last bar line) and loops them from the next bar - to the region end, else 4 times; 1 2 4 8 set N',
    'fix: names used before their definition were nil globals - retro a / j k / h l and its hint labels, the \\ menu submenus (event / track / pattern / view), monome take / grid buttons, hint labels on the control cells, browser preview with the top panel open, and committing a dragged slice marker in the slicer',
  } },
  { v = '0.5.36', d = '2026-10-02', items = {
    'DSP: TG33 vector module (jf_tg33_xy) with an XY pad - drag moves vector X and Y together; gesture loop / record / speed, beatsync, variate, glitch, return, program, FX next to it',
    'DSP: chord latch module (jf_chord_latch, the harmony generator) - complexity, style, voicing order / window / spread, hold, octave, velocity, articulation, attack / release, full auto, slow arp, latch wall',
    'DSP: XY pad widget for any curated module (xy = { x, y } in jf_tracker_dspmods.lua)',
  } },
  { v = '0.5.35', d = '2026-10-02', items = {
    'curve generator (modulation tab, L): types lfo / podkat / follow. podkat brings Anticipate into the tracker - a lead curve before every hit of a source track (its events or the transients of its audio), hold, exponential release, duck or swell, lengths in rows; follow draws a curve from another envelope (pick it) or from the audio level of a track, with attack, release, shift (lookahead) and invert; dense curves are thinned (Ramer-Douglas-Peucker)',
  } },
  { v = '0.5.34', d = '2026-10-02', items = {
    'modulation tab: LFO generator panel (L) - sin / tri / saw+ / saw- / sqr / rnd, period in rows (follows LPB and tempo), depth, center, phase, points per period, live preview; g makes an automation item with the curve, p writes points into the envelope at the tracker cursor (time selection, else the cursor region, else one bar)',
  } },
  { v = '0.5.33', d = '2026-10-02', items = {
    'DSP: ReaSamplOmatic5000 module - the sample wave with start / end handles (drag the nearest one), drop a browser file on the wave to load it; volume, pan, note range, root, pitch, mode, voices, ADSR, note-off, loop in two columns',
  } },
  { v = '0.5.32', d = '2026-10-02', items = {
    'fix: an XRNI / REX dragged from the browser onto a track column became an empty item (no wave, no slices) - it is now imported with its slices into that track library and the instrument is placed at the drop row',
    'control block: control / options / help simply start on new rows (no lines or labels)',
  } },
  { v = '0.5.31', d = '2026-10-02', items = {
    'control block split into control / options / help groups; control has the metronome (metro), the time signature (sig) and a beats row: bar, beat of the bar, beat squares (downbeat edge, current lit), rows per beat / per bar',
    'monome moved from the control block into its own grid tab; the tab can be switched off in options (grid tab) - on by default only when jf_grid is installed',
    'midi tab: monitor of all incoming MIDI on the left (channel, event, which target took it), mappings on the right',
  } },
  { v = '0.5.30', d = '2026-10-02', items = {
    'fix: an open picker (fzf) or hydra menu gets the keys before the focused module - in the modulation tab a (modulate parameter) and the link source picker could not be typed into or confirmed; same for the DSP parameter picker',
  } },
  { v = '0.5.29', d = '2026-10-02', items = {
    'Shift+1 (!) listens to the selected instrument from any module (its own length, a slice plays only its piece)',
    'browser: track button - files are heard through the selected track and its FX (on, default) or directly to the output (off)',
  } },
  { v = '0.5.28', d = '2026-10-02', items = {
    'sample tab: autotrim (button, z, MIDI target) cuts the silence at the start and the end (-48 dB from the peak, 5 ms before the attack and 20 ms of tail kept) - all notes of the instrument, slices shifted, one undo',
    'cells no longer show the slice command Sxx: like Renoise, note + volume and the row with the instrument number and name (typing Sxx still works)',
  } },
  { v = '0.5.27', d = '2026-10-02', items = {
    'midi tab (next to modulation, :midi): MIDI learn for the slicer - knobs for slice start / end / move, sensitivity, volume, instrument (abs or relative encoders), pads = slices, buttons for equal / transients / detect / clear / snap / quantize / preview / insert / to library / play; knob edits land as one undo 0.5 s after the knob stops; bound CC / notes do not reach note recording',
    'browser: the <> and hide buttons are gone (the sidebar has > and =)',
    'instruments / browser split: separator as thick as between the other modules, = on the right drags the height (dblclick: auto)',
  } },
  { v = '0.5.26', d = '2026-10-02', items = {
    'instruments module has a Vim grammar like the matrix and DSP: dd / x cut an instrument (its events and library item, to the register), yy yank, p / P put a copy into the cursor track library, yp duplicates, v selects a range; pending operators show their hints',
    'f hint labels jump into the instruments (also on the empty .. slots) and move the focus there; fix: the instruments in the sidebar could not take focus while the top dock was closed',
    'preview on select moved from p to a (p now puts)',
  } },
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
-- about (4 окт): под логотипом — короткое описание (введение автора допишем),
-- благодарности; дальше — изменения
V.INTRO = {
  'i waited for someone to build a tracker for reaper. more than seven years later it was time to do it myself.',
  'a tracker lets your hands leave the mouse alone and type the notes that the keyboard can type anyway.',
  'why jf: my initials and short nick - and j f are the keys under your index fingers on the home row. the tracker is meant to be played from the keyboard.',
  'vim is the foundation: modes, operators + motions, counts, registers, the dot repeat and the : command line drive every module.',
  'it stays as close to native reaper as it can: tracks, items, midi, regions, envelopes and fx are plain reaper - close the window and the project plays on; every edit is one undo step.',
  'it needs sws and js_reascriptapi - the extensions most people making music in reaper have installed anyway.',
  'it grew out of my own ecosystem of scripts and ties them together: look natively into other reaper projects and take, say, an automation curve from another one - or just enjoy that you can.',
  'pt-mode is a simple view without a crowd of channels - a tribute to the old-school protracker way, the tracker a ton of jungle and electronic music was written on.',
  'no icons and no symbols - only letters, and the alphabets have plenty: Δ is delta solo, ø is phase.',
  'i am not a professional programmer - claude helped me write it, so i see no point in making it a commercial product.',
  'what you get here is worth at least 2500 euro of tokens and months of almost non-stop work, which i loved doing and will keep doing - it is what i could do 24/7.',
  'if it makes you as happy as it makes me, buy me a coffee:',
  'https://ko-fi.com/jeeruff',
}
V.THANKS = {
  'thanks to my friends and teachers - in particular esa ruoho (lackluster):',
  'parts of jf_tracker are based on his paketti for renoise, used with his permission.',
  'support his work: https://www.patreon.com/esaruoho',
}
-- tutorial (4 окт): первые шаги, ячейка tutorial главного модуля / :tutorial
V.TUTORIAL = {
  'jf_tracker in twelve steps - every key here is a Vim habit',
  '',
  '1. Why jf. Index fingers on f and j - the two keys with bumps: hands on the home row. Every module answers to letters, the mouse is optional.',
  '2. Move. h j k l - cursor, gg / G - start / end, { } - bars. Tab - next module (matrix, top, lib, browser, DSP).',
  '3. Jump anywhere. f puts two-letter labels on everything on screen - type a label and you are there.',
  '4. Write notes. m - the keyboard on / off (on: it has priority over Vim keys). The top row q 2 w 3 e r 5 t 6 y 7 u i 9 o 0 p plays C .. E, z / x - octave; Esc - INSERT, where the keys write; Esc - back. With the keyboard off everything is plain Vim (i - INSERT).',
  '5. Pick a sound. The lib on the right: j k - select; in INSERT , . switch sounds. Shift+note only plays.',
  '6. Slice a break. Select a sample, the item tab on top: s opens the slice menu - s8 = eight equal slices, st = by transients, sd = remove. In INSERT q writes the whole sample, the next keys its slices: 2 w 3 e = slices 1 2 3 4 (as in Renoise; the note is the pitch, Sxx - the slice; Option + key - the pitch of the last slice).',
  '7. Edit like text. x - delete, dw / d3j / dG - delete with a motion, yy p - copy, u - undo, . - repeat the last edit.',
  '8. Select. v - block, V - rows; then d y M (mute) or :interp vol to ramp the volumes.',
  '9. Commands. : opens the command line - :arp up 2, :legato, :macro, :pt, :big, :wave back; Tab completes.',
  '10. Menus. \\ - the main menu of everything (v view, P project, o options); \\\\ - the context menu of what is under the cursor, the same as the right click; ? - any REAPER action. Ctrl+/ - find an effect, Option+/ - inside the DSP chain, Cmd+/ - a file.',
  '11. Play. Space - play / stop, F - follow the playhead; =START and =END markers bound the song.',
  '12. Help. F1 - the whole help, / searches it; the help button of the main module shows the keys of the focused module, live.',
  '',
  'Everything you write is plain REAPER: tracks, items, MIDI, regions - close the window and keep working in REAPER.',
}

function V.lines()
  -- ссылки (5 окт): каждая — своей строкой, кликабельна
  local out = { 'https://jeeruff.com', 'itch.io   https://jeeruff.itch.io/jftracker', 'github    https://github.com/jeeruff',
                'youtube   https://youtube.com/@jeerufff',
                'e-mail    jeeruff@gmail.com',
                'bandcamp  https://jeeruff.bandcamp.com', '', ('jf_tracker %s  (%s)'):format(V.VERSION, V.DATE), '' }
  for _, l in ipairs(V.INTRO) do out[#out + 1] = l end
  out[#out + 1] = ''
  out[#out + 1] = 'Free software, GNU GPL v3 (see LICENSE). No warranty.'
  out[#out + 1] = ''
  for _, l in ipairs(V.THANKS) do out[#out + 1] = l end
  out[#out + 1] = ''
  out[#out + 1] = 'changes'
  for _, c in ipairs(V.CHANGES) do
    out[#out + 1] = ('%s  %s'):format(c.v, c.d)
    for _, it in ipairs(c.items) do out[#out + 1] = '  - ' .. it end
    out[#out + 1] = ''
  end
  return out
end
return V
