// Offline: App-Dateien vorab speichern. Der Lernstand liegt im Handy (localStorage).
const CACHE = "bezirke-v8";
const IMGS = Array.from({ length: 23 }, (_, i) => `img/${i + 1}.jpg`);
const FILES = ["./", "index.html", "app.js", "app.css", "manifest.webmanifest", "icon-180.png", "icon-192.png", "icon-512.png",
  "sascha/", "sascha/manifest.webmanifest", "sascha/orte.enc.json", ...IMGS];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(FILES))); self.skipWaiting(); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener("fetch", e => {
  if (e.request.method !== "GET") return;
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;
  // Netz zuerst, damit Updates ankommen; offline aus dem Speicher
  // no-cache: immer beim Server nachfragen, ob es eine neuere Datei gibt
  e.respondWith(fetch(e.request, { cache: "no-cache" }).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put(e.request, c)); return r; })
    .catch(() => caches.match(e.request, { ignoreSearch: true }).then(r => r || caches.match("index.html"))));
});
