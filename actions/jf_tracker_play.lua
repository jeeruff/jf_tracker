-- jf_tracker: transport: play / stop (button) - an action for the native REAPER learn (MIDI CC / OSC / shortcut), 12 ноя.
-- Значение → трекер через ExtState jf_tracker/in (строка «цель режим разрешение значение»).
local _, _, _, _, mode, res, val = reaper.get_action_context()
reaper.SetExtState('jf_tracker', 'in', reaper.GetExtState('jf_tracker', 'in') .. ('slicer:play %d %d %s\n'):format(mode or -1, res or 127, tostring(val or 0)), false)
