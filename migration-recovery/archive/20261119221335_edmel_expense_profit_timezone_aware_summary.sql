
create index if not exists orders_paid_settled_profit_idx
  on public.orders(restaurant_id, settled_at, branch_id)
  where payment_status='paid' and settled_at is not null;

create index if not exists restaurant_expenses_approved_profit_idx
  on public.restaurant_expenses(restaurant_id, expense_date, branch_id)
  where status='approved';

create or replace function public.edmel_get_expense_profit_summary(
  p_restaurant_id uuid,
  p_branch_id uuid,
  p_start_date date,
  p_end_date_exclusive date
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_timezone text;
  v_currency text;
  v_order_count bigint := 0;
  v_gross_sales numeric(16,2) := 0;
  v_discounts numeric(16,2) := 0;
  v_net_sales numeric(16,2) := 0;
  v_tax_collected numeric(16,2) := 0;
  v_tips numeric(16,2) := 0;
  v_service_charges numeric(16,2) := 0;
  v_total_collected numeric(16,2) := 0;
  v_expense_count bigint := 0;
  v_expenses numeric(16,2) := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required.' using errcode='42501'; end if;
  if p_restaurant_id is null or p_start_date is null or p_end_date_exclusive is null
     or p_end_date_exclusive<=p_start_date
     or p_end_date_exclusive-p_start_date>3660 then
    raise exception 'A valid reporting date range is required.' using errcode='22023';
  end if;
  if not public.edmel_is_restaurant_owner_admin(p_restaurant_id) then
    raise exception 'Owner or Admin access is required for Profit & Loss reporting.' using errcode='42501';
  end if;

  select coalesce(nullif(r.timezone,''),'UTC'),upper(coalesce(r.currency,'USD'))
    into v_timezone,v_currency
  from public.restaurants r where r.id=p_restaurant_id;
  if not found then raise exception 'Restaurant was not found.' using errcode='P0002'; end if;

  if p_branch_id is not null and not exists(
    select 1 from public.restaurant_branches b
    where b.id=p_branch_id and b.restaurant_id=p_restaurant_id and b.is_active=true
  ) then raise exception 'The selected branch is invalid or inactive.' using errcode='22023'; end if;

  select count(*),
         coalesce(sum(coalesce(o.subtotal,0)),0),
         coalesce(sum(coalesce(o.discount_amount,0)),0),
         coalesce(sum(coalesce(o.tax,0)),0),
         coalesce(sum(coalesce(o.tip,0)),0),
         coalesce(sum(coalesce(o.service_charge,0)),0),
         coalesce(sum(coalesce(o.total,0)),0)
    into v_order_count,v_gross_sales,v_discounts,v_tax_collected,
         v_tips,v_service_charges,v_total_collected
  from public.orders o
  where o.restaurant_id=p_restaurant_id
    and (p_branch_id is null or o.branch_id=p_branch_id)
    and o.payment_status='paid'
    and o.settled_at is not null
    and (o.settled_at at time zone v_timezone)::date>=p_start_date
    and (o.settled_at at time zone v_timezone)::date<p_end_date_exclusive
    and lower(coalesce(o.order_status,o.status,'')) not in ('cancelled','canceled','voided','refunded');

  v_net_sales:=v_gross_sales-v_discounts;

  select count(*),coalesce(sum(e.amount),0)
    into v_expense_count,v_expenses
  from public.restaurant_expenses e
  where e.restaurant_id=p_restaurant_id
    and (p_branch_id is null or e.branch_id=p_branch_id)
    and e.status='approved'
    and e.expense_date>=p_start_date
    and e.expense_date<p_end_date_exclusive;

  return jsonb_build_object(
    'restaurant_id',p_restaurant_id,
    'branch_id',p_branch_id,
    'currency',v_currency,
    'timezone',v_timezone,
    'period_start',p_start_date,
    'period_end_exclusive',p_end_date_exclusive,
    'sales_order_count',v_order_count,
    'gross_sales',v_gross_sales,
    'discounts',v_discounts,
    'net_sales',v_net_sales,
    'tax_collected',v_tax_collected,
    'tips_collected',v_tips,
    'service_charges_collected',v_service_charges,
    'total_collected',v_total_collected,
    'approved_expense_count',v_expense_count,
    'approved_expenses',v_expenses,
    'pre_cogs_operating_balance',v_net_sales-v_expenses,
    'cogs_available',false,
    'refunds_available',false,
    'net_profit_available',false
  );
end;
$function$;

revoke all on function public.edmel_get_expense_profit_summary(uuid,uuid,date,date) from public, anon;
grant execute on function public.edmel_get_expense_profit_summary(uuid,uuid,date,date) to authenticated;
