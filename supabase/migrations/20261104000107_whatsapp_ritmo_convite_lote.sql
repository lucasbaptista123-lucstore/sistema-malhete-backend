-- Sistema Malhete: ritmo seguro do WhatsApp e convite em lote (04/11/2026, pedido do Lucas: "não pode disparar tudo
-- de uma vez, senão vai gerar ban"; ritmo pedido: uma a cada 30 s). A rotina passa a rodar a cada minuto e manda até 2
-- mensagens por Loja, com 30 a 45 s entre elas (na função whatsapp); nunca menos de 25 s desde a última enviada e no
-- máximo 60 por dia; o que sobra sai nos dias seguintes. Convite em lote só põe na fila.
create or replace function public.notificacoes_proximas(p_por_loja integer default 2)
returns table (id uuid, loja_id uuid, telefone text, mensagem text, botoes text[])
language plpgsql security definer set search_path = '' as $$
begin
  update public.notificacoes set status = 'descartado', erro = 'WhatsApp desconectado por mais de 3 dias'
  where status = 'pendente' and criado_em < now() - interval '3 days'
    and not exists (select 1 from public.integracoes_whatsapp w where w.loja_id = notificacoes.loja_id and w.status = 'conectado');
  return query
  select x.id, x.loja_id, x.telefone, x.mensagem, x.botoes from (
    select n.*, row_number() over (partition by n.loja_id order by n.criado_em) as k
    from public.notificacoes n
    join public.integracoes_whatsapp w on w.loja_id = n.loja_id and w.status = 'conectado'
    where n.status = 'pendente'
      and not exists (select 1 from public.notificacoes e where e.loja_id = n.loja_id and e.status = 'enviado'
                      and e.enviado_em > now() - interval '25 seconds')
      and (select count(*) from public.notificacoes e where e.loja_id = n.loja_id and e.status = 'enviado'
           and e.enviado_em > now() - interval '24 hours') < 60
  ) x where x.k <= least(greatest(p_por_loja, 1), 2);
end $$;
revoke execute on function public.notificacoes_proximas from public, anon, authenticated;
grant execute on function public.notificacoes_proximas to service_role;

-- Convidar todos os irmãos ativos/licenciados sem acesso e sem convite válido (só põe na fila; sai no ritmo acima).
create or replace function public.convidar_todos(p_loja uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n_fila int := 0;
  n_sem int := 0;
begin
  if not public.tem_permissao(p_loja, 'cadastro.editar') then raise exception 'Sem permissão'; end if;
  for r in
    select i.id, nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') as tel
    from public.irmaos i
    where i.loja_id = p_loja and i.user_id is null and i.situacao in ('ativo', 'licenciado')
      and not exists (select 1 from public.convites c where c.irmao_id = i.id and c.usado_em is null and c.expira_em > now())
    order by i.nome
  loop
    if r.tel is null then n_sem := n_sem + 1; continue; end if;
    perform public.convidar_irmao(r.id, true);
    n_fila := n_fila + 1;
  end loop;
  return jsonb_build_object('na_fila', n_fila, 'sem_telefone', n_sem);
end $$;
revoke execute on function public.convidar_todos from public, anon;
grant execute on function public.convidar_todos to authenticated;

select cron.alter_job((select jobid from cron.job where jobname = 'malhete-whatsapp-fila'), schedule := '* * * * *');
