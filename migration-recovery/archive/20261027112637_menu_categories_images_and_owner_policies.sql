
alter table public.menu_categories
  add column if not exists image_url text;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_categories' and policyname='HALINA owners manage categories insert') then
    create policy "HALINA owners manage categories insert"
      on public.menu_categories for insert to authenticated
      with check (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_categories.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_categories' and policyname='HALINA owners manage categories update') then
    create policy "HALINA owners manage categories update"
      on public.menu_categories for update to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_categories.restaurant_id
            and ru.role in ('owner','admin')
        )
      )
      with check (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_categories.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_categories' and policyname='HALINA owners manage categories delete') then
    create policy "HALINA owners manage categories delete"
      on public.menu_categories for delete to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_categories.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_categories' and policyname='HALINA owners view all categories') then
    create policy "HALINA owners view all categories"
      on public.menu_categories for select to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_categories.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_items' and policyname='HALINA owners manage menu items insert') then
    create policy "HALINA owners manage menu items insert"
      on public.menu_items for insert to authenticated
      with check (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_items.restaurant_id
            and ru.role in ('owner','admin')
        )
        and (
          category_id is null or exists (
            select 1 from public.menu_categories mc
            where mc.id = menu_items.category_id
              and mc.restaurant_id = menu_items.restaurant_id
          )
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_items' and policyname='HALINA owners manage menu items update') then
    create policy "HALINA owners manage menu items update"
      on public.menu_items for update to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_items.restaurant_id
            and ru.role in ('owner','admin')
        )
      )
      with check (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_items.restaurant_id
            and ru.role in ('owner','admin')
        )
        and (
          category_id is null or exists (
            select 1 from public.menu_categories mc
            where mc.id = menu_items.category_id
              and mc.restaurant_id = menu_items.restaurant_id
          )
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_items' and policyname='HALINA owners manage menu items delete') then
    create policy "HALINA owners manage menu items delete"
      on public.menu_items for delete to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_items.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='menu_items' and policyname='HALINA owners view all menu items') then
    create policy "HALINA owners view all menu items"
      on public.menu_items for select to authenticated
      using (
        exists (
          select 1 from public.restaurant_users ru
          where ru.user_id = auth.uid()
            and ru.restaurant_id = menu_items.restaurant_id
            and ru.role in ('owner','admin')
        )
      );
  end if;
end
$$;
