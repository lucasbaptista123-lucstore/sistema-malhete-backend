-- Sistema Malhete — o irmão cadastrado pela Secretaria (com e-mail) ganha acesso
-- ao criar a conta com o mesmo e-mail: o app chama vincular_por_email() no login.
-- Só vale para e-mail confirmado, para ninguém se passar por outro irmão.

create function public.vincular_por_email() returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_email text;
  n int;
begin
  select lower(email) into v_email
  from auth.users
  where id = auth.uid() and email_confirmed_at is not null;

  if v_email is null then
    return 0;
  end if;

  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos i
  set user_id = auth.uid()
  where i.user_id is null
    and lower(i.email) = v_email
    and i.situacao in ('ativo', 'licenciado', 'irregular')
    and not exists (select 1 from public.irmaos o where o.loja_id = i.loja_id and o.user_id = auth.uid());

  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $$;

create index on public.irmaos (lower(email)) where user_id is null;

-- A trava de campos vale para edição direta pela API; funções do sistema
-- ligam 'malhete.sistema' durante a própria atualização (o app não consegue ligar).
create or replace function public.proteger_campos_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  if auth.uid() is null
     or current_setting('malhete.sistema', true) = 'on'
     or public.tem_permissao(old.loja_id, 'cadastro.editar') then
    return new;
  end if;
  if new.loja_id is distinct from old.loja_id
     or new.user_id is distinct from old.user_id
     or new.admin_loja is distinct from old.admin_loja
     or new.cim is distinct from old.cim
     or new.grau is distinct from old.grau
     or new.mestre_instalado is distinct from old.mestre_instalado
     or new.data_iniciacao is distinct from old.data_iniciacao
     or new.data_elevacao is distinct from old.data_elevacao
     or new.data_exaltacao is distinct from old.data_exaltacao
     or new.situacao is distinct from old.situacao
     or new.observacoes is distinct from old.observacoes then
    raise exception 'Somente a Secretaria pode alterar esses campos do cadastro';
  end if;
  return new;
end $$;

revoke execute on function public.vincular_por_email from public, anon;
grant execute on function public.vincular_por_email to authenticated;
