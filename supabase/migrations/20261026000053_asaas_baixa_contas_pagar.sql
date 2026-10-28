-- Sistema Malhete — saída do Asaas que é pagamento de uma conta cadastrada (ex.: aluguel pago por PIX no app do
-- Asaas): o sistema reconhece e dá BAIXA na conta, em vez de lançar "a classificar".
--   • automático: exatamente UMA conta em aberto da natureza certa, com o mesmo valor e vencimento até 10 dias
--     antes/depois da data do PIX → baixa nela (entrada sem cobrança faz o mesmo com conta a receber);
--   • senão vai como "a classificar" e o Tesoureiro vincula depois com um clique ("É esta conta"), que
--     transforma aquela saída na baixa (estorna o avulso e baixa a conta, mesmo valor, data e conta).

-- conta candidata única (null se nenhuma ou mais de uma)
create function private.conta_unica_para(p_loja uuid, p_valor numeric, p_data date) returns uuid
language sql stable security definer set search_path = '' as $$
  select case when count(*) = 1 then min(t.id::text)::uuid end
  from public.titulos t
  where t.loja_id = p_loja and not t.cancelado
    and t.natureza = case when p_valor > 0 then 'receber' else 'pagar' end
    and t.valor - t.valor_pago = abs(p_valor)
    and abs(t.vencimento - p_data) <= 10
$$;

