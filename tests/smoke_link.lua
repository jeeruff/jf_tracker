-- smoke_link.lua — связь копий инструмента живьём в песочнице → ExtState jf_tracker/smoke
-- (3 окт): ноты и слайсы подряд (каждый обрезан следующим) не плодят записей
-- в lib; растянутая нота — уникальная, «применить ко всем» связывает обратно;
-- beatsync подгоняет rate. Пишет только в песочницу (guard по трекам A/B/M).
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local out = {}
local function log(s) out[#out + 1] = s end
local function done() R.SetExtState('jf_tracker', 'smoke', table.concat(out, ' | '), false) end
local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
local all = table.concat(names, ',')
if (pname and pname ~= '') or not (all:find('A drums', 1, true) and all:find('B lanes', 1, true) and all:find('M synth', 1, true)) then log('REFUSED'); done(); return end
local model = dofile(DIR .. '/jf_tracker_model.lua')
local edit = dofile(DIR .. '/jf_tracker_edit.lua')
edit.init(model)
edit.keep_samples = false
local ok, err = pcall(function()
  -- свой трек L link с одним item-инструментом (2 с amen)
  R.InsertTrackAtIndex(R.CountTracks(0), true)
  local L = R.GetTrack(0, R.CountTracks(0) - 1)
  R.GetSetMediaTrackInfo_String(L, 'P_NAME', 'L link', true)
  local src = R.GetMediaItemTake_Source(R.GetActiveTake(R.GetTrackMediaItem(R.GetTrack(0, 0), 0)))
  local root = R.AddMediaItemToTrack(L)
  local tk = R.AddTakeToMediaItem(root)
  R.SetMediaItemTake_Source(tk, src)
  R.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', 'linkroot', true)
  R.SetMediaItemInfo_Value(root, 'D_POSITION', 60)
  R.SetMediaItemInfo_Value(root, 'D_LENGTH', 2)
  edit.set_slices(root, { 0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75 })
  local function pool_n() model.invalidate(); local snap = model.build(4); return #snap.pool, snap end
  local n0 = pool_n()
  -- три ноты инструмента подряд (каждая режет предыдущую) и три слайса 3
  for _, row in ipairs({ 0, 4, 8 }) do edit.insert_note(L, nil, 4, row, model.BASE_NOTE + 2, 100, 1, root) end
  for _, row in ipairs({ 16, 18, 20 }) do edit.insert_slice(L, nil, 4, row, root, 3) end
  local n1, snap = pool_n()
  log(('lib entries %d → %d (want +1: slice 3)'):format(n0, n1))
  local rootv = edit.get_iid(root)
  local slicev = rootv .. '#3'
  log(('root notes linked %d (want 4), slice 3 linked %d (want 3)'):format(#edit.items_with_iid(rootv), #edit.items_with_iid(slicev)))
  -- растянуть одну ноту слайса (= beatsync к доле): уникальная + вопрос
  local sl = edit.items_with_iid(slicev)
  table.sort(sl, function(a, b) return R.GetMediaItemInfo_Value(a, 'D_POSITION') < R.GetMediaItemInfo_Value(b, 'D_POSITION') end)
  local last = sl[#sl]
  edit.beatsync({ { kind = 'audio', item = last, take = R.GetActiveTake(last) } }, 4, 'bar')
  log(('stretch → queued %d, slice 3 linked now %d (want 1, 2)'):format(#edit.modified, #edit.items_with_iid(slicev)))
  local n2 = pool_n()
  log(('lib entries after unique %d (want %d)'):format(n2, n1 + 1))
  local mods = edit.take_modified()
  local np = edit.propagate(mods)
  local r_last = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(last), 'D_PLAYRATE')
  local r_first = R.GetMediaItemTakeInfo_Value(R.GetActiveTake(sl[1]), 'D_PLAYRATE')
  log(('apply to all → %d updated, linked %d (want 2, 3), rates %.3f / %.3f equal'):format(np, #edit.items_with_iid(slicev), r_first, r_last))
  local n3 = pool_n()
  log(('lib entries after relink %d (want %d)'):format(n3, n1))
  -- beatsync корня: 4 доли при 120 = 2 с → rate 1 у корня, ноты по месту
  local grp = edit.items_with_iid(rootv)
  edit.bsync_set(grp, root, 8)
  local b = edit.bsync_of(root)
  log(('bsync 8 beats: root rate %.3f (want 0.5), mark n=%s'):format(R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE'), b and b.n or '-'))
  edit.bsync_set(grp, root, nil)
  log(('bsync off: root rate %.3f (want 1)'):format(R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')))
end)
if not ok then log('ERR ' .. tostring(err)) end
done()
