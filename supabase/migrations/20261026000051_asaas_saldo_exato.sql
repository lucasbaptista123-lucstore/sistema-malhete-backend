-- Sistema Malhete — Asaas com saldo exato e sem avisos indevidos.
-- (1) Toda saída do extrato do Asaas vira lançamento sozinha: taxas → Tarifas bancárias; o resto → "Saída a
--     classificar (Asaas)" (já desconta do saldo; o Tesoureiro só troca a categoria depois). Entradas avulsas
--     (sem cobrança) → "Entrada a classificar (Asaas)".
-- (2) Na primeira sincronização, o saldo inicial da conta Asaas é ajustado para o saldo real do Asaas.
-- (3) Pagamento ANTERIOR à conexão (histórico trazido do Asaas) não gera aviso a ninguém.

-- ---- (3) avisos: interruptor por transação
create or replace function private.notificar(p_loja uuid, p_irmao uuid, p_tipo text, p_ref uuid, p_msg text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  c public.avisos_config;
  v_tel text;
begin
  if current_setting('malhete.sem_avisos', true) = 'on' then return; end if;
  select * into c from public.avisos_config where loja_id = p_loja;
  if c.loja_id is not null and not (case p_tipo
      when 'cobranca' then c.cobranca when 'debito' then c.debitos when 'baixa' then c.baixa else c.trabalhos end) then
    return;
  end if;
  select nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_tel from public.irmaos where id = p_irmao and situacao in ('ativo', 'licenciado');
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  values (p_loja, p_irmao, p_tipo, p_ref, p_msg, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
end $$;

alter function public.asaas_espelhar_pagamento(uuid, text, jsonb, jsonb) rename to asaas_espelhar_base;
alter function public.asaas_espelhar_base(uuid, text, jsonb, jsonb) set schema private;

create function public.asaas_espelhar_pagamento(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_conectado date := (select criado_em::date from public.integracoes_asaas where loja_id = p_loja);
  v_quando date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date,
                            nullif(p_pg->>'dateCreated', '')::date, current_date);
  v_res text;
begin
  -- histórico (antes da conexão): espelha em silêncio
  if v_conectado is not null and v_quando < v_conectado then
    perform set_config('malhete.sem_avisos', 'on', true);
  end if;
  v_res := private.asaas_espelhar_base(p_loja, p_evento, p_pg, p_cliente);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_res;
end $$;

-- ---- (1) e (2)
create function private.categoria_asaas(p_loja uuid, p_codigo text, p_nome text, p_tipo text, p_grupo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v uuid;
begin
  select id into v from public.categorias_financeiras where loja_id = p_loja and codigo = p_codigo;
  if v is null then
    insert into public.categorias_financeiras (loja_id, codigo, nome, tipo, grupo)
    values (p_loja, p_codigo, p_nome, p_tipo, p_grupo)
    on conflict do nothing
    returning id into v;
    if v is null then select id into v from public.categorias_financeiras where loja_id = p_loja and codigo = p_codigo; end if;
  end if;
  return v;
end $$;

create function public.asaas_concluir_sincronizacao(p_loja uuid, p_saldo numeric, p_primeira boolean)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  v_tarifa uuid;
  v_saida uuid;
  v_entrada uuid;
  e record;
  v_lanc uuid;
  n_saidas int := 0;
  n_entradas int := 0;
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
      and (valor < 0 or referencia_externa is null)   -- entrada com cobrança fica para a conciliação pela cobrança
    order by data, id
  loop
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
    values (p_loja, v_conta,
            case when e.valor > 0 then v_entrada
                 when e.descricao ~* '(^|\s)(taxa|tarifa)' then coalesce(v_tarifa, v_saida)
                 else v_saida end,
            case when e.valor > 0 then 'receita' else 'despesa' end,
            abs(e.valor), e.data, e.data, left('Asaas: ' || e.descricao, 250), e.id_externo)
    returning id into v_lanc;
    update public.extrato_itens
    set situacao = 'conciliado', lancamento_id = v_lanc, motivo = 'lançado automaticamente', conciliado_em = now()
    where id = e.id;
    if e.valor < 0 then n_saidas := n_saidas + 1; else n_entradas := n_entradas + 1; end if;
  end loop;

  -- primeira sincronização: o saldo da conta passa a ser o saldo real do Asaas
  if p_primeira and p_saldo is not null then
    select saldo into v_saldo_sistema from public.contas_saldo where conta_id = v_conta;
    v_ajuste := p_saldo - coalesce(v_saldo_sistema, 0);
    if v_ajuste <> 0 then
      update public.contas_financeiras set saldo_inicial = saldo_inicial + v_ajuste where id = v_conta;
    end if;
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return jsonb_build_object('saidas_lancadas', n_saidas, 'entradas_lancadas', n_entradas, 'ajuste_saldo_inicial', v_ajuste,
                            'saldo_sistema', (select saldo from public.contas_saldo where conta_id = v_conta));
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.asaas_espelhar_pagamento, public.asaas_concluir_sincronizacao from public, anon, authenticated;
grant execute on function public.asaas_espelhar_pagamento, public.asaas_concluir_sincronizacao to service_role;
