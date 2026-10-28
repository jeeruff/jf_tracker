-- jf_tracker_mini.lua — мини-нотация Tidal / Strudel (28 окт; тест tests/test_mini.lua). Без reaper / gfx.
-- Строка описывает один цикл (такт): пробел — шаг, [a b] — уместить в шаг, a, b — одновременно, <a b> — по циклам,
-- a*2 быстрее, a/2 медленнее, a!3 повторить, a@2 вес шага, a? — через раз (детерминированно), ~ пауза,
-- a(3,8) / a(3,8,2) — евклид. Значения — ноты (c e4 f#3 bb2), числа (0 7 -3), прочее — как есть (bd sn:2).
-- Цепочка: n("c [e g]").fast(2).rev().add(7).oct(-1).vel(0.8).every(4, "rev") — или голая строка.
-- M.query(expr, cycle) → { { s, e, v, vel } } в долях цикла [0, 1); M.notes(...) — с высотами MIDI.
local M = {}

-- ── разбор строки в дерево ────────────────────────────────────────────────
local function tokenize(s)
  local t, i = {}, 1
  while i <= #s do
    local ch = s:sub(i, i)
    if ch:match('%s') then i = i + 1
    elseif ch:match('[%[%]<>,%*/!@%?%(%)~]') then t[#t + 1] = ch; i = i + 1
    else
      local w = s:match('^[^%s%[%]<>,%*/!@%?%(%)]+', i)
      t[#t + 1] = w; i = i + #w
    end
  end
  return t
end

local parse_seq
local function parse_atom(T, p)
  local tk = T[p]
  local node
  if tk == '[' then
    local seqs = {}
    local cur
    cur, p = parse_seq(T, p + 1, { [']'] = true, [','] = true })
    seqs[#seqs + 1] = cur
    while T[p] == ',' do cur, p = parse_seq(T, p + 1, { [']'] = true, [','] = true }); seqs[#seqs + 1] = cur end
    if T[p] ~= ']' then error('missing ]') end
    p = p + 1
    node = #seqs == 1 and seqs[1] or { k = 'stack', c = seqs }
  elseif tk == '<' then
    local cur
    cur, p = parse_seq(T, p + 1, { ['>'] = true })
    if T[p] ~= '>' then error('missing >') end
    p = p + 1
    local alts = {}
    for _, st in ipairs(cur.c) do alts[#alts + 1] = st.n end
    node = { k = 'alt', c = alts }
  elseif tk == '~' then node = { k = 'rest' }; p = p + 1
  elseif tk and not tk:match('^[%]>,%*/!@%?%(%)]$') then node = { k = 'atom', v = tk }; p = p + 1
  else error('unexpected ' .. tostring(tk)) end
  -- модификаторы
  while true do
    local m = T[p]
    if m == '*' or m == '/' then
      local num = tonumber(T[p + 1]); if not num then error('number after ' .. m) end
      node = { k = m == '*' and 'fast' or 'slow', n = num, c = node }; p = p + 2
    elseif m == '?' then node = { k = 'degrade', c = node }; p = p + 1
    elseif m == '(' then
      local a, b = tonumber(T[p + 1]), tonumber(T[p + 3])
      local r = 0
      if not (a and T[p + 2] == ',' and b) then error('euclid (k,n)') end
      p = p + 4
      if T[p] == ',' then r = tonumber(T[p + 1]) or 0; p = p + 2 end
      if T[p] ~= ')' then error('missing )') end
      p = p + 1
      node = { k = 'euclid', a = a, b = b, r = r, c = node }
    else break end
  end
  return node, p
end
-- последовательность шагов с весами; ! и @ — на уровне шага
function parse_seq(T, p, stop)
  local steps = {}
  while T[p] and not stop[T[p]] do
    if T[p] == '!' and #steps > 0 and not tonumber(T[p + 1]) then   -- «a !» — ещё раз прошлый
      steps[#steps + 1] = { n = steps[#steps].n, w = 1 }; p = p + 1
    else
      local node
      node, p = parse_atom(T, p)
      local st = { n = node, w = 1 }
      steps[#steps + 1] = st
      while T[p] == '!' or T[p] == '@' do
        local num = tonumber(T[p + 1])
        if T[p] == '@' then st.w = num or 1; p = p + (num and 2 or 1)
        else for _ = 2, num or 2 do steps[#steps + 1] = { n = node, w = 1 } end; p = p + (num and 2 or 1) end
      end
    end
  end
  return { k = 'seq', c = steps }, p
end

function M.parse(s)
  local T = tokenize(s or '')
  local tree, p = parse_seq(T, 1, {})
  if T[p] then error('unexpected ' .. T[p]) end
  return tree
end

-- ── события цикла ─────────────────────────────────────────────────────────
local function hash(c, s) local x = math.sin(c * 12.9898 + s * 78.233) * 43758.5453; return x - math.floor(x) end

local function euclid(k, n, r)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = ((i * k) % n) < k end
  if r and r ~= 0 then
    local o2 = {}
    for i = 1, n do o2[i] = out[((i - 1 + r) % n) + 1] end
    out = o2
  end
  return out
end

-- события узла в цикле c (целое), в локальном [0, 1)
local function ev(node, c)
  local k = node.k
  if k == 'atom' then return { { s = 0, e = 1, v = node.v } }
  elseif k == 'rest' then return {}
  elseif k == 'seq' then
    local W = 0
    for _, st in ipairs(node.c) do W = W + st.w end
    local out, pos = {}, 0
    for _, st in ipairs(node.c) do
      local w = st.w / math.max(W, 1e-9)
      for _, e in ipairs(ev(st.n, c)) do out[#out + 1] = { s = pos + e.s * w, e = pos + e.e * w, v = e.v } end
      pos = pos + w
    end
    return out
  elseif k == 'stack' then
    local out = {}
    for _, ch in ipairs(node.c) do for _, e in ipairs(ev(ch, c)) do out[#out + 1] = e end end
    return out
  elseif k == 'alt' then
    local n = #node.c
    if n == 0 then return {} end
    return ev(node.c[(c % n) + 1], c // n)
  elseif k == 'fast' then
    local out = {}
    local n = node.n
    local whole = math.floor(n)
    if whole == n then
      for j = 0, whole - 1 do
        for _, e in ipairs(ev(node.c, c * whole + j)) do out[#out + 1] = { s = (j + e.s) / whole, e = (j + e.e) / whole, v = e.v } end
      end
      return out
    end
    return M.slowdown(node.c, c, 1 / n)
  elseif k == 'slow' then return M.slowdown(node.c, c, node.n)
  elseif k == 'degrade' then
    local out = {}
    for _, e in ipairs(ev(node.c, c)) do if hash(c, e.s) >= 0.5 then out[#out + 1] = e end end
    return out
  elseif k == 'euclid' then
    local pat = euclid(node.a, node.b, node.r)
    local out = {}
    for i, hit in ipairs(pat) do
      if hit then
        for _, e in ipairs(ev(node.c, c)) do out[#out + 1] = { s = (i - 1 + e.s) / node.b, e = (i - 1 + e.e) / node.b, v = e.v } end
      end
    end
    return out
  end
  return {}
end
M.ev = ev
-- медленнее в n раз: цикл c — часть [c / n, (c + 1) / n) исходного; события, что начинаются в ней
function M.slowdown(node, c, n)
  local out = {}
  local a, b = c / n, (c + 1) / n
  for cc = math.floor(a), math.ceil(b) - 1 do
    for _, e in ipairs(ev(node, cc)) do
      local s, e2 = cc + e.s, cc + e.e
      if s >= a - 1e-9 and s < b - 1e-9 then out[#out + 1] = { s = (s - a) * n, e = math.min(1, (e2 - a) * n), v = e.v } end
    end
  end
  return out
end

-- ── цепочка функций ───────────────────────────────────────────────────────
-- 'n("c e").fast(2).rev()' | '"c e" .fast 2' | 'c e g' → { mini = '…', ops = { { name, args } } }
function M.chain(expr)
  expr = (expr or ''):gsub('^%s+', ''):gsub('%s+$', '')
  local q = expr:match('^%a*%(?%s*"([^"]*)"%s*%)?') or expr:match("^%a*%(?%s*'([^']*)'%s*%)?")
  local rest
  if q then rest = expr:gsub('^%a*%(?%s*["\'][^"\']*["\']%s*%)?', '', 1)
  else
    local a = expr:find('%s*%.%a') -- голая строка до первой .функции
    q = a and expr:sub(1, a - 1) or expr
    rest = a and expr:sub(a) or ''
  end
  local ops = {}
  for name, args in rest:gmatch('%.(%a+)%s*%(([^%)]*)%)') do ops[#ops + 1] = { name = name, args = args } end
  for name, args in rest:gmatch('%.(%a+)%s+([^%.]+)') do if not rest:find('%.' .. name .. '%s*%(') then ops[#ops + 1] = { name = name, args = args } end end
  return { mini = q, ops = ops }
end

local NOTE = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }
-- значение → высота MIDI: c e4 f#3 bb2 eb (октава по умолчанию oct), число — ступень от base
function M.pitch(v, base, oct)
  if type(v) ~= 'string' then return nil end
  local num = tonumber(v)
  if num then return (base or 60) + math.floor(num) end
  local l, acc, o = v:lower():match('^([a-g])([#sbf]*)(%-?%d*)$')
  if not l then return nil end
  local p = NOTE[l]
  for ch in acc:gmatch('.') do p = p + ((ch == '#' or ch == 's') and 1 or -1) end
  return (tonumber(o ~= '' and o or nil) or (oct or 4)) * 12 + 12 + p
end

-- события с функциями цепочки в цикле c: { s, e, v, pitch, vel }
function M.query(expr, c, opts)
  opts = opts or {}
  local ch = M.chain(expr)
  local tree = M.parse(ch.mini)
  local fast, add, vel, revd = 1, 0, opts.vel or 0.8, false
  local every = {}
  for _, op in ipairs(ch.ops) do
    local a = op.args:gsub('^%s+', ''):gsub('%s+$', '')
    local num = tonumber((a:match('^[%-%d%.]+')))
    if op.name == 'fast' then fast = fast * (num or 1)
    elseif op.name == 'slow' then fast = fast / (num or 1)
    elseif op.name == 'rev' then revd = not revd
    elseif op.name == 'add' then add = add + (num or 0)
    elseif op.name == 'oct' then add = add + 12 * (num or 0)
    elseif op.name == 'vel' or op.name == 'gain' then vel = num or vel
    elseif op.name == 'every' then
      local n, what = a:match('^(%d+)%s*,?%s*["\']?(%a+)')
      if n then every[#every + 1] = { n = tonumber(n), what = what } end
    end
  end
  local node = tree
  if fast ~= 1 then node = fast > 1 and { k = 'fast', n = fast, c = tree } or { k = 'slow', n = 1 / fast, c = tree } end
  local evs = ev(node, c)
  for _, ew in ipairs(every) do if c % ew.n == 0 and ew.what == 'rev' then revd = not revd end end
  local out = {}
  for _, e in ipairs(evs) do
    local s, en = e.s, e.e
    if revd then s, en = 1 - e.e, 1 - e.s end
    local p = M.pitch(e.v, opts.base, opts.oct)
    out[#out + 1] = { s = s, e = en, v = e.v, pitch = p and (p + add) or nil, vel = vel }
  end
  table.sort(out, function(x, y) if math.abs(x.s - y.s) > 1e-9 then return x.s < y.s end return (x.pitch or 0) < (y.pitch or 0) end)
  return out
end

return M
