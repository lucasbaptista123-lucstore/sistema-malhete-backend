-- Painel Plataforma: tipos das colunas (uf é char(2)) e a data do registro de auditoria é a coluna "em" (0087 usava criado_em e o painel dava erro).
create or replace function public.plataforma_lojas()
returns table (
  loja_id uuid, nome text, numero text, cidade text, uf text, criada_em timestamptz,
  status text, plano text, teste_ate date, ciclo text, valor numeric, forma text, proximo_vencimento date,
  liberada boolean, bloqueio_manual boolean, liberada_ate date, faturas_abertas int, valor_aberto numeric,
  pago_total numeric, irmaos_ativos int, com_acesso int, whatsapp text, asaas boolean, ultima_atividade timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select l.id, trim(l.nome)::text, l.numero::text, l.cidade::text, l.uf::text, l.criado_em,
         a.status::text, a.plano::text, a.teste_ate, a.ciclo::text, a.valor::numeric, a.forma::text, a.proximo_vencimento,
         private.loja_liberada(l.id), a.bloqueio_manual, a.liberada_ate,
         (select count(*)::int from public.faturas_plataforma f where f.loja_id = l.id and f.status in ('pendente', 'vencida')),
         (select coalesce(sum(f.valor), 0) from public.faturas_plataforma f where f.loja_id = l.id and f.status in ('pendente', 'vencida')),
         (select coalesce(sum(f.valor), 0) from public.faturas_plataforma f where f.loja_id = l.id and f.status = 'paga'),
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.situacao = 'ativo'),
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.user_id is not null),
         coalesce((select w.status from public.integracoes_whatsapp w where w.loja_id = l.id), 'sem'),
         exists (select 1 from public.integracoes_asaas x where x.loja_id = l.id and x.ativo),
         (select max(g.em) from public.audit_log g where g.loja_id = l.id)
  from public.lojas l left join public.assinaturas a on a.loja_id = l.id
  order by l.criado_em desc;
end $$;
