-- Sistema Malhete: TRONCO SEM TAXA. O irmão paga pelo QR da chave PIX da Loja (não é cobrança, o Asaas não cobra
-- taxa). Ao gerar o QR, a contribuição fica "aguardando"; na sincronização com o Asaas, o PIX recebido sem cobrança
-- com o MESMO valor (gerado até 3 dias antes) é lançado sozinho no Tronco. Ambíguo (2+ iguais) fica para o Tesoureiro.

drop policy informa on public.tronco_contribuicoes;
create policy informa on public.tronco_contribuicoes for insert to authenticated
  with check (irmao_id = (select public.meu_irmao_id(loja_id)) and status in ('aguardando', 'informada')
              and decidido_por is null and lancamento_id is null);

create function public.tronco_ja_paguei(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.tronco_contribuicoes set status = 'informada', informado_em = now()
  where id = p_id and status = 'aguardando' and irmao_id = public.meu_irmao_id(loja_id);
  if not found then raise exception 'Contribuição não encontrada'; end if;
end $$;
revoke execute on function public.tronco_ja_paguei from public, anon;
grant execute on function public.tronco_ja_paguei to authenticated;

create function private.tronco_por_extrato(p_loja uuid, p_conta uuid, p_valor numeric, p_data date, p_doc text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  c public.tronco_contribuicoes;
  n int;
  v_lanc uuid;
  v_nome text;
begin
  select count(*) into n from public.tronco_contribuicoes
  where loja_id = p_loja and status in ('aguardando', 'informada') and origem = 'pix_chave' and valor = p_valor
    and informado_em::date between p_data - 3 and p_data;
  if n <> 1 then return null; end if;
  select * into c from public.tronco_contribuicoes
  where loja_id = p_loja and status in ('aguardando', 'informada') and origem = 'pix_chave' and valor = p_valor
    and informado_em::date between p_data - 3 and p_data
  for update;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento, irmao_id)
  values (p_loja, p_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tronco'),
          'receita', p_valor, p_data, p_data, 'Tronco de Beneficência (PIX)', p_doc, c.irmao_id)
  returning id into v_lanc;
  update public.tronco_contribuicoes set status = 'confirmada', decidido_em = now(), lancamento_id = v_lanc where id = c.id;
  select nome into v_nome from public.irmaos where id = c.irmao_id;
  perform private.notificar(p_loja, c.irmao_id, 'baixa', c.id,
    format('Olá, %s! Recebemos sua contribuição de %s ao Tronco de Beneficência. Obrigado.', private.primeiro_nome(v_nome), private.moeda(p_valor)));
  return v_lanc;
end $$;
revoke execute on function private.tronco_por_extrato from public, anon, authenticated;

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
end $function$;
