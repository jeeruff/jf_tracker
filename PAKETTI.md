# Paketti → jf_tracker: catalog of features worth porting

Source: Paketti, 192 Lua files, ~285k lines. About 2,800 keybindings and 1,950 menu entries are registered. Most of them are numbered variants of the same few hundred functions; `PakettiMenuConfig.lua` only re-registers menus.
Checked against: jf_tracker 0.6.6 (`jf_tracker_version.lua` CHANGES, `V.COMMANDS`, `jf_tracker_keyhelp.lua`, `jf_tracker_cmds.lua`, README).

## What jf_tracker already covers (so these Paketti groups are skipped)

| Paketti group | jf_tracker equivalent |
|---|---|
| ChordsPlus arpeggio up/down/updown/random, PakettiArpeggiator | `:arp [mode] [step] [oct] [gate]`, `:arp live` |
| LFO write to automation (PakettiAutomation "LFO Write…") | curve generator, types lfo/podkat/follow (sin/tri/saw/sqr/rnd) |
| Uxx/Dxx/Gxx/vibrato/arp/volume-slide/retrig/probability/tempo effect cmds | `jf_tracker_cmds.lua` U D G 4 0 A R P F B |
| Equal slicing 2..64, transient slicing, BPM-from-length | slicer tab buttons; BPM list from item length/metadata |
| Strip silence | autotrim |
| Beatsync per slice (SlicePro), double/halve beatsync | Txx / beatsync property (`:beatsync beat\|bar\|N`) |
| Sample offset Sxx / Fit offset to pattern | Sxx = slice or offset |
| REX / RX2 / XRNI loaders | import in the browser (Enter) |
| Find note next/prev | `/` search by name/note/command, `n N *` |
| Fuzzy track/sample/action search, Autocomplete | fzf everywhere, `:!` / `\ a` over Main actions |
| Pattern matrix duplicate / clone / mute slots, sequence queue (Tkna "schedule") | matrix Vim grammar, cln/dup/alias, `MX.queued` |
| LPB double/halve, keyboard velocity, octave | `+ -`, `c C`, `z x`, Cmd+wheel LPB zoom |
| Capture last take, sample recorder, overdub | jf_rec retro, rec tab |
| Legato fill | `:legato` |
| Note transposition ±1/±12 (PlayerPro transpose) | `^A ^X`, `r{note}`, count prefix |
| Fade in/out, ramps on envelopes | `:fade`, `:ramp`, `/ \` |
| Insert/delete time in pattern | `:deltime`, `:instime`, BS/INS |

---

## Candidates (prioritized within each group; ★ = in the top 10)

Size: S ≈ <150 lines, M ≈ 150–500, L ≈ >500.

### A. Pattern editing (selection operators)

1. ★ **Interpolate selection.** File: `PakettiRequests.lua`: `volume_interpolation`, `note_interpolation`, plus pan/delay/sample-FX variants (~l.2664, 7980). `PakettiImpulseTracker.lua`: "ALT-X Smart (Auto-detect Column)" (interpolate and clear).
   - What it does: makes a linear ramp from the first value of the selection to the last, across volume, delay, pan, note or effect amount.
   - REAPER mapping: VISUAL block in the vol/delay field. Rewrite item vol (`D_VOL`·take) or MIDI velocity on each event in the block. On the delay field, rewrite the position offset. On a cmd column, rewrite the `jf_cmds` xx then `C.rebuild`. On an env column `:ramp` already does this.
   - Size: S. Risk: the delay field changes the item position, so each item has to be renamed unique the way jf already does for offsets.

2. ★ **Humanize + Wonkify.** Files: `PakettiRequests.lua`: `humanizeSelection(delay, vol, pan)` and Quick Humanize 5/10/20. `PakettiWonkify.lua`: `PakettiWonkifyPattern`, `PakettiWonkifyApplySwingTemplate`, `PakettiWonkifyApplyScaleAwarePitchDrift`, `PakettiWonkifyGenerateRandomEffect`, plus presets SubtleHumanize / DrunkGroove / LoFiGrit / Glitchy / Chaos.
   - What it does: random drift of delay, velocity and pan. Wonkify adds scale-aware pitch drift, row drift, ghost notes, retrigs, random effects and swing templates.
   - REAPER mapping: positions and vol of items or MIDI notes in the region or VISUAL block. Ghosts become extra items or notes at low vol. Retrig becomes `Rxy` in `jf_cmds`. Swing becomes a position offset on odd rows (REAPER groove templates are an alternative).
   - Size: S for `:humanize [amt]`, M for `:wonk preset`. Risk: keep one undo block. Pitch drift on audio is D_PITCH; it needs the scale from jf_angle or the user.

3. ★ **Chord tools.** File: `PakettiChordsPlus.lua`:
   - `DistributeNotes("even2"/"even4"/"uneven")` and `SpreadNotesVertically(n)`: strum a chord over rows.
   - `cycle_inversion("up"/"down")`: chord inversion.
   - `RandomizeVoicing`
   - `NoteSorterAscending/Descending`
   - "Random Chord", "Next Chord in List"

   What it does: works on the chord in the subcolumns of a row. Strum moves notes 1..n down by k rows or by delay; inversion moves the lowest note +12.

   REAPER mapping: subcolumn notes are MIDI notes in one item, or audio items with D_PITCH. Change the pitch or position in place.

   Size: S each (M as a set). Risk: subcolumn order must stay stable after a re-sort.

4. **Extract line / explode.** Files: `PakettiChordsPlus.lua`: `ExtractBassline`, "Extract Highest Note to New Track", "Duplicate Lowest/Highest Notes to New Track". `PakettiRequests.lua`: `explode_notes_to_tracks` (one track per pitch).
   - What it does: moves the bass or top line of chords to a new track, or splits drums by pitch.
   - REAPER mapping: new track (InsertTrackAtIndex), copy items or notes. For MIDI, REAPER has a native "Item: Explode MIDI note rows (pitch) to new items". Look up the ID by name; don't hard-code it.
   - Size: S.

5. ★ **Reverse / rotate / shuffle selection.** File: `PakettiRequests.lua`: `PakettiReverseNotesInSelection` (retrograde), `rotate_track_content_to_selection_start_first`, `randomize_notes_in_selection` ("Roll the Dice": the same notes on shuffled positions), `random_note_offs_to_empty_rows`. `PakettiPatternEditor.lua`: `randomly_raise_selected_notes_one_octave(p)`.
   - What it does: retrograde, cyclic rotate and positional shuffle of events in a block.
   - REAPER mapping: rewrite the positions of items or notes inside the block (row → time). Rotate wraps at the region end.
   - Size: S. Risk: items that cross the block end must be clipped or skipped.

6. ★ **Pattern expand / shrink ×2 ÷2.** File: `PakettiPatternEditor.lua`: `resize_pattern(pattern, lines, …)` (dBlue Expand/Shrink ± Resize, ~l.1290–1310), `pakettiPatternDoubler`, Halver, `cloneAndExpandPatternToLPBDouble`.
   - What it does: content plays at half or double speed. Doubler repeats the pattern into double length.
   - REAPER mapping: positions relative to the region start ×2 or ÷2, region end ×2 or ÷2, then `shift_after` for the following regions. Audio lengths are kept (one-shot) or scaled by option. MIDI: `MIDI_SetNote` ppq ×2. Envelopes: scale point times. Doubler = region length ×2 plus a copy of the content (an alias exists).
   - Size: M. Risk: shifting the song after the region uses the existing `alias.shift_after`. Looped items and automation items need care.

7. **Replicate selection to region end.** File: `PakettiImpulseTracker.lua`: "ALT-F Expand Selection Replicate". `PakettiRequests.lua`: "Flood Fill with Selection". `PakettiPatternEditor.lua`: `pakettiFloodFill` ("Flood Fill Note and Instrument every N").
   - What it does: tiles the yanked block (or the note on the cursor row) every N rows to the end of the region.
   - REAPER mapping: repeated `E.paste` at row + k·len, in one undo block.
   - Size: S.

8. **Write notes ascending / descending / random.** Files: `PakettiPatternEditor.lua`: `writeNotesMethod("ascending"|"descending"|"random")`. `PakettiSubColumnModifier.lua`: the same per subcolumn (vol/pan/delay).
   - What it does: overwrites the selected rows with a run of notes or values.
   - REAPER mapping: set pitch or vol per event in the VISUAL block.
   - Size: S.

9. **Match column to current row.** File: `PakettiPatternEditor.lua`: `match_volume_to_current_row`, plus delay/pan/effect variants (All rows / Forward).
   - What it does: copies the vol, delay or pan of the cursor row to all events of the track in the region, or only to rows after the cursor.
   - REAPER mapping: set D_VOL or velocity, or position offset, per event.
   - Size: S.

10. **Clever note-off / gate %.** File: `PakettiPatternEditor.lua`: `CleverNoteOff("HalfBefore"|"RightBefore"|"RightAfter")`.
    - What it does: places a note-off between each note and the next one. It is the counterpart of legato.
    - REAPER mapping: D_LENGTH of each item, or the MIDI note end, set to a fraction of the gap to the next event. Expose as `:gate 50%` next to `:legato`.
    - Size: S.

### B. Generators / fills

11. ★ **Fill with euclid / density / scale.** File: `PakettiFill.lua`: `PakettiFillApplyFill`, `PakettiFillGenerateEuclideanPattern(events, len)`, `PakettiFillShouldFillLine`, `PakettiFillGenerateRandomMappedNote` (notes only from mapped slices/keyzones).
    - What it does: fills the track region or block with hits, using euclid k/n, density %, every-N, or "where empty". Notes come from a range or the instrument's slices, with optional random effects.
    - REAPER mapping: insert lib items with `E.insert_slice`. A "slices" source picks random Sxx. MIDI notes go into the MIDI item. Example: `:fill euclid 5 16 [slices|C-4..C-5]`.
    - Size: M. Risk: none special. Orca already has a euclid operator, so reuse its function.

12. **Tuplet writer.** File: `PakettiTupletGenerator.lua`: `generate_pattern(note_count, row_count)`, `calculate_delay` (delay = (i−1)·255/n).
    - What it does: places N notes evenly over M rows using delay values.
    - REAPER mapping: jf has a delay field of xx/256 per row, so the positions are exact time. Example: `:tuplet 3 4`.
    - Size: S.

13. **Equation → column / envelope.** File: `PakettiEquationCalculator.lua`: `PakettiEquationCalculatorEvaluate(eq, t)`, `…ApplyWaveform`.
    - What it does: evaluates a formula f(t) over the selection and writes it to volume, delay or pan.
    - REAPER mapping: velocity or D_VOL per event, or envelope points (an `expr` type in the curve generator). Example: `:expr sin(t*pi*2)*0.5+0.5`.
    - Size: S–M. Risk: `load()` needs a sandboxed env with only `math`.

14. **Gater / step envelope (Steppers, HyperEdit).** Files: `PakettiGater.lua` (16/32-step volume / retrig / pan gate rows). `PakettiSteppers.lua` (pitch / vol / pan / cutoff step modulators). `PakettiHyperEdit.lua` (8 rows × parameter step sequencer).
    - What it does: draws per-step values for a parameter.
    - REAPER mapping: a "steps" type in the curve generator. It writes square-shaped points (shape 1) per row into the track, take or FX-param envelope, or into an automation item, so it can loop. A volume gate on a take writes the take Volume envelope.
    - Size: M. Risk: overlaps with the LFO sqr/rnd type, so it should be a mode of the same panel.

### C. Sample / slice processing

15. ★ **Slices to pattern (break reconstruction).** Files: `PakettiOldschoolSlicePitch.lua`: `pakettiSlicesToPattern(from_first_row, detected_bpm)`, `pakettiSlicesToPatternEvenly`, `pakettiSlicesToPatternBeatsyncOnly`. `PakettiSlice.lua`: `WipeSliceAndWrite`, `createPatternSequencerPatternsBasedOnSliceCount`.
    - What it does: writes all slices of a sample in order. They go either at their natural positions (the break plays as recorded, quantized to rows plus delay) or one per step.
    - REAPER mapping: loop over `E.item_slices`, `E.insert_slice` at row = slice_offset·BPM. This is a one-shot version of the "step auto stitches slices" logic. Example: `:slices write [even]`.
    - Size: M.

16. ★ **Zero-crossing snap.** File: `PakettiZeroCrossings.lua`: "Snap Selection to Zero Crossings", Zero Cross Wipe&Slice N, "Randomize Slice Positions", and Move Slice Start/End ±1/4..1/32 beat.
    - What it does: moves slice points to the nearest zero crossing (no clicks). It also nudges slice edges by beat fractions.
    - REAPER mapping: an AudioAccessor read around each `jf_slices` point, then search for a sign change. Add a "zc" toggle next to the snap button. Nudge keys move the slice start/end by beat/N.
    - Size: S–M.

17. **Curved / random / BPM slicing.** File: `PakettiSlice.lua`: "Curved Slice Creator", "Random Slice Distribution", `pakettiBPMBasedSlice(bpm, beats_per_slice)` (½…8 beats).
    - What it does: slice spacing that is exponential (accelerando), random, or N beats at a given BPM.
    - REAPER mapping: generate the `jf_slices` list. Add buttons beside 2..64.
    - Size: S.

18. **Gap fill after slowing down (Oldschool slice pitch).** File: `PakettiOldschoolSlicePitch.lua`: `detectGapsInSample`, `fillGapWithReversedAudio`, `fillGapWithPingPongLoop`, `fillGapWithCopiedAudio`, `pakettiOldschoolSlicePitchWorkflow`.
    - What it does: when a sliced break plays slower than its tempo, the silence between a slice end and the next note is filled with a reversed or ping-pong tail. This is the jungle/oldschool trick.
    - REAPER mapping: for each slice note whose item ends before the next note, add a generated item (P_EXT jf_gen, like Rxy) over the gap. Its source is the tail of the slice with take reverse (action "Item properties: Toggle take reverse" on a temporary selection). Ping-pong uses alternating reversed copies.
    - Size: M. Risk: take reverse is only an action, so selection juggling is needed. The generated items must be rebuilt on edits, which the existing `jf_gen` path does.

19. **Per-sample / per-slice processing.** File: `PakettiProcess.lua`: Normalize Sample Slices Independently, Reverse Selected Sample or Slice, Convert Stereo→Mono (Keep L / Keep R / Mix), Duplicate Selected Sample at ±12/±24. `PakettiSamples.lua`: Flip Sample by 1/16…1/2 (rotate), Destructive Repeat. `PakettiAudioProcessing.lua`: Move Beginning Silence to End, Phase Inversion.
    - REAPER mapping:
      - normalize: take vol from peak (`NF_GetMediaItemMaxPeak`, or the native normalize action)
      - mono: `I_CHANMODE` 2/3/4
      - reverse: take reverse
      - rotate: D_STARTOFFS + B_LOOPSRC
      - invert phase: take FX or `I_CHANMODE`
    - Size: S each.

### D. Automation

20. ★ **Envelope selection ops.** File: `PakettiAutomation.lua`: `FlipAutomationHorizontal` / Vertical, `ScaleAutomation(0.5…2.0)`, `randomize_envelope`, `automation_ramp_up_exp` / lin, center↔top/bottom presets, "Set Automation Range to Min/Mid/Max", "Flood Fill Automation Selection", "Replicate at Cursor".
    - What it does: transforms the envelope points inside the VISUAL rows.
    - REAPER mapping: `GetEnvelopePointEx` / `SetEnvelopePointEx` on the env column inside the row range. Flip H mirrors times, flip V gives 1−v, scale is around the centre. Replicate tiles the points to the region end.
    - Size: S. Risk: automation items need `autoitem_idx`.

21. **Snapshot FX params to automation.** File: `PakettiAutomation.lua`: `snapshot_all_devices_to_automation`.
    - What it does: writes a point for every parameter of the track FX at the cursor row. It works as a scene snapshot.
    - REAPER mapping: `GetFXEnvelope(tr, fx, p, true)` plus `InsertEnvelopePoint` at the row time. Limit it to parameters that were touched or are in a DSP block, or the project fills with envelopes.
    - Size: S.

22. **Automation from notes.** File: `PakettiAutomation.lua`: "Generate Automation Points from Notes in Selected Track".
    - What it does: writes an envelope point at each note, with value = velocity (or pitch).
    - REAPER mapping: read events from the model, insert points on the chosen env column (square shape).
    - Size: S.

### E. Workflow / navigation

23. **Tempo ramp between patterns.** File: `PakettiPatternEditor.lua`: `PakettiTempoInterpolateCurrentToNext`.
    - What it does: a linear BPM ramp from this region to the next.
    - REAPER mapping: `SetTempoTimeSigMarker` at both region starts with linear shape (lineartempo = true).
    - Size: S.

24. **Loop markers in pattern names.** File: `PakettiPatternNameLoop.lua` ("[" start, "]" end, "[]" single).
    - What it does: the loop range follows the region names.
    - REAPER mapping: `:loop names` finds regions with [ ] and sets `GetSet_LoopTimeRange` on play or on a key. It fits the existing `:loop region`.
    - Size: S.

25. **Clearance.** File: `PakettiClearance.lua`: `findUsedInstruments`, Delete Unused Instruments / Samples, Remove Empty Tracks.
    - What it does: removes lib samples that no note uses, and empty tracks.
    - REAPER mapping: census by `P_EXT:jf_iid` vs. lib items after =LIB, then delete. Tracks with no items, FX or envelopes are removed.
    - Size: S. Risk: must not fight the "samples are kept" rescue (`E.no_rescue`).

26. **Render region / selection to a lib sample.** File: `PakettiRender.lua`: `pakettiCleanRenderSelection(muteOriginal, justwav, newtrack, …)`, Render Pattern Selection (New Track / Mute Original).
    - What it does: resamples a track or selection into a new sample.
    - REAPER mapping: set the time selection to the region, select the track, run the native "Render tracks to stereo stem tracks" or apply track FX / glue. Then `E.depot_add` the result to the lib.
    - Size: M. Risk: the render actions take time and change the selection, so state has to be saved and restored. Test only in the sandbox project.

27. **Small fun ones.**
    - "Play at Random Line in Current Pattern" and "Jump Forward/Backward Within Song by Random" (`PakettiRequests.lua`): seek to a random row. S.
    - "Oblique Strategies" card in the status line: S.
    - "Record+Follow+Metronome Precount N Bar": native count-in toggle plus record. S.

### F. Import / export

28. ★ **WAV cue markers ↔ slices.** File: `PakettiWavCueExtract.lua`: `PakettiWavCueParseWavCues(path)`, `…ImportWavWithCuesIntoSample`, `…BuildCueChunk`, `…WriteCueChunksToWav`, `PakettiBatchOTToWavCue`.
    - What it does: reads the RIFF `cue ` chunk as slice points; the export side writes them back.
    - REAPER mapping:
      - Import: a pure Lua RIFF reader puts the points into `P_EXT:jf_slices` on browser drop or Enter (next to the REX/XRNI import).
      - Export: append a cue chunk to a copy of the file. REAPER also reads cue markers as media cues, which could be cross-checked.
    - Size: S import, M export.

29. **Octatrack .ot slices import / export.** File: `PakettiOTExport.lua`: `read_ot_file`, `write_ot_file`, `make_ot_table`, `apply_ot_slices_to_sample_direct`.
    - What it does: reads and writes the .ot sidecar with up to 64 slices, tempo and trim.
    - REAPER mapping: the .ot sits beside the WAV. On import, the slices go to `jf_slices`. On export, the lib sample's `jf_slices` become the .ot.
    - Size: M. Only worth it if hardware use is planned.

30. **MOD / XM import into a jf_tracker project.** Files: `PakettiMODLoader.lua`, `PakettiXMImport.lua` (binary readers, sample → WAV writer).
    - What it does: imports a tracker module.
    - REAPER mapping: the samples become WAV files in the lib, patterns become regions, channels become tracks, notes become items with D_PITCH, and Cxx/ECx become vol/length.
    - Size: L. It is iconic for a tracker view. Risk: effects map only partly. Speed/tempo (Fxx) maps through the existing Fxx command.

31. **Stem loader.** File: `PakettiStemLoader.lua`.
    - What it does: loads a folder or multi-select of stems, each onto its own track at the cursor bar, in one undo.
    - REAPER mapping: the browser multi-select drop uses `InsertMedia` with the add-new-track flag.
    - Size: S.

---

## Top 10 (overall priority)

1. Interpolate selection (vol/delay/pan/note/cmd): #1
2. Humanize + Wonkify (`:humanize`, `:wonk preset`): #2
3. Chord tools (strum/distribute, inversion, voicing, sort): #3
4. Fill with euclid/density/slices (`:fill`): #11
5. Slices to pattern, i.e. break reconstruction (`:slices write [even]`): #15
6. Reverse / rotate / shuffle selection: #5
7. Pattern expand/shrink ×2 ÷2 and doubler: #6
8. Envelope selection ops (flip, scale, randomize, curve presets): #20
9. Zero-crossing snap and beat-fraction slice nudge: #16
10. WAV cue markers ↔ slices: #28

The next tier: gate% / clever note-off (#10), tuplet writer (#12), tempo ramp (#23), gap fill (#18), render to lib (#26).

## Deliberately skipped

- **Phrases** (PhraseEditor/Workflow/Generator, Stacker phrases, Gater/8120 "to phrase"): REAPER has no instrument-local phrase. A region or alias already plays that role.
- **Keyzones, velocity layers, sample slots** (KeyzoneDistributor, Stacker velocity mapping, sample velocity ranges, "Add 84 sample slots"): there is no instrument/keyzone model. jf slices cover what makes sense.
- **Renoise instrument properties** (autofade, autoseek, interpolation, oversampling, FX/mod groups, mod sets, exit-loop note-off, loop modes): these are internals of the Renoise sampler with no item equivalent. The few that map (loop, fades) are already in the item panel.
- **Renoise native devices** (Gainer A/B, Hydra, Key Tracker, LFO→Gainer chains, DeviceChains, Preset++, LoadDevices/Plugins, EQ30, CCizer): these are device-specific. jf has the DSP panel and fx list instead.
- **Groovebox 8120 / Slice Step Sequencer / Multitap**: large dialog UIs. Step sequencing is better served by the monome grid, Orca and the matrix in jf.
- **Renoise view / window switching** (DynamicViews, IT F2..F12 frames, Views, ThemeSelector, Canvas fonts): REAPER has no equivalent windows. jf has its own tabs and themes.
- **MIDI mappings, KeyBindings, ActionSelector, Autocomplete**: these are Renoise binding infrastructure. jf has its midimap tab and fzf.
- **Hardware exports** (Polyend PTI, Digitakt, M8, OP-1, Akai S900/S1000/S3000/MPC2000, ITI/XI export, OctaCycle): niche formats. .ot is listed above as optional.
- **Sample synthesis** (PCMWriter, Wavetabler, Chebyshev waveshaper, Sample Effect Generator, Image→Sample, AKWF, eSpeak): these write sample data. That would mean generating WAV files, which is outside the tracker's native-data scope. AKWF could at most be a browser bookmark.
- **Sample-format loaders** (SF2, IFF/8SVX, WT, Akai programs, XRNS probe): low value against the REX/XRNI imports that already exist. SF2 would need a keyzone model.
- **ZDxx pattern delay, Pattern Delay Viewer, Beat Structure / Metric Modulation editors**: these are bound to Renoise's line/tick timing model. jf works in continuous time, so they reduce to the tempo map.
- **Global groove → delay**: REAPER groove templates and humanize (#2) cover it.
- **OctaMED pick/put slots, hold-to-fill, note echo**: Vim registers and macros cover pick/put. Note echo is close to Rxy and the replicate idea in #7.
- **Recorder / overdub / Capture Last Take / AutoSamplify**: jf_rec retro and the rec tab exist.
- **Sections/sequence scheduling (Tkna), PatternSequencer sort/clear**: the matrix queue and Vim slot editing exist. "Wipe empty patterns from end" could be a one-liner if wanted.
- **YT-DLP / VideoSlicer / StemSlicer, Sononymph, LaunchApp**: external tools that depend on PATH (see the ExecProcess PATH issue) and are not tracker features.
- **BeatDetect**: unfinished upstream ("TODO Finish").
- **Switcharoo reharmonizer, Chords progression player**: L-sized dialogs. They could come later on top of the chord tools (#3).
