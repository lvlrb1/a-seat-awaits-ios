-- Account deletion must remove every subscription record and Event Pass owned
-- by the deleted user. A BEFORE DELETE trigger on auth.users keeps this cleanup
-- in the same database transaction as Supabase Auth's admin.deleteUser call:
-- either the entitlements and account are all removed, or none of them are.

create or replace function public.cleanup_deleted_account_entitlements()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.event_passes
  where user_id = old.id;

  delete from public.subscriptions
  where user_id = old.id;

  return old;
end;
$$;

-- This function is trigger-only; clients must not be able to invoke it.
revoke all on function public.cleanup_deleted_account_entitlements()
  from public, anon, authenticated;

drop trigger if exists cleanup_deleted_account_entitlements on auth.users;

create trigger cleanup_deleted_account_entitlements
before delete on auth.users
for each row
execute function public.cleanup_deleted_account_entitlements();
