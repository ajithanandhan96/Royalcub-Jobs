-- =====================================================================================
-- RoyalCub Jobs: chat photos (Storage), automatic image note, 1-month cleanup, push alerts
-- Run once in the Supabase SQL editor. Safe to re-run.
-- Assumes the existing table public.rc_msgs(id, from_name, to_name, body, ts bigint, status).
-- Before the two "vault.create_secret" calls at the bottom, deploy the Edge Functions
-- (see supabase/README.md).
-- =====================================================================================

-- 1. Storage bucket for chat photos --------------------------------------------------
-- Public-read bucket: a photo is reachable only through its random (UUID) URL, and nobody can list the bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The app signs people in itself (it does not use Supabase Auth sessions), so uploads come from the anon role.
-- Upload only: no select/update/delete policy, so nobody can overwrite, delete or enumerate files from the browser.
drop policy if exists "rc chat-media upload" on storage.objects;
create policy "rc chat-media upload" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'chat-media' and name like 'm/%');

-- 2. Backend appends the note to every photo message ----------------------------------
create or replace function public.rc_msgs_image_note()
returns trigger language plpgsql as $$
declare
  note constant text := 'This image will disappear within one month';
begin
  -- a photo message looks like  [⟪rp|who|snippet⟫] ⟦img|<url>⟧ [caption]
  if new.body ~ '^(⟪rp\|[^⟫]*⟫\s*)?⟦img\|' and new.body !~ (note || '\s*$') then
    new.body := rtrim(new.body) || E'\n' || note;
  end if;
  return new;
end $$;

drop trigger if exists rc_msgs_image_note on public.rc_msgs;
create trigger rc_msgs_image_note
  before insert on public.rc_msgs
  for each row execute function public.rc_msgs_image_note();

-- 3. Permanent deletion of photos after one month (30 days) --------------------------
-- Files must be removed through the Storage API (deleting storage.objects rows in SQL would leave the
-- files behind), so a daily cron job calls the purge-chat-media Edge Function, which uses these helpers.
create or replace function public.rc_expired_media()
returns setof text language sql security definer set search_path = public, storage as $$
  select name from storage.objects
  where bucket_id = 'chat-media' and created_at < now() - interval '30 days'
  order by created_at
  limit 1000
$$;

create or replace function public.rc_expire_image_messages(names text[], cutoff_ms bigint)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; c integer;
begin
  -- messages whose file was just deleted
  if coalesce(array_length(names, 1), 0) > 0 then
    update public.rc_msgs set body = '⟦img-expired⟧'
    where body like '%⟦img|%'
      and exists (select 1 from unnest(names) x where strpos(body, '/chat-media/' || x) > 0);
    get diagnostics c = row_count; n := n + c;
  end if;
  -- any other photo message older than the cutoff (this also clears old photos that were stored inside the table)
  update public.rc_msgs set body = '⟦img-expired⟧'
  where ts < cutoff_ms and body ~ '^(⟪rp\|[^⟫]*⟫\s*)?⟦img\|';
  get diagnostics c = row_count; n := n + c;
  return n;
end $$;

revoke all on function public.rc_expired_media() from public, anon, authenticated;
revoke all on function public.rc_expire_image_messages(text[], bigint) from public, anon, authenticated;
grant execute on function public.rc_expired_media() to service_role;
grant execute on function public.rc_expire_image_messages(text[], bigint) to service_role;

-- 4. Push subscriptions ----------------------------------------------------------------
create table if not exists public.rc_push_subs (
  endpoint   text primary key,
  name       text not null,
  p256dh     text not null,
  auth       text not null,
  updated_at timestamptz not null default now()
);
create index if not exists rc_push_subs_name_idx on public.rc_push_subs (name);
alter table public.rc_push_subs enable row level security;   -- no policies: the browser never reads this table

create or replace function public.rc_push_register(p_endpoint text, p_name text, p_p256dh text, p_auth text)
returns void language sql security definer set search_path = public as $$
  insert into public.rc_push_subs (endpoint, name, p256dh, auth, updated_at)
  values (p_endpoint, p_name, p_p256dh, p_auth, now())
  on conflict (endpoint) do update
    set name = excluded.name, p256dh = excluded.p256dh, auth = excluded.auth, updated_at = now()
$$;
create or replace function public.rc_push_unregister(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.rc_push_subs where endpoint = p_endpoint
$$;
grant execute on function public.rc_push_register(text, text, text, text) to anon, authenticated;
grant execute on function public.rc_push_unregister(text) to anon, authenticated;

-- 5. Trigger: new message -> push-notify Edge Function ---------------------------------
create extension if not exists pg_net with schema extensions;

create or replace function public.rc_msgs_push()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare _url text; _secret text;
begin
  select decrypted_secret into _url    from vault.decrypted_secrets where name = 'rc_push_url';
  select decrypted_secret into _secret from vault.decrypted_secrets where name = 'rc_push_secret';
  if _url is null or _secret is null then return new; end if;
  perform net.http_post(
    url     := _url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', _secret),
    body    := jsonb_build_object('record', to_jsonb(new)),
    timeout_milliseconds := 5000
  );
  return new;
exception when others then
  return new;   -- a push problem must never block a chat message
end $$;

drop trigger if exists rc_msgs_push on public.rc_msgs;
create trigger rc_msgs_push
  after insert on public.rc_msgs
  for each row execute function public.rc_msgs_push();

-- 6. Daily cleanup schedule (03:17 UTC) ------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'rc-purge-chat-media',
  '17 3 * * *',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'rc_purge_url'),
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'rc_purge_secret')),
      body    := '{}'::jsonb,
      timeout_milliseconds := 60000
    )
  $cron$
);

-- 7. Secrets used by the triggers above (run ONCE, with your real values) --------------
-- select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co/functions/v1/push-notify',        'rc_push_url');
-- select vault.create_secret('THE-SAME-VALUE-AS-WEBHOOK_SECRET',                                    'rc_push_secret');
-- select vault.create_secret('https://YOUR-PROJECT-REF.supabase.co/functions/v1/purge-chat-media',   'rc_purge_url');
-- select vault.create_secret('THE-SAME-VALUE-AS-CRON_SECRET',                                        'rc_purge_secret');
