#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({
  DIR..'?.lua', DIR..'?/init.lua', package.path,
  '/data/data/com.termux/files/usr/share/lua/5.4/?.lua',
  '/data/data/com.termux/files/usr/share/lua/5.4/?/init.lua',
  '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua',
}, ';')

local argparse = require('argparse')
local json = require('dkjson')
local C = require('config')

local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function width()
  local h = io.popen('stty size 2>/dev/null'); local s = h and h:read('*a') or ''; if h then h:close() end
  return tonumber(s:match('%d+ (%d+)')) or tonumber(os.getenv('COLUMNS')) or 80
end
local function glow(sep, text)
  local w, t = width(), (text or ''):gsub('^%s+',''):gsub('%s+$','')
  local f = w - (#t + 2); if f < 2 then io.write(sep:rep(w), '\n'); return end
  local l = math.floor(f/2); io.write(sep:rep(l),' ',t,' ',sep:rep(f-l),'\n')
end

local parser = argparse('harness', 'Harness TUI (config: '..DIR..'config.lua)')
parser:flag('-v --version'):action(function() print('harness-tui 1.1'); os.exit(0) end)
parser:option('--groq-key', 'Groq API key (or GROQ_API_KEY)'):default(C.groq_key or '')
parser:option('--tg-token', 'Telegram bot token (or TG_TOKEN)'):default(C.tg_token or '')
parser:option('--chat', 'Target channel/chat id'):default(C.out_chat)
parser:option('--model', 'Groq model'):default(C.model)
parser:option('--overlay', 'Overlay image path'):default(C.overlay)
parser:option('--mc-ver', 'Default MC version'):default(C.mc_ver)
parser:option('--log', 'Log file'):default(C.log)

local subs = parser:command_target('cmd')
local idx = subs:command('index i', 'Индексировать папку для RAG')
idx:argument('dir', 'Папка'):args('?')
local ask = subs:command('ask a', 'Спросить Groq с RAG-контекстом')
ask:argument('query', 'Вопрос/запрос'):args('+')
local run = subs:command('run r', 'Запустить polling harness')
run:flag('--fg', 'На переднем плане')
local once = subs:command('once o', 'Разовая генерация из локальных файлов')
once:option('-i --image', 'Путь к изображению'):count(1)
once:option('-d --doc', 'Путь к файлу аддона'):default('')
once:option('-n --name', 'Имя файла аддона'):default('addon.mcaddon')
once:option('-c --caption', 'Текст под фото'):default('')
once:option('-u --url', 'URL страницы'):default('')
once:flag('--post', 'Отправить в канал')
local fmt = subs:command('format f', 'Groq: имя + формат поста')
fmt:argument('filename', 'Имя файла')
fmt:argument('caption', 'Описание'):args('*')
local st = subs:command('status s', 'Статус/лог')
local sp = subs:command('stop x', 'Остановить')

local args = parser:parse()

local function env_prefix(a)
  local p = {}; local function e(k,v) if v and v~='' then p[#p+1]=k..'='..q(v) end end
  e('GROQ_API_KEY', a.groq_key); e('TG_TOKEN', a.tg_token); e('TG_CHAT', a.chat)
  e('GROQ_MODEL', a.model); e('OVERLAY', a.overlay); e('MC_VERSION', a.mc_ver)
  return table.concat(p, ' ')
end

if args.cmd == 'index' then
  glow('=', 'RAG INDEX')
  local dir = args.dir or C.kb_dir
  os.execute(string.format("lua5.4 -e %s", q("package.path="..q(DIR.."?.lua;").."..package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'; local C=require'config'; local rag=require'rag'; local n=rag.index_dir("..q(dir).."); rag.store=C.rag_store; rag.save(); print('dir="..dir:gsub("'","").." docs='..n)")))
elseif args.cmd == 'ask' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'RAG ASK')
  local query = table.concat(args.query, ' ')
  local tmpf=C.tmp..'/ask_run.lua'; local f=io.open(tmpf,'w')
  f:write(string.format([=[
package.path=%q..package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json=require('dkjson'); local C=require('config'); local rag=require('rag'); rag.store=C.rag_store; rag.load()
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(c) local l={}; for _,a in ipairs(c) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local ctx=rag.context(%q,C.rag_k,C.rag_max) or '(нет локального контекста)'
local body=json.encode({model=C.model,temperature=C.temperature,messages={{role='system',content='Отвечай по-русски, опираясь на контекст если релевантен. Кратко.'},{role='user',content='Контекст:\n'..ctx..'\n\nВопрос: '..%q}}})
local out=sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..(C.groq_key or %q),'-H','Content-Type: application/json','-d',body})
local obj=json.decode(out); if not obj or obj.error then print(out) else print(obj.choices[1].message.content) end
]=], DIR..'?.lua;', query, query, args.groq_key)); f:close(); os.execute('lua5.4 '..q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'run' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'HARNESS')
  local cmd = 'cd ' .. q(C.home) .. ' && ' .. env_prefix(args) .. ' lua5.4 ' .. q(DIR..'harness.lua')
  if args.fg then io.write('out=', args.chat, '\n'); os.execute(cmd)
  else os.execute(cmd .. ' >> ' .. q(args.log) .. ' 2>&1 & echo PID=$!'); os.execute('sleep 1; tail -n 3 ' .. q(args.log)) end
