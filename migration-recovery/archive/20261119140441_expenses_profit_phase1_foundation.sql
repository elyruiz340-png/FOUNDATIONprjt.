
begin;

create table if not exists public.restaurant_expense_categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete restrict,
  name text not null check (char_length(btrim(name)) between 2 and 80),
  description text,
  is_active boolean not null default true,
  created_by_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurant_expense_categories_id_restaurant_unique unique (id, restaurant_id)
);

create unique index if not exists restaurant_expense_categories_name_uidx
  on public.restaurant_expense_categories (restaurant_id, lower(btrim(name)));

create table if not exists public.restaurant_expenses (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete restrict,
  branch_id uuid,
  category_id uuid not null,
  expense_date date not null default current_date,
  description text not null check (char_length(btrim(description)) between 3 and 500),
  payee text check (payee is null or char_length(btrim(payee)) <= 160),
  reference_number text check (reference_number is null or char_length(btrim(reference_number)) <= 120),
  amount numeric(14,2) not null check (amount > 0),
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','voided')),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_by_staff_id uuid,
  updated_by_user_id uuid references auth.users(id) on delete set null,
  approved_by_user_id uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  approval_note text,
  rejected_by_user_id uuid references auth.users(id) on delete set null,
  rejected_at timestamptz,
  rejection_reason text,
  voided_by_user_id uuid references auth.users(id) on delete set null,
  voided_at timestamptz,
  void_reason text,
  last_change_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurant_expenses_branch_restaurant_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete restrict,
  constraint restaurant_expenses_category_restaurant_fk
    foreign key (category_id, restaurant_id)
    references public.restaurant_expense_categories(id, restaurant_id) on delete restrict,
  constraint restaurant_expenses_approval_consistency check (
    (status <> 'approved' or (approved_by_user_id is not null and approved_at is not null))
    and (status <> 'rejected' or (rejected_by_user_id is not null and rejected_at is not null))
    and (status <> 'voided' or (voided_by_user_id is not null and voided_at is not null))
  )
);

create index if not exists restaurant_expenses_restaurant_date_idx
  on public.restaurant_expenses (restaurant_id, expense_date desc);
create index if not exists restaurant_expenses_branch_date_idx
  on public.restaurant_expenses (restaurant_id, branch_id, expense_date desc);
create index if not exists restaurant_expenses_status_date_idx
  on public.restaurant_expenses (restaurant_id, status, expense_date desc);
create index if not exists restaurant_expenses_category_idx
  on public.restaurant_expenses (restaurant_id, category_id);

create table if not exists public.restaurant_expense_audit_logs (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete restrict,
  branch_id uuid,
  record_type text not null check (record_type in ('operating_expense','expense_category')),
  record_id uuid not null,
  action text not null,
  actor_user_id uuid,
  actor_staff_id uuid,
  actor_name text not null default 'System',
  actor_role text not null default 'system',
  permission_key text,
  reason text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now(),
  constraint restaurant_expense_audit_branch_restaurant_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete restrict
);

create index if not exists restaurant_expense_audit_restaurant_created_idx
  on public.restaurant_expense_audit_logs (restaurant_id, created_at desc);
create index if not exists restaurant_expense_audit_branch_created_idx
  on public.restaurant_expense_audit_logs (restaurant_id, branch_id, created_at desc);
create index if not exists restaurant_expense_audit_record_idx
  on public.restaurant_expense_audit_logs (record_type, record_id, created_at desc);

