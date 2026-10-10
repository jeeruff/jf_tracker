-- live_dump.lua — снимок проекта-песочницы в текст (10 окт) для живых тестов:
--   REAPER -nonewinst tests/live_dump.lua  →  tests/shots/live_dump.txt
-- Только чтение (Get*), только в песочнице (проект без имени, треки sandbox_setup);
-- иначе пишет REFUSED. Формат строк стабильный — драйвер tests/live.py его парсит
-- и сравнивает «до / после». Числа — секунды и QN с 4 знаками.
local R = reaper
local DIR = debug.getinfo(1, 'S').source:sub(2):match('(.*)/tests/')
local OUT = DIR .. '/tests/shots/live_dump.txt'
local out = {}
local function w(...) out[#out + 1] = string.format(...) end

local _, pname = R.EnumProjects(-1, '')
local names = {}
for i = 0, R.CountTracks(0) - 1 do local _, n = R.GetTrackName(R.GetTrack(0, i)); names[#names + 1] = n end
if (pname and pname ~= '') or not table.concat(names, ','):find('A drums', 1, true) then
  w('REFUSED: not a sandbox (%s)', tostring(pname))
else
  local ok, err = pcall(function()
    w('PROJECT tracks=%d bpm=%.2f cursor=%.4f play=%d undo=%s', R.CountTracks(0), R.Master_GetTempo(), R.GetCursorPosition(),
      R.GetPlayState(), tostring(R.Undo_CanUndo2(0)))
    local n = R.CountProjectMarkers(0)
    for i = 0, n - 1 do
      local _, isrgn, pos, rend, name, idx = R.EnumProjectMarkers(i)
      if isrgn then w('REGION %d "%s" %.4f %.4f', idx, name, pos, rend) else w('MARKER %d "%s" %.4f', idx, name, pos) end
    end
    for ti = 0, R.CountTracks(0) - 1 do
      local tr = R.GetTrack(0, ti)
      local _, nm = R.GetTrackName(tr)
      w('TRACK %d "%s" sel=%d mute=%d solo=%d lanes=%d fx=%d vol=%.3f', ti + 1, nm, R.IsTrackSelected(tr) and 1 or 0,
        R.GetMediaTrackInfo_Value(tr, 'B_MUTE'), R.GetMediaTrackInfo_Value(tr, 'I_SOLO'),
        R.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'), R.TrackFX_GetCount(tr), R.GetMediaTrackInfo_Value(tr, 'D_VOL'))
      for ii = 0, R.CountTrackMediaItems(tr) - 1 do
        local it = R.GetTrackMediaItem(tr, ii)
        local tk = R.GetActiveTake(it)
        local tname = tk and R.GetTakeName(tk) or ''
        local midi = tk and R.TakeIsMIDI(tk)
        w('  ITEM %d "%s" pos=%.4f len=%.4f lane=%d mute=%d vol=%.3f pitch=%.2f rate=%.3f offs=%.4f loop=%d %s',
          ii + 1, tname, R.GetMediaItemInfo_Value(it, 'D_POSITION'), R.GetMediaItemInfo_Value(it, 'D_LENGTH'),
          R.GetMediaItemInfo_Value(it, 'I_FIXEDLANE'), R.GetMediaItemInfo_Value(it, 'B_MUTE'), R.GetMediaItemInfo_Value(it, 'D_VOL'),
          tk and R.GetMediaItemTakeInfo_Value(tk, 'D_PITCH') or 0, tk and R.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE') or 1,
          tk and R.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS') or 0, R.GetMediaItemInfo_Value(it, 'B_LOOPSRC'), midi and 'MIDI' or 'AUDIO')
        if midi then
          local _, nn = R.MIDI_CountEvts(tk)
          for k = 0, nn - 1 do
            local _, sel, mu, sp, ep, ch, pitch, vel = R.MIDI_GetNote(tk, k)
            w('    NOTE qn=%.4f len=%.4f p=%d v=%d ch=%d', R.MIDI_GetProjQNFromPPQPos(tk, sp),
              R.MIDI_GetProjQNFromPPQPos(tk, ep) - R.MIDI_GetProjQNFromPPQPos(tk, sp), pitch, vel, ch)
          end
        end
        if tk then
          for ei = 0, R.CountTakeEnvelopes(tk) - 1 do
            local env = R.GetTakeEnvelope(tk, ei)
            local _, en = R.GetEnvelopeName(env)
            local pts = {}
            for pi = 0, math.min(R.CountEnvelopePoints(env), 40) - 1 do
              local _, t, v, sh = R.GetEnvelopePoint(env, pi); pts[#pts + 1] = ('%.3f:%.3f/%d'):format(t, v, sh)
            end
            w('    TAKEENV "%s" n=%d %s', en, R.CountEnvelopePoints(env), table.concat(pts, ' '))
          end
        end
      end
      for ei = 0, R.CountTrackEnvelopes(tr) - 1 do
        local env = R.GetTrackEnvelope(tr, ei)
        local _, en = R.GetEnvelopeName(env)
        local pts = {}
        for pi = 0, math.min(R.CountEnvelopePoints(env), 40) - 1 do
          local _, t, v, sh = R.GetEnvelopePoint(env, pi); pts[#pts + 1] = ('%.3f:%.3f/%d'):format(t, v, sh)
        end
        local nai = R.CountAutomationItems(env)
        w('  ENV "%s" pts=%d ai=%d %s', en, R.CountEnvelopePoints(env), nai, table.concat(pts, ' '))
        for ai = 0, nai - 1 do
          w('    AI %d pos=%.4f len=%.4f pool=%d', ai + 1, R.GetSetAutomationItemInfo(env, ai, 'D_POSITION', 0, false),
            R.GetSetAutomationItemInfo(env, ai, 'D_LENGTH', 0, false), R.GetSetAutomationItemInfo(env, ai, 'D_POOL_ID', 0, false))
        end
      end
    end
  end)
  if not ok then w('ERR %s', tostring(err)) end
end
local f = io.open(OUT, 'w'); f:write(table.concat(out, '\n') .. '\n'); f:close()
R.SetExtState('jf_tracker', 'live_dump', tostring(#out) .. ' lines ' .. os.date('%H:%M:%S'), false)
R.defer(function() end)   -- без точки undo «ReaScript: Run» (иначе u в тесте откатывает её, а не правку)
