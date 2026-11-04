-- Sistema Malhete: EXCLUIR lançamento (04/11/2026, pedido do Lucas: "tem que deixar apagar").
-- Nada some do banco: é um estorno com a MESMA data do original (o par se anula no próprio período e sai das
-- listas, do saldo e dos relatórios), motivo obrigatório e audit_log. Se estava conciliado com o extrato,
-- a linha do extrato volta a "pendente" para ser conciliada de novo.
create or replace function public.excluir_lancamento(p_lancamento uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig public.lancamentos;
  v_id uuid;
begin
  select * into v_orig from public.lancamentos where id = p_lancamento;
  if v_orig.id is null then raise exception 'Lançamento não encontrado'; end if;
  if not public.pode_lancar(v_orig.conta_id)
     or (v_orig.conta_destino_id is not null and not public.pode_lancar(v_orig.conta_destino_id)) then
    raise exception 'Sem permissão para excluir este lançamento';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo'; end if;
  if v_orig.estorno_de is not null then raise exception 'Este lançamento já é uma exclusão'; end if;
  if exists (select 1 from public.lancamentos where estorno_de = p_lancamento) then
    raise exception 'Lançamento já excluído';
  end if;

  update public.extrato_itens
  set situacao = 'pendente', lancamento_id = null, motivo = null, conciliado_por = null, conciliado_em = null
  where lancamento_id = p_lancamento;

  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia,
                                  descricao, irmao_id, favorecido_id, centro_custo_id, titulo_id, abatimento,
                                  estorno_de, motivo_estorno)
  values (v_orig.loja_id, v_orig.conta_id, v_orig.conta_destino_id, v_orig.categoria_id, v_orig.tipo, -v_orig.valor,
          v_orig.data, v_orig.competencia, 'Exclusão: ' || v_orig.descricao, v_orig.irmao_id, v_orig.favorecido_id,
          v_orig.centro_custo_id, v_orig.titulo_id, -v_orig.abatimento, v_orig.id, p_motivo)
  returning id into v_id;

  insert into public.audit_log (loja_id, tabela, registro_id, acao, depois)
  values (v_orig.loja_id, 'lancamentos', v_orig.id, 'exclusao', jsonb_build_object('motivo', p_motivo, 'estorno', v_id));
  return v_id;
end $$;
revoke execute on function public.excluir_lancamento from public, anon;
grant execute on function public.excluir_lancamento to authenticated;