create or replace function public.edmel_expense_has_access(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_action text
) returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = p_restaurant_id
      and coalesce(ru.is_active, true) = true
      and (
        lower(coalesce(ru.role, '')) in ('owner','admin')
        or (
          p_branch_id is not null
          and exists (
            select 1
            from public.restaurant_branches b
            join public.staff_branch_access sba
              on sba.branch_id = b.id
             and sba.restaurant_id = b.restaurant_id
            where b.id = p_branch_id
              and b.restaurant_id = p_restaurant_id
              and b.is_active = true
              and sba.restaurant_user_id = ru.id
              and sba.is_active = true
              and (
                (p_action = 'view' and (
                  sba.permissions #>> '{modules,expenses,view}' = 'true'
                  or sba.permissions #>> '{modules,expenses,manage}' = 'true'
                ))
                or (p_action = 'create' and (
                  sba.permissions #>> '{modules,expenses,create}' = 'true'
                  or sba.permissions #>> '{modules,expenses,manage}' = 'true'
                ))
                or (p_action = 'edit' and (
                  sba.permissions #>> '{modules,expenses,edit}' = 'true'
                  or sba.permissions #>> '{modules,expenses,manage}' = 'true'
                ))
                or (p_action = 'delete' and sba.permissions #>> '{modules,expenses,delete}' = 'true')
                or (p_action = 'approve' and sba.permissions #>> '{modules,expenses,approve}' = 'true')
                or (p_action = 'manage' and sba.permissions #>> '{modules,expenses,manage}' = 'true')
              )
          )
        )
      )
  );
$function$;

create or replace function public.edmel_expense_can_view_categories(p_restaurant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.restaurant_users ru
    where ru.user_id = (select auth.uid())
      and ru.restaurant_id = p_restaurant_id
      and coalesce(ru.is_active, true) = true
      and (
        lower(coalesce(ru.role, '')) in ('owner','admin')
        or exists (
          select 1
          from public.staff_branch_access sba
          join public.restaurant_branches b
            on b.id = sba.branch_id
           and b.restaurant_id = sba.restaurant_id
          where sba.restaurant_user_id = ru.id
            and sba.restaurant_id = p_restaurant_id
            and sba.is_active = true
            and b.is_active = true
            and (
              sba.permissions #>> '{modules,expenses,view}' = 'true'
              or sba.permissions #>> '{modules,expenses,manage}' = 'true'
            )
        )
      )
  );
$function$;

create or replace function public.edmel_capture_expense_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_new jsonb;
  v_old jsonb;
  v_restaurant_id uuid;
  v_branch_id uuid;
  v_record_id uuid;
  v_record_type text;
  v_action text;
  v_actor_user_id uuid := auth.uid();
  v_actor_staff_id uuid;
  v_actor_name text := 'System';
  v_actor_role text := 'system';
  v_permission text := coalesce(nullif(current_setting('edmel.expense_permission', true), ''), 'owner_admin');
  v_reason text;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;

  v_restaurant_id := coalesce((v_new->>'restaurant_id')::uuid, (v_old->>'restaurant_id')::uuid);
  v_branch_id := nullif(coalesce(v_new->>'branch_id', v_old->>'branch_id'), '')::uuid;
  v_record_id := coalesce((v_new->>'id')::uuid, (v_old->>'id')::uuid);
  v_record_type := case when tg_table_name = 'restaurant_expenses'
                        then 'operating_expense' else 'expense_category' end;

  if tg_op = 'INSERT' then
    if v_record_type = 'operating_expense' and v_new->>'status' = 'approved' then
      v_action := 'created_auto_approved';
    elsif v_record_type = 'operating_expense' then
      v_action := 'created_pending_approval';
    else
      v_action := 'category_created';
    end if;
  elsif tg_op = 'UPDATE' then
    if v_record_type = 'operating_expense' and coalesce(v_old->>'status','') <> coalesce(v_new->>'status','') then
      v_action := case v_new->>'status'
        when 'approved' then 'approved'
        when 'rejected' then 'rejected'
        when 'voided' then 'voided'
        else 'status_changed'
      end;
    elsif v_record_type = 'operating_expense' then
      v_action := 'edited';
    else
      v_action := 'category_updated';
    end if;
  else
    v_action := 'record_deleted';
  end if;

  select ru.id,
         coalesce(nullif(ru.display_name,''), nullif(ru.full_name,''), nullif(ru.cashier_username,''), 'Staff'),
         coalesce(nullif(lower(ru.role),''), 'staff') ||
           case when nullif(ru."position",'') is not null then ' (' || ru."position" || ')' else '' end
    into v_actor_staff_id, v_actor_name, v_actor_role
  from public.restaurant_users ru
  where ru.user_id = v_actor_user_id
    and ru.restaurant_id = v_restaurant_id
    and coalesce(ru.is_active,true) = true
  order by ru.created_at desc
  limit 1;

  v_reason := coalesce(v_new->>'last_change_reason', v_new->>'approval_note',
                       v_new->>'rejection_reason', v_new->>'void_reason',
                       v_old->>'last_change_reason', v_old->>'approval_note',
                       v_old->>'rejection_reason', v_old->>'void_reason');

  insert into public.restaurant_expense_audit_logs (
    restaurant_id, branch_id, record_type, record_id, action,
    actor_user_id, actor_staff_id, actor_name, actor_role,
    permission_key, reason, before_data, after_data
  ) values (
    v_restaurant_id, v_branch_id, v_record_type, v_record_id, v_action,
    v_actor_user_id, v_actor_staff_id, v_actor_name, v_actor_role,
    v_permission, v_reason, v_old, v_new
  );

  insert into public.audit_logs (
    restaurant_id, actor_user_id, actor_name, actor_role,
    action_category, action, record_type, record_id, result, details, created_at
  ) values (
    v_restaurant_id,
    v_actor_user_id,
    v_actor_name,
    v_actor_role,
    'Expenses & Profit',
    replace(initcap(replace(v_action,'_',' ')),'Auto Approved','Auto-approved'),
    v_record_type,
    v_record_id::text,
    'success',
    jsonb_build_object(
      'branch_id', v_branch_id,
      'permission_used', v_permission,
      'reason', v_reason,
      'before', v_old,
      'after', v_new
    ),
    now()
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$function$;

create or replace function public.edmel_block_expense_audit_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception 'Expense audit history is append-only and cannot be changed or deleted.';
end;
$function$;

create or replace function public.edmel_create_operating_expense(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_category_id uuid,
  p_expense_date date,
  p_description text,
  p_amount numeric,
  p_payee text default null,
  p_reference_number text default null,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_staff_id uuid;
  v_currency text;
  v_manage boolean;
  v_status text;
  v_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required.'; end if;
  if p_description is null or char_length(btrim(p_description)) not between 3 and 500 then
    raise exception 'Description must be between 3 and 500 characters.';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if p_category_id is null then raise exception 'An expense category is required.'; end if;
  if not public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'create') then
    raise exception 'You do not have permission to create expenses for this branch.';
  end if;

  if not exists (
    select 1 from public.restaurant_expense_categories c
    where c.id=p_category_id and c.restaurant_id=p_restaurant_id and c.is_active=true
  ) then raise exception 'The selected expense category is unavailable.'; end if;

  select r.currency into v_currency from public.restaurants r where r.id=p_restaurant_id;
  if v_currency is null then raise exception 'Restaurant currency could not be verified.'; end if;

  select ru.id into v_staff_id
  from public.restaurant_users ru
  where ru.user_id=v_user_id and ru.restaurant_id=p_restaurant_id and coalesce(ru.is_active,true)=true
  order by ru.created_at desc limit 1;

  v_manage := public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'manage');
  v_status := case when v_manage then 'approved' else 'pending' end;
  perform set_config('edmel.expense_permission',case when v_manage then 'manage' else 'create' end,true);

  insert into public.restaurant_expenses (
    restaurant_id,branch_id,category_id,expense_date,description,payee,
    reference_number,amount,currency_code,status,created_by_user_id,created_by_staff_id,
    approved_by_user_id,approved_at,approval_note
  ) values (
    p_restaurant_id,p_branch_id,p_category_id,coalesce(p_expense_date,current_date),
    btrim(p_description),nullif(btrim(p_payee),''),nullif(btrim(p_reference_number),''),
    p_amount,upper(v_currency),v_status,v_user_id,v_staff_id,
    case when v_manage then v_user_id else null end,
    case when v_manage then now() else null end,
    case when v_manage then 'Automatically approved under Manage permission.' else null end
  ) returning id into v_id;

  return v_id;
end;
$function$;

create or replace function public.edmel_update_operating_expense(
  p_expense_id uuid,
  p_category_id uuid,
  p_expense_date date,
  p_description text,
  p_amount numeric,
  p_payee text,
  p_reference_number text,
  p_notes text,
  p_reason text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row public.restaurant_expenses%rowtype;
  v_user_id uuid := auth.uid();
  v_manage boolean;
begin
  if v_user_id is null then raise exception 'Authentication required.'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(btrim(p_reason)) > 500 then
    raise exception 'A change reason between 3 and 500 characters is required.';
  end if;
  if p_description is null or char_length(btrim(p_description)) not between 3 and 500 then
    raise exception 'Description must be between 3 and 500 characters.';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;

  select * into v_row from public.restaurant_expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense record not found.'; end if;
  if not public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'edit') then
    raise exception 'You do not have permission to edit this expense.';
  end if;

  v_manage := public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'manage');
  if v_row.status in ('rejected','voided') then
    raise exception 'Rejected or voided expenses cannot be edited.';
  end if;
  if v_row.status='pending' and v_row.created_by_user_id<>v_user_id and not v_manage
     and not public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'approve') then
    raise exception 'You may only edit your own pending expense submission.';
  end if;
  if v_row.status='approved' and not v_manage then
    raise exception 'Only Owner/Admin or a Manager with Manage permission may edit an approved expense.';
  end if;
  if not exists (
    select 1 from public.restaurant_expense_categories c
    where c.id=p_category_id and c.restaurant_id=v_row.restaurant_id and c.is_active=true
  ) then raise exception 'The selected expense category is unavailable.'; end if;

  perform set_config('edmel.expense_permission',case when v_manage then 'manage' else 'edit' end,true);
  update public.restaurant_expenses
  set category_id=p_category_id,
      expense_date=coalesce(p_expense_date,expense_date),
      description=btrim(p_description),
      amount=p_amount,
      payee=nullif(btrim(p_payee),''),
      reference_number=nullif(btrim(p_reference_number),''),
      last_change_reason=btrim(p_reason),
      updated_by_user_id=v_user_id,
      updated_at=now()
  where id=p_expense_id;

  return p_expense_id;
