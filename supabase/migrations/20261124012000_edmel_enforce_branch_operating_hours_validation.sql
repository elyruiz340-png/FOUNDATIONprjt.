-- Keep branch operating hours valid even if a future code path writes directly to the branch row.
ALTER TABLE public.restaurant_branches
  ADD CONSTRAINT restaurant_branches_operating_hours_valid
  CHECK (private.edmel_valid_branch_operating_hours(operating_hours));