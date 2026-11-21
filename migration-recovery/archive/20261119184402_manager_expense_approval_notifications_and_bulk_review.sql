
create table if not exists public.manager_expense_request_notifications (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  request_id uuid not null references public.manager_expense_requests(id) on delete cascade,
  recipient_role text not null check (recipient_role in ('admin','manager')),
  recipient_user_id uuid,
  notification_type text not null check (notification_type in ('approval_requested','approval_decided')),
  title text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  constraint manager_expense_request_notifications_branch_fk
    foreign key (branch_id, restaurant_id)
    references public.restaurant_branches(id, restaurant_id) on delete cascade,
  constraint manager_expense_request_notifications_recipient_check
    check (
      (recipient_role='admin' and recipient_user_id is null)
      or (recipient_role='manager' and recipient_user_id is not null)
    )
);

create index if not exists manager_expense_request_notifications_inbox_idx
  on public.manager_expense_request_notifications
  (restaurant_id, recipient_role, recipient_user_id, is_read, created_at desc);

alter table public.manager_expense_request_notifications enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='manager_expense_request_notifications'
      and policyname='manager_expense_request_notifications_select_recipient'
  ) then
    create policy manager_expense_request_notifications_select_recipient
      on public.manager_expense_request_notifications
      for select to authenticated
      using (
        (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
        or
        (recipient_role='manager' and recipient_user_id=(select auth.uid()))
      );
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='manager_expense_request_notifications'
      and policyname='manager_expense_request_notifications_update_recipient'
  ) then
    create policy manager_expense_request_notifications_update_recipient
      on public.manager_expense_request_notifications
      for update to authenticated
      using (
        (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
        or
        (recipient_role='manager' and recipient_user_id=(select auth.uid()))
      )
      with check (
        (recipient_role='admin' and public.edmel_is_restaurant_owner_admin(restaurant_id))
        or
        (recipient_role='manager' and recipient_user_id=(select auth.uid()))
      );
  end if;
end $$;

grant select on public.manager_expense_request_notifications to authenticated;
grant update (is_read, read_at) on public.manager_expense_request_notifications to authenticated;

create or replace function public.edmel_capture_manager_expense_request_notification()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_manager_name text;
  v_branch_name text;
  v_request_label text;
  v_decision_label text;
begin
  select coalesce(
    nullif(btrim(ru.display_name),''),
    nullif(btrim(ru.full_name),''),
    nullif(btrim(ru.cashier_username),''),
    'Manager'
  )
  into v_manager_name
  from public.restaurant_users ru
  where ru.id=new.manager_restaurant_user_id
    and ru.restaurant_id=new.restaurant_id
  limit 1;

  select b.name into v_branch_name
  from public.restaurant_branches b
  where b.id=new.branch_id and b.restaurant_id=new.restaurant_id;

  v_request_label := case new.request_type
    when 'create' then 'new expense'
    when 'edit' then 'expense change'
    when 'void' then 'expense void'
    else 'expense'
  end;

  if tg_op='INSERT' then
    if new.status='pending' then
      insert into public.manager_expense_request_notifications (
        restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,
        notification_type,title,message
      ) values (
        new.restaurant_id,new.branch_id,new.id,'admin',null,
        'approval_requested','Manager expense approval requested',
        coalesce(v_manager_name,'A Manager') || ' submitted a ' || v_request_label ||
        ' request for ' || coalesce(v_branch_name,'an assigned branch') || '.'
      );
    end if;
    return new;
  end if;

  if old.status is distinct from new.status
     and new.status in ('approved','rejected') then
    v_decision_label := case new.status when 'approved' then 'approved' else 'rejected' end;
    insert into public.manager_expense_request_notifications (
      restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,
      notification_type,title,message
    ) values (
      new.restaurant_id,new.branch_id,new.id,'manager',new.submitted_by_user_id,
      'approval_decided',
      case new.status when 'approved' then 'Expense request approved' else 'Expense request rejected' end,
      'Your ' || v_request_label || ' request for ' || coalesce(v_branch_name,'your branch') ||
      ' was ' || v_decision_label || '. Review note: ' || coalesce(nullif(btrim(new.review_reason),''),'No note provided.')
    );
  end if;
  return new;
end;
$function$;

drop trigger if exists manager_expense_request_notification_insert
  on public.manager_expense_requests;
create trigger manager_expense_request_notification_insert
  after insert on public.manager_expense_requests
  for each row execute function public.edmel_capture_manager_expense_request_notification();

drop trigger if exists manager_expense_request_notification_decision
  on public.manager_expense_requests;
create trigger manager_expense_request_notification_decision
  after update of status on public.manager_expense_requests
  for each row
  when (old.status is distinct from new.status)
  execute function public.edmel_capture_manager_expense_request_notification();

create or replace function public.edmel_review_manager_expense_requests_bulk(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_request_ids uuid[],
  p_decision text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_actor_id uuid := (select auth.uid());
  v_request_id uuid;
  v_expected_count integer;
  v_found_count integer;
  v_processed integer := 0;
begin
  if v_actor_id is null then
    raise exception 'Authentication required.' using errcode='42501';
  end if;
  if p_restaurant_id is null or p_branch_id is null
     or p_request_ids is null or cardinality(p_request_ids) not between 1 and 50
     or p_decision not in ('approved','rejected')
     or p_reason is null or char_length(btrim(p_reason)) not between 3 and 500 then
    raise exception 'Choose 1 to 50 requests, a valid decision, and a reason between 3 and 500 characters.'
      using errcode='22023';
  end if;
  if cardinality(p_request_ids) <> (
    select count(distinct x) from unnest(p_request_ids) as t(x)
  ) then
    raise exception 'Duplicate request IDs are not allowed.' using errcode='22023';
  end if;
  if not exists (
    select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true
  ) then
    raise exception 'The selected branch is unavailable.' using errcode='22023';
  end if;
  if not public.edmel_is_restaurant_owner_admin(p_restaurant_id)
     and not public.edmel_expense_has_access(p_restaurant_id,p_branch_id,'approve') then
    raise exception 'You do not have approval permission for this branch.' using errcode='42501';
  end if;

  v_expected_count := cardinality(p_request_ids);
  select count(*) into v_found_count
  from public.manager_expense_requests r
  where r.id = any(p_request_ids)
    and r.restaurant_id=p_restaurant_id
    and r.branch_id=p_branch_id
    and r.status='pending';

  if v_found_count <> v_expected_count then
    raise exception 'One or more selected requests are no longer pending or do not belong to this branch. Refresh and try again.'
      using errcode='22023';
  end if;

  for v_request_id in
    select r.id
    from public.manager_expense_requests r
    where r.id = any(p_request_ids)
      and r.restaurant_id=p_restaurant_id
      and r.branch_id=p_branch_id
      and r.status='pending'
    order by r.submitted_at, r.id
  loop
    perform public.edmel_review_manager_expense_request(
      v_request_id,p_decision,btrim(p_reason)
    );
    v_processed := v_processed + 1;
  end loop;

  return jsonb_build_object(
    'success',true,
    'status',p_decision,
    'branch_id',p_branch_id,
    'processed_count',v_processed
  );
end;
$function$;

revoke all on function public.edmel_review_manager_expense_requests_bulk(uuid,uuid,uuid[],text,text) from public, anon;
grant execute on function public.edmel_review_manager_expense_requests_bulk(uuid,uuid,uuid[],text,text) to authenticated;