end;
$function$;

create or replace function public.edmel_review_operating_expense(
  p_expense_id uuid,
  p_decision text,
  p_reason text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row public.restaurant_expenses%rowtype;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Authentication required.'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected.'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(btrim(p_reason)) > 500 then
    raise exception 'An approval or rejection reason between 3 and 500 characters is required.';
  end if;

  select * into v_row from public.restaurant_expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense record not found.'; end if;
  if v_row.status <> 'pending' then raise exception 'Only pending expenses can be reviewed.'; end if;
  if not public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'approve') then
    raise exception 'You do not have approval permission for this branch.';
  end if;

  perform set_config('edmel.expense_permission','approve',true);
  if p_decision='approved' then
    update public.restaurant_expenses
    set status='approved',approved_by_user_id=v_user_id,approved_at=now(),
        approval_note=btrim(p_reason),updated_by_user_id=v_user_id,updated_at=now()
    where id=p_expense_id;
  else
    update public.restaurant_expenses
    set status='rejected',rejected_by_user_id=v_user_id,rejected_at=now(),
        rejection_reason=btrim(p_reason),updated_by_user_id=v_user_id,updated_at=now()
    where id=p_expense_id;
  end if;

  return p_expense_id;
end;
$function$;

create or replace function public.edmel_void_operating_expense(
  p_expense_id uuid,
  p_reason text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row public.restaurant_expenses%rowtype;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'Authentication required.'; end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(btrim(p_reason)) > 500 then
    raise exception 'A void reason between 3 and 500 characters is required.';
  end if;

  select * into v_row from public.restaurant_expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense record not found.'; end if;
  if v_row.status='voided' then raise exception 'Expense is already voided.'; end if;
  if not public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'delete') then
    raise exception 'You do not have permission to void this expense.';
  end if;

  perform set_config('edmel.expense_permission','delete',true);
  update public.restaurant_expenses
  set status='voided',voided_by_user_id=v_user_id,voided_at=now(),
      void_reason=btrim(p_reason),last_change_reason=btrim(p_reason),
      updated_by_user_id=v_user_id,updated_at=now()
  where id=p_expense_id;

  return p_expense_id;
