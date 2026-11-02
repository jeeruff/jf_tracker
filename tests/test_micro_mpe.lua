-- test_micro_mpe.lua — микротоны через MPE (2 ноя): перезапись потока, каналы, bend, чтение обратно, миграция MTS
local DIR = debug.getinfo(1, 'S').source:match('^@(.*)/tests/') or '.'
_G.reaper = setmetatable({}, { __index = function() return function() return 0 end end })
local M = dofile(DIR .. '/jf_tracker_model.lua')
local n, bad = 0, 0
local function eq(name, got, want) n = n + 1; if got ~= want then bad = bad + 1; print(('FAIL %s: got %s want %s'):format(name, tostring(got), tostring(want))) end end
local function ev(off, msg) return string.pack('<i4Bs4', off, 0, msg) end
local function evs(buf)
  local out, pos, ppq = {}, 1, 0
  while pos <= #buf do local off, fl, msg; off, fl, msg, pos = string.unpack('<i4Bs4', buf, pos); ppq = ppq + off; out[#out + 1] = { ppq = ppq, msg = msg } end
  return out
end
-- bend туда-обратно
eq('bend centre', M.mpe_bend(0), 8192)
eq('bend +1/6 tone back', M.micro_of_cents(M.mpe_cents(M.mpe_bend(100 / 6))), 1)
eq('bend -3/6 back', M.micro_of_cents(M.mpe_cents(M.mpe_bend(-50))), -3)
-- аккорд C E G на канале 1, E с микротоном -1: E уходит на канал 2 с bend, C G на месте без bend
local buf = ev(0, string.char(0x90, 60, 100)) .. ev(0, string.char(0x90, 64, 100)) .. ev(0, string.char(0x90, 67, 100))
  .. ev(480, string.char(0x80, 60, 0)) .. ev(0, string.char(0x80, 64, 0)) .. ev(0, string.char(0x80, 67, 0))
local nb = M.micro_rewrite(buf, { ['0:0:64'] = -1 })
local e = evs(nb)
eq('one bend added', #e, 7)
local bends, onch = 0, {}
for _, x in ipairs(e) do
  local st, ch = x.msg:byte(1) & 0xF0, x.msg:byte(1) & 0x0F
  if st == 0xE0 then bends = bends + 1; eq('bend on channel 2', ch, 1); eq('bend value -1/6', M.micro_of_cents(M.mpe_cents(x.msg:byte(3) * 128 + x.msg:byte(2))), -1) end
  if st == 0x90 then onch[x.msg:byte(2)] = ch end
  if st == 0x80 and x.msg:byte(2) == 64 then eq('E note-off follows to channel 2', ch, 1) end
end
eq('bends', bends, 1); eq('C stays ch1', onch[60], 0); eq('E on ch2', onch[64], 1); eq('G stays ch1', onch[67], 0)
-- модель читает микротон обратно
local notes = M.parse_midi(nb)
local got = {}
for _, nt in ipairs(notes) do got[nt.pitch] = M.micro_of_cents(nt.cents) end
eq('read E -1', got[64], -1); eq('read C none', got[60], nil)
-- повторная перезапись без изменений — тот же поток (bend снят и поставлен заново, без дублей)
eq('idempotent', M.micro_rewrite(nb, nil), nb)
-- два микротона одновременно — разные каналы
local nb2 = M.micro_rewrite(buf, { ['0:0:60'] = 1, ['0:0:64'] = -1 })
local ch2 = {}
for _, x in ipairs(evs(nb2)) do if x.msg:byte(1) & 0xF0 == 0x90 then ch2[x.msg:byte(2)] = x.msg:byte(1) & 0x0F end end
eq('C and E on different channels', ch2[60] ~= ch2[64] and ch2[60] >= 1 and ch2[64] >= 1, true)
-- снять микротон: bend 0 перед нотой на канале 2, поток без микротонов дальше не тронут
local nb3 = M.micro_rewrite(nb, { ['1:0:64'] = 0 })
local cents3
for _, nt in ipairs(M.parse_midi(nb3)) do if nt.pitch == 64 then cents3 = nt.cents end end
eq('cleared micro reads none', cents3, nil)
eq('plain take untouched', M.micro_rewrite(buf, nil), nil)
-- миграция: старый MTS sysex → MPE, sysex убран
local old = ev(0, M.mts_bytes(64, 6400 - 100 / 6)) .. buf
local nb4 = M.micro_rewrite(old, nil)
local sx = 0
for _, x in ipairs(evs(nb4)) do if x.msg:byte(1) == 0xF0 then sx = sx + 1 end end
eq('MTS sysex removed', sx, 0)
for _, nt in ipairs(M.parse_midi(nb4)) do if nt.pitch == 64 then eq('migrated E -1', M.micro_of_cents(nt.cents), -1) end end
-- base64
eq('b64 round', M.b64dec(M.b64enc('<mpeEnabled v="0" />xy')), '<mpeEnabled v="0" />xy')
eq('b64 known', M.b64enc('Man'), 'TWFu'); eq('b64 pad', M.b64enc('Ma'), 'TWE=')
print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
