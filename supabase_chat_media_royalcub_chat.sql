-- RoyalCub Jobs: storage setup for the public bucket named "royalcub chat"
-- Run once in Supabase -> SQL Editor. Safe to re-run.

-- 1) Make sure the bucket is public, JPEG-only and capped at 2 MB per photo
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('royalcub chat', 'royalcub chat', true, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/jpeg'];

-- 2) Allow the app (anon / logged-in key) to upload photos into m/ in that bucket.
--    Reading needs no policy because the bucket is public.
drop policy if exists "royalcub chat upload" on storage.objects;
create policy "royalcub chat upload"
  on storage.objects for insert
  to anon, authenticated
  with check (bucket_id = 'royalcub chat' and name like 'm/%.jpg');
