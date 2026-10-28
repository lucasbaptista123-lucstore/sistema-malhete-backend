-- Sistema Malhete — para o app montar o menu: permissões do usuário logado na loja,
-- numa chamada só. A segurança continua no RLS; isto só decide o que mostrar.

create function public.minhas_permissoes(p_loja uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select case
    when bool_or(i.admin_loja) then array['*']
    else coalesce(array_agg(distinct p) filter (where p is not null), '{}')
  end
  from public.irmaos i
  left join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
  left join public.loja_cargos c on c.id = m.cargo_id
  left join lateral unnest(c.permissoes) as p on true
  where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
$$;

revoke execute on function public.minhas_permissoes from public, anon;
grant execute on function public.minhas_permissoes to authenticated;