end;
$function$;

alter table public.restaurant_expense_categories enable row level security;
alter table public.restaurant_expenses enable row level security;
alter table public.restaurant_expense_audit_logs enable row level security;

drop policy if exists expense_categories_select_assigned on public.restaurant_expense_categories;
create policy expense_categories_select_assigned
on public.restaurant_expense_categories for select to authenticated
using (public.edmel_expense_can_view_categories(restaurant_id));

drop policy if exists expense_categories_insert_owner_admin on public.restaurant_expense_categories;
create policy expense_categories_insert_owner_admin
on public.restaurant_expense_categories for insert to authenticated
with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

drop policy if exists expense_categories_update_owner_admin on public.restaurant_expense_categories;
create policy expense_categories_update_owner_admin
on public.restaurant_expense_categories for update to authenticated
using (public.edmel_is_restaurant_owner_admin(restaurant_id))
with check (public.edmel_is_restaurant_owner_admin(restaurant_id));

drop policy if exists expenses_select_assigned_branch on public.restaurant_expenses;
create policy expenses_select_assigned_branch
on public.restaurant_expenses for select to authenticated
using (public.edmel_expense_has_access(restaurant_id,branch_id,'view'));

drop policy if exists expense_audit_select_owner_admin on public.restaurant_expense_audit_logs;
create policy expense_audit_select_owner_admin
on public.restaurant_expense_audit_logs for select to authenticated
using (public.edmel_is_restaurant_owner_admin(restaurant_id));

