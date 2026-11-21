alter table public.restaurants
add column if not exists appearance_settings jsonb
not null
default jsonb_build_object(
  'font_family', 'Inter',
  'font_scale', 1.0,
  'logo_scale', 1.15
);