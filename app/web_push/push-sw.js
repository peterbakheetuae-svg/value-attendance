// Value Attendance — Web Push service worker (the web app on iPhone Home Screen / browsers).
// Registered by va-push.js with its own scope (./push/) so it never replaces Flutter's own worker.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'Value Attendance';
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || '',
    tag: d.id || undefined,
    renotify: true,
    requireInteraction: !!d.ring,          // ringing alerts stay until tapped (where the browser allows it)
    vibrate: d.ring ? [600, 300, 600, 300, 600] : [200],
    icon: '../icons/Icon-192.png',
    badge: '../icons/Icon-192.png',
    dir: 'rtl', lang: 'ar',
    data: d,
  }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const app = new URL('../', self.registration.scope).href; // /value-attendance/
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((ws) => {
    for (const w of ws) if (w.url.startsWith(app) && 'focus' in w) return w.focus();
    return self.clients.openWindow(app);
  }));
});