create or replace function public.asaas_concluir_sincronizacao(p_loja uuid, p_saldo numeric, p_primeira boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  v_tarifa uuid;
  v_saida uuid;
  v_entrada uuid;
  e record;
  v_lanc uuid;
  v_tit uuid;
  n_saidas int := 0;
  n_entradas int := 0;
  n_baixas int := 0;
  v_ajuste numeric := 0;
  v_saldo_sistema numeric;
begin
  if v_conta is null then raise exception 'Integração inativa'; end if;
  perform set_config('malhete.sem_avisos', 'on', true);
  v_tarifa := (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas');
  v_saida := private.categoria_asaas(p_loja, 'saida_asaas', 'Saída a classificar (Asaas)', 'despesa', 'outras_despesas');
  v_entrada := private.categoria_asaas(p_loja, 'entrada_asaas', 'Entrada a classificar (Asaas)', 'receita', 'outras_receitas');

  for e in
    select * from public.extrato_itens
    where conta_id = v_conta and situacao = 'pendente'
      and (valor < 0 or referencia_externa is null)
    order by data, id
  loop
    v_lanc := null;
    -- taxa do Asaas nunca é conta cadastrada
    if not (e.valor < 0 and e.descricao ~* '(^|\s)(taxa|tarifa)') then
      v_tit := private.conta_unica_para(p_loja, e.valor, e.data);
      if v_tit is not null then
        v_lanc := private.quitar_titulo(v_tit, v_conta, e.data, abs(e.valor), e.id_externo);
        if v_lanc is not null then n_baixas := n_baixas + 1; end if;
      end if;
    end if;
    if v_lanc is null then
      insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
      values (p_loja, v_conta,
              case when e.valor > 0 then v_entrada
                   when e.descricao ~* '(^|\s)(taxa|tarifa)' then coalesce(v_tarifa, v_saida)
                   else v_saida end,
              case when e.valor > 0 then 'receita' else 'despesa' end,
              abs(e.valor), e.data, e.data, left('Asaas: ' || e.descricao, 250), e.id_externo)
      returning id into v_lanc;
      if e.valor < 0 then n_saidas := n_saidas + 1; else n_entradas := n_entradas + 1; end if;
    end if;
    update public.extrato_itens
    set situacao = 'conciliado', lancamento_id = v_lanc, motivo = 'lançado automaticamente', conciliado_em = now()
    where id = e.id;
  end loop;

  if p_primeira and p_saldo is not null then
    select saldo into v_saldo_sistema from public.contas_saldo where conta_id = v_conta;
    v_ajuste := p_saldo - coalesce(v_saldo_sistema, 0);
    if v_ajuste <> 0 then
      update public.contas_financeiras set saldo_inicial = saldo_inicial + v_ajuste where id = v_conta;
    end if;
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return jsonb_build_object('saidas_lancadas', n_saidas, 'entradas_lancadas', n_entradas, 'contas_baixadas', n_baixas,
                            'ajuste_saldo_inicial', v_ajuste,
                            'saldo_sistema', (select saldo from public.contas_saldo where conta_id = v_conta));
end $$;

-- sugestões de conta para um lançamento avulso (saída → contas a pagar; entrada → contas a receber)
create function public.sugestoes_para_lancamento(p_lancamento uuid)
returns table (titulo_id uuid, descricao text, vencimento date, saldo numeric, pessoa text, exato boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  l public.lancamentos;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão'; end if;
  return query
  select t.id, t.descricao, t.vencimento, t.valor - t.valor_pago,
         coalesce(i.nome, f.nome), (t.valor - t.valor_pago) = l.valor
  from public.titulos t
  left join public.irmaos i on i.id = t.irmao_id
  left join public.favorecidos f on f.id = t.favorecido_id
  where t.loja_id = l.loja_id and not t.cancelado and t.valor_pago < t.valor
    and t.natureza = case when l.tipo = 'receita' then 'receber' else 'pagar' end
    and abs(t.vencimento - l.data) <= 45
  order by ((t.valor - t.valor_pago) = l.valor) desc, abs((t.valor - t.valor_pago) - l.valor), abs(t.vencimento - l.data)
  limit 8;
end $$;

-- "É esta conta": a saída/entrada avulsa vira a baixa da conta (diferença a maior = juros; a menor = baixa parcial)
create function public.vincular_lancamento_titulo(p_lancamento uuid, p_titulo uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  t public.titulos;
  v_saldo numeric(12,2);
  v_abat numeric(12,2);
  v_novo uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento for update;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão para alterar este lançamento'; end if;
  if l.titulo_id is not null or l.estorno_de is not null or l.tipo = 'transferencia'
     or exists (select 1 from public.lancamentos s where s.estorno_de = l.id) then
    raise exception 'Só um lançamento avulso (sem conta vinculada) pode ser vinculado';
  end if;
  select * into t from public.titulos where id = p_titulo for update;
  if t.id is null or t.loja_id <> l.loja_id or t.cancelado then raise exception 'Conta inválida'; end if;
  if (l.tipo = 'receita') <> (t.natureza = 'receber') then raise exception 'Saída só quita conta a pagar; entrada, conta a receber'; end if;
  v_saldo := t.valor - t.valor_pago;
  if v_saldo <= 0 then raise exception 'Esta conta já está quitada'; end if;
  v_abat := least(l.valor, v_saldo);

  perform set_config('malhete.sem_avisos', 'on', true);
  -- tira o avulso (estorno idêntico) …
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, estorno_de, motivo_estorno)
  values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, l.data, l.competencia,
          'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.documento, l.id,
          'Vinculado à conta: ' || t.descricao);
  -- … e lança a baixa da conta com o mesmo valor, data e conta
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento)
  values (l.loja_id, l.conta_id, t.categoria_id, l.tipo, l.valor, l.data, t.competencia, t.descricao,
          t.irmao_id, t.favorecido_id, t.centro_custo_id, l.documento, t.id, v_abat)
  returning id into v_novo;
  -- a linha do extrato passa a apontar para a baixa
  update public.extrato_itens set lancamento_id = v_novo, motivo = 'vinculado à conta' where lancamento_id = l.id;
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_novo;
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.asaas_concluir_sincronizacao from public, anon, authenticated;
grant execute on function public.asaas_concluir_sincronizacao to service_role;
revoke execute on function public.sugestoes_para_lancamento, public.vincular_lancamento_titulo from public, anon;
grant execute on function public.sugestoes_para_lancamento, public.vincular_lancamento_titulo to authenticated;
