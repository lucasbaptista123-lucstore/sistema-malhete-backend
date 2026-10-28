-- Sistema Malhete: o irmão QUITA DE UMA VEZ as parcelas em aberto de uma cobrança parcelada (captação etc.),
-- ou paga à vista desde o início. As parcelas abertas (sem nenhum pagamento) viram uma conta só, com o total e
-- vencimento hoje; as parcelas são canceladas. Devolve os ids do Asaas das parcelas canceladas, para a função
-- do Asaas apagar as cobranças lá.
create function public.quitar_parcelas(p_grupo uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_eu uuid;
  t public.titulos;
  v_total numeric(12,2);
  v_qtd int;
  v_asaas text[];
  v_novo uuid;
begin
  select * into t from public.titulos where grupo_id = p_grupo order by parcela limit 1;
  if t.id is null then raise exception 'Cobrança não encontrada'; end if;
  v_eu := public.meu_irmao_id(t.loja_id);
  if v_eu is null or t.irmao_id is distinct from v_eu then raise exception 'Esta cobrança não é sua'; end if;
  select coalesce(sum(valor), 0), count(*), array_agg(asaas_id) filter (where asaas_id is not null)
    into v_total, v_qtd, v_asaas
  from public.titulos
  where grupo_id = p_grupo and irmao_id = v_eu and natureza = 'receber' and not cancelado and valor_pago = 0;
  if v_qtd < 2 then raise exception 'Não há parcelas em aberto para juntar'; end if;

  perform set_config('malhete.sistema', 'on', true);
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, centro_custo_id, irmao_id, valor, vencimento, competencia, observacoes)
  values (t.loja_id, 'receber',
          regexp_replace(t.descricao, '\s*\(\d+/\d+\)\s*$', '') || format(' (quitação de %s parcelas)', v_qtd),
          t.categoria_id, t.centro_custo_id, v_eu, v_total, current_date, current_date,
          'Parcelas juntadas pelo próprio irmão para pagar de uma vez')
  returning id into v_novo;
  update public.titulos set cancelado = true, motivo_cancelamento = 'Quitada de uma vez pelo irmão'
  where grupo_id = p_grupo and irmao_id = v_eu and natureza = 'receber' and not cancelado and valor_pago = 0;
  perform set_config('malhete.sistema', 'off', true);
  return jsonb_build_object('titulo', v_novo, 'total', v_total, 'parcelas', v_qtd, 'asaas_ids', coalesce(to_jsonb(v_asaas), '[]'::jsonb));
end $$;
revoke execute on function public.quitar_parcelas from public, anon;
grant execute on function public.quitar_parcelas to authenticated;
