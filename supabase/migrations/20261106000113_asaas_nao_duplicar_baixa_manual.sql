-- Boleto pago no Asaas e baixa dada à mão ANTES de o débito aparecer no extrato (06/11, alerta do Lucas):
-- a sincronização lançava de novo (duplicidade no saldo). Agora, antes de lançar uma linha do extrato,
-- procura lançamento feito À MÃO na conta do Asaas, mesmo sentido, de até 10 dias antes (ou 1 depois),
-- que nenhuma linha do extrato usa e que não foi excluído/estornado:
--   * mesmo valor: só concilia com ele;
--   * baixa de conta com valor menor (o Asaas cobrou juros/multa, até 25% a mais): concilia e lança só a
--     diferença como "Juros e multa" na categoria da conta.
-- Vem ANTES da baixa automática por valor (senão quitaria OUTRA conta de mesmo valor, ex.: a do mês seguinte).
create or replace function private.lancamento_manual_para(p_conta uuid, p_valor numeric, p_data date, p_doc text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_dif numeric(12,2);
begin
  select x.* into l from public.lancamentos x
  where x.conta_id = p_conta
    and x.tipo = case when p_valor > 0 then 'receita' else 'despesa' end
    and x.estorno_de is null
    and x.data between p_data - 10 and p_data + 1
    and (x.valor = abs(p_valor) or (x.titulo_id is not null and abs(p_valor) > x.valor and abs(p_valor) <= round(x.valor * 1.25, 2)))
    and coalesce(x.documento, '') !~ '^(pay|ftn|ft|fin)_'
    and x.descricao not like 'Asaas: %'
    and not exists (select 1 from public.lancamentos s where s.estorno_de = x.id)
    and not exists (select 1 from public.extrato_itens i where i.lancamento_id = x.id)
  order by (x.valor = abs(p_valor)) desc, abs(x.data - p_data), x.criado_em
  limit 1
  for update;
  if l.id is null then return null; end if;
  v_dif := abs(p_valor) - l.valor;
  if v_dif > 0 then
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                    irmao_id, favorecido_id, centro_custo_id, documento)
    values (l.loja_id, l.conta_id, l.categoria_id, l.tipo, v_dif, p_data, l.competencia,
            left('Juros e multa: ' || l.descricao, 250), l.irmao_id, l.favorecido_id, l.centro_custo_id, p_doc);
  end if;
  return l.id;
end $$;
revoke execute on function private.lancamento_manual_para from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.asaas_concluir_sincronizacao(p_loja uuid, p_saldo numeric, p_primeira boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  v_tarifa uuid;
  v_saida uuid;
  v_entrada uuid;
  e record;
  v_lanc uuid;
  v_lanc_manual boolean;
  v_tit uuid;
  n_saidas int := 0;
  n_entradas int := 0;
  n_baixas int := 0;
  n_ja_lancados int := 0;
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
    v_lanc_manual := false;
    -- 1º: já lançado à mão? (ex.: boleto pago no Asaas, Tesoureiro deu baixa antes de o débito aparecer)
    if not (e.valor < 0 and e.descricao ~* '(^|\s)(taxa|tarifa)') then
      v_lanc := private.lancamento_manual_para(v_conta, e.valor, e.data, e.id_externo);
      v_lanc_manual := v_lanc is not null;
      if v_lanc_manual then n_ja_lancados := n_ja_lancados + 1; end if;
    end if;
    -- taxa do Asaas nunca é conta cadastrada
    if v_lanc is null and not (e.valor < 0 and e.descricao ~* '(^|\s)(taxa|tarifa)') then
      v_tit := private.conta_unica_para(p_loja, e.valor, e.data);
      if v_tit is not null then
        v_lanc := private.quitar_titulo(v_tit, v_conta, e.data, abs(e.valor), e.id_externo);
        if v_lanc is not null then n_baixas := n_baixas + 1; end if;
      end if;
    end if;
    -- PIX direto na chave da Loja (sem cobrança, sem taxa) com o valor de uma contribuição ao Tronco aguardando
    if v_lanc is null and e.valor > 0 then
      v_lanc := private.tronco_por_extrato(p_loja, v_conta, e.valor, e.data, e.id_externo);
      if v_lanc is not null then n_entradas := n_entradas + 1; end if;
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
    set situacao = 'conciliado', lancamento_id = v_lanc,
        motivo = case when v_lanc_manual then 'já lançado à mão' else 'lançado automaticamente' end, conciliado_em = now()
    where id = e.id;
  end loop;

  if p_primeira and p_saldo is not null then
    -- o saldo real do Asaas já inclui as entradas do extrato que ainda esperam conciliação;
    -- elas vão virar lançamento depois, então contam aqui para não entrarem duas vezes no saldo
    select saldo into v_saldo_sistema from public.contas_saldo where conta_id = v_conta;
    v_saldo_sistema := coalesce(v_saldo_sistema, 0)
      + coalesce((select sum(valor) from public.extrato_itens where conta_id = v_conta and situacao = 'pendente'), 0);
    v_ajuste := p_saldo - v_saldo_sistema;
    if v_ajuste <> 0 then
      update public.contas_financeiras set saldo_inicial = saldo_inicial + v_ajuste where id = v_conta;
    end if;
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return jsonb_build_object('saidas_lancadas', n_saidas, 'entradas_lancadas', n_entradas, 'contas_baixadas', n_baixas, 'ja_lancados', n_ja_lancados,
                            'ajuste_saldo_inicial', v_ajuste,
                            'saldo_sistema', (select saldo from public.contas_saldo where conta_id = v_conta));
end $function$;
