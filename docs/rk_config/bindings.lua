---@type Definition
local global = { -- applies both to main and midi
	timeline_motion = {
		["0"] = "ProjectStart",
		["<return>"] = "ProjectStart",
		["<C-$>"] = "ProjectEnd",
		["f"] = "PlayPosition",
		["x"] = "MousePosition",
		["["] = "LoopStart",
		["]"] = "LoopEnd",
		["<left>"] = "PrevMarker",
		["<right>"] = "NextMarker",
		["<M-left>"] = "PrevTimeSignatureMarker",
		["<M-right>"] = "NextTimeSignatureMarker",
		["<M-h>"] = "Left10Pix",
		["<M-l>"] = "Right10Pix",
		["<M-H>"] = "Left40Pix",
		["<M-L>"] = "Right40Pix",
		["h"] = "LeftGridDivision",
		["l"] = "RightGridDivision",
		["H"] = "PrevMeasure",
		["L"] = "NextMeasure",
		["<C-i>"] = "MoveRedo",
		["<C-o>"] = "MoveUndo",
		["<C-h>"] = "Prev4Beats",
		["<C-l>"] = "Next4Beats",
		["<C-H>"] = "Prev4Measures",
		["<C-L>"] = "Next4Measures",
		["`"] = "MarkedTimelinePosition",
	},
	timeline_operator = {
		["r"] = "Record",
		["<C-p>"] = "DuplicateTimeline",
		["t"] = "PlayAndLoop",
		["|"] = "CreateMeasures",
		["<C-|>"] = "CreateProjectTempo",
	},
	timeline_selector = {
		["~"] = "MarkedRegion",
		["!"] = "LoopSelection",
		["<S-right>"] = "NextRegion",
		["<S-left>"] = "PrevRegion",
		["<CS-right>"] = "TimeSelectionShiftedRight",
		["<CS-left>"] = "TimeSelectionShiftedLeft",
		["i"] = {
			"+inner",
			{
				["<M-w>"] = "AutomationItem",
				["l"] = "AllTrackItems",
				["r"] = "Region",
				["p"] = "ProjectTimeline",
				["w"] = "Item",
				["W"] = "BigItem",
			},
		},
	},
	visual_timeline_command = {
		["v"] = "SetModeNormal",
		["o"] = "SwitchTimelineSelectionSide",
	},
	command = {
		["<M-x>"] = "ShowActionList",
		["<CM-x>"] = "ShowBindingList",
		["<ESC>"] = "Reset",
		["<S-<ESC>>"] = "ClearTimeSelection",

		["tt"] = "PlayFromTimeSelectionStart",
		["<C-T>"] = "PlayAndSkipTimeSelection",
		["<M-t>"] = "PlayFromMousePosition",
		["<M-T>"] = "PlayFromMouseAndSoloTrack",
		["<C-t>"] = "PlayFromEditCursorAndSoloTrackUnderMouse",
		["F"] = "Pause",

		["<C-<SPC>>"] = "ShowMixer", -- remove in 2.1

		-- *** CUSTOM: SPC = play/stop, SPC SPC = Leader key ***
		["<SPC>"] = {
			"+space",
			{
				["<SPC>"] = {
					"+leader commands",
					{
						q = {
							"+quit",
							{ q = "QuitReaper" },
						},
						["?"] = "OpenBindingsConfig",
					},
				},
			},
		},

		["."] = "RepeatLastCommand",
		["<C-.>"] = "RepeatPenultimateAction",
		["@"] = "PlayMacro",
		[","] = "RecordMacro",
		["m"] = "Mark",
		["~"] = "MarkedRegion",
		["<C-'>"] = "DeleteMark",
		["<S-right>"] = "NextRegion",
		["<S-left>"] = "PrevRegion",
		["<C-r>"] = "Redo",
		["u"] = "Undo",
		["R"] = "ToggleRecord",
		["<C-z>"] = "ZoomUndo",
		["<C-Z>"] = "ZoomRedo",
		["v"] = "SetModeVisualTimeline",
		["<M-v>"] = "ClearTimelineSelectionAndSetModeVisualTimeline",
		["X"] = "MoveToMousePositionAndPlay",
		["dr"] = "RemoveRegion",
		["!"] = "ToggleLoop",
		["<C-a>"] = "SelectAllItems",   -- Cmd+A: select items, never envelope points
		["A"] = "ToggleShowActiveFxEnvSelTracks",  -- Shift+A: активные огибающие выделенных треков
		["<W-a>"] = "ToggleBetweenReadAndTouchAutomationMode",  -- Ctrl+A (W = macOS Control)
		["<CM-a>"] = "ToggleBetweenReadAndTouchAutomationMode",  -- was <C-a>
		["<M-n>"] = "ShowNextFx",
		["<M-N>"] = "ShowPrevFx",
		["<M-g>"] = "FocusMain",
		["<M-f>"] = "ToggleShowFx",
		["<M-F>"] = "CloseFx",
		["<CM-f>"] = "MidiLearnLastTouchedFxParam",
		["<CM-m>"] = "ModulateLastTouchedFxParam",
		["<C-m>"] = "TapTempo",

		['"'] = {
			"+snapshots",
			{
				["j"] = "RecallNextSnapshot",
				["k"] = "RecallPreviousSnapshot",
				["D"] = "DeleteAllSnapshots",
				["t"] = "ShowSnapshotsWindow", -- remove in 2.1
				["y"] = "CopyCurrentSnapshot",
				["p"] = "PasteSnapshot",
				["r"] = "RecallCurrentSnapshot",
				["#"] = {
					"+recall #",
					{
						["1"] = "RecallSnapshot1",
						["2"] = "RecallSnapshot2",
						["3"] = "RecallSnapshot3",
						["4"] = "RecallSnapshot4",
						["5"] = "RecallSnapshot5",
						["6"] = "RecallSnapshot6",
						["7"] = "RecallSnapshot7",
						["8"] = "RecallSnapshot8",
						["9"] = "RecallSnapshot9",
					},
				},
			},
		},
		["q"] = {
			"+options",
			{
				["p"] = "TogglePlaybackPreroll",
				["r"] = "ToggleRecordingPreroll",
				["R"] = "ToggleRazorMode",       -- right-drag draws razor areas
				["X"] = "ShowMixer",             -- toggle mixer
				["z"] = "TogglePlaybackAutoScroll",
				["v"] = "ToggleLoopSelectionFollowsTimeSelection",
				["s"] = "ToggleSnap",
				["m"] = "ToggleMetronome",
				["t"] = "ToggleStopAtEndOfTimeSelectionIfNoRepeat",
				["x"] = "ToggleAutoCrossfade",
				["e"] = "ToggleEnvelopePointsMoveWithItems",
				["c"] = "CycleRippleEditMode",
				f = "SoloInFront",
				F = "ResetFeedbackWindow",
				M = "ToggleMasterMonoStereo",
				V = "ToggleVideoWindow",
				["q"] = "NvsdItemView",          -- NVSD item view
				-- цифры = window sets (окна), Shift+цифры = track views (треки)
				["1"] = "LoadWindowSet1",
				["2"] = "LoadWindowSet2",
				["3"] = "LoadWindowSet3",
				["4"] = "LoadWindowSet4",
				["!"] = "LoadTrackView1",
				["@"] = "LoadTrackView2",
				["#"] = "LoadTrackView3",
				["$"] = "LoadTrackView4",
			},
		},
		["i"] = {
			"+insert",
			{
				["f"] = "InsertMediaFile",
				["m"] = "InsertMidiItem",
				["M"] = "InsertOrExtendMidiItem",
				["t"] = "InsertTrackFromTemplate",
				["v"] = "InsertVirtualInstrumentTrack",
				["c"] = "InsertClickTrack",
				["1"] = "InsertTrackFromTemplateSlot1",
				["2"] = "InsertTrackFromTemplateSlot2",
				["3"] = "InsertTrackFromTemplateSlot3",
				["4"] = "InsertTrackFromTemplateSlot4",
			},
		},
		-- *** CUSTOM: Leader key is SPACE (vim/emacs style) ***
		["<SPC>"] = {
			"+leader commands",
			{
				["<SPC>"] = "StartStop", -- spc spc = play/stop
				["?"] = "OpenBindingsConfig",
				["V"] = "ToggleVimLayer", -- leave the vim layer (v is the +view menu)
				h = "JfPmBrowser",
				d = {
					"+duplicate",
					{
						d = "MplSmartDuplicateItems",      -- smart: obeys time selection
						n = "MplSmartDuplicateItemsNTimes",
						g = "MplSmartDuplicateGridRelative",
						b = "MplDuplicateBarRelative",
						t = "MplDuplicateUntilTimeSelEnd",
						i = "DuplicateItems",              -- plain native duplicate
						a = "DuplicateItemsArea",
						e = "MplDuplicateEnvelopePoints",
						T = "CfillionDuplicateTracks",     -- keeps SWS track notes
						x = "BuyOneDuplicateWithInput",    -- asks how many
						f = "MplDuplicatePluginLR",
						m = {
							"+midi events",
							{
								d = "SmartDuplicateEvents",  -- native smart (time sel aware)
								e = "DuplicateEvents",
								s = "MplSmartDuplicateEvents",
							},
						},
					},
				},
				b = {
					"+bounce/render",
					{
						b = "BounceInPlace",
						r = "RenderItemsToNewTake",
						a = "ApplyFxToItemAsNewTake",
						m = "ApplyFxToItemMono",
						M = "ApplyFxToItemMultichannel",
						g = "GlueItems",
						G = "GlueSelectedItemsInTimeSelection",
						t = "RenderTrack",
						p = "RenderProject",
						P = "RenderProjectWithLastSetting",
						f = {
							"+freeze",
							{
								m = "FreezeTrackMono",
								s = "FreezeTrackStereo",
								u = "UnfreezeTrack",
							},
						},
						z = {
							"+razor",
							{
								c = "RazorClearAll",
								e = "RazorEncloseItems",
								E = "RazorEncloseItemsWithGaps",
								s = "RazorSelectItems",
								a = "RazorAreaFromCursorToMouse",
								l = "RazorLoopFromArea",
								m = "RazorEdgeToCursor",
								g = "ToggleRazorGrouping",
								r = "ToggleRazorMode",
							},
						},
					},
				},
				j = {
					"+jf scripts",
					{
						f = "JfTracker",   -- SPC j f: jf_tracker — запустить или перейти к нему (6 окт)
						M = "JfMdx",
						b = {
							"+buffer/perf",
							{
								b = "JfBufferize",
								d = "JfDawsync",
								t = {
									"+buffer size",
									{
										["1"] = "JfBuf64",
										["2"] = "JfBuf128",
										["3"] = "JfBuf256",
										["4"] = "JfBuf512",
										["5"] = "JfBuf1024",
										["0"] = "JfBuf32",
										t = "JfToggleBufferSize",
									},
								},
							},
						},
						c = {
							"+chords",
							{
								c = "JfChordcheat",
								p = "JfChordPrint",
								s = "JfChordsense",
							},
						},
						e = {
							"+edit/items",
							{
								q = "JfQuantumCut",
								a = "JfInsertAutomationItem",
								i = "JfInsertFromNvk",
								v = "JfItemAudioToInvertedVolume",
							},
						},
						i = {
							"+input/midi",
							{
								s = "JfSmartSetInput",
								m = "JfSmartInputMonitor",
								d = "JfDebugMidiRecent",
							},
						},
						p = {
							"+project manager",
							{
								b = "JfPmBrowser",
								c = "JfPmCore",
								h = "JfPmHarvest",
								r = "JfPmReport",
								w = "JfPmWatcher",
							},
						},
						s = {
							"+slixer/sample",
							{
								l = "JfSlixerLoadSample",
								m = "JfSlixerPushMarkers",
								p = "JfSamplepacker",
							},
						},
						t = {
							"+tools",
							{
								t = "JfTranscribe",
								m = "JfModmatrix",
								x = "JfConsoleX2Cycle",
								d = "JfMdx",
							},
						},
						z = {
							"+setup",
							{
								r = "JfRegisterScripts",
								h = "JfSetupHotkeys",
							},
						},
					},
				},

				q = {
					"+quit/clips",
					{
						q = "QuitReaper",
						["<TAB>"] = "TkProjectClips",   -- TK: клипы проекта
					},
				},

				N = "ShowNotesWindow",
				n = {
					"+notes",
					{
						i = "ShowNotesItem",
						t = "ShowNotesTrack",
						p = "ShowNotesProject",
						g = "ShowNotesGlobal",
						m = "ShowNotesMarkerNames",
						M = "ShowNotesMarkerSubtitles",
						r = "ShowNotesRegionNames",
						R = "ShowNotesRegionSubtitles",
					},
				},
				v = {
					"+view",
					{
						[","] = "ShowPreferences",
						['"'] = "ShowSnapshotsWindow",
						a = "ToggleShowMasterTrack",
						A = "ShowFloatingMixerMaster",
						b = "ShowProjectBay",
						c = "ShowBigClock",
						d = "ShowDocker",
						D = "ShowToolbarDocker",
						e = "ShowEnvelopeManager",
						E = "ShowTempoEnvelope",
						f = "AddFx",
						F = "ShowMasterFxChain",
						g = "ShowTrackGroupingMatrix",
						G = "ShowTrackGroupManager",
						i = "BirdBird_FXInspector",
						I = "BirdBird_FXInspectorCapture",
						l = "ShowLayouts",
						m = "ShowMixer",
						M = "ShowMonitoringFx",
						n = "ShowNavigator",
						p = "ShowPerformanceMeter",
						P = "ShowPeaksDisplaySettings",
						r = "ShowRoutingMatrix",
						R = "ShowRegionMarkerManager",
						s = "ShowScaleFinder",
						t = "ShowTrackManager",
						T = "ShowTransport",
						v = "ShowVirtualMidiKeyboard",
						w = "ShowWiringDiagram",
						x = "ShowMediaExplorer",
					},
				},
				["z"] = {
					"+zoom/scroll",
					{
						["t"] = "ScrollToPlayPosition",
						["e"] = "ScrollToEditCursor",
					},
				},
				["m"] = {
					"+midi",
					{
						["g"] = "SetMidiGridDivision",
						["G"] = "ToggleMidiEditorUsesMainGridDivision",
						["q"] = "Quantize",
						["s"] = "ToggleMidiSnap",
					},
				},
				["r"] = {
					"+recording",
					{
						["o"] = "SetRecordMidiOutput",
						["d"] = "SetRecordMidiOverdub",
						["t"] = "SetRecordMidiTouchReplace",
						["R"] = "SetRecordMidiReplace",
						["v"] = "SetRecordMonitorOnly",
						["r"] = "SetRecordInput",
						[","] = {
							"+options",
							{
								["n"] = "SetRecordModeNormal",
								["s"] = "SetRecordModeItemSelectionAutoPunch",
								["v"] = "SetRecordModeTimeSelectionAutoPunch",
								["p"] = "ToggleRecordingPreroll",
								["z"] = "ToggleRecordingAutoScroll",
								["t"] = "ToggleRecordToTapeMode",
							},
						},
					},
				},
				["a"] = {
					"+automation",
					{
						["a"] = "ToggleBetweenReadAndTouchAutomationMode",
						["y"] = "NextEnvelope",
						["Y"] = "PrevEnvelope",
						["r"] = "SetAutomationModeTrimRead",
						["R"] = "SetAutomationModeRead",
						["l"] = "SetAutomationModeLatch",
						["g"] = "SetAutomationModeLatchAndArm",
						["p"] = "SetAutomationModeLatchPreview",
						["t"] = "SetAutomationModeTouch",
						["w"] = "SetAutomationModeWrite",
						["L"] = "jf_insert_automation_item_last_touched",
					},
				},
				["s"] = {
					"+selected items",
					{
						["j"] = "NextTake",
						["k"] = "PrevTake",
						["m"] = "ToggleMuteItem",
						["M"] = "BirdBird_ItemModifiers",
						["d"] = "DeleteActiveTake",
						["c"] = "CropToActiveTake",
						["R"] = "nvk_CREATE_replace",
						["o"] = "OpenInMidiEditor",
						["E"] = "OpenInlineEditor",  -- e is the envelopes submenu
						["n"] = "ItemNormalize",
						["g"] = "GroupItems",
						["q"] = "QuantizeItems",
						["h"] = "HealItemsSplits",
						["s"] = "ToggleSoloItem",
						["B"] = "MoveItemContentToEditCursor",
						x = {
							"+explode takes",
							{
								p = "ExplodeTakesInPlace",
								o = "ExplodeTakesInOrder",
								a = "ExplodeTakesAcrossTracks",
							},
						},
						i = {
							"+implode items",
							{
								p = "ImplodeItemsOnSameTrackIntoTakes",
								o = "ImplodeItemsAcrossTracksIntoTakes",
								a = "ImplodeItemsAcrossTracksIntoOneTrack",
							},
						},
						["S"] = {
							"+stretch",
							{
								["a"] = "AddStretchMarker",
								["d"] = "DeleteStretchMarker",
							},
						},
						["#"] = {
							"+fade",
							{
								["i"] = "CycleItemFadeInShape",
								["o"] = "CycleItemFadeOutShape",
							},
						},
						["t"] = {
							"+transients",
							{
								["a"] = "AdjustTransientDetection",
								["t"] = "CalculateTransientGuides",
								["c"] = "ClearTransientGuides",
								["s"] = "SplitItemAtTransients",
							},
						},
						["e"] = {
							"+envelopes",
							{
								["s"] = "ViewTakeEnvelopes",
								["m"] = "ToggleTakeMuteEnvelope",
								["p"] = "ToggleTakePanEnvelope",
								["P"] = "ToggleTakePitchEnvelope",
								["v"] = "ToggleTakeVolumeEnvelope",
							},
						},
						["f"] = {
							"+fx",
							{
								["a"] = "ApplyFxToItem",
								["p"] = "PasteItemFxChain",
								["d"] = "CutItemFxChain",
								["y"] = "CopyItemFxChain",
								["c"] = "ToggleShowTakeFxChain",
								["b"] = "ToggleTakeFxBypass",
							},
						},
						["r"] = {
							"+rename",
							{
								["s"] = "RenameTakeSourceFile",
								["t"] = "RenameTake",
								["r"] = "RenameTakeAndSourceFile",
								["a"] = "AutoRenameTake",
							},
						},
						["b"] = {
							"+timebase",
							{
								["t"] = "SetItemsTimebaseToTime",
								["b"] = "SetItemsTimebaseToBeatsPos",
								["r"] = "SetItemsTimebaseToBeatsPosLengthAndRate",
							},
						},
						p = {
							"+properties",
							{
								p = "ShowMediaItemProperties",
								s = "ShowMediaItemSourceProperties",
							},
						},
					},
				},
				["t"] = {
					"+track",
					{
						["t"] = "InsertTrackBelow",
						["v"] = "InsertVirtualInstrumentTrack",
						["T"] = "InsertTrackFromTemplate",
						["s"] = "TrackToggleSolo",
						S = "TrackToggleSoloDefeat",
						["m"] = "TrackToggleMute",
						["r"] = "RenameTrack",
						["n"] = "ResetTrackToNormal",
						["z"] = "MinimizeTracks",
						["M"] = "CycleRecordMonitor",
						["F"] = "CycleFolderState",
						["I"] = "SetTrackInputToMatchFirstSelected",
						["y"] = "SaveTrackAsTemplate",
						["x"] = "ToggleShowTrackRouting",
						["p"] = "TrackToggleSendToParent",
						["f"] = {
							"+freeze",
							{
								["m"] = "FreezeTrackMono",
								["s"] = "FreezeTrackStereo",
								["u"] = "UnfreezeTrack",
								["v"] = "ShowTrackFreezeDetails",
							},
						},
					},
				},
				["e"] = {
					"+envelopes",
					{
						l = "ToggleDisplayVisibleEnvelopesInLanes",
						["t"] = "ToggleShowAllEnvelope",
						["a"] = "ToggleArmAllEnvelopes",
						["A"] = "UnarmAllEnvelopes",
						["d"] = "ClearAllEnvelope",
						["v"] = "ToggleVolumeEnvelope",
						V = "TogglePreFxVolumeEnvelope",
						["p"] = "TogglePanEnvelope",
						["w"] = "SelectWidthEnvelope",
						-- P jumps straight to the take pitch envelope, the one
						-- that actually gets used; the rest live under T
						["P"] = "ToggleTakePitchEnvelope",
						["T"] = {
							"+take envelopes",
							{
								["p"] = "ToggleTakePitchEnvelope",
								["v"] = "ToggleTakeVolumeEnvelope",
								["n"] = "ToggleTakePanEnvelope",
								["m"] = "ToggleTakeMuteEnvelope",
							},
						},
						["s"] = {
							"+selected",
							{
								["d"] = "ClearEnvelope",
								["a"] = "ToggleArmEnvelope",
								["y"] = "CopyEnvelope",
								["t"] = "ToggleShowSelectedEnvelope",
								["b"] = "ToggleEnvelopeBypass",
								["s"] = {
									"+shape",
									{
										["b"] = "SetEnvelopeShapeBezier",
										["e"] = "SetEnvelopeShapeFastEnd",
										["f"] = "SetEnvelopeShapeFastStart",
										["l"] = "SetEnvelopeShapeLinear",
										["s"] = "SetEnvelopeShapeSlowStart",
										["S"] = "SetEnvelopeShapeSquare",
									},
								},
							},
						},
					},
				},
				["f"] = {
					"+fx",
					{
						["a"] = "AddFx",
						["c"] = "ToggleShowFxChain",
						["d"] = "CutFxChain",
						["f"] = "nvk_SEARCH",
						["w"] = "nvk_CREATE",
						["h"] = "hackey_trackey",
						["y"] = "CopyFxChain",
						["p"] = "PasteFxChain",
						["b"] = "ToggleFxBypass",
						["i"] = {
							"+input",
							{
								["s"] = "ToggleShowInputFxChain",
								["d"] = "CutInputFxChain",
							},
						},
						["s"] = {
							"+show",
							{
								["1"] = "ToggleShowFx1",
								["2"] = "ToggleShowFx2",
								["3"] = "ToggleShowFx3",
								["4"] = "ToggleShowFx4",
								["5"] = "ToggleShowFx5",
								["6"] = "ToggleShowFx6",
								["7"] = "ToggleShowFx7",
								["8"] = "ToggleShowFx8",
							},
						},
					},
				},
				["T"] = {
					"+timeline",
					{
						["a"] = "AddTimeSignatureMarker",
						["e"] = "EditTimeSignatureMarker",
						["d"] = "DeleteTimeSignatureMarker",
						["s"] = "ShowTempoEnvelope", -- remove in 2.1
						["r"] = "InsertRegionFromTimeSelection",
						["R"] = "InsertRegionFromSelectedItems",
						["n"] = "EditRegion",
						["D"] = "RemoveRegion",
						["m"] = "ShowRegionMarkerManager",
						["x"] = "DeleteTimeline",       -- ripple-delete the time selection
						["X"] = "RemoveTimeSelection",  -- clear contents, keep the gap
						["u"] = "ClearTimeSelection",   -- just unselect the time range
					},
				},
				["g"] = {
					"+global",
					{
						["g"] = "SetGridDivision",
						["r"] = "ResetControlDevices",
						[","] = "ShowPreferences", -- remove in 2.1
						["S"] = "UnsoloAllTracks",
						["s"] = {
							"+show/hide",
							{ -- remove in 2.1
								["x"] = "ShowRoutingMatrix", -- remove in 2.1
								["w"] = "ShowWiringDiagram", -- remove in 2.1
								["t"] = "ShowTrackManager", -- remove in 2.1
								["f"] = "ShowMonitoringFx", -- remove in 2.1
								["m"] = "ToggleShowMasterTrack", -- remove in 2.1
								["M"] = "ToggleMasterMonoStereo", -- remove in 2.1
								["r"] = "ShowRegionMarkerManager", -- remove in 2.1
							},
						},
						["f"] = {
							"+fx",
							{
								["x"] = "CloseAllFxChainsAndWindows",
								["c"] = "ShowMasterFxChain", -- remove in 2.1
							},
						},
						["e"] = "ToggleShowAllEnvelopeGlobal",
						["a"] = {
							"+automation",
							{
								["r"] = "SetGlobalAutomationModeTrimRead",
								["l"] = "SetGlobalAutomationModeLatch",
								["p"] = "SetGlobalAutomationModeLatchPreview",
								["t"] = "SetGlobalAutomationModeTouch",
								["R"] = "SetGlobalAutomationModeRead",
								["w"] = "SetGlobalAutomationModeWrite",
								["S"] = "SetGlobalAutomationModeOff",
							},
						},
					},
				},
				["p"] = {
					"+project",
					{
						D = "jf_dawsync",
						[","] = "ShowProjectSettings",
						["n"] = "NextTab",
						["p"] = "PrevTab",
						s = "SaveProject",
						S = "SaveProjectAs",
						v = "SaveProjectWithNewVersion",
						["o"] = "OpenProject",
						["c"] = "NewProjectTab",
						["x"] = "CloseProject",
						["C"] = "CleanProjectDirectory",
						["t"] = {
							"+timebase",
							{
								["t"] = "SetProjectTimebaseToTime",
								["b"] = "SetProjectTimebaseToBeatsPos",
								["r"] = "SetProjectTimebaseToBeatsPosLengthAndRate",
							},
						},
						r = "RenderProject",
						R = "RenderProjectWithLastSetting",
					},
				},
			},
		},
	},
}

