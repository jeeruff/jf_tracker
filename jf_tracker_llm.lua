-- jf_tracker_llm.lua — мост к языковой модели / MCP (10 окт).
--
-- Модель живёт снаружи (MCP-сервер tools/jf_tracker_mcp.py, позже — Ollama /
-- llama.cpp / ключ Claude тем же мостом): трекер процессов не порождает и HTTP
-- не умеет. Канал — тот же, что у живых тестов:
--   внешняя программа → ExtState jf_tracker/llm_in = «id|op|payload» (веб 8080);
--   трекер раз в кадр читает, выполняет, пишет ответ в файл
--   <ресурсы REAPER>/Data/jf_tracker_llm_out.txt и ExtState llm_ack = id.
-- Файл, а не ExtState: веб-интерфейс молча режет значения на ~995 знаках.
--
-- op: state (снимок для модели: треки, курсор, lib, слоты, строки паттерна),
--     help (команды трекера; payload — страница справки), run (команды и
--     клавиши; payload — строки через «;;»: «:команда …» или «keys:…»).
-- Опция llm (options → sound and samples): off — молчит, ask — run только
-- после y во всплывашке, on — сразу. Чтение (state, help) — при ask и on.
-- Каждая :команда — свой undo (edit.run), откат — u.
--
-- Без reaper.* в разборе (LLM.parse, LLM.split_run) — тестируется заглушками.

local LLM = {}
LLM.last = nil          -- последний id: тот же запрос дважды не исполняется
LLM.pending = nil       -- run ждёт подтверждения (ask) или опустения очереди клавиш

-- «id|op|payload» → id, op, payload
function LLM.parse(s)
  if type(s) ~= 'string' or s == '' then return nil end
  local id, op, payload = s:match('^([^|]+)|([^|]+)|?(.*)$')
  if not id then return nil end
  return id, op, payload or ''
end

