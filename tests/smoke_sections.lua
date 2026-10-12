-- smoke_sections.lua — коды и секции вживую (песочница): A1 A2 под секцией verse; модель не считает verse слотом;
-- A2 растёт на такт через edit.run (как :len) — конец verse уезжает за ним; A1 удаляется — начало verse на A2.
-- Отчёт → ExtState jf_tracker/smoke. Всё в одном undo-блоке на каждый шаг; в конце регионы убираются.
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or table.concat(names, ','):find('B lanes', 1, true) == nil then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local model = dofile(DIR .. '/jf_tracker_model.lua')
model.SEC = dofile(DIR .. '/jf_tracker_sections.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
edit.init(model)
local out, bad = {}, 0
local function ok(what, c, d) if not c then bad = bad + 1 end; out[#out + 1] = (c and 'ok ' or 'BAD ') .. what .. (d and (' (' .. d .. ')') or '') end
local function bar(n) return R.TimeMap2_QNToTime(0, n * 4) end
local function find(name)
  local i = 0
  while true do
    local ret, isrgn, pos, rgnend, nm, idx = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then return nil end
    if isrgn and nm == name then return { i = i, pos = pos, rgnend = rgnend, idx = idx } end
    i = i + 1
  end
end
local base = 0                      -- до =END: регионы последовательности (после =END — библиотека, там секций нет)
local endm
do local i = 0
  while true do
    local ret, isrgn, pos, _, nm = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and nm == '=END' then endm = pos end
    i = i + 1
  end
end
R.AddProjectMarker2(0, true, base, base + bar(1), 'A1', -1, 0)
R.AddProjectMarker2(0, true, base + bar(1), base + bar(2), 'A2', -1, 0)
R.AddProjectMarker2(0, true, base, base + bar(2), 'verse', -1, 0)
local regs = model.regions(4)
local isslot = false
for _, r in ipairs(regs) do if r.name == 'verse' then isslot = true end end
ok('verse is not a slot', not isslot)
ok('verse is a section', #(regs.sections or {}) >= 1 and regs.sections[1].name == 'verse')
ok('next family is B1', model.SEC.next_family(regs) == 'B1', model.SEC.next_family(regs))
-- A2 растёт на такт: маркеры после конца — вперёд, конец A2 — дальше (как set_region_len без items)
local a2 = find('A2')
edit.run('smoke: A2 longer', function()
  local i = 0
  local list = {}
  while true do
    local ret, isrgn, pos, rgnend, nm, idx, col = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if pos >= a2.rgnend - 1e-6 then list[#list + 1] = { i, isrgn, pos, rgnend, nm, idx, col } end
    i = i + 1
  end
  for _, m in ipairs(list) do R.SetProjectMarkerByIndex(0, m[1], m[2], m[3] + bar(1), m[2] and m[4] + bar(1) or 0, m[6], m[5], m[7]) end
  R.SetProjectMarkerByIndex(0, a2.i, true, a2.pos, a2.rgnend + bar(1), a2.idx, 'A2', 0)
end)
local v = find('verse')
ok('verse end follows A2', v and math.abs(v.rgnend - (base + bar(3))) < 1e-6, v and ('%.3f vs %.3f'):format(v.rgnend, base + bar(3)))
ok('verse start stays', v and math.abs(v.pos - base) < 1e-6)
-- A1 удалён (без сдвига): начало verse — на A2
local a1 = find('A1')
edit.run('smoke: delete A1', function() R.DeleteProjectMarkerByIndex(0, a1.i) end)
v = find('verse')
ok('verse start moves to A2', v and math.abs(v.pos - (base + bar(1))) < 1e-6, v and ('%.3f'):format(v.pos))
-- уборка
for _, nm in ipairs({ 'verse', 'A2', 'A1' }) do local m = find(nm); if m then R.DeleteProjectMarkerByIndex(0, m.i) end end
if endm then   -- =END назад, куда был
  local i = 0
  while true do
    local ret, isrgn, pos, _, nm, idx, col = R.EnumProjectMarkers3(0, i)
    if not ret or ret == 0 then break end
    if not isrgn and nm == '=END' then R.SetProjectMarkerByIndex(0, i, false, endm, 0, idx, nm, col) end
    i = i + 1
  end
end
out[#out + 1] = ('%d bad'):format(bad)
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
