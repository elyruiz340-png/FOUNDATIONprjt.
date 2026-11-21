
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
  v_approval_mode text;
  v_manager_approver_count integer := 0;
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
      v_approval_mode:=coalesce(new.request_data->>'approval_mode','admin');
      if v_approval_mode='manager' then
        insert into public.manager_expense_request_notifications (
          restaurant_id,branch_id,request_id,recipient_role,recipient_user_id,
          notification_type,title,message
        )
        select
          new.restaurant_id,new.branch_id,new.id,'manager',ru.user_id,
          'approval_requested','Manager expense request awaiting review',
          coalesce(v_manager_name,'A Manager') || ' submitted a ' || v_request_label ||
          ' request for ' || coalesce(v_branch_name,'your assigned branch') || '.'
        from public.restaurant_users ru
        join public.staff_branch_access sba
          on sba.restaurant_user_id=ru.id
         and sba.restaurant_id=ru.restaurant_id
         and sba.branch_id=new.branch_id
         and sba.is_active=true
        where ru.restaurant_id=new.restaurant_id
          and ru.user_id is not null
          and ru.id<>new.manager_restaurant_user_id
          and coalesce(ru.is_active,true)=true
          and lower(coalesce(ru.role,''))='staff'
          and lower(coalesce(ru.position,''))='manager'
          and sba.permissions #>> '{modules,expenses,approve}'='true';
        get diagnostics v_manager_approver_count = row_count;
      end if;
      if v_approval_mode<>'manager' or v_manager_approver_count=0 then
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
