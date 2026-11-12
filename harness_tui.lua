#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({DIR..'?.lua', DIR..'?/init.lua', package.path,
  '/data/data/com.termux/files/usr/share/lua/5.4/?.lua','/data/data/com.termux/files/usr/share/lua/5.4/?/init.lua',
  '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'}, ';')
local argparse = require('argparse')
local json = require('dkjson')
local C = require('config')

local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function sh(argv)
  local line = {"'exec'"}; for _, a in ipairs(argv) do line[#line+1] = "'"..tostring(a):gsub("'","'\\''").."'" end
  local h = io.popen("sh -c 'exec \"$@\"' sh " .. table.concat(line,' ')); local o=h and h:read('*a') or ''; local ok=h and h:close() or false; return o, ok
end
local function glow(sep, text)
  local h=io.popen('stty size 2>/dev/null'); local s=h and h:read('*a') or ''; if h then h:close() end
  local w = tonumber(s:match('%d+ (%d+)')) or tonumber(os.getenv('COLUMNS')) or 80
  local t=(text or ''):gsub('^%s+',''):gsub('%s+$',''); local f=w-(#t+2)
  if f<2 then io.write(sep:rep(w),'\n'); return end; local l=math.floor(f/2); io.write(sep:rep(l),' ',t,' ',sep:rep(f-l),'\n')
end
local function env_prefix(a)
  local p={}; local function e(k,v) if v and v~='' then p[#p+1]=k..'='..q(v) end end
  e('GROQ_API_KEY',a.groq_key); e('TG_TOKEN',a.tg_token); e('TG_CHAT',a.chat); e('GROQ_MODEL',a.model); e('OVERLAY',a.overlay); e('MC_VERSION',a.mc_ver)
  return table.concat(p,' ')
end

local parser = argparse('harness', 'Harness TUI (config: '..DIR..'config.lua)')
parser:flag('-v --version'):action(function() print('harness-tui 1.2'); os.exit(0) end)
parser:option('--groq-key','Groq API key (or GROQ_API_KEY)'):default(C.groq_key or '')
parser:option('--tg-token','Telegram bot token (or TG_TOKEN)'):default(C.tg_token or '')
parser:option('--chat','Target channel/chat id'):default(C.out_chat)
parser:option('--model','Groq model'):default(C.model)
parser:option('--overlay','Overlay image path'):default(C.overlay)
parser:option('--mc-ver','Default MC version'):default(C.mc_ver)
parser:option('--log','Log file'):default(C.log)

local subs = parser:command_target('cmd')
local idx = subs:command('index i','Индексировать папку для RAG'); idx:argument('dir','Папка'):args('?')
local ask = subs:command('ask a','Спросить Groq с RAG-контекстом'); ask:argument('query','Вопрос'):args('+')
local run = subs:command('run r','Запустить polling harness'); run:flag('--fg','На переднем плане')
local once = subs:command('once o','Разовая генерация из локальных файлов')
once:option('-i --image','Изображение'):count(1); once:option('-d --doc','Файл аддона'):default(''); once:option('-n --name','Имя аддона'):default('addon.mcaddon')
once:option('-c --caption','Текст/описание'):default(''); once:option('-u --url','URL страницы'):default(''); once:flag('--post','Отправить в канал')
local fmt = subs:command('format f','Groq: имя + формат поста'); fmt:argument('filename','Имя файла'); fmt:argument('caption','Описание'):args('*')
local st = subs:command('status s','Статус/лог'); local sp = subs:command('stop x','Остановить')

local args = parser:parse()

if args.cmd == 'index' then
  glow('=', 'RAG INDEX')
  local dir = args.dir or C.kb_dir
  local rag = require('rag'); rag.store = C.rag_store; local n = rag.index_dir(dir); rag.save(); print('dir='..dir..' docs='..tostring(n)..' store='..rag.store)
elseif args.cmd == 'ask' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'RAG ASK')
  local query = table.concat(args.query,' ')
  local rag = require('rag'); rag.store = C.rag_store; rag.load()
  local ctx = rag.context(query, C.rag_k, C.rag_max) or '(нет локального контекста)'
  local bodyf, hdrf, outf = C.tmp..'/ask_b.json', C.tmp..'/ask_h.txt', C.tmp..'/ask_o.json'
  local bf=io.open(bodyf,'wb'); bf:write(json.encode({model=args.model,temperature=C.temperature,messages={{role='system',content='Отвечай по-русски, опираясь на контекст если релевантен. Кратко.'},{role='user',content='Контекст:\n'..ctx..'\n\nВопрос: '..query}}})); bf:close()
  local hf=io.open(hdrf,'wb'); hf:write('Authorization: Bearer '..args.groq_key..'\nContent-Type: application/json\n'); hf:close(); os.execute('chmod 600 '..hdrf)
  sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','@'..hdrf,'--data-binary','@'..bodyf,'-o',outf})
  local of=io.open(outf,'rb'); local raw=of and of:read('*a') or ''; if of then of:close() end; os.remove(bodyf); os.remove(hdrf); os.remove(outf)
  local obj=json.decode(raw); if obj and obj.choices and obj.choices[1] then print(obj.choices[1].message.content) else print(raw) end
elseif args.cmd == 'run' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'HARNESS')
  local cmd = 'cd '..q(C.home)..' && '..env_prefix(args)..' '..q('lua5.4')..' '..q(DIR..'harness.lua')
  if args.fg then io.write('out=', args.chat, '\n'); os.execute(cmd)
  else os.execute(cmd..' >> '..q(args.log)..' 2>&1 & echo PID=$!'); os.execute('sleep 1; tail -n 3 '..q(args.log)) end
elseif args.cmd == 'once' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'ONCE')
  local tgmod = require('tg'); local okrag,rag = pcall(require,'rag')
  local function groq_call(key,model,sys,user)
    local bodyf,hdrf,outf = C.tmp..'/o_b.json', C.tmp..'/o_h.txt', C.tmp..'/o_o.json'
    local bf=io.open(bodyf,'wb'); bf:write(json.encode({model=model,temperature=C.temperature,messages={{role='system',content=sys},{role='user',content=user}}})); bf:close()
    local hf=io.open(hdrf,'wb'); hf:write('Authorization: Bearer '..key..'\nContent-Type: application/json\n'); hf:close(); os.execute('chmod 600 '..hdrf)
    sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','@'..hdrf,'--data-binary','@'..bodyf,'-o',outf})
    local of=io.open(outf,'rb'); local raw=of and of:read('*a') or ''; if of then of:close() end; os.remove(bodyf); os.remove(hdrf); os.remove(outf)
    local obj=json.decode(raw); if obj and obj.choices and obj.choices[1] then return obj.choices[1].message.content end; return nil,raw
  end
  local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
  local function html_to_text(html)
    local s=html:gsub('<!%-%-.-%-%->',' '); for _,tag in ipairs({'script','style','noscript','svg','header','footer','nav'}) do s=s:gsub('<'..tag..'[%s>/].-</'..tag..'%s*>',' '):gsub('<'..tag..'[^>]*>',' ') end
    s=s:gsub('<[bB][rR]%s*/?>','\n'); for _,tag in ipairs({'p','div','li','tr','section','h%d'}) do s=s:gsub('</'..tag..'%s*>','\n'):gsub('<'..tag..'[%s>/][^>]*>','\n') end
    s=s:gsub('<[^>]+>',' '):gsub('[ \t]+',' '):gsub(' *\n *','\n'):gsub('\n\n\n+','\n\n'):gsub('^%s+',''):gsub('%s+$',''); return s:sub(1,C.page_max)
  end
  local fname = (args.doc~='' and args.doc:match('([^/]+)$')) or args.name
  local outimg = C.tmp..'/once_'..tostring(os.time())..'.jpg'
  sh({'magick', args.image, '-gravity','SouthEast', args.overlay, '-geometry','+12+12', '-composite', outimg})
  local an = select(1, groq_call(args.groq_key, args.model, C.prompt_extract_name, 'Имя файла: '..fname)) or fname
  an = an:gsub('[\r\n"]+',''):gsub('^%s+',''):gsub('%s+$',''); if an=='' then an=fname end
  local page_text
  if args.url~='' then local out = select(1, sh({'curl','-sS','-L','--max-time','25','--max-redirs','3','--proto','=http,https','-A','Mozilla/5.0','--',args.url})); if out~='' then page_text=html_to_text(out) end end
  local user='Имя аддона: '..an..'\nТекст под фото:\n'..(args.caption or ''); if page_text then user=user..'\n\nТекст страницы:\n'..page_text:sub(1,6000) end
  if okrag and rag then rag.store=C.rag_store; rag.load(); local ctx=rag.context(an..' '..(args.caption or ''),C.rag_k,C.rag_max); if ctx then user=user..'\n\nКонтекст из базы знаний (RAG):\n'..ctx end end
  local out, err = groq_call(args.groq_key, args.model, C.prompt_format:format(args.mc_ver), user)
  local obj = (out and json.decode(out:match('%b{}') or out)) or {}
  local ver=tostring(obj.version or ''); if ver=='' or ver:match('^1%.0') then ver=args.mc_ver end
  local desc=tostring(obj.description or args.caption or ''):gsub('[\r\n]+',' '):gsub('%s+',' ')
  local text=string.format('『 <b>%s</b> • #<b>%s</b> 』<blockquote expandable>%s%s</blockquote><b>— Вᴇᴩᴄия: </b><code>%s</code>+​', esc(obj.name or an), esc(obj.type or 'аддон'), esc(desc), C.author, esc(ver))
  print(text)
  if not out then io.stderr:write('groq error: '..tostring(err)..'\n') end
  if args.post then
    local bot=tgmod.new(args.tg_token); local res=bot:post_photo(args.chat,'@'..outimg,text,{parse_mode='HTML'}); print(json.encode(res))
    if res and res.ok and args.doc~='' then print(json.encode(bot:post_doc(args.chat,'@'..args.doc,C.footer,{parse_mode='HTML',reply_parameters=json.encode({message_id=res.result.message_id})}))) end
  end
  os.remove(outimg)
