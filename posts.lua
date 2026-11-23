-- posts.lua: cache of formatted posts (AI dedupe) + history of posted messages
local C = require('config')
local json = require('dkjson')

local M = { posts = {} }
local by_key = {}

local function load()
  local f = io.open(C.posts_file, 'rb')
  if not f then return end
  local obj = json.decode(f:read('*a') or '')
  f:close()
  if type(obj) == 'table' and type(obj.posts) == 'table' then
    for _, e in ipairs(obj.posts) do
      if type(e) == 'table' and e.key then by_key[e.key] = e; M.posts[#M.posts+1] = e end
    end
  end
end
load()

function M.get(key) return by_key[key] end

function M.add(e)
  if type(e) ~= 'table' or e.key == nil then return end
  local old = by_key[e.key]
  if old then
    for i, v in ipairs(M.posts) do if v == old then table.remove(M.posts, i); break end end
  end
  by_key[e.key] = e
  M.posts[#M.posts+1] = e
  local limit = tonumber(C.posts_limit) or 200
  while #M.posts > limit do
    local r = table.remove(M.posts, 1)
    if r then by_key[r.key] = nil end
  end
  local f = io.open(C.posts_file, 'wb'); if f then f:write(json.encode({posts = M.posts})); f:close() end
end

function M.list()
  local out = {}
  for _, e in ipairs(M.posts) do out[#out+1] = e end
  table.sort(out, function(a, b) return (a.at or 0) > (b.at or 0) end)
  return out
end
return M
