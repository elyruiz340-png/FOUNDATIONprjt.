
create table public.restaurant_receipt_settings (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  logo_url text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table public.restaurant_printer_devices (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  device_id text not null check (char_length(btrim(device_id)) between 1 and 200),
  device_name text,
  printer_name text,
  printer_model text,
  connection_type text not null default 'browser'
    check (connection_type in ('browser','usb','bluetooth','network')),
  paper_width text not null default '80'
    check (paper_width in ('58','80','custom')),
  custom_width_mm numeric
    check (custom_width_mm is null or custom_width_mm between 30 and 300),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  constraint unique_restaurant_device unique (restaurant_id, device_id),
  constraint valid_custom_paper_width check (
    (paper_width = 'custom' and custom_width_mm is not null)
    or (paper_width in ('58','80') and custom_width_mm is null)
  )
);

create index idx_printer_devices_restaurant
  on public.restaurant_printer_devices(restaurant_id);

alter table public.restaurant_receipt_settings enable row level security;
alter table public.restaurant_printer_devices enable row level security;

grant select, insert, update, delete on public.restaurant_receipt_settings to authenticated;
grant select, insert, update, delete on public.restaurant_printer_devices to authenticated;

create policy "Restaurant owners admins manage receipt settings"
on public.restaurant_receipt_settings
for all to authenticated
using (
  exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_receipt_settings.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_receipt_settings.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);

create policy "Restaurant owners admins manage printer devices"
on public.restaurant_printer_devices
for all to authenticated
using (
  exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_printer_devices.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = restaurant_printer_devices.restaurant_id
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('halina-receipt-logos', 'halina-receipt-logos', true, 2097152,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Public can view receipt logos"
on storage.objects for select to anon, authenticated
using (bucket_id = 'halina-receipt-logos');

create policy "Restaurant owners admins upload receipt logos"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'halina-receipt-logos'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id::text = (storage.foldername(name))[1]
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);

create policy "Restaurant owners admins update receipt logos"
on storage.objects for update to authenticated
using (
  bucket_id = 'halina-receipt-logos'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id::text = (storage.foldername(name))[1]
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
)
with check (
  bucket_id = 'halina-receipt-logos'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id::text = (storage.foldername(name))[1]
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);

create policy "Restaurant owners admins delete receipt logos"
on storage.objects for delete to authenticated
using (
  bucket_id = 'halina-receipt-logos'
  and (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  and exists (
    select 1 from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id::text = (storage.foldername(name))[1]
      and lower(coalesce(ru.role,'')) in ('owner','admin')
  )
);
