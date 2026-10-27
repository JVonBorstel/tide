// Chef service worker: keeps the app shell available when the connection drops, so the app opens and says "can't reach the kitchen"
// instead of a browser error. Network first for everything (never a stale app after an update); live data (/api/*) is never cached.
// The server writes the app build into this file, so every new build installs a fresh worker that drops the old shell.
const CACHE = 'chef-shell-__BUILD__';
const SHELL = ['/', '/app.css', '/app.js', '/scene.js', '/world.js', '/sprites.js', '/live.js', '/frame.js', '/frame-meter.js', '/moments.js', '/purpose.js', '/patch.js', '/rows.js', '/main-status.js', '/undo-pause.js', '/lobe.js', '/lobe-self.js','/world-line.js', '/city.js', '/icon.svg', '/manifest.webmanifest', '/jetbrains-mono.woff2'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {})); self.skipWaiting(); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin || u.pathname.startsWith('/api/') || u.pathname === '/login') return;
  // network first, but a connection that is up and passes nothing (Tailscale up, no route) no longer means a white screen: after
  // 3 s the cached shell answers (it then says "can't reach the kitchen"), while the fetch keeps going and refreshes the cache
  const net = fetch(e.request).then((r) => {
    if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {}); }
    return r;
  });
  const cached = () => caches.match(e.request, { ignoreSearch: true }).then((m) => m || caches.match('/'));
  const slow = new Promise((resolve) => setTimeout(resolve, 3000)).then(() => cached()).then((m) => m || net);
  e.waitUntil(net.catch(() => {}));
  e.respondWith(Promise.race([net, slow]).catch(() => cached()).then((r) => r || net));
});
// a tap on a phone alert opens Chef (an open window first), at the pass; the alert itself never carries order words
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((ws) => ws[0] ? ws[0].focus() : self.clients.openWindow('/#/pass')));
});
