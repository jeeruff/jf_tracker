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

return MEM
