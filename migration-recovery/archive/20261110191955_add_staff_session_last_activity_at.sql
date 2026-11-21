alter table public.staff_sessions
  add column if not exists last_activity_at timestamptz;

update public.staff_sessions
set last_activity_at = coalesce(last_activity_at, last_seen_at, login_at)
where last_activity_at is null;

create index if not exists staff_sessions_active_activity_idx
on public.staff_sessions (restaurant_user_id, last_activity_at desc)
where logout_at is null;