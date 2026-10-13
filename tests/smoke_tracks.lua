-- smoke_tracks.lua — модуль tracks как lf (13 окт): операции дерева вживую (песочница) → ExtState jf_tracker/smoke
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out, bad = {}, 0
local function log(s) out[#out + 1] = s end
local function check(name, cond, info) if not cond then bad = bad + 1 end; log((cond and 'ok ' or 'BAD ') .. name .. (info and (' (' .. info .. ')') or '')) end
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local _, pname = R.EnumProjects(-1, '')
if (pname and pname ~= '') or table.concat(names, ',') ~= 'A drums,B lanes,M synth,DEPOT' then R.SetExtState('jf_tracker', 'smoke', 'REFUSED', false); return end
local ok, err = pcall(function()
  local model = dofile(DIR .. '/jf_tracker_model.lua')
  local edit = dofile(DIR .. '/jf_tracker_edit.lua'); edit.init(model)
  local function g(name) for i = 0, R.CountTracks(0) - 1 do local tr = R.GetTrack(0, i); local _, n = R.GetTrackName(tr); if n == name then return R.GetTrackGUID(tr) end end end
  -- дерево строкой: «A drums ( B lanes ) M synth DEPOT»
  local function S()
    local list, map = edit.tree_read()
    local o, d = {}, 0
    for _, e in ipairs(list) do
      while d < e.d do o[#o + 1] = '('; d = d + 1 end
      while d > e.d do o[#o + 1] = ')'; d = d - 1 end
      local _, n = R.GetTrackName(map[e.id]); o[#o + 1] = n
    end
    while d > 0 do o[#o + 1] = ')'; d = d - 1 end
    return table.concat(o, ' ')
  end
  local A, B, M = g('A drums'), g('B lanes'), g('M synth')
  check('start flat', S() == 'A drums B lanes M synth DEPOT', S())
  edit.tree_op('indent', { B }, B)
  check('>> B into A', S() == 'A drums ( B lanes ) M synth DEPOT', S())
  edit.tree_op('indent', { M }, M)
  check('>> M into the folder A (last child)', S() == 'A drums ( B lanes M synth ) DEPOT', S())
  edit.tree_op('outdent', { B }, B)
  check('<< B out after the whole folder', S() == 'A drums ( M synth ) B lanes DEPOT', S())
  edit.tree_op('up', { B }, B)
  check('K moves B over the folder', S() == 'B lanes A drums ( M synth ) DEPOT', S())
  edit.tree_op('down', { B }, B)
  check('J back', S() == 'A drums ( M synth ) B lanes DEPOT', S())
  edit.tree_op('folder', { B }, B)
  check('F folder around B', S() == 'A drums ( M synth ) folder ( B lanes ) DEPOT', S())
  edit.tree_op('new_after', { A }, A)
  check('o after a folder - at its level', S():match('^A drums %( M synth %) Track %d+ folder') ~= nil and R.CountTracks(0) == 6, S())
  local n0 = R.CountTracks(0)
  edit.tree_op('copy', { A }, A)
  edit.tree_op('paste_after', { B }, B)
  check('yy A (folder) p after B: 2 tracks, the copy a folder too', R.CountTracks(0) == n0 + 2 and S():find('B lanes A drums %( M synth %) %) DEPOT') ~= nil, S())
  edit.tree_op('cut', { A }, A)
  check('dd A takes its child too', R.CountTracks(0) == n0, S())
  check('the plan still nests right', not S():find('^%(') and select(2, S():gsub('%(', '')) == select(2, S():gsub('%)', '')), S())
end)
if not ok then log('ERR ' .. tostring(err)); bad = bad + 1 end
log(bad .. ' bad')
R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false)