drop trigger if exists restaurant_expenses_audit_trigger on public.restaurant_expenses;
create trigger restaurant_expenses_audit_trigger
after insert or update on public.restaurant_expenses
for each row execute function public.edmel_capture_expense_audit();

drop trigger if exists restaurant_expense_categories_audit_trigger on public.restaurant_expense_categories;
create trigger restaurant_expense_categories_audit_trigger
after insert or update on public.restaurant_expense_categories
for each row execute function public.edmel_capture_expense_audit();

drop trigger if exists restaurant_expense_audit_no_mutation on public.restaurant_expense_audit_logs;
create trigger restaurant_expense_audit_no_mutation
before update or delete on public.restaurant_expense_audit_logs
for each row execute function public.edmel_block_expense_audit_mutation();

revoke all on public.restaurant_expense_categories from anon, authenticated;
revoke all on public.restaurant_expenses from anon, authenticated;
revoke all on public.restaurant_expense_audit_logs from anon, authenticated;
grant select, insert, update on public.restaurant_expense_categories to authenticated;
grant select on public.restaurant_expenses to authenticated;
grant select on public.restaurant_expense_audit_logs to authenticated;

revoke all on function public.edmel_expense_has_access(uuid,uuid,text) from public;
revoke all on function public.edmel_expense_can_view_categories(uuid) from public;
revoke all on function public.edmel_capture_expense_audit() from public;
revoke all on function public.edmel_block_expense_audit_mutation() from public;
revoke all on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) from public;
revoke all on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) from public;
revoke all on function public.edmel_review_operating_expense(uuid,text,text) from public;
revoke all on function public.edmel_void_operating_expense(uuid,text) from public;

grant execute on function public.edmel_expense_has_access(uuid,uuid,text) to authenticated;
grant execute on function public.edmel_expense_can_view_categories(uuid) to authenticated;
grant execute on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) to authenticated;
grant execute on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) to authenticated;
grant execute on function public.edmel_review_operating_expense(uuid,text,text) to authenticated;
grant execute on function public.edmel_void_operating_expense(uuid,text) to authenticated;

commit;
