-- Sistema Malhete: PIX DIRETO NA CHAVE da Loja (o Asaas transforma em "cobrança gerada automaticamente a partir de
-- Pix recebido", com o CPF de quem pagou). Se quem pagou é irmão (CPF ou cliente Asaas), o sistema:
--   1) Tronco: contribuição aguardando/informada do irmão com o mesmo valor (até 3 dias) -> lança no Tronco;
--   2) uma conta aberta do irmão com exatamente esse saldo -> vincula e dá baixa (fluxo normal do Asaas);
--   3) a soma das contas abertas mais antigas fecha com o valor ("pagar tudo") -> baixa em todas;
--   senão segue o fluxo antigo (conta nova espelhada). Sem cobrança gerada pelo sistema = sem taxa do Asaas.

create function private.pix_irmao(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_pid text := p_pg->>'id';
  v_valor numeric(12,2) := (p_pg->>'value')::numeric;
  v_liquido numeric(12,2) := coalesce(nullif(p_pg->>'netValue', '')::numeric, (p_pg->>'value')::numeric);
  v_data date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date, current_date);
  v_doc text := nullif(regexp_replace(coalesce(p_cliente->>'cpfCnpj', ''), '\D', '', 'g'), '');
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  v_irmao uuid;
  v_contrib uuid;
  v_tit uuid;
  v_acum numeric(12,2) := 0;
  v_ids uuid[] := '{}';
  t record;
  n int;
begin
  if v_pid is null or v_conta is null or v_valor is null or v_valor <= 0 then return null; end if;
  if not (p_evento in ('PAYMENT_RECEIVED', 'PAYMENT_CONFIRMED', 'PAYMENT_RECEIVED_IN_CASH')
          or (p_evento = 'VARREDURA' and p_pg->>'status' in ('RECEIVED', 'CONFIRMED', 'RECEIVED_IN_CASH'))) then
    return null;
  end if;
  -- cobrança feita pelo sistema (referência de título ou do Tronco) segue o fluxo normal
  if coalesce(p_pg->>'externalReference', '') <> '' then return null; end if;
  if exists (select 1 from public.titulos where loja_id = p_loja and asaas_id = v_pid) then return null; end if;
  -- já tratado (varredura repetida)
  if exists (select 1 from public.lancamentos where loja_id = p_loja and documento = v_pid) then return 'já lançado'; end if;

  select i.id into v_irmao from public.irmaos i
  where i.loja_id = p_loja and ((v_doc is not null and i.cpf = v_doc) or i.asaas_cliente_id = p_cliente->>'id')
  order by (i.situacao = 'ativo') desc limit 1;
  if v_irmao is null then return null; end if;

  -- 1) Tronco
  select count(*) into n from public.tronco_contribuicoes
  where loja_id = p_loja and irmao_id = v_irmao and status in ('aguardando', 'informada') and origem = 'pix_chave'
    and valor = v_valor and informado_em::date between v_data - 3 and v_data;
  if n = 1 then
    select id into v_contrib from public.tronco_contribuicoes
    where loja_id = p_loja and irmao_id = v_irmao and status in ('aguardando', 'informada') and origem = 'pix_chave'
      and valor = v_valor and informado_em::date between v_data - 3 and v_data;
    return private.tronco_asaas(p_loja, 'PAYMENT_RECEIVED', p_pg || jsonb_build_object('externalReference', 'tronco:' || v_contrib));
  end if;

  -- 2) uma conta aberta com exatamente esse saldo (a mais antiga): vincula e deixa o fluxo normal dar baixa
  select id into v_tit from public.titulos
  where loja_id = p_loja and irmao_id = v_irmao and natureza = 'receber' and not cancelado and asaas_id is null
    and valor - valor_pago = v_valor
  order by vencimento limit 1;
  if v_tit is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set asaas_id = v_pid where id = v_tit;
    return null;   -- o espelhamento normal encontra o título pelo asaas_id e dá baixa (com tarifa, se houver)
  end if;

  -- 3) soma das contas abertas mais antigas fecha com o valor
  for t in select id, valor - valor_pago as saldo from public.titulos
           where loja_id = p_loja and irmao_id = v_irmao and natureza = 'receber' and not cancelado and asaas_id is null
             and valor - valor_pago > 0
           order by vencimento, parcela
  loop
    v_acum := v_acum + t.saldo;
    v_ids := v_ids || t.id;
    exit when v_acum >= v_valor;
  end loop;
  if v_acum <> v_valor or array_length(v_ids, 1) is null then return null; end if;
  perform set_config('malhete.sistema', 'on', true);
  for t in select id, valor - valor_pago as saldo from public.titulos where id = any (v_ids) loop
    perform private.quitar_titulo(t.id, v_conta, v_data, t.saldo, v_pid);
  end loop;
  if v_liquido < v_valor then
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
    values (p_loja, v_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
            'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas: PIX recebido', v_pid);
  end if;
  perform set_config('malhete.sistema', 'off', true);
  perform private.auto_conciliar(v_conta, v_pid);
  return format('baixa de %s contas por PIX na chave', array_length(v_ids, 1));
end $$;
revoke execute on function private.pix_irmao from public, anon, authenticated;

CREATE OR REPLACE FUNCTION private.auto_conciliar(p_conta uuid, p_ref text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  e record;
  v_lanc uuid;
  n int := 0;
begin
  for e in select * from public.extrato_itens
           where conta_id = p_conta and situacao = 'pendente' and referencia_externa = p_ref
           order by data, id
  loop
    select l.id into v_lanc
    from public.lancamentos l
    where l.documento = p_ref and (l.conta_id = p_conta or l.conta_destino_id = p_conta)
      and l.estorno_de is null and public.efeito_na_conta(l, p_conta) = e.valor
      and not exists (select 1 from public.extrato_itens x where x.lancamento_id = l.id)
      and not exists (select 1 from public.lancamentos s where s.estorno_de = l.id)
    order by l.criado_em
    limit 1;
    -- um PIX que pagou várias contas: a soma dos lançamentos com o mesmo documento fecha com a linha do extrato
    if v_lanc is null and (select sum(public.efeito_na_conta(l, p_conta)) from public.lancamentos l
                           where l.documento = p_ref and l.conta_id = p_conta and l.estorno_de is null and l.titulo_id is not null
                             and not exists (select 1 from public.lancamentos s where s.estorno_de = l.id)) = e.valor then
      select l.id into v_lanc from public.lancamentos l
      where l.documento = p_ref and l.conta_id = p_conta and l.estorno_de is null and l.titulo_id is not null
        and not exists (select 1 from public.extrato_itens x where x.lancamento_id = l.id)
      order by l.criado_em limit 1;
    end if;
    if v_lanc is not null then
      update public.extrato_itens
      set situacao = 'conciliado', lancamento_id = v_lanc, motivo = null, conciliado_por = null, conciliado_em = now()
      where id = e.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.asaas_espelhar_pagamento(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- PIX do Tronco gerado pelo sistema (externalReference tronco:<contribuição>)
  if coalesce(p_pg->>'externalReference', '') like 'tronco:%' then
    v_res := private.tronco_asaas(p_loja, p_evento, p_pg);
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  -- PIX direto na chave da Loja vindo de um irmão (CPF): Tronco ou baixa das contas abertas dele, sem cobrança e sem taxa
  v_res := private.pix_irmao(p_loja, p_evento, p_pg, p_cliente);
  if v_res is not null then
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  v_res := private.asaas_espelhar_base(p_loja, p_evento, p_pg, p_cliente);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_res;
end $function$;
