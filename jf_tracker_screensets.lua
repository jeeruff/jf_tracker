-- jf_tracker_screensets.lua — формат файла скринсетов (4 окт): строка на набор,
-- «имя<TAB>ключ=тип:значение;…», тип b (0/1) / n (число) / s (строка, ; → %3B).
-- Без reaper.*: файл читает и пишет main, здесь — только текст.
local SS = {}

function SS.decode(text)
  local sets, order = {}, {}
  for line in (text or ''):gmatch('[^\n]+') do
    local name, body = line:match('^([^\t]+)\t(.*)$')
    if name then
      local t = {}
      for k, ty, v in body:gmatch('([%w_]+)=(%a):([^;]*);') do
        if ty == 'b' then t[k] = v == '1'
        elseif ty == 'n' then t[k] = tonumber(v)
        else t[k] = (v:gsub('%%3B', ';')) end
      end
      if not sets[name] then order[#order + 1] = name end
      sets[name] = t
    end
  end
  return sets, order
end

function SS.encode(sets, order)
  local out = {}
  for _, name in ipairs(order) do
    local t = sets[name]
    if t then
      local keys = {}
      for k in pairs(t) do keys[#keys + 1] = k end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        local v = t[k]
        local ty = type(v) == 'boolean' and 'b' or (type(v) == 'number' and 'n' or 's')
        local sv = ty == 'b' and (v and '1' or '0') or (tostring(v):gsub(';', '%%3B'))
        parts[#parts + 1] = k .. '=' .. ty .. ':' .. sv .. ';'
      end
      out[#out + 1] = name:gsub('[\t\n]', ' ') .. '\t' .. table.concat(parts)
    end
  end
  return table.concat(out, '\n') .. (#out > 0 and '\n' or '')
end

return SS
