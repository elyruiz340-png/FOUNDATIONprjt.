
begin;

create or replace function public.edmel_guard_expense_category()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then raise exception 'Authentication required to create an expense category.'; end if;
    new.created_by_user_id := auth.uid();
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();
  else
    if new.id <> old.id or new.restaurant_id <> old.restaurant_id then
      raise exception 'Expense category identity and restaurant ownership cannot be changed.';
    end if;
    new.created_by_user_id := old.created_by_user_id;
    new.created_at := old.created_at;
    new.updated_at := now();
  end if;
  return new;
end;
$function$;

drop trigger if exists restaurant_expense_category_guard_trigger on public.restaurant_expense_categories;
create trigger restaurant_expense_category_guard_trigger
before insert or update on public.restaurant_expense_categories
for each row execute function public.edmel_guard_expense_category();

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
  if p_notes is not null and char_length(p_notes) > 2000 then raise exception 'Notes cannot exceed 2000 characters.'; end if;
  if p_category_id is null then raise exception 'An expense category is required.'; end if;
  if p_branch_id is not null and not exists (
    select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true
  ) then
    raise exception 'The selected branch is invalid or inactive for this restaurant.';
  end if;
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
    reference_number,notes,amount,currency_code,status,created_by_user_id,created_by_staff_id,
    approved_by_user_id,approved_at,approval_note
  ) values (
    p_restaurant_id,p_branch_id,p_category_id,coalesce(p_expense_date,current_date),
    btrim(p_description),nullif(btrim(p_payee),''),nullif(btrim(p_reference_number),''),
    nullif(btrim(p_notes),''),p_amount,upper(v_currency),v_status,v_user_id,v_staff_id,
    case when v_manage then v_user_id else null end,
    case when v_manage then now() else null end,
    case when v_manage then 'Automatically approved under Manage permission.' else null end
  ) returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.edmel_guard_expense_category() from public;
revoke all on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) from public;
grant execute on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) to authenticated;

commit;
