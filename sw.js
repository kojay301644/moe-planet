// 萌獸星球 service worker:網頁與程式一律先抓最新版(沒網路才用快取),圖片先用快取。
const C='moe-v2';
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==C).map(k=>caches.delete(k)))).then(()=>clients.claim())));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==location.origin)return;
  const img=/\/assets\//.test(u.pathname);
  e.respondWith(caches.open(C).then(async c=>{
    if(img){const hit=await c.match(e.request);if(hit)return hit;const r=await fetch(e.request);if(r.ok)c.put(e.request,r.clone());return r}
    try{const r=await fetch(e.request,{cache:'no-cache'});if(r.ok)c.put(e.request,r.clone());return r}catch(x){const hit=await c.match(e.request);if(hit)return hit;throw x}}))});
