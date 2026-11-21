
begin;

alter table public.restaurant_expenses
  add column if not exists notes text;

alter table public.restaurant_expenses
  drop constraint if exists restaurant_expenses_notes_length_check;
alter table public.restaurant_expenses
  add constraint restaurant_expenses_notes_length_check
  check (notes is null or char_length(notes) <= 2000);

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
  if p_notes is not null and char_length(p_notes) > 2000 then raise exception 'Notes cannot exceed 2000 characters.'; end if;

  select * into v_row from public.restaurant_expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense record not found.'; end if;
  if not public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'edit') then
    raise exception 'You do not have permission to edit this expense.';
  end if;

  v_manage := public.edmel_expense_has_access(v_row.restaurant_id,v_row.branch_id,'manage');
  if v_row.status in ('rejected','voided') then
    raise exception 'Rejected or voided expenses cannot be edited.';
  end if;
  if v_row.status='pending' and v_row.created_by_user_id<>v_user_id and not v_manage then
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
      notes=nullif(btrim(p_notes),''),
      last_change_reason=btrim(p_reason),
      updated_by_user_id=v_user_id,
      updated_at=now()
  where id=p_expense_id;

  return p_expense_id;
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
  if p_notes is not null and char_length(p_notes) > 2000 then raise exception 'Notes cannot exceed 2000 characters.'; end if;
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

revoke all on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) from public;
revoke all on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) from public;
grant execute on function public.edmel_create_operating_expense(uuid,uuid,uuid,date,text,numeric,text,text,text) to authenticated;
grant execute on function public.edmel_update_operating_expense(uuid,uuid,date,text,numeric,text,text,text,text) to authenticated;

commit;
