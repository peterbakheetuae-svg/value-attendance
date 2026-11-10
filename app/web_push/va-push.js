// Value Attendance — Web Push helper for the Flutter web app (window.vaPush). On iPhone it needs iOS 16.4+, the
// app opened from its Home Screen icon, and the permission asked from a real button tap — so the "enable" button
// here is a plain HTML button shown over the app.
(function () {
  var SCOPE = './push/';
  var ls = { get: function (k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
             set: function (k, v) { try { localStorage.setItem(k, v); } catch (_) {} } };
  function bytes(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
    var r = atob(s), a = new Uint8Array(r.length); for (var i = 0; i < r.length; i++) a[i] = r.charCodeAt(i); return a;
  }
  function overlay(html, buttons) {
    var o = document.createElement('div');
    o.setAttribute('dir', 'rtl');
    o.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;padding:20px;font-family:Cairo,system-ui,sans-serif;-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px)';
    var c = document.createElement('div');
    c.style.cssText = 'max-width:380px;width:100%;background:rgba(255,255,255,.92);color:#1b1b1f;border-radius:24px;padding:22px 18px 16px;box-shadow:0 12px 30px rgba(0,0,0,.25);text-align:center;line-height:1.7;font-size:15px';
    if (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) { c.style.background = 'rgba(40,44,58,.95)'; c.style.color = '#fff'; }
    c.innerHTML = html;
    var row = document.createElement('div'); row.style.cssText = 'display:flex;gap:10px;margin-top:16px';
    buttons.forEach(function (b) {
      var el = document.createElement('button'); el.type = 'button'; el.textContent = b.label;
      el.style.cssText = 'flex:1;border:0;border-radius:14px;padding:12px 8px;font:inherit;font-weight:800;cursor:pointer;' +
        (b.primary ? 'background:#3b5bdb;color:#fff' : 'background:rgba(127,127,127,.18);color:inherit');
      el.addEventListener('click', function () { b.onTap(function () { o.remove(); }); });
      row.appendChild(el);
    });
    c.appendChild(row); o.appendChild(c); document.body.appendChild(o);
    return o;
  }
  var api = {
    supported: function () { return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window; },
    ios: function () { return /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1); },
    standalone: function () { return (window.matchMedia && matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true; },
    permission: function () { return 'Notification' in window ? Notification.permission : 'unsupported'; },
    register: function () {
      return navigator.serviceWorker.register('push-sw.js', { scope: SCOPE }).then(function (reg) {
        if (reg.active) return reg;
        return new Promise(function (res) {
          var w = reg.installing || reg.waiting; var done = function () { res(reg); };
          if (!w) return done();
          w.addEventListener('statechange', function () { if (w.state === 'activated') done(); });
          setTimeout(done, 8000);
        });
      });
    },
    // permission already granted: (re)subscribe with the server's key; '' when not possible
    current: function (key) {
      if (!api.supported() || api.permission() !== 'granted' || !key) return Promise.resolve('');
      return api.register().then(function (reg) {
        return reg.pushManager.getSubscription().then(function (sub) {
          var want = bytes(key);
          if (sub && sub.options && sub.options.applicationServerKey) {
            var have = new Uint8Array(sub.options.applicationServerKey), same = have.length === want.length;
            for (var i = 0; same && i < have.length; i++) if (have[i] !== want[i]) same = false;
            if (!same) return sub.unsubscribe().then(function () { return null; });
          }
          return sub;
        }).then(function (sub) {
          return sub || reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytes(key) });
        });
      }).then(function (sub) { return JSON.stringify(sub.toJSON()); }).catch(function () { return ''; });
    },
    // asks once a day at most; resolves with the subscription JSON or ''
    prompt: function (key) {
      return new Promise(function (resolve) {
        if (!api.supported() || api.permission() !== 'default' || !key) return resolve('');
        var last = Number(ls.get('va_push_asked') || 0);
        if (Date.now() - last < 24 * 3600 * 1000) return resolve('');
        ls.set('va_push_asked', String(Date.now()));
        overlay('<div style="font-size:34px">🔔</div><div style="font-weight:800;font-size:18px;margin:4px 0 6px">تفعيل الإشعارات</div>' +
          'عشان توصلك الطلبات والتنبيهات حتى والتطبيق مقفول.', [
          { label: 'تفعيل', primary: true, onTap: function (close) {
            Notification.requestPermission().then(function (p) {
              close();
              if (p !== 'granted') return resolve('');
              api.current(key).then(resolve);
            }).catch(function () { close(); resolve(''); });
          } },
          { label: 'بعدين', onTap: function (close) { close(); resolve(''); } },
        ]);
      });
    },
    // iPhone in Safari (not from the Home Screen icon): how to add it — at most every 3 days
    installHint: function () {
      if (!api.ios() || api.standalone()) return Promise.resolve(false);
      var last = Number(ls.get('va_push_hint') || 0);
      if (Date.now() - last < 3 * 24 * 3600 * 1000) return Promise.resolve(false);
      ls.set('va_push_hint', String(Date.now()));
      return new Promise(function (resolve) {
        overlay('<div style="font-size:34px">📲</div><div style="font-weight:800;font-size:18px;margin:4px 0 6px">عشان توصلك الإشعارات على الآيفون</div>' +
          'من Safari دوس <b>مشاركة</b> ⬆️ ← <b>إضافة إلى الشاشة الرئيسية</b>، وبعدين افتح التطبيق من الأيقونة الجديدة.', [
          { label: 'تمام', primary: true, onTap: function (close) { close(); resolve(true); } },
        ]);
      });
    },
  };
  window.vaPush = api;
  if (api.supported()) { try { api.register().catch(function () {}); } catch (_) {} }
})();