---@type Definition
local main = {
	track_motion = {
		["G"] = "LastTrack",
		gg = "ToTrack",
		["J"] = "NextFolderNear",
		["K"] = "PrevFolderNear",
		["/"] = "MatchedTrackForward",
		["?"] = "MatchedTrackBackward",
		["n"] = "NextTrackMatchForward",
		["N"] = "NextTrackMatchBackward",
		[":"] = "TrackWithNumber",
		["j"] = "NextTrack",
		["k"] = "PrevTrack",
		["<C-b>"] = "Prev10Track",
		["<C-f>"] = "Next10Track",
		["<C-d>"] = "Next5Track",
		["<C-u>"] = "Prev5Track",
	},
	visual_track_command = {
		["V"] = "SetModeNormal",
		["<C-h>"] = "NudgeTrackPanLeft",
		["<C-l>"] = "NudgeTrackPanRight",
		["<C-H>"] = "NudgeTrackPanLeft10Times",
		["<C-L>"] = "NudgeTrackPanRight10Times",
	},
	track_selector = {
		["'"] = "MarkedTracks",
		["f"] = "Folder",
		["F"] = "FolderParent",
		["i"] = {
			"+inner",
			{
				["c"] = "InnerFolder",
				["f"] = "InnerFolderAndParent",
				["g"] = "AllTracks",
			},
		},
	},
	track_operator = {
		['"'] = {
			"+snapshots",
			{
				["s"] = "SaveTracksToCurrentSnapshot",
				["c"] = "CreateNewSnapshotWithTracks",
				["d"] = "DeleteTracksFromCurrentSnapshot",
			},
		},
		["z"] = "ZoomTrackSelection",
		["Z"] = "ZoomTrackSelectionMinimizeOthers", -- the old z: squashes the rest
		["<C-f>"] = "MakeFolder", -- Moved from TAB to Ctrl+F
		["d"] = "CutTrack",
		["a"] = "ArmTracks",
		["s"] = "SelectTracks",
		["S"] = "ToggleSolo",
		["M"] = "ToggleMute",
		["y"] = "CopyTrack",
		["<M-C>"] = "ColorTrackGradient",
		["<M-c>"] = "ColorTrack",
	},
	timeline_operator = {
		["s"] = "SelectItemsAndSplit",
		["<M-p>"] = "CopyAndFitByLooping",
		["<M-s>"] = "SelectEnvelopePoints",
		["d"] = "CutItems",
		["y"] = "CopyItems",
		["<C-c>"] = "CopyItems",
		["<M-d>"] = "CutEnvelopePoints",
		["<M-y>"] = "CopyEnvelopePoints",
		["<C-D>"] = "DeleteTimeline",
		["g"] = "GlueItems",
		["#"] = "SetItemFadeBoundaries",
		["z"] = "ZoomTimeSelection",
		["Z"] = "ZoomTimeAndTrackSelection",
		["<M-a>"] = "InsertAutomationItem",
		["c"] = {
			"+change/fit",
			{
				["a"] = "InsertOrExtendMidiItem",
				["c"] = "FitByLoopingNoExtend",
				["f"] = "FitByLooping",
				["p"] = "FitByPadding",
				["s"] = "FitByStretching",
			},
		},
	},
	timeline_selector = {
		["s"] = "SelectedItems",
	},
	timeline_motion = {
		["<CM-l>"] = "NextTransientInItem",
		["<CM-h>"] = "PrevTransientInItem",
		["<CM-L>"] = "NextTransientInItemMinusFadeTime",
		["<CM-H>"] = "PrevTransientInItemMinusFadeTime",
		["B"] = "PrevBigItemStart",
		["E"] = "NextBigItemEnd",
		["W"] = "NextBigItemStart",
		["<M-b>"] = "PrevEnvelopePoint",
		w = "NextItemStart",
		e = "NextItemEnd",
		b = "PrevItemStart",
		["<M-w>"] = "NextEnvelopePoint",
		["^"] = "FirstItemStart",
		["$"] = "LastItemEnd",
		["("] = "TimeSelectionStart",
		[")"] = "TimeSelectionEnd",
	},
	command = {
		[">"] = "TrimItemRightEdge",
		["<"] = "TrimItemLeftEdge",
		["<C-f>"] = "CycleFolderCollapsedState", -- Moved from TAB to Ctrl+F
		["<TAB>"] = "TabToNextTransient", -- Pro Tools style: Tab to next transient
		["<S-<TAB>>"] = "TabToPreviousTransient", -- Pro Tools style: Shift+Tab to previous transient
		["zp"] = "ZoomProject",
		["D"] = "CutSelectedItems",
		["Y"] = "CopySelectedItems",
		["V"] = "SetModeVisualTrack",
		["<M-j>"] = "NextEnvelope",
		["<M-k>"] = "PrevEnvelope",
		["<C-+>"] = "ZoomInVert",
		["<C-->"] = "ZoomOutVert",
		["+"] = "ZoomInHoriz",
		["-"] = "ZoomOutHoriz",
		[";"] = "MoveItemToEditCursor",
		["dd"] = "CutTrack",
		["aa"] = "ArmTracks",
		["O"] = "EnterTrackAbove",
		["o"] = "EnterTrackBelow",
		["p"] = "Paste",
		["<C-v>"] = "Paste",
		["yy"] = "CopyTrack",
		["zz"] = "ScrollToSelectedTracks",
		-- Вне слоя этот экшен висел на Z; слой перехватывает букву,
		-- поэтому внутри него он живёт в z-пространстве зума (s = smarter).
		["zs"] = "SmarterZoom",
		["%"] = "SplitItemsAtEditCursor",
		["~"] = "MarkedTracks",
		["<C-j>"] = "NudgeTrackVolumeDownBy1Tenth",
		["<C-k>"] = "NudgeTrackVolumeUpBy1Tenth",
		["<C-J>"] = "NudgeTrackVolumeDownBy1",
		["<C-K>"] = "NudgeTrackVolumeUpBy1",
		["<CM-j>"] = "ShiftEnvelopePointsDownATinyBit",
		["<CM-k>"] = "ShiftEnvelopePointsUpATinyBit",
		["<CM-J>"] = "ShiftEnvelopePointsDown",
		["<CM-K>"] = "ShiftEnvelopePointsUp",
		["<M-S>"] = "SelectItemsUnderEditCursor",
		["'"] = "MarkedTracks",
	},
}