elseif args.cmd == 'once' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'ONCE')
  local fname = (args.doc~='' and args.doc:match('([^/]+)$') or args.name)
  local tmpf = C.tmp .. '/once_run.lua'; local f=io.open(tmpf,'w')
  f:write(string.format([=[
package.path=%q..package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json=require('dkjson'); local tg=require('tg'); local C=require('config'); local okrag,rag=pcall(require,'rag')
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(cmd) local l={}; for _,a in ipairs(cmd) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local function groq(sys,u) local body=json.encode({model=C.model,temperature=C.temperature,messages={{role='system',content=sys},{role='user',content=u}}}); local out=sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..(C.groq_key or %q),'-H','Content-Type: application/json','-d',body}); local obj=json.decode(out); if not obj or obj.error then return nil,out end; return obj.choices[1].message.content end
local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
local function html_to_text(html) local s=html:gsub('<!%%-%%-.-%%-%%->',' '); for _,tag in ipairs({'script','style','noscript','svg','header','footer','nav'}) do s=s:gsub('<'..tag..'[%%s>/].-</'..tag..'%%s*>',' '):gsub('<'..tag..'[^>]*>',' ') end; s=s:gsub('<[bB][rR]%%s*/?>','\n'); for _,tag in ipairs({'p','div','li','tr','section','h%%d'}) do s=s:gsub('</'..tag..'%%s*>','\n'):gsub('<'..tag..'[%%s>/][^>]*>','\n') end; s=s:gsub('<[^>]+>',' '):gsub('[ \t]+',' '):gsub(' *\n *','\n'):gsub('\n\n\n+','\n\n'); return s:gsub('^%%s+',''):gsub('%%s+$',''):sub(1,C.page_max) end
local img,doc,caption,url,fname,post,out_chat = %q,%q,%q,%q,%q,%s,%q
local outimg=C.tmp..'/once_'..tostring(os.time())..'.jpg'
sh({'magick',img,'-gravity','SouthEast',C.overlay,'-geometry','+12+12','-composite',outimg})
local an=groq(C.prompt_extract_name,'Имя файла: '..fname) or fname; an=an:gsub('[\r\n"]+',''):gsub('^%%s+',''):gsub('%%s+$',''); if an=='' then an=fname end
local page_text; if url~='' then local h=sh({'curl','-sS','-L','--max-time','25','-A','Mozilla/5.0','--',url}); if h~='' then page_text=html_to_text(h) end end
local user='Имя аддона: '..an..'\nТекст под фото:\n'..caption; if page_text then user=user..'\n\nТекст страницы:\n'..page_text:sub(1,6000) end
if okrag and rag then rag.store=C.rag_store; rag.load(); local ctx=rag.context(an..' '..caption,C.rag_k,C.rag_max); if ctx then user=user..'\n\nКонтекст из базы знаний (RAG):\n'..ctx end end
local out=groq(C.prompt_format,user); local o=json.decode((out or ''):match('%%b{}') or out or '{}') or {}
local desc=tostring(o.description or caption):gsub('[\r\n]+',' '):gsub('%%s+',' '); local ver=tostring(o.version or ''); if ver=='' then ver=C.mc_ver end
local text=string.format('『 <b>%%s</b> • #<b>%%s</b> 』<blockquote expandable>%%s%%s</blockquote><b>— Вᴇᴩᴄия: </b><code>%%s</code>+​', esc(o.name or an), esc(o.type or 'аддон'), esc(desc), C.author, esc(ver))
print(text)
if post then local bot=tg.new(C.tg_token); local res=bot:post_photo(out_chat,'@'..outimg,text,{parse_mode='HTML'}); print(json.encode(res)); if res and res.ok and doc~='' then print(json.encode(bot:post_doc(out_chat,'@'..doc,C.footer,{parse_mode='HTML',reply_parameters=json.encode({message_id=res.result.message_id})}))) end end
os.remove(outimg)
]=], DIR..'?.lua;', args.groq_key, args.image, args.doc, args.caption, args.url, fname, tostring(args.post), args.chat)); f:close()
  os.execute('lua5.4 '..q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'format' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'FORMAT')
  local caption = table.concat(args.caption or {}, ' ')
  local tmpf=C.tmp..'/fmt_run.lua'; local f=io.open(tmpf,'w')
  f:write(string.format([=[
package.path=%q..package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json=require('dkjson'); local C=require('config')
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(c) local l={}; for _,a in ipairs(c) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local function groq(sys,u) local body=json.encode({model=C.model,temperature=C.temperature,messages={{role='system',content=sys},{role='user',content=u}}}); local out=sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..(C.groq_key or %q),'-H','Content-Type: application/json','-d',body}); local obj=json.decode(out); if not obj or obj.error then return nil,out end; return obj.choices[1].message.content end
local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
local an=groq(C.prompt_extract_name,'Имя файла: '..%q) or %q; an=an:gsub('[\r\n"]+',''):gsub('^%%s+',''):gsub('%%s+$',''); if an=='' then an=%q end
local out=groq(C.prompt_format, 'Имя: '..an..'\nТекст:\n'..%q); local o=json.decode((out or ''):match('%%b{}') or out or '{}') or {}
local desc=tostring(o.description or ''):gsub('[\r\n]+',' '):gsub('%%s+',' '); local ver=tostring(o.version or ''); if ver=='' or ver:match('^1%%.0') then ver=C.mc_ver end
io.write('\n-- addon name: '..an..'\n')
print(string.format('『 <b>%%s</b> • #<b>%%s</b> 』<blockquote expandable>%%s%%s</blockquote><b>— Вᴇᴩᴄия: </b><code>%%s</code>+​', esc(o.name or an), esc(o.type or 'аддон'), esc(desc), C.author, esc(ver)))
]=], DIR..'?.lua;', args.groq_key, args.filename,args.filename,args.filename, caption)); f:close(); os.execute('lua5.4 '..q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'status' then
  glow('-', 'STATUS'); os.execute('pgrep -a lua 2>/dev/null | grep harness || echo "(no harness process)"'); os.execute('echo ---; tail -n 8 ' .. q(args.log) .. ' 2>/dev/null || true')
elseif args.cmd == 'stop' then
  os.execute("pkill -f 'lua5%.4.*/harness%.lua' 2>/dev/null; echo stopped")
else parser:print_help() end
