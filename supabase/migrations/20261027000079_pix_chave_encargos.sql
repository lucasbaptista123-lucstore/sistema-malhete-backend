-- Sistema Malhete: PIX na chave reconhece também conta atrasada paga com multa e juros (valor atualizado do QR).
CREATE OR REPLACE FUNCTION private.pix_irmao(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_acum_enc numeric(12,2) := 0;
  v_comenc boolean := false;
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

  -- 2b) uma conta atrasada paga com multa e juros (o QR do irmão já mostra o valor atualizado)
  select id into v_tit from public.titulos
  where loja_id = p_loja and irmao_id = v_irmao and natureza = 'receber' and not cancelado and asaas_id is null
    and valor - valor_pago > 0
    and valor - valor_pago + private.encargos(p_loja, valor - valor_pago, vencimento) = v_valor
  order by vencimento limit 1;
  if v_tit is not null then
    v_ids := array[v_tit];
    v_comenc := true;
  else
    -- 3) soma das contas abertas mais antigas fecha com o valor (sem ou com encargos)
    for t in select id, valor - valor_pago as saldo, private.encargos(p_loja, valor - valor_pago, vencimento) as enc
             from public.titulos
             where loja_id = p_loja and irmao_id = v_irmao and natureza = 'receber' and not cancelado and asaas_id is null
               and valor - valor_pago > 0
             order by vencimento, parcela
    loop
      v_acum := v_acum + t.saldo;
      v_acum_enc := v_acum_enc + t.saldo + t.enc;
      v_ids := v_ids || t.id;
      exit when v_acum >= v_valor or v_acum_enc = v_valor;
    end loop;
    if v_acum_enc = v_valor and v_acum <> v_valor then v_comenc := true;
    elsif v_acum <> v_valor or array_length(v_ids, 1) is null then return null;
    end if;
  end if;
  perform set_config('malhete.sistema', 'on', true);
  for t in select id, valor - valor_pago as saldo, vencimento from public.titulos where id = any (v_ids) loop
    perform private.quitar_titulo(t.id, v_conta, v_data,
      t.saldo + case when v_comenc then private.encargos(p_loja, t.saldo, t.vencimento) else 0 end, v_pid);
  end loop;
  if v_liquido < v_valor then
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
    values (p_loja, v_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
            'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas: PIX recebido', v_pid);
  end if;
  perform set_config('malhete.sistema', 'off', true);
  perform private.auto_conciliar(v_conta, v_pid);
  return format('baixa de %s contas por PIX na chave', array_length(v_ids, 1));
end $function$;