---@type Definition
local midi = {
	timeline_selector = {
		["s"] = "SelectedNotes",
	},
	timeline_operator = {
		["d"] = "CutNotes",
		["y"] = "CopyNotes",
		["c"] = "FitNotes",
		["g"] = "JoinNotes",
		["s"] = "SelectNotes",
		["z"] = "MidiZoomTimeSelection",
	},
	timeline_motion = {
		["l"] = "RightMidiGridDivision",
		["h"] = "LeftMidiGridDivision",
		["("] = "MidiTimeSelectionStart",
		[")"] = "MidiTimeSelectionEnd",
		["w"] = "NextNoteStart",
		["b"] = "PrevNoteStart",
		["W"] = "NextNoteSamePitchStart",
		["B"] = "PrevNoteSamePitchStart",
		["e"] = "EventSelectionEnd",
	},
	command = {
		-- Without this the MIDI editor falls back to global's <SPC>, whose
		-- <SPC><SPC> opens the leader submenu instead of starting playback.
		["<SPC>"] = {
			"+space",
			{
				["<SPC>"] = "MidiStartStop",   -- 40016: the editor's own play/stop
				["p"] = "MidiPlayPause",
				["!"] = "MidiToggleRepeat",
				["t"] = "MidiGoToPlayCursor",
				["?"] = "OpenBindingsConfig",
				["V"] = "ToggleVimLayer", -- leave the vim layer
			},
		},
		["<C-a>"] = "SelectAllEvents",   -- Cmd+A in the editor = all notes
		["n"] = "AddNextNoteToSelection",
		["N"] = "AddPrevNoteToSelection",
		["+"] = "MidiZoomInVert",
		["-"] = "MidiZoomOutVert",
		["<C-+>"] = "MidiZoomInHoriz",
		["<C-->"] = "MidiZoomOutHoriz",
		["Z"] = "CloseWindow",
		["a"] = "InsertNote",
		["p"] = "MidiPaste",
		["S"] = "UnselectAllEvents",
		["Y"] = "CopySelectedEvents",
		["D"] = "CutSelectedEvents",
		["k"] = "PitchUp",
		["j"] = "PitchDown",
		["K"] = "PitchUpOctave",
		["zp"] = "MidiZoomContent",
		["J"] = "PitchDownOctave",
		["<C-b>"] = "PitchUpOctave",
		["<C-f>"] = "PitchDownOctave",
		["<C-u>"] = "PitchUp7",
		["<C-d>"] = "PitchDown7",
		["V"] = "SelectAllNotesAtPitch",
		["<M-k>"] = "MoveNoteUpSemitone",
		["<M-j>"] = "MoveNoteDownSemitone",
		["<M-K>"] = "MoveNoteUpOctave",
		["<M-J>"] = "MoveNoteDownOctave",
		["<M-l>"] = "MoveNoteRight",
		["<M-h>"] = "MoveNoteLeft",
	},
}

return { ["global"] = global, ["main"] = main, ["midi"] = midi }
