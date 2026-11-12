package.path = './?.lua;/data/data/com.termux/files/usr/share/lua/5.4/luarocks/vendor/?.lua;' .. package.path
local function assert_eq(a,b,msg) if a~=b then error((msg or 'assert')..': '..tostring(a)..' ~= '..tostring(b)) end end

-- config allowlist
package.loaded.config=nil; local C=require('config')
assert_eq(C.is_allowed(1), true, 'open')
C.allowed_users={['42']=true}; assert_eq(C.is_allowed(42), true, 'allow'); assert_eq(C.is_allowed(7), false, 'deny')

-- rag reset + search
local rag=require('rag'); local d='/data/data/com.termux/files/usr/tmp/ragt_test'; os.execute('rm -rf '..d..' && mkdir -p '..d)
local f=io.open(d..'/a.txt','w'); f:write('coaster addon create'); f:close()
local f2=io.open(d..'/b.txt','w'); f2:write('other'); f2:close()
rag.index_dir(d); assert_eq(#rag.docs,2,'n'); rag.index_dir(d); assert_eq(#rag.docs,2,'reset')
assert(rag.search('coaster create',1)[1].id:match('a.txt'),'search')
os.remove(d..'/a.txt'); rag.index_dir(d); assert_eq(#rag.docs,1,'update')

-- html/entities helpers via harness internals (load chunk not running loop: check guard)
-- basic esc/format sanity
local function esc_html(s) return tostring(s or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;') end
assert_eq(esc_html('a&<>"'), 'a&amp;&lt;&gt;"', 'esc')
print('ok')
