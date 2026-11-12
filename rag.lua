#!/usr/bin/env lua5.4
-- tiny local RAG (BM25-ish over text files)
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
package.path = script_dir()..'?.lua;' .. package.path .. ';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json = require('dkjson')
local M = { store = os.getenv('RAG_STORE') or (os.getenv('HOME') .. '/rag_index.json'), docs = {} }

local function tokens(s)
  s = (s or ''):lower():gsub('[%z\1-\31]', ' ')
  local t = {}; for w in s:gmatch("[%w\128-\255_%-]+") do if #w > 1 then t[#t+1] = w end end; return t
end
local function tf(tokens_list)
  local m, n = {}, #tokens_list
  for _, w in ipairs(tokens_list) do m[w] = (m[w] or 0) + 1 end
  for w, c in pairs(m) do m[w] = c / math.max(n,1) end
  return m
end
function M.add(id, text, meta)
  M.docs[#M.docs+1] = {id=id, text=text or '', meta=meta or {}, tf=tf(tokens(text)), len=#(text or '')}
end
function M.index_dir(dir)
  M.docs = {}
  local h = io.popen("find '" .. tostring(dir):gsub("'","'\\''") .. "' -type f 2>/dev/null")
  local n = 0
  for path in (h and h:lines() or function() end) do
    if path:match('%.txt$') or path:match('%.md$') or path:match('%.lua$') then
      local f = io.open(path,'rb'); if f then local t=f:read('*a') or ''; f:close(); M.add(path,t,{path=path}); n=n+1 end
    end
  end
  if h then h:close() end; return n
end
function M.save(path)
  path = path or M.store; local f = io.open(path,'wb'); if not f then return nil end
  f:write(json.encode({docs=M.docs})); f:close(); return path
end
function M.load(path)
  path = path or M.store; local f = io.open(path,'rb'); if not f then return false end
  local o = json.decode(f:read('*a') or ''); f:close(); M.docs = (o and o.docs) or {}; return true
end
function M.search(query, k)
  k = k or 4; local qt = tokens(query); if #qt == 0 or #M.docs == 0 then return {} end
  local df = {}
  for _, d in ipairs(M.docs) do for _, w in ipairs(qt) do if d.tf and d.tf[w] then df[w]=(df[w] or 0)+1 end end end
  local N, scored = #M.docs, {}
  for _, d in ipairs(M.docs) do
    local s = 0
    for _, w in ipairs(qt) do local idf = math.log((N - (df[w] or 0) + 0.5) / ((df[w] or 0) + 0.5) + 1); s = s + ((d.tf and d.tf[w]) or 0) * idf end
    if s > 0 then scored[#scored+1] = {score=s, doc=d} end
  end
  table.sort(scored, function(a,b) return a.score > b.score end)
  local out = {}; for n=1, math.min(k,#scored) do local d=scored[n].doc; out[n]={id=d.id,score=scored[n].score,text=d.text,meta=d.meta} end
  return out
end
function M.context(query, k, maxchars)
  maxchars = maxchars or 3500
  local parts, used = {}, 0
  for i, h in ipairs(M.search(query, k or 4)) do
    local chunk = ('[источник %d: %s]\n%s'):format(i, h.id, (h.text or ''):sub(1,1200))
    if used + #chunk > maxchars then break end
    parts[#parts+1]=chunk; used=used+#chunk
  end
  if #parts == 0 then return nil end; return table.concat(parts, '\n\n')
end

if arg and arg[0]:match('rag%.lua$') then
  local cmd = arg[1]
  if cmd == 'index' then M.index_dir(arg[2] or '.'); M.save(); print('indexed', #M.docs, '->', M.store)
  elseif cmd == 'search' then M.load(); local q = table.concat(arg,' ',2); for i,h in ipairs(M.search(q,5)) do print(('%.4f %s'):format(h.score,h.id)); print((h.text:gsub('%s+',' ')):sub(1,180)); print('---') end
  else io.stderr:write('usage: lua5.4 rag.lua index [dir] | search <query>\n') end
end
return M
