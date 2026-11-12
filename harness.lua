#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({DIR..'?.lua', DIR..'?/init.lua', package.path, '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'}, ';')
local C = require('config')
local json = require('dkjson')
local tg = require('tg')
local okrag, rag = pcall(require, 'rag')

local function tmp(base, ext) return C.tmp..'/'..base..'_'..tostring(os.time())..'_'..tostring(math.random(0,0x7fffffff))..(ext or '') end
local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function run(argv)
  local line = {"'exec'"}; for _, a in ipairs(argv) do line[#line+1] = "'"..tostring(a):gsub("'","'\\''").."'" end
  local h = io.popen("sh -c 'exec \"$@\"' sh " .. table.concat(line,' '))
  local out = h and h:read('*a') or ''; local ok,_,code = h and h:close() or false,nil,nil; return out, ok, code
end
local function file_exists(p) local f=io.open(p,'rb'); if f then f:close(); return true end end
local function rm(p) if p then os.remove(p) end end

local function html_to_text(html)
  local s = html:gsub('<!%-%-.-%-%->', ' ')
  for _, tag in ipairs({'script','style','noscript','svg','header','footer','nav'}) do s=s:gsub('<'..tag..'[%s>/].-</'..tag..'%s*>',' '):gsub('<'..tag..'[^>]*>',' ') end
  s=s:gsub('<[bB][rR]%s*/?>','\n')
  for _, tag in ipairs({'p','div','li','tr','section','h%d'}) do s=s:gsub('</'..tag..'%s*>','\n'):gsub('<'..tag..'[%s>/][^>]*>','\n') end
  s=s:gsub('<[^>]+>',' ')
  local entities={nbsp=' ',amp='&',lt='<',gt='>',quot='"',apos="'",mdash='—',ndash='–'}
  s=s:gsub('&(%w+);',entities)
  s=s:gsub('&#(%d+);',function(n) n=tonumber(n); return (n and n>=0 and n<0x110000) and utf8.char(n) or '' end)
  s=s:gsub('&#x(%x+);',function(n) n=tonumber(n,16); return (n and n>=0 and n<0x110000) and utf8.char(n) or '' end)
  s=s:gsub('[ \t]+',' '):gsub(' *\n *','\n'):gsub('\n\n\n+','\n\n'):gsub('^%s+',''):gsub('%s+$','')
  if #s > C.page_max then s=s:sub(1,C.page_max) end
  return s
end

local function host_ok(host)
  host = (host or ''):lower()
  if host=='' or host=='localhost' or host:match('%.local$') then return false end
  if host:match('^%d+%.%d+%.%d+%.%d+$') then
    local a,b = host:match('^(%d+)%.(%d+)')
    a,b = tonumber(a),tonumber(b)
    if a==10 or a==127 or a==0 or a==169 and b==254 or a==172 and b>=16 and b<=31 or a==192 and b==168 then return false end
  end
  if host:match('^%[?::1') or host:match('^fc') or host:match('^fd') or host:match('^fe80') then return false end
  return true
end
local function safe_url(url)
  if type(url)~='string' then return nil end
  local scheme, rest = url:match('^(https?)://(.+)$'); if not scheme then return nil end
  local host = rest:match('^([^/%?#:]+)') or rest:match('^%[([^%]]+)%]')
  if not host_ok(host) then return nil end
  return scheme..'://'..rest
end
local function fetch_page_text(url)
  url = safe_url(url); if not url then return nil end
  local out, ok = run({'curl','-sS','-L','--max-time','25','--max-redirs',tostring(C.max_redirects or 3),'--proto','=http,https','-A','Mozilla/5.0','--',url})
  if not ok or not out or out=='' then return nil end
  local t = html_to_text(out); return (t~='' and t) or nil
end

local function groq(system, user)
  local bodyf = tmp('groq_body','.json'); local hdrf = tmp('groq_hdr','.txt'); local outf = tmp('groq_out','.json')
  local bf = io.open(bodyf,'wb'); if not bf then return nil,'tmp failed' end
  bf:write(json.encode({model=C.model, temperature=C.temperature, messages={{role='system',content=system},{role='user',content=user}}})); bf:close()
  local hf = io.open(hdrf,'wb'); if not hf then rm(bodyf); return nil,'tmp failed' end
  hf:write('Authorization: Bearer '..(C.groq_key or '')..'\nContent-Type: application/json\n'); hf:close(); os.execute('chmod 600 '..hdrf)
  local _, ok = run({'curl','-sS','--max-time',tostring(C.groq_timeout or 90),'https://api.groq.com/openai/v1/chat/completions','-H','@'..hdrf,'--data-binary','@'..bodyf,'-o',outf})
  local of = io.open(outf,'rb'); local raw = of and of:read('*a') or ''; if of then of:close() end
  rm(bodyf); rm(hdrf); rm(outf)
  local obj = select(1, json.decode(raw))
  if not obj then return nil, ok and raw or 'groq request failed' end
  if obj.error then return nil, json.encode(obj.error) end
  return (obj.choices and obj.choices[1] and obj.choices[1].message and obj.choices[1].message.content) or ''
end

local function best_photo(msg) local p=msg.photo; if not p or #p==0 then return nil end; return p[#p].file_id end
local function first_url(s) local u=s and s:match('(https?://[%w%-%._~:/%?#%[%]@!$&\'()*+,;=%%]+)'); return safe_url(u) end
local function esc_html(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end

local function rag_context(query)
  if not okrag or not rag then return nil end
  rag.store = C.rag_store; rag.load(); return rag.context(query, C.rag_k, C.rag_max)
end
local function save_kb(chat_id, text)
  os.execute('mkdir -p '..q(C.kb_dir))
  local name = C.kb_dir..'/tg_'..tostring(chat_id)..'_'..tostring(os.time())..'.txt'
  local f=io.open(name,'wb'); if not f then return nil,'write failed' end; f:write(text); f:close()
  if okrag and rag then rag.store=C.rag_store; rag.index_dir(C.kb_dir); rag.save() end
  return name
end

local function overlay_image(inpath, outpath)
  local _, ok = run({'magick', inpath, '-gravity','SouthEast', C.overlay, '-geometry','+12+12', '-composite', outpath})
  if not ok or not file_exists(outpath) then return nil, 'overlay failed' end
  return outpath
end

local function extract_name(filename)
  local name, err = groq(C.prompt_extract_name, 'Имя файла: '..tostring(filename))
  if not name or name=='' then return filename, err end
  name = name:gsub('[\r\n"]+',''):gsub('^%s+',''):gsub('%s+$',''); if name=='' then name=filename end
  return name
end

local function format_post(raw_caption, addon_name, page_text)
  local user = 'Имя аддона: '..addon_name..'\nТекст под фото:\n'..(raw_caption or '')
  if page_text and page_text~='' then user=user..'\n\nТекст страницы (распарсено):\n'..page_text:sub(1,6000) end
  local ctx = rag_context(addon_name..' '..(raw_caption or '')); if ctx and ctx~='' then user=user..'\n\nКонтекст из базы знаний (RAG):\n'..ctx end
  local out, err = groq(C.prompt_format, user); if not out then return nil, err end
  local obj = select(1, json.decode(out:match('%b{}') or out)) or {}
  obj.version = (obj.version and obj.version~='' and not tostring(obj.version):match('^1%.0')) and obj.version or C.mc_ver
  local desc = tostring(obj.description or raw_caption or ''):gsub('[\r\n]+',' '):gsub('%s+',' ')
  local tpl = '『 <b>%s</b> • #<b>%s</b> 』<blockquote expandable>%s%s</blockquote><b>— Вᴇᴩᴄия: </b><code>%s</code>+​'
  return string.format(tpl, esc_html(obj.name or addon_name), esc_html(obj.type or 'аддон'), esc_html(desc), C.author, esc_html(obj.version))
end

local bot = tg.new(C.tg_token)
local pending, pending_kb, pending_at, offset = {}, {}, {}, 0

local function gc_pending()
  local now = os.time()
  for cid, t in pairs(pending_at) do if now - t > (C.pending_ttl or 3600) then pending[cid]=nil; pending_kb[cid]=nil; pending_at[cid]=nil end end
end
local function touch(cid) pending_at[cid]=os.time() end

local function process(chat_id, st)
  bot:call('sendMessage', {chat_id=chat_id, text='Обрабатываю…'})
  local uid = tostring(os.time())..'_'..tostring(math.random(0,0x7fffffff))
  local in_img, out_img, doc_path = C.tmp..'/in_'..uid..'.jpg', C.tmp..'/out_'..uid..'.jpg', C.tmp..'/doc_'..uid
  local dl, derr = bot:download(st.photo_id, in_img)
  if not dl then rm(in_img); return nil, 'не скачал фото: '..tostring(derr and json.encode(derr) or '') end
  local ok_img, oerr = overlay_image(in_img, out_img); if not ok_img then out_img = in_img end
  local fname, has_doc = st.doc_name or 'addon.mcaddon', false
  if st.doc_id then has_doc = bot:download(st.doc_id, doc_path) and true or false end
  local addon_name = extract_name(fname)
  local url = st.url or first_url(st.caption)
  local page_text
  if url then bot:call('sendMessage',{chat_id=chat_id,text='Парсю страницу…'}); page_text = fetch_page_text(url) end
  local text, e2 = format_post(st.caption or '', addon_name, page_text)
  if not text then rm(in_img); if out_img~=in_img then rm(out_img) end; rm(doc_path); return nil, tostring(e2) end
  local res = bot:post_photo(C.out_chat, '@'..out_img, text, {parse_mode='HTML'})
  local doc_res, doc_err
  if res and res.ok then
    if has_doc then doc_res = bot:post_doc(C.out_chat, '@'..doc_path, C.footer, {parse_mode='HTML', reply_parameters=json.encode({message_id=res.result.message_id})})
    elseif st.doc_id then doc_res = bot:call('sendDocument', {chat_id=C.out_chat, document=st.doc_id, caption=C.footer, parse_mode='HTML', reply_parameters=json.encode({message_id=res.result.message_id})}, 120) end
    if (has_doc or st.doc_id) and not (doc_res and doc_res.ok) then doc_err = json.encode(doc_res) end
  end
  rm(in_img); if out_img~=in_img then rm(out_img) end; rm(doc_path)
  if res and res.ok then res.doc = doc_res; res.doc_err = doc_err end
  return res, text
end

if not C.groq_key then io.stderr:write('set GROQ_API_KEY\n'); os.exit(1) end
if not C.tg_token then io.stderr:write('set TG_TOKEN\n'); os.exit(1) end
if not next(C.allowed_users) then io.stderr:write('warn: ALLOWED_USERS not set, bot accepts messages from anyone\n') end
print('harness polling… out='..tostring(C.out_chat))

while true do
  local upd = bot:get_updates(offset, 30)
  if upd and upd.ok and upd.result then
    gc_pending()
    for _, u in ipairs(upd.result) do
      offset = u.update_id + 1
      local msg = u.message
      if msg and msg.chat then
        local cid = msg.chat.id
        local from = msg.from and tostring(msg.from.id) or tostring(cid)
        if not C.is_allowed(from) then
          -- ignore unauthorized
        else
          touch(cid)
          local txt = msg.text or ''
          if txt:match('^/clear') then pending[cid]=nil; pending_kb[cid]=nil; bot:call('sendMessage',{chat_id=cid,text='ok, очищено'})
          elseif txt:match('^/start') then bot:call('sendMessage',{chat_id=cid,text='Пост: пришли фото (с подписью) и файл аддона — запощу в канал.\nБаза знаний: пришли текст, затем /kb чтобы сохранить в RAG.'})
          elseif txt:match('^/kb%s*$') or txt:match('^/savekb%s*$') then
            local body = (pending_kb[cid] and pending_kb[cid]~='') and pending_kb[cid] or (msg.reply_to_message and (msg.reply_to_message.text or msg.reply_to_message.caption) or '')
            if body=='' then bot:call('sendMessage',{chat_id=cid,text='нет текста. Пришли сообщение, потом /kb (или ответь /kb на сообщение).'})
            else local path, err = save_kb(cid, body); pending_kb[cid]=nil
              bot:call('sendMessage',{chat_id=cid,text=path and ('сохранено в базу знаний: '..path:match('([^/]+)$')) or ('ошибка: '..tostring(err))})
            end
          else
            local st = pending[cid] or {}
            if msg.photo then st.photo_id = best_photo(msg); st.caption = msg.caption or st.caption end
            if msg.document then st.doc_id = msg.document.file_id; st.doc_name = msg.document.file_name; st.caption = msg.caption or st.caption end
            if msg.caption and not st.caption then st.caption = msg.caption end
            if txt and txt:match('^https?://') then st.url = safe_url(txt:match('(https?://%S+)')) or st.url end
            local u = first_url(st.caption or txt); if u then st.url = st.url or u end
            pending[cid] = st
            if txt ~= '' and not txt:match('^/') and not msg.photo and not msg.document then
              local cur = pending_kb[cid] or ''
              local add = ((cur~='') and (cur..'\n\n') or '') .. txt
              if #add > (C.max_pending_kb or 8000) then add = add:sub(- (C.max_pending_kb or 8000)) end
              pending_kb[cid] = add
              local hint = (st.photo_id or st.caption or st.doc_id) and '' or ' (отправь /kb чтобы добавить в базу знаний)'
              bot:call('sendMessage',{chat_id=cid,text='текст сохранён в буфер'..hint..'.'})
            end
            local ready = st.photo_id and st.caption and (st.doc_id or st.doc_name)
            if ready or txt:match('^/post') then
              if not (st.photo_id and st.caption) then bot:call('sendMessage',{chat_id=cid,text='нужно: фото + подпись (и документ с именем аддона).'})
              else
                if not st.doc_name and not st.doc_id then st.doc_name = 'addon.mcaddon' end
                local res, out = process(cid, st); pending[cid]=nil
                if res and res.ok then
                  local extra = res.doc_err and (' (файл не отправлен: '..res.doc_err..')') or ''
                  bot:call('sendMessage',{chat_id=cid,text='запощено (msg '..tostring(res.result.message_id)..')'..extra})
                else bot:call('sendMessage',{chat_id=cid,text='ошибка: '..tostring(type(out)=='string' and out or json.encode(res))}) end
              end
            else
              local need = {}
              if not st.photo_id then need[#need+1]='фото' end
              if not st.caption then need[#need+1]='подпись/описание' end
              if not st.doc_id and not st.doc_name then need[#need+1]='файл(документ)' end
              if #need < 3 then bot:call('sendMessage',{chat_id=cid,text='принял. ещё нужно: '..table.concat(need, ', ')}) end
            end
          end
        end
      end
    end
  elseif upd and not upd.ok then
    -- transient error, brief pause
    os.execute('sleep 2')
  end
end
