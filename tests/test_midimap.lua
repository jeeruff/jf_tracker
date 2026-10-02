-- test_midimap.lua — MIDI learn без REAPER: lua tests/test_midimap.lua
package.path = './?.lua;' .. package.path
gfx = { mouse_x = 0, mouse_y = 0 }
local MM = dofile('jf_tracker_midimap.lua')
local n, bad = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then bad = bad + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end
local function row(id) return MM.BY_ID[id].i end

-- не привязано — не наше
eq('unbound CC passes', MM.feed(0xB0, 21, 64, 'pad'), nil)
eq('unbound note passes', MM.feed(0x90, 60, 100, 'pad'), nil)
eq('monitor logs unbound', MM.log[1] and MM.log[1].fate, nil)

-- learn ручки
MM.cur = row('zone_start'); eq('Enter starts learn', MM.key(13), true); eq('learning', MM.learning, 'zone_start')
local a = MM.feed(0xB1, 21, 10, 'pad')
eq('learned', a and a.learned, 'zone_start'); eq('learn done', MM.learning, nil)
eq('monitor logs learn', MM.log[1].fate, 'learned slice start')
eq('bind cc', MM.binds.zone_start.kind, 'cc'); eq('bind ch', MM.binds.zone_start.ch, 1)
a = MM.feed(0xB1, 21, 127, 'pad'); eq('abs value', a and a.v, 1)
eq('monitor logs target', MM.log[1].fate, 'slice start')
eq('other channel passes', MM.feed(0xB0, 21, 64, 'pad'), nil)
eq('other device passes', MM.feed(0xB1, 21, 64, 'keys'), nil)
-- режим энкодера
eq('m cycles mode', MM.key(('m'):byte()), 'save'); eq('mode rel', MM.binds.zone_start.mode, 'rel')
eq('rel up', MM.feed(0xB1, 21, 3, 'pad').d, 3)
eq('rel down', MM.feed(0xB1, 21, 126, 'pad').d, -2)
MM.key(('m'):byte()); eq('mode rel64', MM.binds.zone_start.mode, 'rel64')
eq('rel64', MM.feed(0xB1, 21, 61, 'pad').d, -3)

-- кнопка CC: фронт через 64
MM.cur = row('eq8'); MM.key(13); MM.feed(0xB0, 30, 0, 'pad')
eq('cc button press', MM.feed(0xB0, 30, 127, 'pad').trig, true)
eq('cc button held is eaten', MM.feed(0xB0, 30, 127, 'pad').eaten, true)
eq('cc button release is eaten', MM.feed(0xB0, 30, 0, 'pad').eaten, true)
-- кнопка нотой
MM.cur = row('trans'); MM.key(13)
eq('learn ignores note-off', MM.feed(0x80, 40, 0, 'pad').eaten, true)
MM.feed(0x90, 40, 90, 'pad')
eq('note trigger', MM.feed(0x90, 40, 90, 'pad').trig, true)
eq('note off eaten', MM.feed(0x80, 40, 0, 'pad').eaten, true)

-- пэды
MM.cur = row('pads'); MM.key(13); MM.feed(0x99, 36, 100, 'pad')
local p = MM.feed(0x99, 39, 80, 'pad')
eq('pad k', p and p.k, 4); eq('pad vel', p and p.vel, 80)
eq('note below pads passes', MM.feed(0x99, 35, 80, 'pad'), nil)

-- переназначение: тот же CC на другую цель снимает старую привязку
MM.cur = row('vol'); MM.key(13); MM.feed(0xB1, 21, 0, 'pad')
eq('old bind removed', MM.binds.zone_start, nil); eq('new bind', MM.binds.vol.num, 21)

-- Esc: отмена learn, потом выход
MM.cur = row('sens'); MM.key(13); eq('Esc cancels learn', MM.key(27), true); eq('not learning', MM.learning, nil)
eq('Esc leaves', MM.key(27), 'leave')
-- очистка
MM.cur = row('vol'); eq('d clears', MM.key(('d'):byte()), 'save'); eq('cleared', MM.binds.vol, nil)

-- хранение
local ser = MM.serialize()
local before = 0; for _ in pairs(MM.binds) do before = before + 1 end
MM.parse(ser)
local after = 0; for _ in pairs(MM.binds) do after = after + 1 end
eq('roundtrip count', after, before)
eq('roundtrip pads base', MM.binds.pads.num, 36)
eq('roundtrip device', MM.binds.pads.dev, 'pad')
MM.parse('bogus|x|1|cc|2|abs\nsens||0|cc|5|rel')
eq('parse skips unknown target', MM.binds.bogus, nil); eq('parse empty device', MM.binds.sens.dev, '')
eq('empty device matches any', MM.feed(0xB0, 5, 1, 'whatever').d, 1)

-- монитор: другие статусы и предел длины
MM.feed(0xE0, 0, 64, 'pad'); eq('bend in monitor', MM.log[1].what:match('^bend') ~= nil, true)
for _ = 1, 100 do MM.feed(0xB0, 99, 1, 'pad') end
eq('monitor capped', #MM.log, MM.LOG_MAX)

print(('%d checks, %d failed'):format(n, bad))
os.exit(bad == 0 and 0 or 1)