elseif args.cmd == 'format' then
  if args.groq_key == '' then io.stderr:write('нужен --groq-key или GROQ_API_KEY\n'); os.exit(1) end
  glow('=', 'FORMAT')
  local caption=table.concat(args.caption or {},' ')
  local function groq_call(key,model,sys,user)
    local bodyf,hdrf,outf=C.tmp..'/f_b.json',C.tmp..'/f_h.txt',C.tmp..'/f_o.json'
    local bf=io.open(bodyf,'wb'); bf:write(json.encode({model=model,temperature=C.temperature,messages={{role='system',content=sys},{role='user',content=user}}})); bf:close()
    local hf=io.open(hdrf,'wb'); hf:write('Authorization: Bearer '..key..'\nContent-Type: application/json\n'); hf:close(); os.execute('chmod 600 '..hdrf)
    sh({'curl','-sS','--max-time',tostring(C.groq_timeout),'https://api.groq.com/openai/v1/chat/completions','-H','@'..hdrf,'--data-binary','@'..bodyf,'-o',outf})
    local of=io.open(outf,'rb'); local raw=of and of:read('*a') or ''; if of then of:close() end; os.remove(bodyf); os.remove(hdrf); os.remove(outf)
    local obj=json.decode(raw); if obj and obj.choices and obj.choices[1] then return obj.choices[1].message.content end; return nil,raw
  end
  local function esc(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
  local an=select(1,groq_call(args.groq_key,args.model,C.prompt_extract_name,'Имя файла: '..args.filename)) or args.filename
  an=an:gsub('[\r\n"]+',''):gsub('^%s+',''):gsub('%s+$',''); if an=='' then an=args.filename end
  local out,err=groq_call(args.groq_key,args.model,C.prompt_format:format(args.mc_ver),'Имя: '..an..'\nТекст:\n'..caption)
  local obj=(out and json.decode(out:match('%b{}') or out)) or {}
  local ver=tostring(obj.version or ''); if ver=='' or ver:match('^1%.0') then ver=args.mc_ver end
  local desc=tostring(obj.description or ''):gsub('[\r\n]+',' '):gsub('%s+',' ')
  io.write('\n-- addon name: '..an..'\n')
  print(string.format('『 <b>%s</b> • #<b>%s</b> 』<blockquote expandable>%s%s</blockquote><b>— Вᴇᴩᴄия: </b><code>%s</code>+​', esc(obj.name or an), esc(obj.type or 'аддон'), esc(desc), C.author, esc(ver)))
  if not out then io.stderr:write('groq error: '..tostring(err)..'\n') end
elseif args.cmd == 'status' then
  glow('-', 'STATUS'); os.execute('pgrep -a lua 2>/dev/null | grep harness || echo "(no harness process)"'); os.execute('echo ---; tail -n 8 '..q(args.log)..' 2>/dev/null || true')
elseif args.cmd == 'stop' then os.execute("pkill -f 'lua5%.4.*/harness%.lua' 2>/dev/null; echo stopped")
else parser:print_help() end
