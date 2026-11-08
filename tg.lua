#!/usr/bin/env lua5.4
package.path = package.path .. ';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json = require('dkjson')

local M = {}

local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

local function sh(cmd)
  local line = {}; for _, a in ipairs(cmd) do line[#line+1] = q(a) end
  local h = io.popen(table.concat(line, ' ')); local out = h and h:read('*a') or ''; if h then h:close() end; return out
end

local function api(token, method, params, timeout)
  local cmd = {'curl', '-sS', '--max-time', tostring(timeout or 30), 'https://api.telegram.org/bot' .. token .. '/' .. method}
  for k, v in pairs(params or {}) do
    if v ~= nil then
      cmd[#cmd+1] = (type(v)=='string' and v:sub(1,1)=='@') and '-F' or '-F'
      cmd[#cmd+1] = k .. '=' .. tostring(v)
    end
  end
  local body = sh(cmd)
  local obj, _, err = json.decode(body)
  if not obj then return nil, err or body end
  return obj
end

function M.new(token) return setmetatable({token = token}, {__index = M}) end
function M:call(method, params, timeout) return api(self.token, method, params, timeout) end
function M:post(chat_id, text, params)
  params = params or {}; params.chat_id = chat_id; params.text = text
  return self:call('sendMessage', params)
end
function M:post_photo(chat_id, photo, caption, params)
  params = params or {}; params.chat_id = chat_id; params.photo = photo
  if caption and caption ~= '' then params.caption = caption end
  return self:call('sendPhoto', params, 120)
end
function M:post_doc(chat_id, document, caption, params)
  params = params or {}; params.chat_id = chat_id; params.document = document
  if caption and caption ~= '' then params.caption = caption end
  return self:call('sendDocument', params, 120)
end
function M:get_updates(offset, timeout)
  return self:call('getUpdates', {offset = offset, timeout = timeout or 30, allowed_updates = json.encode({'message'})}, (timeout or 30) + 10)
end
function M:get_file(file_id)
  local r = self:call('getFile', {file_id = file_id})
  if r and r.ok and r.result and r.result.file_path then
    local url = 'https://api.telegram.org/file/bot' .. self.token .. '/' .. r.result.file_path
    return url, r.result.file_path
  end
  return nil, r
end
function M:download(file_id, dest)
  local url = self:get_file(file_id); if not url then return nil end
  sh({'curl','-sS','-L','--max-time','120','-o', dest, url}); return dest
end

if arg and arg[0]:match('tg%.lua$') then
  local token = os.getenv('TG_TOKEN') or arg[1]
  local chat = os.getenv('TG_CHAT') or arg[2]
  if not token then io.stderr:write('set TG_TOKEN\n'); os.exit(1) end
  local text = table.concat(arg, ' ', (os.getenv('TG_TOKEN') and 2 or 3))
  if not token or not chat or text == '' then
    io.stderr:write('usage: TG_TOKEN=.. TG_CHAT=.. lua5.4 tg.lua <text>\n   or: lua5.4 tg.lua <token> <chat_id> <text>\n')
    os.exit(1)
  end
  local res = M.new(token):post(chat, text)
  print(json.encode(res, {indent=true}))
  if not (res and res.ok) then os.exit(2) end
end

return M
