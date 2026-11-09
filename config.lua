-- config.lua: единая конфигурация (key=value). Секреты (tg_token/groq_key) — только из env.
local HOME = os.getenv('HOME') or '/data/data/com.termux/files/home'
local DIR  = (function() local s=debug.getinfo(1,'S').source:match('^@?(.*)'); return s and s:match('(.*/)') or './' end)()

local C = {
  -- env/credentials
  tg_token = os.getenv('TG_TOKEN'),
  groq_key = os.getenv('GROQ_API_KEY'),
  -- target & model
  out_chat = os.getenv('TG_CHAT') or '-1003627991849',
  model    = os.getenv('GROQ_MODEL') or 'openai/gpt-oss-120b',
  temperature = 0.3,
  -- paths
  home    = HOME,
  dir     = DIR,
  overlay = os.getenv('OVERLAY') or (HOME .. '/downloads/overlay.png'),
  tmp     = os.getenv('HARNESS_TMP') or '/data/data/com.termux/files/usr/tmp',
  kb_dir  = os.getenv('KB_DIR') or (HOME .. '/kb'),
  rag_store = os.getenv('RAG_STORE') or (HOME .. '/rag_index.json'),
  log     = os.getenv('HARNESS_LOG') or '/data/data/com.termux/files/usr/tmp/harness.log',
  -- content
  mc_ver  = os.getenv('MC_VERSION') or '26.30',
  author  = '@karasichekMC',
  -- prompts
  prompt_extract_name = 'Извлеки только чистое имя аддона из имени файла. Верни ТОЛЬКО имя файла/аддона (пример: "tacz 1.5.mcaddon"), без кавычек, без пояснений.',
  prompt_format = [[Ты оформляешь пост о Minecraft-контенте. Верни СТРОГО JSON (без markdown-блоков) с полями:
name - красивое название без расширения файла (напр. "Create Coasters"),
type - ровно одно: аддон | DLC | ресурспак | мир,
description - подробное описание на русском, ~100 слов: что добавляет, ключевые фичи, геймплей/сценарии, кому понравится; опирайся на текст под фото/страницы и контекст из базы знаний (если дан). Избегай технических деталей (форматы файлов, API, движок, номера сборок) — пиши о сути и пользе для игрока.
version - минимальная версия Minecraft (если не указана, "%s").
Определи type по имени/описанию (.mcaddon/.mcpack часто аддон/ресурспак; мир=.mcworld; DLC если явно DLC).]],
  -- footer appended to the addon document caption (HTML)
  footer = '\n\n<a href="https://t.me/boost/KarasichekMC">⚡Буст</a> | <a href="https://t.me/karasichek_family">😺 Наш чат</a>\n\nПᴏдбᴏᴩᴋᴀ ᴀддᴏнᴏʙ:\n<a href="https://t.me/KarasichekMC/2338">🔥 Actions&amp;Stuff</a> | <a href="https://t.me/KarasichekMC/2260">😇 Aether</a>\n<a href="https://t.me/KarasichekMC/2290">🎨 Intresting GUI</a> | <a href="https://t.me/KarasichekMC/2314">🧔 Villager News</a>\n🪁 <a href="https://t.me/KarasichekMC/2335">Create Aeronautics</a> | 🔧 <a href="https://t.me/KarasichekMC/2327">Create</a>\n\n<b>@karasichekMC</b> — ᴏ Bᴇdrᴏᴄᴋ',
  -- limits
  page_max = 12000, rag_k = 3, rag_max = 3000, groq_timeout = 90, tg_timeout = 30,
}

C.prompt_format = C.prompt_format:format(C.mc_ver)
return C
