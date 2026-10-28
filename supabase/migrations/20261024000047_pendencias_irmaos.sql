-- Sistema Malhete — além das mensalidades, o irmão pode ter outras pendências com a loja (captação/campanhas,
-- taxas do GOB, jóias, taxas de grau…). A situação do irmão passa a somar tudo o que ele deve; o aviso lista
-- cada pendência; e o Tesoureiro lança uma cobrança para vários irmãos de uma vez.

-- categorias de receita novas (lojas existentes e as que vierem)
create function private.categorias_irmaos(p_loja uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.categorias_financeiras (loja_id, codigo, nome, tipo, grupo)
  values (p_loja, 'captacao', 'Captação / campanhas', 'receita', 'doacoes'),
         (p_loja, 'taxas_gob', 'Taxas do GOB (cobradas dos irmãos)', 'receita', 'receitas_associativas')
  on conflict do nothing
$$;
select private.categorias_irmaos(id) from public.lojas;
create function public.categorias_irmaos_nova_loja() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.categorias_irmaos(new.id);
  return null;
end $$;
create trigger zz_categorias_irmaos after insert on public.lojas
for each row execute function public.categorias_irmaos_nova_loja();
revoke execute on function public.categorias_irmaos_nova_loja from public, anon, authenticated;

drop function public.situacao_mensalidades(uuid, int);
create function public.situacao_mensalidades(p_loja uuid, p_ano int)
returns table (
  irmao_id uuid, nome text, grau smallint, situacao_irmao public.situacao_irmao, tem_telefone boolean,
  total_aberto numeric, total_atrasado numeric, meses_atrasados int, atrasado_desde date,
  ultimo_pagamento date, meses text[],
  outros_aberto numeric, outros_atrasado numeric, outros_qtd int
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.tem_permissao(p_loja, 'tesouraria.ler') then raise exception 'Sem permissão'; end if;
  return query
  with tit as (
    select t.*, (t.valor - t.valor_pago) as saldo
    from public.titulos t
    where t.loja_id = p_loja and t.natureza = 'receber' and t.irmao_id is not null and not t.cancelado
  ), mens as (select * from tit where origem = 'mensalidade'),
     outros as (select * from tit where origem <> 'mensalidade')
  select i.id, i.nome, i.grau, i.situacao,
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is not null,
         coalesce((select sum(m.saldo) from mens m where m.irmao_id = i.id and m.saldo > 0), 0),
         coalesce((select sum(m.saldo) from mens m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date), 0),
         (select count(*)::int from mens m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date),
         (select min(m.vencimento) from tit m where m.irmao_id = i.id and m.saldo > 0 and m.vencimento < current_date),
         (select max(l.data) from public.lancamentos l join tit m on m.id = l.titulo_id where m.irmao_id = i.id and l.valor > 0),
         array(
           select coalesce((
             select case when m.saldo <= 0 then 'pago'
                         when m.vencimento < current_date then 'atrasado'
                         else 'aberto' end
             from mens m
             where m.irmao_id = i.id and m.competencia = make_date(p_ano, mes, 1)
             limit 1), 'nenhum')
           from generate_series(1, 12) mes
         ),
         coalesce((select sum(o.saldo) from outros o where o.irmao_id = i.id and o.saldo > 0), 0),
         coalesce((select sum(o.saldo) from outros o where o.irmao_id = i.id and o.saldo > 0 and o.vencimento < current_date), 0),
         (select count(*)::int from outros o where o.irmao_id = i.id and o.saldo > 0)
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado', 'irregular')
  order by i.nome;
end $$;

-- aviso: {valor} = tudo o que está em aberto; {meses} = mensalidades vencidas; a lista de pendências vai no fim
create or replace function public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_txt text;
  v_tel text;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro envia avisos de mensalidade'; end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;
  for r in
    select i.id, i.nome, i.telefone,
           coalesce(sum(t.valor - t.valor_pago) filter (where t.valor_pago < t.valor), 0) as aberto,
           count(*) filter (where t.valor_pago < t.valor and t.vencimento < current_date and t.origem = 'mensalidade') as atrasados,
           string_agg(format('• %s — %s%s%s', t.descricao, private.moeda(t.valor - t.valor_pago),
                             case when t.vencimento < current_date then ' (vencida em ' || to_char(t.vencimento, 'DD/MM') || ')'
                                  else ' (vence ' || to_char(t.vencimento, 'DD/MM') || ')' end,
                             coalesce(E'\n  ' || t.asaas_link, '')),
                      E'\n' order by t.vencimento) filter (where t.valor_pago < t.valor) as itens
    from public.irmaos i
    left join public.titulos t on t.irmao_id = i.id and t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado
    where i.loja_id = p_loja and i.id = any (p_irmaos)
    group by i.id, i.nome, i.telefone
  loop
    v_txt := replace(replace(replace(trim(p_mensagem),
               '{nome}', private.primeiro_nome(r.nome)),
               '{valor}', private.moeda(r.aberto)),
               '{meses}', r.atrasados::text);
    if r.itens is not null then v_txt := v_txt || E'\n\nPendências:\n' || r.itens; end if;
    v_tel := nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '');
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (p_loja, r.id, 'debito', null, v_txt, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
    n := n + 1;
  end loop;
  return n;
end $$;

-- cobrança para vários irmãos de uma vez (captação, taxa do GOB, jóia…): um título a receber para cada um
create function public.cobrar_irmaos(p_loja uuid, p_irmaos uuid[], p_descricao text, p_categoria uuid,
                                     p_valor numeric, p_vencimento date)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
  v_grupo uuid := gen_random_uuid();
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro lança cobranças'; end if;
  if coalesce(trim(p_descricao), '') = '' then raise exception 'Informe a descrição'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor'; end if;
  if not exists (select 1 from public.categorias_financeiras where id = p_categoria and loja_id = p_loja and tipo = 'receita') then
    raise exception 'Escolha uma categoria de receita';
  end if;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, grupo_id)
  select p_loja, 'receber', trim(p_descricao), p_categoria, i.id, p_valor, p_vencimento,
         date_trunc('month', p_vencimento)::date, v_grupo
  from public.irmaos i
  where i.loja_id = p_loja and i.id = any (p_irmaos) and i.situacao in ('ativo', 'licenciado', 'irregular');
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.situacao_mensalidades, public.cobrar_irmaos from public, anon;
grant execute on function public.situacao_mensalidades, public.cobrar_irmaos to authenticated;
