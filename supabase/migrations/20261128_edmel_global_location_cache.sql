create table if not exists public.edmel_global_location_cache (
  cache_key text primary key,
  payload jsonb not null,
  release text,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists edmel_global_location_cache_expires_idx
  on public.edmel_global_location_cache (expires_at);
alter table public.edmel_global_location_cache enable row level security;
revoke all on table public.edmel_global_location_cache from public, anon, authenticated;
grant all on table public.edmel_global_location_cache to service_role;