-- payload run → список { kind = 'cmd' | 'keys', text = … }
function LLM.split_run(payload)
  local out = {}
  for part in (payload .. ';;'):gmatch('(.-);;') do
    local t = part:match('^%s*(.-)%s*$')
    if t ~= '' then
      local k = t:match('^keys:(.*)$')
      if k then out[#out + 1] = { kind = 'keys', text = k }
      else out[#out + 1] = { kind = 'cmd', text = (t:gsub('^:', '')) } end
    end
  end
  return out
end

-- клавиши строкой: буквы как есть, <cr> <esc> <tab> <bs> <up> <down> <left> <right> <space>
local SPECIAL = { cr = 13, enter = 13, esc = 27, tab = 9, bs = 8, space = 32,
                  up = 30064, down = 1685026670, left = 1818584692, right = 1919379572 }
function LLM.key_codes(text)
  local out, i = {}, 1
  while i <= #text do
    local ch = text:sub(i, i)
    if ch == '<' then
      local j = text:find('>', i, true)
      local name = j and text:sub(i + 1, j - 1):lower()
      if name and SPECIAL[name] then out[#out + 1] = SPECIAL[name]; i = j + 1
      else out[#out + 1] = ch:byte(); i = i + 1 end
    else out[#out + 1] = ch:byte(); i = i + 1 end
  end
  return out
end

-- ── снимок для модели ──────────────────────────────────────────────────
-- env: { snap, L, vim, state, seq, model, cur_col, rows }
local function cell_text(cell, snap)
  if not cell then return '...' end
  if cell.kind == 'cont' then return '|' end
  if cell.kind == 'off' then return 'OFF' end
  local s = cell.note or '???'
  local inst = cell.item and snap.inst_of and snap.inst_of[cell.item]
  if inst then s = s .. (' %02d'):format(inst) end
  if cell.vol then s = s .. ' ' .. tostring(cell.vol) end
  return s
end

function LLM.state_text(env, want_rows)
  local snap, L, vim, st, seq = env.snap, env.L, env.vim, env.state, env.seq or {}
  local o = {}
  local function w(...) o[#o + 1] = string.format(...) end
  local cc = env.cur_col and env.cur_col()
  w('jf_tracker state (rows = tracker rows, LPB %d rows per beat)', st.lpb or 4)
  w('bpm %.2f  play %s', env.bpm or 0, tostring(env.playing))
  w('cursor: row %d, track "%s", inst %s, mode %s, focus %s', vim.cur.row or 0, cc and cc.name or '?', tostring(vim.inst), vim.mode, st.focus)
  w('')
  w('tracks:')
  for ci, c in ipairs((snap and snap.cols) or {}) do
    local nl = c.lanes and #c.lanes or 0
    w('  %d "%s"%s lanes %d%s', ci, c.name or '', (cc and c.track == cc.track) and ' (cursor)' or '', nl,
      c.muted and ' muted' or '')
  end
  w('')
  w('lib (instruments of the cursor track, number = inst):')
  for i, e in ipairs((cc and cc.pool) or {}) do
    if not e.parent then w('  %02d %s%s', i, e.name or '', e.slices and (' (' .. #e.slices .. ' slices)') or '') end
  end
  w('')
  w('slots (regions in the sequence; row = first tracker row):')
  local cur_rg
  for i, rg in ipairs(seq) do
    if not rg.gap then
      w('  slot %d "%s" rows %d-%d', i, rg.name or '', rg.r0 or 0, (rg.r1 or 0) - 1)
      if (vim.cur.row or 0) >= (rg.r0 or 0) and (vim.cur.row or 0) < (rg.r1 or 0) then cur_rg = rg end
    end
  end
  -- строки: регион курсора, иначе want_rows строк от курсора
  local r0, r1
  if cur_rg then r0, r1 = cur_rg.r0, cur_rg.r1 - 1 else r0 = math.max(0, (vim.cur.row or 0) - 4); r1 = r0 + (want_rows or 32) - 1 end
  if r1 - r0 > 127 then r1 = r0 + 127 end
  w('')
  w('pattern rows %d-%d (cell: note inst vol | "|" holds | ... empty):', r0, r1)
  local cols = {}
  for fi, f in ipairs((L and L.flat) or {}) do
    if f.lane and f.sub then cols[#cols + 1] = { fi = fi, f = f, name = (f.col and f.col.name or '?') .. (f.si and f.si > 1 and ('.' .. f.si) or '') } end
  end
  local hdr = { 'row ' }
  for _, c in ipairs(cols) do hdr[#hdr + 1] = c.name end
  w('%s', table.concat(hdr, ' | '))
  for r = r0, r1 do
    local line = { ('%04d'):format(r) }
    local any = false
    for _, c in ipairs(cols) do
      local t = cell_text(c.f.sub[r], snap)
      if t ~= '...' then any = true end
      line[#line + 1] = t
    end
    if any or r == r0 or r == r1 then w('%s', table.concat(line, ' | ')) end
  end
  return table.concat(o, '\n')
end

-- справка: все «:команды» из страниц справки, или одна страница целиком
function LLM.help_text(KH, page)
  local o = {}
  if page and page ~= '' and KH.PAGES[page] then
    local P = KH.PAGES[page]
    o[#o + 1] = 'page ' .. page .. ': ' .. (P.title or '')
    for _, e in ipairs(P.e) do o[#o + 1] = ('  %-22s %s'):format(e.k, e.d) end
    return table.concat(o, '\n')
  end
  o[#o + 1] = 'jf_tracker commands (run them with op run: ":cmd args"; keys with "keys:...")'
  o[#o + 1] = 'every :command is one undo step; u in the tracker undoes it'
  local seen = {}
  for name, P in pairs(KH.PAGES) do
    for _, e in ipairs(P.e or {}) do
      if e.k:match('^:') and not seen[e.k] then seen[e.k] = true; o[#o + 1] = ('  %-26s %s'):format(e.k, e.d) end
    end
  end
  table.sort(o, function(a, b) if a:sub(1, 2) == '  ' and b:sub(1, 2) == '  ' then return a < b end return a:sub(1, 2) ~= '  ' and b:sub(1, 2) == '  ' end)
  local pages = {}
  for name in pairs(KH.PAGES) do pages[#pages + 1] = name end
  table.sort(pages)
  o[#o + 1] = ''
  o[#o + 1] = 'key pages (op help with a page name): ' .. table.concat(pages, ' ')
  return table.concat(o, '\n')
end

return LLM
