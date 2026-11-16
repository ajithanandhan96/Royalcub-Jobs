# Backend setup: chat photos, one-month cleanup, push alerts

Do these once, in order. Nothing here changes existing tables except adding a trigger to `rc_msgs`.

1. **Run `supabase_chat_media.sql`** in the Supabase SQL editor (steps 1-6 at the top; leave the commented `vault.create_secret` lines for step 4 below).
2. **Make VAPID keys** (the identity your server uses to send push): `npx web-push generate-vapid-keys`
   Keep the private key secret. The public key goes in the website (step 5).
3. **Deploy the two Edge Functions** (Supabase CLI):
   ```
   supabase functions deploy purge-chat-media --no-verify-jwt
   supabase functions deploy push-notify      --no-verify-jwt
   supabase secrets set CRON_SECRET=<random string> WEBHOOK_SECRET=<another random string> \
     VAPID_PUBLIC_KEY=<public> VAPID_PRIVATE_KEY=<private> VAPID_SUBJECT=mailto:you@example.com
   ```
4. **Store the URLs/secrets the database uses** (SQL editor, section 7 of the .sql file, with your project ref and the same two random strings):
   `rc_push_url`, `rc_push_secret`, `rc_purge_url`, `rc_purge_secret`.
5. **Website:** put `sw.js` in the same folder as `index.html`, and add this line *above* the main `<script>` in `index.html`:
   `<script>window.RC_CONFIG={vapidPublicKey:"<public key>"};</script>`
   Until a key is set the alert banner stays hidden and everything else works.
6. **Check it:** send a photo (it should appear instantly, then show Sent); in Storage > chat-media a file appears under `m/`; the message row in `rc_msgs` ends with "This image will disappear within one month". Run the purge once by hand:
   `curl -X POST https://<ref>.supabase.co/functions/v1/purge-chat-media -H "x-cron-secret: <CRON_SECRET>"`

Notes: "one month" is 30 days. On iPhone, web push only works after the site is added to the Home Screen. If the `rc_content` table only allows certain `kind` values, allow `view` as well (story/post views).
