-- Sistema Malhete: apoio à função `convite` (conta criada pelo convite, sem e-mail de confirmação). Só service_role.
create or replace function public.convite_conta_existente(p_email text)
returns table (id uuid, confirmado boolean)
language sql security definer set search_path = '' stable as $$
  select u.id, u.email_confirmed_at is not null from auth.users u where lower(u.email) = lower(trim(p_email)) limit 1;
$$;
revoke execute on function public.convite_conta_existente from public, anon, authenticated;
grant execute on function public.convite_conta_existente to service_role;
