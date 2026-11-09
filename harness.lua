#!/usr/bin/env lua5.4
local function script_dir() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end
local DIR = script_dir()
package.path = table.concat({DIR..'?.lua', DIR..'?/init.lua', package.path, '/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua'}, ';')
local json = require('dkjson')
local tg = require('tg')
local okrag, rag = pcall(require, 'rag')

local function q(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
local function sh(cmd)
  local line = {}; for _, a in ipairs(cmd) do line[#line+1] = q(a) end
  local h = io.popen(table.concat(line, ' ')); local out = h and h:read('*a') or ''; if h then h:close() end; return out
end

local function html_to_text(html)
  local s = html
  s = s:gsub('<!%-%-.-%-%->', ' ')
  for _, tag in ipairs({'script','style','noscript','svg','header','footer','nav'}) do
    s = s:gsub('<'..tag..'[%s>/].-</'..tag..'%s*>', ' ')
    s = s:gsub('<'..tag..'[^>]*>', ' ')
  end
  s = s:gsub('<[bB][rR]%s*/?>', '\n')
  for _, tag in ipairs({'p','div','li','tr','section','h%d'}) do
    s = s:gsub('</'..tag..'%s*>', '\n')
    s = s:gsub('<'..tag..'[%s>/][^>]*>', '\n')
  end
  s = s:gsub('<[^>]+>', ' ')
  local entities = {nbsp=' ', amp='&', lt='<', gt='>', quot='"', apos="'", mdash='—', ndash='–'}
  s = s:gsub('&(%w+);', entities)
  s = s:gsub('&#(%d+);', function(n) n=tonumber(n); return (n and n<0x110000) and utf8.char(n) or '' end)
  s = s:gsub('&#x(%x+);', function(n) n=tonumber(n,16); return (n and n<0x110000) and utf8.char(n) or '' end)
  s = s:gsub('[ \t]+', ' ')
  s = s:gsub(' *\n *', '\n')
  s = s:gsub('\n\n\n+', '\n\n')
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  if #s > 12000 then s = s:sub(1,12000) end
  return s
end

local function fetch_page_text(url)
  local html = sh({'curl','-sS','-L','--max-time','25','-A','Mozilla/5.0','--', url})
  if not html or html == '' then return nil end
  local text = html_to_text(html)
  if text == '' then return nil end
  return text
end

local CFG = {
  tg_token = os.getenv('TG_TOKEN'),
  out_chat = os.getenv('TG_CHAT') or '-1003627991849',
  groq_key = os.getenv('GROQ_API_KEY'),
  model = os.getenv('GROQ_MODEL') or 'openai/gpt-oss-120b',
  overlay = os.getenv('OVERLAY') or (os.getenv('HOME') .. '/downloads/overlay.png'),
  tmp = '/data/data/com.termux/files/usr/tmp',
  mc_ver = os.getenv('MC_VERSION') or '26.30',
}

local function groq(system, user)
  local body = json.encode({model=CFG.model, temperature=0.3, messages={{role='system',content=system},{role='user',content=user}}})
  local out = sh({'curl','-sS','--max-time','90','https://api.groq.com/openai/v1/chat/completions',
    '-H','Authorization: Bearer ' .. CFG.groq_key,'-H','Content-Type: application/json','-d',body})
  local obj = select(1, json.decode(out))
  if not obj then return nil, out end
  if obj.error then return nil, json.encode(obj.error) end
  return (obj.choices and obj.choices[1] and obj.choices[1].message and obj.choices[1].message.content) or '', obj
end

local function best_photo(msg)
  local p = msg.photo; if not p or #p==0 then return nil end
  return p[#p].file_id
end

local function overlay_image(inpath, outpath)
  local cmd = {'magick', inpath, '-gravity','SouthEast', CFG.overlay, '-geometry','+12+12', '-composite', outpath}
  sh(cmd); local f = io.open(outpath,'r'); if f then f:close(); return outpath end; return nil, 'overlay failed'
end

local function extract_name(filename)
  local prompt = 'Извлеки только чистое имя аддона из имени файла. Верни ТОЛЬКО имя файла/аддона (пример: "tacz 1.5.mcaddon"), без кавычек, без пояснений.'
  return groq(prompt, 'Имя файла: ' .. filename)
end

local function first_url(s)
  if not s then return nil end
  return s:match('(https?://[%w%-%._~:/%?#%[%]@!$&\'()*+,;=%%]+)')
end

local function esc_html(s)
  s = tostring(s or '')
  return s:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;')
end

local function rag_context(query)
  if not okrag or not rag then return nil end
  rag.load()
  return rag.context(query, 3, 3000)
end

local function format_post(raw_caption, addon_name, page_text)
  local sys = [[Ты оформляешь пост о Minecraft-контенте. Верни СТРОГО JSON (без markdown-блоков) с полями:
name - красивое название без расширения файла (напр. "Create Coasters"),
type - ровно одно: аддон | DLC | ресурспак | мир,
description - подробное описание на русском, ~100 слов: что добавляет, ключевые фичи, геймплей/сценарии, кому понравится; опирайся на текст под фото/страницы и контекст из базы знаний (если дан). Избегай технических деталей (форматы файлов, API, движок, номера сборок) — пиши о сути и пользе для игрока.
version - минимальная версия Minecraft (если не указана, "26.30").
Определи type по имени/описанию (.mcaddon/.mcpack часто аддон/ресурспак; мир=.mcworld; DLC если явно DLC).]]
  local user = 'Имя аддона: ' .. addon_name .. '\nТекст под фото:\n' .. (raw_caption or '')
  if page_text and page_text ~= '' then user = user .. '\n\nТекст страницы (распарсено):\n' .. page_text:sub(1,6000) end
  local ctx = rag_context(addon_name .. ' ' .. (raw_caption or ''))
  if ctx and ctx ~= '' then user = user .. '\n\nКонтекст из базы знаний (RAG):\n' .. ctx end
  local out, err = groq(sys, user)
  if not out then return nil, err end
  local j = out:match('%b{}') or out
  local obj = select(1, json.decode(j))
  if not obj then
    obj = {name=addon_name, type='аддон', description=(raw_caption or ''):sub(1,600), version=CFG.mc_ver}
  end
  obj.version = (obj.version and obj.version ~= '') and obj.version or CFG.mc_ver
  local desc = tostring(obj.description or ''):gsub('[\r\n]+',' '):gsub('%s+',' ')
  local tpl = '『 <b>%s</b> • #<b>%s</b> 』<blockquote expandable>%s@karasichekMC</blockquote><b>— Вᴇᴩᴄия: </b><code>%s</code>+​'
  return string.format(tpl, esc_html(obj.name or addon_name), esc_html(obj.type or 'аддон'), esc_html(desc), esc_html(obj.version))
end

local bot = tg.new(CFG.tg_token)
local pending = {} -- chat_id -> {photo_id, caption, doc_id, doc_name}
local pending_kb = {} -- chat_id -> text to save
local offset = 0

local function save_kb(chat_id, text)
  local dir = (os.getenv('HOME') or '/data/data/com.termux/files/home') .. '/kb'
  os.execute('mkdir -p ' .. dir)
  local name = dir .. '/tg_' .. tostring(chat_id) .. '_' .. tostring(os.time()) .. '.txt'
  local f = io.open(name, 'w'); if not f then return nil, 'write failed' end
  f:write(text); f:close()
  if okrag and rag then rag.index_dir(dir); rag.store = (os.getenv('HOME') or '/data/data/com.termux/files/home') .. '/rag_index.json'; rag.save() end
  return name
end

local function process(chat_id, st)
  bot:call('sendMessage', {chat_id=chat_id, text='Обрабатываю…'})
  local uid = tostring(os.time()) .. math.random(1000,9999)
  local in_img = CFG.tmp .. '/in_'..uid..'.jpg'
  local out_img = CFG.tmp .. '/out_'..uid..'.jpg'
  local doc_path = CFG.tmp .. '/doc_'..uid
  if not bot:download(st.photo_id, in_img) then return nil,'не скачал фото' end
  local ok = overlay_image(in_img, out_img); if not ok then out_img = in_img end
  local fname = st.doc_name or 'addon.mcaddon'
  local has_doc = false
  if st.doc_id then has_doc = bot:download(st.doc_id, doc_path) and true or false end
  local addon_name = select(1, extract_name(fname))
  if not addon_name or addon_name=='' then addon_name = fname end
  addon_name = addon_name:gsub('^%s+',''):gsub('%s+$',''):gsub('[\r\n]+',''):gsub('^"',''):gsub('"$','')
  local page_text
  local url = st.url or first_url(st.caption)
  if url then
    bot:call('sendMessage', {chat_id=chat_id, text='Парсю страницу…'})
    page_text = fetch_page_text(url)
  end
  local text, e2 = format_post(st.caption or '', addon_name, page_text)
  if not text then os.remove(in_img); os.remove(out_img); os.remove(doc_path); return nil, tostring(e2) end
  local footer = '\n\n<a href="https://t.me/boost/KarasichekMC">⚡Буст</a> | <a href="https://t.me/karasichek_family">😺 Наш чат</a>\n\nПᴏдбᴏᴩᴋᴀ ᴀддᴏнᴏʙ:\n<a href="https://t.me/KarasichekMC/2338">🔥 Actions&amp;Stuff</a> | <a href="https://t.me/KarasichekMC/2260">😇 Aether</a>\n<a href="https://t.me/KarasichekMC/2290">🎨 Intresting GUI</a> | <a href="https://t.me/KarasichekMC/2314">🧔 Villager News</a>\n🪁 <a href="https://t.me/KarasichekMC/2335">Create Aeronautics</a> | 🔧 <a href="https://t.me/KarasichekMC/2327">Create</a>\n\n<b>@karasichekMC</b> — ᴏ Bᴇdrᴏᴄᴋ'
  local res = bot:post_photo(CFG.out_chat, '@'..out_img, text, {parse_mode='HTML'})
  local doc_res
  if res and res.ok and has_doc then
    doc_res = bot:post_doc(CFG.out_chat, '@'..doc_path, footer, {parse_mode='HTML', reply_parameters = json.encode({message_id = res.result.message_id})})
  elseif res and res.ok and st.doc_id and not has_doc then
    doc_res = bot:call('sendDocument', {chat_id=CFG.out_chat, document=st.doc_id, caption=footer, parse_mode='HTML', reply_parameters=json.encode({message_id=res.result.message_id})}, 120)
  end
  os.remove(in_img); if out_img~=in_img then os.remove(out_img) end; os.remove(doc_path)
  if res and res.ok then res.doc = doc_res end
  return res, text
end

if not CFG.groq_key then io.stderr:write('set GROQ_API_KEY\n'); os.exit(1) end
print('harness polling… out='..CFG.out_chat)

while true do
  local upd = bot:get_updates(offset, 30)
  if upd and upd.ok and upd.result then
    for _, u in ipairs(upd.result) do
      offset = u.update_id + 1
      local msg = u.message
      if msg and msg.chat then
        local cid = msg.chat.id
        local txt = msg.text or ''
        if txt:match('^/clear') then pending[cid]=nil; pending_kb[cid]=nil; bot:call('sendMessage',{chat_id=cid,text='ok, очищено'})
        elseif txt:match('^/start') then bot:call('sendMessage',{chat_id=cid,text='Пост: пришли фото (с подписью) и файл аддона — запощу в канал.\nБаза знаний: пришли текст, затем /kb чтобы сохранить в RAG.'})
        elseif txt:match('^/kb%s*$') or txt:match('^/savekb%s*$') then
          local body = (pending_kb[cid] and pending_kb[cid] ~= '') and pending_kb[cid] or (msg.reply_to_message and (msg.reply_to_message.text or msg.reply_to_message.caption) or '')
          if body == '' then bot:call('sendMessage',{chat_id=cid,text='нет текста. Пришли сообщение, потом /kb (или ответь /kb на сообщение).'})
          else local path, err = save_kb(cid, body); pending_kb[cid]=nil
            if path then bot:call('sendMessage',{chat_id=cid,text='сохранено в базу знаний и переиндексировано: '..path:match('([^/]+)$')})
            else bot:call('sendMessage',{chat_id=cid,text='ошибка сохранения: '..tostring(err)}) end
          end
        else
          local st = pending[cid] or {}
          if msg.photo then st.photo_id = best_photo(msg); st.caption = msg.caption or st.caption end
          if msg.document then st.doc_id = msg.document.file_id; st.doc_name = msg.document.file_name; st.caption = msg.caption or st.caption end
          if msg.caption and not st.caption then st.caption = msg.caption end
          if txt and txt:match('^https?://') then st.url = txt:match('(https?://%S+)') end
          local u = first_url(st.caption or txt); if u then st.url = st.url or u end
          pending[cid] = st
          if txt and not txt:match('^/') and not msg.photo and not msg.document then
            pending_kb[cid] = ((pending_kb[cid] and pending_kb[cid] ~= '') and (pending_kb[cid] .. '\n\n') or '') .. txt
            local hint = (st.photo_id or st.caption or st.doc_id) and '' or ' (отправь /kb чтобы добавить в базу знаний)'
            bot:call('sendMessage',{chat_id=cid,text='текст сохранён в буфер'..hint..'.'})
          end
          local ready = st.photo_id and st.caption and (st.doc_id or st.doc_name)
          if ready or txt:match('^/post') then
            if not (st.photo_id and st.caption) then
              bot:call('sendMessage',{chat_id=cid,text='нужно: фото + подпись (и документ с именем аддона).'})
            else
              if not st.doc_name and not st.doc_id then st.doc_name = 'addon.mcaddon' end
              local res, out = process(cid, st)
              pending[cid]=nil
              if res and res.ok then bot:call('sendMessage',{chat_id=cid,text='запощено (msg '..tostring(res.result.message_id)..')'})
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
end
