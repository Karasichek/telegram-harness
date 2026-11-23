#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({DIR..'?.lua', DIR..'?/init.lua', package.path, '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'}, ';')
local C = require('config')
local json = require('dkjson')
local tg = require('tg')
local posts = require('posts')
local okrag, rag = pcall(require, 'rag')

local function tmp(base, ext) return C.tmp..'/'..base..'_'..tostring(os.time())..'_'..tostring(math.random(0,0x7fffffff))..(ext or '') end
local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function run(argv)
  local line = {}; for _, a in ipairs(argv) do line[#line+1] = "'"..tostring(a):gsub("'","'\\''").."'" end
  local h = io.popen("sh -c 'exec \"$@\"' sh " .. table.concat(line,' ') .. " 2>&1")
  local out = h and h:read('*a') or ''; local ok = h and h:close() or false
  return out, ok
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

local function groq_try(api, key, model, system, user)
  local bodyf = tmp('groq_body','.json'); local hdrf = tmp('groq_hdr','.txt'); local outf = tmp('groq_out','.json')
  local bf = io.open(bodyf,'wb'); if not bf then return nil,'tmp failed' end
  bf:write(json.encode({model=model, temperature=C.temperature, messages={{role='system',content=system},{role='user',content=user}}})); bf:close()
  local hf = io.open(hdrf,'wb'); if not hf then rm(bodyf); return nil,'tmp failed' end
  hf:write('Authorization: Bearer '..key..'\nContent-Type: application/json\n'); hf:close(); os.execute('chmod 600 '..hdrf)
  local _, ok = run({'curl','-sS','--max-time',tostring(C.groq_timeout or 90),api,'-H','@'..hdrf,'--data-binary','@'..bodyf,'-o',outf})
  local of = io.open(outf,'rb'); local raw = of and of:read('*a') or ''; if of then of:close() end
  rm(bodyf); rm(hdrf); rm(outf)
  local obj = select(1, json.decode(raw))
  if not obj then return nil, ok and raw or 'groq request failed' end
  if obj.error then return nil, json.encode(obj.error) end
  return (obj.choices and obj.choices[1] and obj.choices[1].message and obj.choices[1].message.content) or ''
end

local function groq(system, user)
  if C.groq_key then
    local out = groq_try('https://api.groq.com/openai/v1/chat/completions', C.groq_key, C.model, system, user)
    if out then return out end
  end
  if C.openrouter_key then
    return groq_try('https://openrouter.ai/api/v1/chat/completions', C.openrouter_key, C.or_model or 'google/gemma-4-31b-it:free', system, user)
  end
  return nil, 'no GROQ_API_KEY/OPENROUTER_API_KEY'
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

local function img_size(path)
  local out = run({'magick','identify','-format','%w %h', path})
  local w, h = tostring(out):match('(%d+) (%d+)')
  return tonumber(w), tonumber(h)
end
local function overlay_image(inpath, outpath)
  local bw = img_size(inpath); local ow, oh = img_size(C.overlay)
  if not (bw and ow and oh) then return nil, 'overlay failed' end
  local tw = math.max(1, math.floor(bw*0.4))
  local th = math.max(1, math.floor(oh*tw/ow))
  local yoff = 12 - math.floor(th*0.25)
  local _, ok = run({'magick', inpath, '(', C.overlay, '-resize', tostring(tw)..'x', ')', '-gravity','SouthEast', '-geometry','+12'..(yoff>=0 and ('+'..yoff) or tostring(yoff)), '-composite', outpath})
  if not ok or not file_exists(outpath) then return nil, 'overlay failed' end
  return outpath
end
local function video_size(path)
  local out = tostring(run({'ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height:stream_side_data=rotation','-of','json', path}))
  local w = tonumber(out:match('"width"%s*:%s*(%d+)'))
  local h = tonumber(out:match('"height"%s*:%s*(%d+)'))
  local rot = tonumber(out:match('"rotation"%s*:%s*(-?%d+)'))
  if w and h and rot and math.abs(rot) % 180 == 90 then w, h = h, w end
  return w, h, rot
end
local function video_dur(path)
  local out = tostring(run({'ffprobe','-v','error','-select_streams','v:0','-show_entries','format=duration','-of','csv=p=0', path}))
  return tonumber(out:match('([%d%.]+)'))
end
local function overlay_video(inpath, outpath)
  local ow, oh = img_size(C.overlay); local vw, vh = video_size(inpath)
  if not (ow and oh and vw and vh) then return nil, 'no dimensions' end
  local tw = math.max(2, math.floor(vw*0.4))
  local th = math.max(2, math.floor(oh*tw/ow))
  local x = math.max(0, vw - tw - 12)
  local y = math.max(0, vh - 12 - math.floor(th*0.75))
  local filter = string.format('[0:v]scale=trunc(iw/2)*2:trunc(ih/2)*2[base];[1:v]scale=%d:%d[ov];[base][ov]overlay=%d:%d[v]', tw, th, x, y)
  local out, ok = run({'timeout','600','ffmpeg','-y','-loglevel','error','-i',inpath,'-i',C.overlay,'-filter_complex',filter,'-map','[v]','-map','0:a?','-c:v','libx264','-preset','veryfast','-crf','23','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-movflags','+faststart',outpath})
  if not ok or not file_exists(outpath) then return nil, ('ffmpeg: '..tostring(out):sub(-300)) end
  return outpath
end

local function extract_name(filename)
  local name, err = groq(C.prompt_extract_name, 'Имя файла: '..tostring(filename))
  if not name or name=='' then return filename, err end
  name = name:gsub('[\r\n"]+',''):gsub('^%s+',''):gsub('%s+$',''); if name=='' then name=filename end
  return name
end

local function posts_key(st)
  local parts = {}
  for _, m in ipairs(st.media or {}) do parts[#parts+1] = tostring(m.type)..':'..tostring(m.id)..':'..tostring(m.size or 0) end
  parts[#parts+1] = 'doc='..tostring(st.doc_name or '')
  parts[#parts+1] = 'cap='..(tostring(st.caption or ''):sub(1,300))
  return table.concat(parts, '|')
end

local function format_post(raw_caption, addon_name, page_text, key)
  local cached = key and posts.get(key) or nil
  if cached then return cached.text end
  local user = 'Имя аддона: '..addon_name..'\nТекст под фото:\n'..(raw_caption or '')
  if page_text and page_text~='' then user=user..'\n\nТекст страницы (распарсено):\n'..page_text:sub(1,6000) end
  local ctx = rag_context(addon_name..' '..(raw_caption or '')); if ctx and ctx~='' then user=user..'\n\nКонтекст из базы знаний (RAG):\n'..ctx end
  local out, err = groq(C.prompt_format, user); if not out then return nil, err end
  local obj = select(1, json.decode(out:match('%b{}') or out)) or {}
  local ver = tostring(obj.version or ''):gsub('^%s+',''):gsub('%s+$',''):gsub('^1%.','')
  obj.version = (ver~='' and not ver:match('^0')) and ver or C.mc_ver
  local desc = tostring(obj.description or raw_caption or ''):gsub('[\r\n]+',' '):gsub('%s+',' ')
  local tpl = '『 <b>%s</b> • #<b>%s</b> 』\n <blockquote expandable>%s%s</blockquote>\u{00A0}\n<b>— Вᴇᴩᴄия: </b><code>%s</code>+​'
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
  local fname = st.doc_name or 'addon.mcaddon'
  local name = (fname:match('([^/\\]+)$') or fname):gsub('[%c";,]',''):gsub('[\\/]','_')
  local base, ext = name:match('^(.*)(%.[^./\\]+)$')
  local safe = (base or name)..' from @karasichekMC'..(ext or '')
  if safe == '' then safe = 'addon.mcaddon' end
  local doc_dir = C.tmp..'/dl_'..uid
  local doc_path = doc_dir..'/'..safe
  local outs, tmps = {}, {}
  local log = {}
  local function plog(s) log[#log+1] = tostring(s); io.stderr:write('[proc] '..tostring(s)..'\n') end
  local function flush_log()
    if #log == 0 then return end
    local body = table.concat(log, '\n')
    for i = 1, #body, 4000 do bot:call('sendMessage', {chat_id=chat_id, text='лог:\n'..body:sub(i, i+3999)}) end
  end
  local function cleanup() for _, p in ipairs(tmps) do rm(p) end; os.execute('rm -rf '..q(doc_dir)) end
  plog('media='..#(st.media or {})..' caption='..tostring(st.caption and #st.caption)..' doc='..tostring(st.doc_name))
  for i, m in ipairs(st.media or {}) do
    plog('#'..i..' '..tostring(m.type)..' size='..tostring(m.size))
    if m.type == 'video' then
      if (m.size or 0) > 20*1024*1024 then
        plog('#'..i..' >20MB, by file_id, no overlay')
        outs[#outs+1] = {type='video', id=m.id}
      else
        local in_v, out_v = C.tmp..'/vin_'..uid..'_'..i..'.mp4', C.tmp..'/vout_'..uid..'_'..i..'.mp4'
        tmps[#tmps+1] = in_v; tmps[#tmps+1] = out_v
        local dl, derr = bot:download(m.id, in_v)
        if dl then
          local w, h, rot = video_size(in_v)
          plog('#'..i..' downloaded dims='..tostring(w)..'x'..tostring(h)..' rot='..tostring(rot))
          local ov, oerr = overlay_video(in_v, out_v)
          plog('#'..i..' overlay='..tostring(ov ~= nil)..(oerr and (' err='..oerr) or ''))
          if ov then
            local ow2, oh2 = video_size(out_v); local dv = video_dur(out_v)
            outs[#outs+1] = {type='video', path=ov, w=ow2, h=oh2, dur=dv and math.floor(dv) or nil}
          else
            outs[#outs+1] = {type='video', path=in_v}
          end
        else
          plog('#'..i..' download failed, by file_id: '..tostring(derr and json.encode(derr) or derr))
          outs[#outs+1] = {type='video', id=m.id}
        end
      end
    else
      local in_img, out_img = C.tmp..'/in_'..uid..'_'..i..'.jpg', C.tmp..'/out_'..uid..'_'..i..'.jpg'
      tmps[#tmps+1] = in_img
      local dl, derr = bot:download(m.id, in_img)
      if not dl then plog('#'..i..' photo download failed'); flush_log(); cleanup(); return nil, 'не скачал фото: '..tostring(derr and json.encode(derr) or '') end
      local okov = overlay_image(in_img, out_img)
      plog('#'..i..' photo overlay='..tostring(okov ~= nil))
      if okov then outs[#outs+1] = {type='photo', path=out_img}; tmps[#tmps+1] = out_img else outs[#outs+1] = {type='photo', path=in_img} end
    end
  end
  if #outs == 0 then flush_log(); cleanup(); return nil, 'нет фото/видео' end
  local has_doc, doc_note = false, nil
  if st.doc_id then
    if (st.doc_size or 0) > 20*1024*1024 then
      doc_note = 'файл больше 20 МБ — Bot API не даёт скачать его для переименования'
    else
      os.execute('mkdir -p '..q(doc_dir))
      has_doc = bot:download(st.doc_id, doc_path) and true or false
      if not has_doc then has_doc = bot:download(st.doc_id, doc_path) and true or false end
      if not has_doc then doc_note = 'не удалось скачать файл для переименования' end
    end
    plog('doc rename='..tostring(has_doc)..' note='..tostring(doc_note))
  end
  local addon_name = extract_name(fname)
  local url = st.url or first_url(st.caption)
  local page_text
  if url then bot:call('sendMessage',{chat_id=chat_id,text='Парсю страницу…'}); page_text = fetch_page_text(url) end
  local key = posts_key(st)
  local text, e2 = format_post(st.caption or '', addon_name, page_text, key)
  if not text then plog('format failed: '..tostring(e2)); flush_log(); cleanup(); return nil, tostring(e2) end
  local function send_one(it, cap)
    if it.type == 'video' then
      local params = {parse_mode='HTML'}
      if it.w then params.width=it.w; params.height=it.h; params.duration=it.dur end
      return bot:post_video(C.out_chat, it.path and ('@'..it.path) or it.id, cap, params)
    end
    return bot:post_photo(C.out_chat, '@'..it.path, cap, {parse_mode='HTML'})
  end
  local res, why
  if #outs == 1 then
    res, why = send_one(outs[1], text)
    if not res then res, why = send_one(outs[1], text) end
  else
    for i = 1, #outs, 10 do
      local chunk = {}
      for j = i, math.min(i+9, #outs) do chunk[#chunk+1] = outs[j] end
      local cap = (i==1) and text or nil
      local r, e = bot:post_album(C.out_chat, chunk, cap, {parse_mode='HTML'})
      if not r then r, e = bot:post_album(C.out_chat, chunk, cap, {parse_mode='HTML'}) end
      res = res or r
      if not (r and r.ok) then res = r; why = e; break end
    end
  end
  if not (res and res.ok) then plog('post failed: '..tostring((res and (res.description or json.encode(res))) or why)); flush_log(); cleanup(); return nil, 'отправка не удалась: '..((res and (res.description or json.encode(res))) or why or 'нет ответа Telegram') end
  local mid = res.result.message_id or (res.result[1] and res.result[1].message_id)
  plog('post ok mid='..tostring(mid))
  posts.add({key=key, text=text, caption=st.caption or '', doc=addon_name, at=os.time(), msg_id=mid, chat=C.out_chat})
  local doc_res, doc_err
  if mid then
    local rp = json.encode({message_id=mid})
    local why
    if has_doc then
      doc_res, why = bot:post_doc(C.out_chat, '@'..doc_path, C.footer, {parse_mode='HTML', reply_parameters=rp})
      if not (doc_res and doc_res.ok) then doc_res, why = bot:post_doc(C.out_chat, '@'..doc_path, C.footer, {parse_mode='HTML', reply_parameters=rp}) end
      if not (doc_res and doc_res.ok) then
        doc_res, why = bot:call('sendDocument', {chat_id=C.out_chat, document=st.doc_id, caption=C.footer, parse_mode='HTML', reply_parameters=rp}, 120)
        if doc_res and doc_res.ok then doc_note = 'отправлен без переименования' end
      end
    elseif st.doc_id then
      doc_res, why = bot:call('sendDocument', {chat_id=C.out_chat, document=st.doc_id, caption=C.footer, parse_mode='HTML', reply_parameters=rp}, 120)
    end
    if (has_doc or st.doc_id) and not (doc_res and doc_res.ok) then
      doc_err = (doc_res and (doc_res.description or json.encode(doc_res))) or why or 'нет ответа Telegram'
    end
    plog('doc sent='..tostring(doc_res and doc_res.ok)..' note='..tostring(doc_note)..' err='..tostring(doc_err))
  end
  cleanup()
  flush_log()
  res.doc = doc_res; res.doc_err = doc_err; res.doc_note = doc_note; res.msg_id = mid
  return res, text
end

if not C.groq_key then io.stderr:write('set GROQ_API_KEY\n'); os.exit(1) end
if not C.tg_token then io.stderr:write('set TG_TOKEN\n'); os.exit(1) end
if not next(C.allowed_users) then io.stderr:write('warn: ALLOWED_USERS not set, bot accepts messages from anyone\n') end
print('harness polling… out='..tostring(C.out_chat)..(C.debug and ' [debug]' or ''))

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
        C.dbg('update', u.update_id, 'from', from, 'chat', cid)
        if not C.is_allowed(from) then
          C.dbg('denied', from)
        else
          touch(cid)
          local txt = msg.text or ''
          if txt:match('^/clear') then pending[cid]=nil; pending_kb[cid]=nil; bot:call('sendMessage',{chat_id=cid,text='ok, очищено'})
          elseif txt:match('^/start') then bot:call('sendMessage',{chat_id=cid,text='Пост: пришли фото или видео (с подписью) и файл аддона — запощу в канал.\nБаза знаний: пришли текст, затем /kb чтобы сохранить в RAG.\nДебаг: /debug /status'})
          elseif txt:match('^/debug') then C.debug = not C.debug; bot:call('sendMessage',{chat_id=cid,text='debug='..tostring(C.debug)})
          elseif txt:match('^/status') then
            local st = pending[cid] or {}; local n=0; for _ in pairs(pending) do n=n+1 end
            local info = string.format('debug=%s out=%s model=%s allowed=%s pending=%d kb_buf=%d', tostring(C.debug), tostring(C.out_chat), tostring(C.model), (next(C.allowed_users) and 'on' or 'ANY'), n, #(pending_kb[cid] or ''))
            bot:call('sendMessage',{chat_id=cid,text=info})
          elseif txt:match('^/kb%s*$') or txt:match('^/savekb%s*$') then
            local body = (pending_kb[cid] and pending_kb[cid]~='') and pending_kb[cid] or (msg.reply_to_message and (msg.reply_to_message.text or msg.reply_to_message.caption) or '')
            if body=='' then bot:call('sendMessage',{chat_id=cid,text='нет текста. Пришли сообщение, потом /kb (или ответь /kb на сообщение).'})
            else local path, err = save_kb(cid, body); pending_kb[cid]=nil
              bot:call('sendMessage',{chat_id=cid,text=path and ('сохранено в базу знаний: '..path:match('([^/]+)$')) or ('ошибка: '..tostring(err))})
            end
          else
            local st = pending[cid] or {media={}}
            st.media = st.media or {}
            if msg.photo then st.media[#st.media+1] = {type='photo', id=best_photo(msg)}; st.caption = msg.caption or st.caption end
            if msg.video then st.media[#st.media+1] = {type='video', id=msg.video.file_id, size=msg.video.file_size}; st.caption = msg.caption or st.caption end
            if msg.document then st.doc_id = msg.document.file_id; st.doc_name = msg.document.file_name; st.doc_size = msg.document.file_size; st.caption = msg.caption or st.caption; io.stderr:write('[doc] name='..tostring(st.doc_name)..' size='..tostring(st.doc_size)..'\n') end
            if msg.caption and not st.caption then st.caption = msg.caption end
            if txt and txt:match('^https?://') then st.url = safe_url(txt:match('(https?://%S+)')) or st.url end
            local u = first_url(st.caption or txt); if u then st.url = st.url or u end
            if txt:match('^/post') then st.force = true end
            pending[cid] = st
            if txt ~= '' and not txt:match('^/') and not msg.photo and not msg.video and not msg.document then
              local cur = pending_kb[cid] or ''
              local add = ((cur~='') and (cur..'\n\n') or '') .. txt
              if #add > (C.max_pending_kb or 8000) then add = add:sub(- (C.max_pending_kb or 8000)) end
              pending_kb[cid] = add
              local hint = (#st.media>0 or st.caption or st.doc_id) and '' or ' (отправь /kb чтобы добавить в базу знаний)'
              bot:call('sendMessage',{chat_id=cid,text='текст сохранён в буфер'..hint..'.'})
            end
            C.dbg('state', 'media='..#st.media, 'caption='..tostring(st.caption~=nil), 'doc='..tostring((st.doc_id or st.doc_name)~=nil))
          end
        end
      end
    end
    for cid, st in pairs(pending) do
      local media = st.media or {}
      local ready = #media>0 and st.caption and (st.doc_id or st.doc_name)
      if ready or st.force then
        pending[cid] = nil
        if not (#media>0 and st.caption) then bot:call('sendMessage',{chat_id=cid,text='нужно: фото/видео + подпись (и документ с именем аддона).'})
        else
          if not st.doc_name and not st.doc_id then st.doc_name = 'addon.mcaddon' end
          local res, out = process(cid, st)
          if res and res.ok then
            local extra = res.doc_err and (' (файл не отправлен: '..res.doc_err..')') or (res.doc_note and (' ('..res.doc_note..')') or '')
            bot:call('sendMessage',{chat_id=cid,text='запощено (msg '..tostring(res.msg_id)..')'..extra})
          else bot:call('sendMessage',{chat_id=cid,text='ошибка: '..tostring(type(out)=='string' and out or json.encode(res))}) end
        end
      elseif #media>0 or st.caption or st.doc_id then
        local need = {}
        if #media==0 then need[#need+1]='фото/видео' end
        if not st.caption then need[#need+1]='подпись/описание' end
        if not st.doc_id and not st.doc_name then need[#need+1]='файл(документ)' end
        if #need < 3 then bot:call('sendMessage',{chat_id=cid,text='принял. ещё нужно: '..table.concat(need, ', ')}) end
      end
    end
  elseif upd and not upd.ok then
    C.dbg('getUpdates error', json.encode(upd))
    os.execute('sleep 2')
  else
    C.dbg('getUpdates failed (network?)')
    os.execute('sleep 5')
  end
end
