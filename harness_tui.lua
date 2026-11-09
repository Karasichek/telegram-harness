#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({
  DIR..'?.lua', DIR..'?/init.lua',
  package.path,
  '/data/data/com.termux/files/usr/share/lua/5.4/?.lua',
  '/data/data/com.termux/files/usr/share/lua/5.4/?/init.lua',
  '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua',
}, ';')

local argparse = require('argparse')
local json = require('dkjson')

local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function sh(cmd)
  local line = {}; for _, a in ipairs(cmd) do line[#line+1] = q(a) end
  local h = io.popen(table.concat(line, ' ')); local out = h and h:read('*a') or ''; if h then h:close() end; return out
end

local function width()
  local h = io.popen('stty size 2>/dev/null'); local s = h and h:read('*a') or ''; if h then h:close() end
  return tonumber(s:match('%d+ (%d+)')) or tonumber(os.getenv('COLUMNS')) or 80
end
local function glow(sep, text)
  local w, t = width(), (text or ''):gsub('^%s+',''):gsub('%s+$','')
  local f = w - (#t + 2); if f < 2 then io.write(sep:rep(w), '\n'); return end
  local l = math.floor(f/2); io.write(sep:rep(l),' ',t,' ',sep:rep(f-l),'\n')
end
-- env for child processes is passed via shell prefix in env_prefix()

local parser = argparse('harness', 'Harness TUI: Telegram post agent (photo+overlay+doc+Groq+page parse)')
parser:flag('-v --version'):action(function() print('harness-tui 1.0'); os.exit(0) end)
parser:option('--groq-key', 'Groq API key (or GROQ_API_KEY)'):default(os.getenv('GROQ_API_KEY') or '')
parser:option('--tg-token', 'Telegram bot token (or TG_TOKEN)'):default(os.getenv('TG_TOKEN') or '')
parser:option('--chat', 'Target channel/chat id'):default(os.getenv('TG_CHAT') or '-1003627991849')
parser:option('--model', 'Groq model'):default(os.getenv('GROQ_MODEL') or 'openai/gpt-oss-120b')
parser:option('--overlay', 'Overlay image path'):default(os.getenv('OVERLAY') or (os.getenv('HOME')..'/downloads/overlay.png'))
parser:option('--mc-ver', 'Default MC version'):default(os.getenv('MC_VERSION') or '26.30')
parser:option('--log', 'Log file'):default('/data/data/com.termux/files/usr/tmp/harness.log')

local subs = parser:command_target('cmd')
local idx = subs:command('index i', 'Индексировать папку для RAG (локальная база знаний)')
idx:argument('dir', 'Папка'):args('?')
local ask = subs:command('ask a', 'Спросить Groq с RAG-контекстом')
ask:argument('query', 'Вопрос/запрос'):args('+')
local run = subs:command('run r', 'Запустить polling harness')
run:flag('--fg', 'На переднем плане (по умолчанию фон)')
local once = subs:command('once o', 'Разовая генерация поста из локальных файлов (без Telegram polling)')
once:option('-i --image', 'Путь к изображению'):count(1)
once:option('-d --doc', 'Путь к файлу/документу аддона'):default('')
once:option('-n --name', 'Имя файла аддона (если --doc нет)'):default('addon.mcaddon')
once:option('-c --caption', 'Текст под фото / описание'):default('')
once:option('-u --url', 'URL страницы для парсинга'):default('')
once:flag('--post', 'Отправить в канал (иначе только вывести текст)')
local fmt = subs:command('format f', 'Только Groq: извлечь имя + отформатировать пост')
fmt:argument('filename', 'Имя файла аддона')
fmt:argument('caption', 'Текст/описание'):args('*')
local st = subs:command('status s', 'Статус фонового процесса и лог')
local sp = subs:command('stop x', 'Остановить фоновый процесс')

local args = parser:parse()

local function env_prefix(a)
  local p = {}
  local function e(k,v) if v and v~='' then p[#p+1]=k..'='..q(v) end end
  e('GROQ_API_KEY', a.groq_key); e('TG_TOKEN', a.tg_token); e('TG_CHAT', a.chat)
  e('GROQ_MODEL', a.model); e('OVERLAY', a.overlay); e('MC_VERSION', a.mc_ver)
  return table.concat(p, ' ')
end

if args.cmd == 'index' then
  glow('=', 'RAG INDEX')
  local dir = args.dir or (os.getenv('HOME')..'/kb')
  os.execute("lua5.4 -e \"package.path=package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua;/data/data/com.termux/files/home/?.lua'; local rag=require'rag'; local n=rag.index_dir('"..dir:gsub("'","").."'); rag.store=os.getenv('HOME')..'/rag_index.json'; rag.save(); print('dir="..dir:gsub("'","").." docs='..n)\"")
elseif args.cmd == 'ask' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'RAG ASK')
  local query = table.concat(args.query, ' ')
  local tmpf='/data/data/com.termux/files/usr/tmp/ask_run.lua'; local f=io.open(tmpf,'w')
  f:write(string.format([=[
package.path=package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua;/data/data/com.termux/files/home/?.lua'
local json=require('dkjson'); local rag=require('rag'); rag.load()
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(c) local l={}; for _,a in ipairs(c) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local ctx=rag.context(%q,4,3500) or '(нет локального контекста; проиндексируй: harness_tui.lua index ~/kb)'
local body=json.encode({model=%q,temperature=0.3,messages={{role='system',content='Отвечай по-русски, опираясь на контекст из базы знаний если релевантен. Кратко и по делу.'},{role='user',content='Контекст:\n'..ctx..'\n\nВопрос: '..%q}}})
local out=sh({'curl','-sS','--max-time','90','https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..%q,'-H','Content-Type: application/json','-d',body})
local obj=json.decode(out); if not obj or obj.error then print(out) else print(obj.choices[1].message.content) end
]=], query,args.model,query,args.groq_key)); f:close(); os.execute('lua5.4 '..q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'run' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'HARNESS')
  local cmd = 'cd ' .. q(os.getenv('HOME')) .. ' && ' .. env_prefix(args) .. ' lua5.4 ' .. q(os.getenv('HOME')..'/harness.lua')
  if args.fg then
    io.write('out=', args.chat, '\n'); os.execute(cmd)
  else
    os.execute(cmd .. ' >> ' .. q(args.log) .. ' 2>&1 & echo PID=$!')
    os.execute('sleep 1; tail -n 3 ' .. q(args.log))
  end
elseif args.cmd == 'once' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'ONCE')
  for k,v in pairs({GROQ_API_KEY=args.groq_key,TG_TOKEN=args.tg_token,TG_CHAT=args.chat,GROQ_MODEL=args.model,OVERLAY=args.overlay,MC_VERSION=args.mc_ver}) do
    if v and v~='' then end -- env set below via shell
  end
  local function escp(s) return (s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n')) end
  local lua = string.format([=[
package.path=package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua;/data/data/com.termux/files/home/?.lua'
local json=require('dkjson'); local tg=require('tg')
local CFG={tmp='/data/data/com.termux/files/usr/tmp',overlay=%q,out_chat=%q,mc_ver=%q,model=%q,groq_key=%q}
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(cmd) local l={}; for _,a in ipairs(cmd) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local function groq(sys,u)
  local body=json.encode({model=CFG.model,temperature=0.3,messages={{role='system',content=sys},{role='user',content=u}}})
  local out=sh({'curl','-sS','--max-time','90','https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..CFG.groq_key,'-H','Content-Type: application/json','-d',body})
  local obj=json.decode(out); if not obj or obj.error then return nil,out end; return obj.choices[1].message.content
end
local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
local function html_to_text(html)
  local s=html:gsub('<!%%-%%-.-%%-%%->',' ')
  for _,tag in ipairs({'script','style','noscript','svg','header','footer','nav'}) do s=s:gsub('<'..tag..'[%%s>/].-</'..tag..'%%s*>',' '); s=s:gsub('<'..tag..'[^>]*>',' ') end
  s=s:gsub('<[bB][rR]%%s*/?>','\n')
  for _,tag in ipairs({'p','div','li','tr','section','h%%d'}) do s=s:gsub('</'..tag..'%%s*>','\n'); s=s:gsub('<'..tag..'[%%s>/][^>]*>','\n') end
  s=s:gsub('<[^>]+>',' '); s=s:gsub('[ \t]+',' '); s=s:gsub(' *\n *','\n'); s=s:gsub('\n\n\n+','\n\n'); return s:gsub('^%%s+',''):gsub('%%s+$',''):sub(1,12000)
end
local img,doc,caption,url,fname,post = %q,%q,%q,%q,%q,%s
local uid=tostring(os.time()); local outimg=CFG.tmp..'/once_'..uid..'.jpg'
sh({'magick',img,'-gravity','SouthEast',CFG.overlay,'-geometry','+12+12','-composite',outimg})
local an=groq('Извлеки только чистое имя аддона из имени файла. Верни ТОЛЬКО имя (пример: "tacz 1.5.mcaddon"), без пояснений/кавычек.','Имя файла: '..fname) or fname
an=an:gsub('[\r\n"]+',''):gsub('^%%s+',''):gsub('%%s+$','')
local page_text; if url~='' then local h=sh({'curl','-sS','-L','--max-time','25','-A','Mozilla/5.0','--',url}); if h~='' then page_text=html_to_text(h) end end
local sys="Верни СТРОГО JSON (без markdown) с полями: name(без расширения),type(аддон|DLC|ресурспак|мир),description(подробно, по-русски, ~100 слов: что добавляет, фичи, геймплей, кому понравится; без тех.деталей),version(если нет \"26.30\")."
local user='Имя аддона: '..an..'\nТекст под фото:\n'..caption; if page_text then user=user..'\n\nТекст страницы:\n'..page_text:sub(1,6000) end
local out=groq(sys,user); local o=json.decode((out or ''):match('%%b{}') or out or '{}') or {}
local desc=tostring(o.description or caption):gsub('[\r\n]+',' '):gsub('%%s+',' ')
local text=string.format('『 <b>%%s</b> • #<b>%%s</b> 』<blockquote expandable>%%s@karasichekMC</blockquote><b>— Вᴇᴩᴄия: </b><code>%%s</code>+​', esc(o.name or an), esc(o.type or 'аддон'), esc(desc), esc(o.version or CFG.mc_ver))
print(text)
if post then
  local bot=tg.new(%q); local res=bot:post_photo(CFG.out_chat,'@'..outimg,text,{parse_mode='HTML'})
  print(json.encode(res))
  local footer='\n\n<a href="https://t.me/boost/KarasichekMC">⚡Буст</a> | <a href="https://t.me/karasichek_family">😺 Наш чат</a>\n\nПᴏдбᴏᴩᴋᴀ ᴀддᴏнᴏʙ:\n<a href="https://t.me/KarasichekMC/2338">🔥 Actions&amp;Stuff</a> | <a href="https://t.me/KarasichekMC/2260">😇 Aether</a>\n<a href="https://t.me/KarasichekMC/2290">🎨 Intresting GUI</a> | <a href="https://t.me/KarasichekMC/2314">🧔 Villager News</a>\n🪁 <a href="https://t.me/KarasichekMC/2335">Create Aeronautics</a> | 🔧 <a href="https://t.me/KarasichekMC/2327">Create</a>\n\n<b>@karasichekMC</b> — ᴏ Bᴇdrᴏᴄᴋ'
  if res and res.ok and doc~='' then print(json.encode(bot:post_doc(CFG.out_chat,'@'..doc,footer,{parse_mode='HTML',reply_parameters=json.encode({message_id=res.result.message_id})}))) end
end
os.remove(outimg)
]=], args.overlay, args.chat, args.mc_ver, args.model, args.groq_key,
    args.image, args.doc, args.caption, args.url, (args.doc~='' and args.doc:match('([^/]+)$') or args.name), tostring(args.post),
    args.tg_token)
  local tmpf = '/data/data/com.termux/files/usr/tmp/once_run.lua'
  local f=io.open(tmpf,'w'); f:write(lua); f:close()
  os.execute('lua5.4 ' .. q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'format' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'FORMAT')
  io.stdout:setvbuf('no')
  local caption = table.concat(args.caption or {}, ' ')
  local code = string.format([=[
package.path=package.path..';/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'
local json=require('dkjson')
local function q(v) return "'"..tostring(v):gsub("'","'\\''").."'" end
local function sh(c) local l={}; for _,a in ipairs(c) do l[#l+1]=q(a) end; local h=io.popen(table.concat(l,' ')); local o=h and h:read('*a') or ''; if h then h:close() end; return o end
local function groq(sys,u) local body=json.encode({model=%q,temperature=0.3,messages={{role='system',content=sys},{role='user',content=u}}}); local out=sh({'curl','-sS','--max-time','90','https://api.groq.com/openai/v1/chat/completions','-H','Authorization: Bearer '..%q,'-H','Content-Type: application/json','-d',body}); local obj=json.decode(out); if not obj or obj.error then return nil,out end; return obj.choices[1].message.content end
local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
local an=groq('Извлеки только чистое имя аддона. Верни ТОЛЬКО имя (пример: "tacz 1.5.mcaddon"), без пояснений/кавычек.','Имя файла: '..%q) or %q
an=an:gsub('[\r\n"]+',''):gsub('^%%s+',''):gsub('%%s+$','')
local out=groq("Верни СТРОГО JSON (без markdown): name(без расширения),type(аддон|DLC|ресурспак|мир),description(подробно,по-русски,~100 слов: фичи/геймплей/кому понравится; без тех.деталей),version(если нет "..%q..")", 'Имя: '..an..'\nТекст:\n'..%q)
local o=json.decode((out or ''):match('%%b{}') or out or '{}') or {}
local desc=tostring(o.description or ''):gsub('[\r\n]+',' '):gsub('%%s+',' ')
io.write('\n-- addon name: '..an..'\n')
local ver=tostring(o.version or ''); if ver=='' or ver:match('^1%%.0') then ver=%q end
print(string.format('『 <b>%%s</b> • #<b>%%s</b> 』<blockquote expandable>%%s@karasichekMC</blockquote><b>— Вᴇᴩᴄия: </b><code>%%s</code>+​', esc(o.name or an), esc(o.type or 'аддон'), esc(desc), esc(ver)))
]=], args.model,args.groq_key,args.filename,args.filename,args.mc_ver,caption,args.mc_ver)
  local tmpf='/data/data/com.termux/files/usr/tmp/fmt_run.lua'; local f=io.open(tmpf,'w'); f:write(code); f:close(); os.execute('lua5.4 '..q(tmpf)); os.remove(tmpf)
elseif args.cmd == 'status' then
  glow('-', 'STATUS')
  os.execute('pgrep -a lua 2>/dev/null | grep harness || echo "(no harness process)"')
  os.execute('echo ---; tail -n 8 ' .. q(args.log) .. ' 2>/dev/null || true')
elseif args.cmd == 'stop' then
  os.execute("pkill -f 'lua5%.4.*/harness%.lua' 2>/dev/null; echo stopped")
  os.execute('tail -n 2 ' .. q(args.log) .. ' 2>/dev/null || true')
else
  parser:print_help()
end
