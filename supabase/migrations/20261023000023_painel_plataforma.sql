-- Sistema Malhete — painel do dono da plataforma (plataforma_admins).
-- Só números de uso e a assinatura de cada loja; nenhum dado interno (nomes, valores, atas).

create function public.eh_admin_plataforma() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.plataforma_admins where user_id = auth.uid())
$$;

create function public.plataforma_lojas()
returns table (
  loja_id uuid, nome text, numero text, cidade text, uf text, criada_em timestamptz,
  status text, plano text, teste_ate date,
  irmaos_ativos int, com_acesso int, whatsapp text, asaas boolean, ultima_atividade timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select l.id, trim(l.nome), l.numero, l.cidade, l.uf, l.criado_em,
         a.status, a.plano, a.teste_ate,
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.situacao = 'ativo'),
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.user_id is not null),
         coalesce((select w.status from public.integracoes_whatsapp w where w.loja_id = l.id), 'sem'),
         exists (select 1 from public.integracoes_asaas x where x.loja_id = l.id and x.ativo),
         (select max(g.em) from public.audit_log g where g.loja_id = l.id)
  from public.lojas l
  left join public.assinaturas a on a.loja_id = l.id
  order by l.criado_em desc;
end $$;

create function public.plataforma_assinatura(p_loja uuid, p_status text, p_plano text default null, p_teste_ate date default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  if p_status not in ('teste', 'ativa', 'atrasada', 'cancelada') then raise exception 'Situação inválida'; end if;
  update public.assinaturas
  set status = p_status, plano = coalesce(nullif(trim(p_plano), ''), plano), teste_ate = coalesce(p_teste_ate, teste_ate)
  where loja_id = p_loja;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, depois)
  values (p_loja, 'assinaturas', null, 'plataforma', jsonb_build_object('status', p_status, 'plano', p_plano, 'teste_ate', p_teste_ate));
end $$;

revoke execute on function public.eh_admin_plataforma, public.plataforma_lojas, public.plataforma_assinatura from public, anon;
grant execute on function public.eh_admin_plataforma, public.plataforma_lojas, public.plataforma_assinatura to authenticated;
