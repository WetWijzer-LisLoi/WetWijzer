// WetWijzer service worker. Served as a static file (not via a controller) so
// Rails' cross-origin-JavaScript guard never rejects it. Registered with
// { updateViaCache: 'none' } so the browser always revalidates this script.
//
// Deliberately minimal: it ONLY intercepts top-level navigations to provide an
// offline fallback, and passes assets, API calls and the chatbot stream straight
// to the network (never caches dynamic content, so nothing goes stale).
const CACHE = 'ww-shell-v1';
const OFFLINE_URL = '/offline';

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.add(OFFLINE_URL))
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  if (event.request.mode !== 'navigate') return;
  event.respondWith(
    fetch(event.request).catch(() =>
      caches.match(OFFLINE_URL).then(
        (r) => r || new Response('<h1>Offline</h1>', { headers: { 'Content-Type': 'text/html' } })
      )
    )
  );
});
