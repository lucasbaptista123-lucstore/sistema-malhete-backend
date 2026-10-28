-- Sistema Malhete — só quem tem o cargo movimenta a Tesouraria.
-- 'tesouraria.editar' e 'tronco.editar' são exclusivas: o '*' (Venerável) não as inclui —
-- ele continua vendo tudo (.ler), mas não altera. O admin_loja (quem cadastrou a loja) só
-- as tem enquanto nenhum cargo vigente da loja tiver a permissão (para a loja começar a usar).

create or replace function public.tem_permissao(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  with exclusiva as (
    select p_perm in ('tesouraria.editar', 'tronco.editar') as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
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

-- O app usa esta lista para mostrar/esconder botões: '*' não cobre as exclusivas,
-- então elas vêm explícitas quando o usuário as tem.
create or replace function public.minhas_permissoes(p_loja uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  with base as (
    select case
      when bool_or(i.admin_loja) then array['*']
      else coalesce(array_agg(distinct p) filter (where p is not null), '{}')
    end as perms
    from public.irmaos i
    left join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
    left join public.loja_cargos c on c.id = m.cargo_id
    left join lateral unnest(c.permissoes) as p on true
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
  )
  select array(
    select distinct x from (
      select unnest(b.perms) as x from base b
      union all
      select e from unnest(array['tesouraria.editar', 'tronco.editar']) e where public.tem_permissao(p_loja, e)
    ) t
    where x <> '' and (x not in ('tesouraria.editar', 'tronco.editar') or public.tem_permissao(p_loja, x))
  )
$$;
