#!/usr/bin/env lua5.4
package.path = package.path .. ';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json = require('dkjson')
local M = {}

local function tmpname(prefix)
  local n = (os.getenv('HARNESS_TMP') or '/data/data/com.termux/files/usr/tmp') .. '/' .. (prefix or 'tgf') .. '_' .. tostring(os.time()) .. '_' .. tostring(math.random(0, 0x7fffffff)) .. '.dat'
  return n
end
local function write_secret(path, data)
  local old = os.umask and os.umask(63) or nil
  local f = io.open(path, 'wb'); if not f then if old and os.umask then os.umask(old) end; return nil end
  f:write(data); f:close(); if old and os.umask then os.umask(old) end; os.execute("chmod 600 " .. path) ; return path
end
local function write_tmp(data)
  local n = tmpname('tg'); local f = io.open(n,'wb'); if not f then return nil end; f:write(data); f:close(); return n
end

local function run_curl(args)
  local cmd = {'curl','-sS'}; for _, a in ipairs(args) do cmd[#cmd+1] = a end
  -- build argv via sh -c 'exec "$@"' -- ... to avoid shell parsing issues
  local line = {"'exec'"}; for _, a in ipairs(cmd) do line[#line+1] = "'" .. tostring(a):gsub("'","'\\''") .. "'" end
  local h = io.popen("sh -c 'exec \"$@\"' sh " .. table.concat(line, ' '))
  local out = h and h:read('*a') or ''; local ok, _, code = h and h:close() or false, nil, nil
  return out, ok, code
end

local function api(token, method, params, timeout)
  if not token or token == '' then return nil, 'missing token' end
  local cfg = tmpname('curlcfg')
  local cf = io.open(cfg,'wb'); if not cf then return nil, 'tmp failed' end
  cf:write('url = "https://api.telegram.org/bot' .. token .. '/' .. method .. '"\n')
  local tmps = {cfg}
  for k, v in pairs(params or {}) do
    if v ~= nil then
      v = tostring(v)
      if v:sub(1,1) == '@' then
        cf:write('form = "'..k..'='..v..'"\n')
      elseif v:find('[\n\r]') or #v > 700 or k=='caption' or k=='text' then
        local tf = write_tmp(v); if tf then tmps[#tmps+1]=tf; cf:write('form = "'..k..'=<'..tf..'"\n') else cf:write('form-string = "'..k..'='..v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')..'"\n') end
      else
        cf:write('form-string = "'..k..'='..v:gsub('\\','\\\\'):gsub('"','\\"')..'"\n')
      end
    end
  end
  cf:close(); os.execute('chmod 600 ' .. cfg)
  local body = select(1, run_curl({'--max-time', tostring(timeout or 30), '-K', cfg}))
  for _, tf in ipairs(tmps) do os.remove(tf) end
  local obj, _, err = json.decode(body)
  if not obj then return nil, err or body end
  return obj
end

function M.new(token) return setmetatable({token = token}, {__index = M}) end
function M:call(method, params, timeout) return api(self.token, method, params, timeout) end
function M:post(chat_id, text, params) params=params or {}; params.chat_id=chat_id; params.text=text; return self:call('sendMessage', params) end
function M:post_photo(chat_id, photo, caption, params)
  params=params or {}; params.chat_id=chat_id; params.photo=photo
  if caption and caption~='' then params.caption=caption end
  return self:call('sendPhoto', params, 120)
end
function M:post_doc(chat_id, document, caption, params)
  params=params or {}; params.chat_id=chat_id; params.document=document
  if caption and caption~='' then params.caption=caption end
  return self:call('sendDocument', params, 120)
end
function M:get_updates(offset, timeout)
  return self:call('getUpdates', {offset=offset, timeout=timeout or 30, allowed_updates=json.encode({'message'})}, (timeout or 30)+10)
end
function M:download(file_id, dest)
  local r = self:call('getFile', {file_id=file_id})
  if not (r and r.ok and r.result and r.result.file_path) then return nil, r end
  local cfg = tmpname('dlcfg'); local f = io.open(cfg,'wb'); if not f then return nil end
  f:write('url = "https://api.telegram.org/file/bot'..self.token..'/'..r.result.file_path..'"\noutput = "'..dest:gsub('\\','\\\\'):gsub('"','\\"')..'"\n'); f:close(); os.execute('chmod 600 '..cfg)
  local _, ok = run_curl({'-L','--max-time','120','-K',cfg}); os.remove(cfg)
  if not ok then os.remove(dest); return nil, 'download failed' end
  local fh = io.open(dest,'rb'); if not fh then return nil, 'no file' end; fh:close(); return dest
end

if arg and arg[0]:match('tg%.lua$') then
  local token = os.getenv('TG_TOKEN') or arg[1]
  local chat = os.getenv('TG_CHAT') or arg[2]
  if not token then io.stderr:write('set TG_TOKEN\n'); os.exit(1) end
  local text = table.concat(arg, ' ', (os.getenv('TG_TOKEN') and 2 or 3))
  if not chat or text == '' then io.stderr:write('usage: TG_TOKEN=.. TG_CHAT=.. lua5.4 tg.lua <text>\n'); os.exit(1) end
  local res = M.new(token):post(chat, text)
  print(json.encode(res, {indent=true}))
  if not (res and res.ok) then os.exit(2) end
end
return M
