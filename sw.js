/* RoyalCub Jobs service worker: shows a notification when a chat message arrives while the app is closed or in the background. */
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    // The person is looking at the app right now: the in-app toast and unread badge already cover it.
    if (wins.some((c) => c.visibilityState === "visible" && c.focused)) return;
    await self.registration.showNotification(d.title || "RoyalCub Jobs", {
      body: d.body || "You have a new message",
      tag: d.tag || "rc-msg",       // one notification per sender; newer ones replace older ones
      renotify: true,
      data: { peer: d.peer || "" },
    });
  })());
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const peer = (e.notification.data && e.notification.data.peer) || "";
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of wins) {
      if ("focus" in c) {
        await c.focus();
        if (peer) c.postMessage({ type: "open-chat", peer });
        return;
      }
    }
    const u = new URL(self.registration.scope);
    if (peer) u.searchParams.set("chat", peer);
    await self.clients.openWindow(u.href);
  })());
});
