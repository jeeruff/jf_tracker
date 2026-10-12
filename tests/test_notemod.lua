-- test_notemod.lua — модуляция по нотам: формат слотов и сверка AI на заглушке REAPER
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/') or '.'
local fails, n = 0, 0
local function eq(name, got, want)
  n = n + 1
  if got ~= want then fails = fails + 1; print(('FAIL %s: got %s, want %s'):format(name, tostring(got), tostring(want))) end
end

-- ── заглушка: один трек, items, одна FX-огибающая с automation items ───────
local tr = { items = {}, fx = { 'G1' }, envs = {} }
local env = { ais = {} }
local projext = {}
local cmd_log = {}
local function new_item(pos, len, pitch, ext)
  local it = { pos = pos, len = len, ext = { ['P_EXT:jf_nmod'] = ext or '', ['P_EXT:jf_iid'] = 'abc' }, take = { pitch = pitch or 0 } }
  tr.items[#tr.items + 1] = it
  return it
end
reaper = {
  GetProjExtState = function(_, s, k) return 1, projext[s .. k] or '' end,
  SetProjExtState = function(_, s, k, v) projext[s .. k] = v end,
  CountTracks = function() return 1 end, GetTrack = function() return tr end, GetMasterTrack = function() return { items = {}, envs = {} } end,
  CountTrackMediaItems = function(t) return #(t.items or {}) end, GetTrackMediaItem = function(t, i) return t.items[i + 1] end,
  GetMediaItemInfo_Value = function(it, k) if k == 'D_POSITION' then return it.pos elseif k == 'D_LENGTH' then return it.len end; return 0 end,
  GetSetMediaItemInfo_String = function(it, k, v, set) if set then it.ext[k] = v end; return true, it.ext[k] or '' end,
  GetActiveTake = function(it) return it.take end, TakeIsMIDI = function() return false end,
  GetMediaItemTakeInfo_Value = function(tk, k) if k == 'D_PITCH' then return tk.pitch elseif k == 'D_PLAYRATE' then return 1 end; return 0 end,
  TrackFX_GetCount = function(t) return #t.fx end, TrackFX_GetFXGUID = function(t, i) return t.fx[i + 1] end,
  GetFXEnvelope = function(_, fx, p) if fx == 0 and p == 3 then return env end end,
  GetTrackEnvelopeByName = function() return nil end,
  CountTrackEnvelopes = function(t) return t == tr and 1 or 0 end, GetTrackEnvelope = function() return env end,
  CountAutomationItems = function(e) return #e.ais end,
  GetSetAutomationItemInfo = function(e, k, key, v, set)
    local a = e.ais[k + 1]
    local F = { D_POOL_ID = 'pool', D_POSITION = 'pos', D_LENGTH = 'len', D_PLAYRATE = 'rate', D_LOOPSRC = 'loop', D_UISEL = 'sel' }
    if set then a[F[key]] = v end
    return a[F[key]] or 0
  end,
  InsertAutomationItem = function(e, pool, pos, len) e.ais[#e.ais + 1] = { pool = pool, pos = pos, len = len, rate = 1, loop = 1, sel = 0 }; return #e.ais - 1 end,
  Main_OnCommand = function(c)
    cmd_log[#cmd_log + 1] = c
    if c == 42086 then local keep = {}; for _, a in ipairs(env.ais) do if a.sel == 0 then keep[#keep + 1] = a end end; env.ais = keep end
  end,
}
local NM = dofile(DIR .. '/jf_tracker_notemod.lua')
local mother
local E = { get_iid = function(it) return it.ext['P_EXT:jf_iid'] end, ensure_iid = function() end,
  inst_ref = function() return mother end, inst_base = function() return 0 end }
NM.init(E, { take_semitones = function(p) return p end })

-- ── формат ────────────────────────────────────────────────────────────────
local s = NM.parse('fx:G1:3|7|rl|eq freq;env:Volume|9||vol')
eq('parse 2 slots', #s, 2)
eq('slot 1 env', s[1].env, 'fx:G1:3'); eq('slot 1 pool', s[1].pool, 7); eq('slot 1 rate', s[1].rate, true); eq('slot 1 loop', s[1].loop, true)
eq('slot 1 label', s[1].label, 'eq freq'); eq('slot 2 rate off', s[2].rate, false)
eq('encode round trip', NM.encode(NM.parse(NM.encode(s))), NM.encode(s))
eq('label | ; escaped', NM.encode({ { env = 'env:Pan', pool = 1, label = 'a|b;c' } }), 'env:Pan|1||a b c')
eq('garbage -> none', #NM.parse('junk;;|'), 0)

-- ── сверка ────────────────────────────────────────────────────────────────
local function count_at(pos) local c = 0; for _, a in ipairs(env.ais) do if math.abs(a.pos - pos) < 1e-4 then c = c + 1 end end; return c end
mother = new_item(100, 2, 0)                          -- инструмент в lib
env.ais[1] = { pool = 7, pos = 100, len = 0.5, rate = 1, loop = 1, sel = 0 }   -- мать пула (new_pool)
local a = new_item(0, 1, 0); local b = new_item(1, 1, 12)
local pre = NM.census()                               -- до: слотов нет
for _, it in ipairs({ mother, a, b }) do NM.set(it, 'fx:G1:3|7|r|eq') end
NM.sync(pre)
eq('slot on: one AI per note + mother (no duplicate)', #env.ais, 3)
eq('mother keeps one AI', count_at(100), 1)
eq('AI length = note length', env.ais[1].len, 2)
local rb; for _, x in ipairs(env.ais) do if x.pos == 1 then rb = x end end
eq('rate by pitch: +12 -> x2', rb and rb.rate, 2)
eq('one-shot (loop off)', rb and rb.loop, 0)

-- новая нота без инструмента в снимке: база — от родни по метке
local refs = {}
E.inst_ref = function(it) return refs[it] == nil and mother or refs[it] end
pre = NM.census()
local hi = new_item(5, 1, 24, 'fx:G1:3|7|r|eq'); refs[hi] = false
NM.sync(pre)
local rh; for _, x in ipairs(env.ais) do if x.pos == 5 then rh = x end end
eq('new note not in the snapshot: rate from the family (+24 -> x4)', rh and rh.rate, 4)
pre = NM.census(); for i, it in ipairs(tr.items) do if it == hi then table.remove(tr.items, i) end end; NM.sync(pre)
E.inst_ref = function() return mother end

-- копия ноты (вставка из чанка: слоты уже в P_EXT)
pre = NM.census()
local c = new_item(2, 0.5, 0, 'fx:G1:3|7|r|eq')
NM.sync(pre)
eq('copy: +1 AI', #env.ais, 4); eq('copy: AI at the note', count_at(2), 1)

-- сдвиг
pre = NM.census(); a.pos = 3
NM.sync(pre)
eq('move: AI follows', count_at(3), 1); eq('move: old place empty', count_at(0), 0); eq('move: count same', #env.ais, 4)

-- две ноты в одной позиции, одна уходит: вторая сохраняет свой AI
pre = NM.census(); local d = new_item(3, 1, 0, 'fx:G1:3|7|r|eq'); NM.sync(pre)
eq('two notes at one place: two AIs', count_at(3), 2)
pre = NM.census(); table.remove(tr.items, #tr.items); NM.sync(pre)
eq('one of two deleted: one AI stays', count_at(3), 1)

-- удаление
pre = NM.census(); for i, it in ipairs(tr.items) do if it == c then table.remove(tr.items, i) end end
NM.sync(pre)
eq('delete: AI gone', count_at(2), 0)

-- правка без нот со слотами — ничего не трогает
local ncmd = #cmd_log
pre = NM.census(); NM.sync(pre)
eq('no change: no delete action', #cmd_log, ncmd)

-- слот снят: все AI пула уходят
pre = NM.census(); for _, it in ipairs(tr.items) do NM.set(it, '') end; NM.sync(pre)
eq('slot off: no AIs', #env.ais, 0)

print(('%d checks, %d failed'):format(n, fails))
if fails > 0 then os.exit(1) end
