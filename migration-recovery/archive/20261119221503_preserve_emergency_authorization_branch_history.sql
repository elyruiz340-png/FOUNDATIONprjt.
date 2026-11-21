
alter table public.manager_emergency_authorization_requests
  drop constraint if exists manager_emergency_authorization_branch_fk;
alter table public.manager_emergency_authorization_requests
  add constraint manager_emergency_authorization_branch_fk
  foreign key (branch_id, restaurant_id)
  references public.restaurant_branches(id, restaurant_id)
  on delete restrict;

alter table public.manager_emergency_authorization_notifications
  drop constraint if exists manager_emergency_authorization_notifications_branch_fk;
alter table public.manager_emergency_authorization_notifications
  add constraint manager_emergency_authorization_notifications_branch_fk
  foreign key (branch_id, restaurant_id)
  references public.restaurant_branches(id, restaurant_id)
  on delete restrict;
