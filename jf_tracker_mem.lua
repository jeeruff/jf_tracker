-- jf_tracker_mem.lua — :mem (21 окт): кто держит память Lua. Обход всего, что достижимо из корней
-- (upvalues кадра трекера, ctx, state): у каждого корня — байты (оценка), таблиц, строк. Объект
-- считается у первого корня, который до него дошёл (порядок корней = приоритет), — сумма не двоится.
-- Оценка размеров (Lua 5.4, 64 бит): строка 24 + длина, таблица 56 + 16 на элемент массива + 32 на пару.
-- Без reaper.* — тест tests/test_mem.lua.

local MEM = {}

-- roots — { { name, value } … } → { { name, bytes, tables, strings, big = самая большая строка } … } по убыванию
function MEM.census(roots, limit)
  local seen = {}
  local out = {}
  limit = limit or 5e7                      -- предохранитель: не больше стольких объектов
  local count = 0
  for _, r in ipairs(roots) do
    local acc = { name = r[1], bytes = 0, tables = 0, strings = 0, big = 0 }
    local stack = { r[2] }
    while #stack > 0 and count < limit do
      local v = table.remove(stack)
      local tv = type(v)
      if tv == 'string' then
        if not seen[v] then seen[v] = true; count = count + 1; acc.strings = acc.strings + 1; acc.bytes = acc.bytes + 24 + #v; if #v > acc.big then acc.big = #v end end
      elseif tv == 'table' then
        if not seen[v] then
          seen[v] = true; count = count + 1
          acc.tables = acc.tables + 1
          local narr, nhash = #v, 0
          for k, x in next, v do
            nhash = nhash + 1
            if type(k) == 'table' or type(k) == 'string' or type(k) == 'function' then stack[#stack + 1] = k end
            if type(x) == 'table' or type(x) == 'string' or type(x) == 'function' then stack[#stack + 1] = x end
          end
          acc.bytes = acc.bytes + 56 + 16 * narr + 32 * math.max(0, nhash - narr)
          local mt = getmetatable(v)
          if type(mt) == 'table' then stack[#stack + 1] = mt end
        end
      elseif tv == 'function' then
        if not seen[v] then
          seen[v] = true; count = count + 1
          acc.bytes = acc.bytes + 40
          local i = 1
          while true do
            local n, x = debug.getupvalue(v, i)
            if not n then break end
            if type(x) == 'table' or type(x) == 'string' or type(x) == 'function' then stack[#stack + 1] = x end
            i = i + 1
          end
        end
      end
    end
    out[#out + 1] = acc
  end
  table.sort(out, function(a, b) return a.bytes > b.bytes end)
  return out, count
end

function MEM.fmt(b)
  if b >= 1048576 then return ('%.1fMB'):format(b / 1048576) end
  return ('%dKB'):format(math.floor(b / 1024))
end

-- строка отчёта: первые n корней
function MEM.report(list, n)
  local t = {}
  for i = 1, math.min(n or 12, #list) do
    local a = list[i]
    t[#t + 1] = ('%s %s (%d tables, %d strings, biggest %s)'):format(a.name, MEM.fmt(a.bytes), a.tables, a.strings, MEM.fmt(a.big))
  end
  return table.concat(t, ' | ')
end

-- 21 окт: :memprof — кто ДЕЛАЕТ мусор: построчный хук (медленно, на несколько секунд) пишет рост кучи на строку.
-- Свои выделения хука (getinfo) не в счёт — отсчёт берётся после них. now — часы, done(report) — по истечении.
-- хук REAPER не держит между вызовами defer — MEM.prof_tick() в начале каждого кадра ставит его снова
function MEM.prof_start(sec, now, done, every)
  local P = { acc = {}, t_end = now() + (sec or 5), sec = sec or 5, now = now, done = done, every = every or 1000 }
  -- построчный хук: рост кучи — на ПРЕДЫДУЩУЮ исполненную строку (она и выделила, вместе с вызовами C);
  -- выборка по счётчику инструкций приписывала рост просто частым строкам (set, text)
  local last = collectgarbage('count')
  local psrc, pline
  P.fn = function(_, line)
    local c = collectgarbage('count')
    local d = c - last
    if d > 0 and psrc then
      local f = P.acc[psrc]
      if not f then f = {}; P.acc[psrc] = f end
      f[pline] = (f[pline] or 0) + d
    end
    local info = debug.getinfo(2, 'S')
    psrc, pline = info and info.source, line
    last = collectgarbage('count')
  end
  P.reset = function() last = collectgarbage('count'); psrc = nil end
  MEM.P = P
  MEM.prof_tick()
end
function MEM.prof_tick()
  local P = MEM.P
  if not P then return end
  if P.now() > P.t_end then
    debug.sethook(); MEM.P = nil
    P.done(MEM.prof_report(P.acc, P.sec))
    return
  end
  P.reset()
  debug.sethook(P.fn, 'l')
end
function MEM.prof_report(acc, sec, top)
  local list = {}
  for src, f in pairs(acc) do
    local short = src:match('([^/]+)$') or src
    for line, kb in pairs(f) do list[#list + 1] = { short .. ':' .. line, kb } end
  end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local t, tot = {}, 0
  for _, e in ipairs(list) do tot = tot + e[2] end
  for i = 1, math.min(top or 25, #list) do t[#t + 1] = ('%s %.0f'):format(list[i][1], list[i][2] / sec) end
  return ('memprof %.0f KB/s: '):format(tot / sec) .. table.concat(t, ' | ')
end

return MEM
