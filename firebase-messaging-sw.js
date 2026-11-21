/* RoyalCub Jobs - Firebase Cloud Messaging service worker (background / app-closed notifications).
   Host at the SAME level as index.html, over HTTPS:  https://yourdomain.com/firebase-messaging-sw.js
   The page registers it with its own scope ("firebase-cloud-messaging-push-scope"), so it never clashes with sw.js. */
importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyCoNyCPesv19o1KbYrY9q-E7siv6Oe7O5I",
  authDomain: "royalcub.firebaseapp.com",
  projectId: "royalcub",
  storageBucket: "royalcub.firebasestorage.app",
  messagingSenderId: "88865217328",
  appId: "1:88865217328:web:1ac15bcf04cdc841ad06f5",
  measurementId: "G-5CYN0VLBG3"
});
const messaging = firebase.messaging();

/* Take over immediately so a new version works without waiting for every tab to close. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

/* Where a notification should open (same-origin only). */
function targetUrl(data) {
  let u = (data && data.url) || "/";
  if (data && data.post && !/[?&]post=/.test(u)) u += (u.includes("?") ? "&" : "?") + "post=" + encodeURIComponent(data.post);
  try { const x = new URL(u, self.location.origin); return x.origin === self.location.origin ? x.href : self.location.origin + "/"; }
  catch (e) { return self.location.origin + "/"; }
}

/* Runs when a push arrives while the app is closed or in the background.
   Messages that carry a "notification" block are shown by the browser itself, so only data messages are shown here (no duplicates). */
messaging.onBackgroundMessage((payload) => {
  if (payload && payload.notification) return;
  const d = (payload && payload.data) || {};
  const title = d.title || "RoyalCub Jobs";
  const opts = {
    body: d.body || "",
    tag: d.tag || (d.post ? "post-" + d.post : undefined),   /* same tag = newer alert replaces the older one */
    renotify: !!d.tag || !!d.post,
    data: { url: targetUrl(d), post: d.post || "" },
    vibrate: [120, 60, 120]
  };
  if (d.icon) opts.icon = d.icon;
  if (d.badge) opts.badge = d.badge;
  if (d.image) opts.image = d.image;
  return self.registration.showNotification(title, opts);
});

/* Tap on a notification: focus an open tab and go to the post, or open the app. */
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || self.location.origin + "/";
  event.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of list) {
      if (new URL(c.url).origin === self.location.origin) {
        try { await c.focus(); } catch (e) {}
        try { c.postMessage({ type: "open-post", post: event.notification.data && event.notification.data.post, url }); } catch (e) {}
        try { if ("navigate" in c) return await c.navigate(url); } catch (e) {}
        return;
      }
    }
    return self.clients.openWindow(url);
  })());
});

/* If the browser rotates the push subscription, tell open pages so they save the new token. */
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil(self.clients.matchAll({ includeUncontrolled: true }).then((l) => l.forEach((c) => c.postMessage({ type: "fcm-refresh" }))));
});

// Background Sync: when the app could not reach the server, the browser wakes this worker once the
// connection is back and we ask any open RoyalCub window to run a full data sync.
self.addEventListener("sync", (event) => {
  if (event.tag !== "rc-sync") return;
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
      cs.forEach((c) => c.postMessage({ type: "rc-sync" }));
    })
  );
});
