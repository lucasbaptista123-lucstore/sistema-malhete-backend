-- Corrige plataforma_lojas(): uf é char(2) na tabela; a função devolve text.
create or replace function public.plataforma_lojas()
returns table (
  loja_id uuid, nome text, numero text, cidade text, uf text, criada_em timestamptz,
  status text, plano text, teste_ate date,
  irmaos_ativos int, com_acesso int, whatsapp text, asaas boolean, ultima_atividade timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select l.id, trim(l.nome), l.numero, l.cidade, l.uf::text, l.criado_em,
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
