// Deletes chat photos older than 30 days (one month) from Storage, permanently,
// and turns the matching chat messages into "image expired" placeholders.
// Called once a day by pg_cron (see supabase_chat_media.sql). Deploy with:
//   supabase functions deploy purge-chat-media --no-verify-jwt
//   supabase secrets set CRON_SECRET=<long random string>
import { createClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "royalcub chat";
const DAY_MS = 864e5;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const cutoffMs = Date.now() - 30 * DAY_MS;
  let removed = 0;

  // rc_expired_media() returns up to 1000 old files per call; loop until none are left.
  for (let round = 0; round < 25; round++) {
    const { data: names, error } = await sb.rpc("rc_expired_media");
    if (error) return json({ error: error.message, removed }, 500);
    if (!names || names.length === 0) break;

    for (let i = 0; i < names.length; i += 100) {
      const chunk = (names as string[]).slice(i, i + 100);
      const { error: rmErr } = await sb.storage.from(BUCKET).remove(chunk); // permanent delete (file + metadata)
      if (rmErr) return json({ error: rmErr.message, removed }, 500);
      removed += chunk.length;
    }
    const { error: mErr } = await sb.rpc("rc_expire_image_messages", { names, cutoff_ms: cutoffMs });
    if (mErr) return json({ error: mErr.message, removed }, 500);
  }

  // Also expire any photo messages older than the cutoff whose file was never uploaded here (older base64 photos).
  const { data: expired, error: eErr } = await sb.rpc("rc_expire_image_messages", { names: [], cutoff_ms: cutoffMs });
  if (eErr) return json({ error: eErr.message, removed }, 500);

  return json({ ok: true, filesRemoved: removed, messagesExpired: expired });
});
