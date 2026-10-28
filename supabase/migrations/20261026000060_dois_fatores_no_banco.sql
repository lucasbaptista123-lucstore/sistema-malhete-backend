-- Sistema Malhete — login em duas etapas vale também no BANCO: quem ativou o código (TOTP verificado) e entrou
-- só com a senha (sessão aal1) não acessa nada da loja até digitar o código (aal2). Quem não ativou segue igual.
create function private.mfa_ok() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status = 'verified')
$$;
revoke execute on function private.mfa_ok from public, anon;
grant execute on function private.mfa_ok to authenticated;

create or replace function public.tem_permissao(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  with exclusiva as (
    select p_perm = any (public.permissoes_exclusivas()) as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo' and private.mfa_ok()
      and (
        (i.admin_loja and (
           not x.sim
           or not exists (
             select 1 from public.mandatos m2
             join public.loja_cargos c2 on c2.id = m2.cargo_id
             where m2.loja_id = p_loja and current_date between m2.inicio and m2.fim
               and p_perm = any (c2.permissoes))))
        or exists (
          select 1 from public.mandatos m
          join public.loja_cargos c on c.id = m.cargo_id
          where m.irmao_id = i.id
            and current_date between m.inicio and m.fim
            and (
              ('*' = any (c.permissoes) and not x.sim)
              or p_perm = any (c.permissoes)
              or (p_perm like '%.ler' and replace(p_perm, '.ler', '.editar') = any (c.permissoes))
            )
        )
      )
  )
$$;

create or replace function public.minhas_lojas() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select loja_id from public.irmaos
  where user_id = auth.uid() and situacao in ('ativo', 'licenciado', 'irregular') and private.mfa_ok()
$$;

create or replace function public.meu_irmao_id(p_loja uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.irmaos where loja_id = p_loja and user_id = auth.uid() and private.mfa_ok()
$$;
