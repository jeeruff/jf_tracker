-- test_params.lua — панель params вкладки modulation на стабах: lua tests/test_params.lua
-- Перечень (огибающие трека + параметры FX), создание / показ огибающей,
-- флаги ACT / ARM, режим used, режим автоматизации, клавиши.
package.path = './?.lua;' .. package.path
local envs = {}                -- ключ → { VISIBLE, ACTIVE, ARM }
local tr = { mode = 0 }
local cmds_run = {}
local function env(key, create)
  if not envs[key] and create then envs[key] = { VISIBLE = '1', ACTIVE = '1', ARM = '0', key = key } end
  return envs[key]
end
_G.gfx = { mouse_x = 0, mouse_y = 0, rect = function() end }
_G.reaper = {
  kbd_getTextFromCmd = function(id) if id == 40406 then return 'Track: Toggle track volume envelope visible' elseif id == 42020 then return 'Track: Toggle track trim envelope visible' end return '' end,
  TrackFX_GetNumParams = function(_, fx) return fx == 0 and 3 or 2 end,
  TrackFX_GetFXName = function(_, fx) return true, 'VST: Fx' .. fx end,
  TrackFX_GetParamName = function(_, fx, p) return true, 'p' .. fx .. p end,
  GetFXEnvelope = function(_, fx, p, create) return env('fx' .. fx .. '.' .. p, create) end,
  GetTrackEnvelopeByName = function(_, n) return envs[n] end,
  GetSetEnvelopeInfo_String = function(e, what, v, set) if set then e[what] = v; return true, v end return true, e[what] end,
  CountEnvelopePoints = function() return 2 end, CountAutomationItems = function() return 1 end,
  TrackFX_GetNamedConfigParm = function(_, fx, key) if fx == 1 and key == 'param.0.mod.active' or fx == 1 and key == 'param.0.lfo.active' then return true, '1' end return true, '0' end,
  TrackFX_GetFormattedParamValue = function() return true, '50%' end,
  GetMediaTrackInfo_Value = function(t) return t.mode end,
  SetMediaTrackInfo_Value = function(t, _, v) t.mode = v end,
  Main_OnCommand = function(id) cmds_run[#cmds_run + 1] = id; if id == 40406 then env('Volume', true) end end,
  TrackList_AdjustWindows = function() end,
  time_precise = function() return os.clock() end,
}
local PP = dofile('jf_tracker_params.lua')
local msgs = {}
local ctx = {
  edit_run = function(_, fn) fn() end, msg = function(s) msgs[#msgs + 1] = s end,
  with_only_track = function(_, fn) fn() end, fit = function(s) return s end,
  fx_addresses = function() return { { fx = 0, prefix = '' }, { fx = 1, prefix = '' } } end,
  mod_add = function(r) envs.modded = r end, mod_goto = function(r) envs.went = r end,
  toggle_track_envs = function() end, envs_shown = function() return false end,
}
local U = { measure = function(s) return #s * 8 end, set = function() end, text = function() end, tint = function(c) return c end }
PP.init(U, ctx)
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end end

local rows = PP.build(tr, ctx.fx_addresses)
eq('rows: 8 track + 5 fx', #rows, 13)
eq('first fx row', rows[9].label, 'Fx0 / p00')
eq('cached build', PP.build(tr, ctx.fx_addresses), rows)
local col = { track = tr, name = 'drums' }
PP.draw({ rh = 16, pad = 4 }, 0, 0, 800, 400, col, true)
eq('shown = all', #PP.shown, 13)
-- fx: Enter на ENV создаёт, второй — прячет
PP.row, PP.col = 9, 2
PP.key(13, col)
eq('fx env created', envs['fx0.0'] ~= nil, true)
PP.key(13, col)
eq('fx env hidden', envs['fx0.0'].VISIBLE, '0')
PP.key(('a'):byte(), col)
eq('arm on', envs['fx0.0'].ARM, '1')
PP.key(('b'):byte(), col)
eq('active off', envs['fx0.0'].ACTIVE, '0')
-- трек: Volume — действием 40406
PP.row = 1
PP.key(('e'):byte(), col)
eq('volume by action', cmds_run[1], 40406)
eq('volume env exists', envs.Volume ~= nil, true)
-- нет действия (Width в стабах) — ничего не падает
PP.row = 3; PP.key(('e'):byte(), col)
eq('width: no action, no env', envs.Width, nil)
-- ARM без огибающей — подсказка
PP.row = 2; PP.key(('a'):byte(), col)
eq('no env msg', msgs[#msgs]:find('no envelope') ~= nil, true)
-- модуляция: нет — добавить, есть — в матрицу
PP.row = 10; PP.key(('m'):byte(), col)
eq('mod add', envs.modded and envs.modded.param, 1)
PP.row = 12; PP.refresh_row(tr, PP.shown[12]); PP.key(('m'):byte(), col)
eq('mod goto', envs.went and envs.went.fx, 1)
eq('mod flags', PP.shown[12].lfo, true)
-- used: Volume, fx0.0, fx1.0 (модуляция)
PP.key(('v'):byte(), col)
PP.draw({ rh = 16, pad = 4 }, 0, 0, 800, 400, col, true)
eq('used rows', #PP.shown, 3)
-- режим автоматизации
PP.key(('M'):byte(), col)
eq('automode read', tr.mode, 1)
eq('leave', PP.key(27, col), 'leave')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
