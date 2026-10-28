-- Sistema Malhete — Tesouraria: situação de cada irmão nas mensalidades (em dia / em atraso), com a grade dos
-- 12 meses do ano, e envio de aviso pelo WhatsApp para os selecionados (com nome, valor e links de pagamento).

create function public.situacao_mensalidades(p_loja uuid, p_ano int)
returns table (
  irmao_id uuid, nome text, grau smallint, situacao_irmao public.situacao_irmao, tem_telefone boolean,
  total_aberto numeric, total_atrasado numeric, meses_atrasados int, atrasado_desde date,
  ultimo_pagamento date, meses text[]
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.tem_permissao(p_loja, 'tesouraria.ler') then raise exception 'Sem permissão'; end if;
  return query
  with mens as (
    select t.*, (t.valor - t.valor_pago) as saldo
    from public.titulos t
    where t.loja_id = p_loja and t.origem = 'mensalidade' and not t.cancelado
  )
  select i.id, i.nome, i.grau, i.situacao,
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is not null,
         coalesce((select sum(m.saldo) from mens m where m.irmao_id = i.id and m.saldo > 0), 0),
         coalesce((select sum(m.saldo) from mens m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date), 0),
         (select count(*)::int from mens m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date),
         (select min(m.vencimento) from mens m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date),
         (select max(l.data) from public.lancamentos l join mens m on m.id = l.titulo_id where m.irmao_id = i.id and l.valor > 0),
         array(
           select coalesce((
             select case when m.saldo <= 0 then 'pago'
                         when m.vencimento < current_date then 'atrasado'
                         else 'aberto' end
             from mens m
             where m.irmao_id = i.id and m.competencia = make_date(p_ano, mes, 1)
             limit 1), 'nenhum')
           from generate_series(1, 12) mes
         )
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado', 'irregular')
  order by i.nome;
end $$;

-- Aviso pelo WhatsApp aos irmãos escolhidos. {nome}, {valor} (em aberto) e {meses} (em atraso) no texto;
-- os links de pagamento do Asaas, quando houver, vão no fim.
create function public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_txt text;
  v_links text;
  v_tel text;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro envia avisos de mensalidade'; end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;
  for r in
    select i.id, i.nome, i.telefone,
           coalesce(sum(t.valor - t.valor_pago) filter (where t.valor_pago < t.valor), 0) as aberto,
           count(*) filter (where t.valor_pago < t.valor and t.vencimento < current_date) as atrasados,
           string_agg(t.descricao || ': ' || t.asaas_link, E'\n' order by t.vencimento)
             filter (where t.valor_pago < t.valor and t.asaas_link is not null) as links
    from public.irmaos i
    left join public.titulos t on t.irmao_id = i.id and t.loja_id = p_loja and t.origem = 'mensalidade' and not t.cancelado
    where i.loja_id = p_loja and i.id = any (p_irmaos)
    group by i.id, i.nome, i.telefone
  loop
    v_txt := replace(replace(replace(trim(p_mensagem),
               '{nome}', private.primeiro_nome(r.nome)),
               '{valor}', private.moeda(r.aberto)),
               '{meses}', r.atrasados::text);
    if r.links is not null then v_txt := v_txt || E'\n\nPara pagar:\n' || r.links; end if;
    v_tel := nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '');
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (p_loja, r.id, 'debito', null, v_txt, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.situacao_mensalidades, public.avisar_mensalidades from public, anon;
grant execute on function public.situacao_mensalidades, public.avisar_mensalidades to authenticated;
