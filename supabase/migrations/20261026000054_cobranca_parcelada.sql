-- Sistema Malhete — cobrança para irmãos em parcelas (ex.: captação de R$ 300 em 5x de R$ 60): cada irmão ganha
-- N contas a receber mensais (parcela 1/5, 2/5…), cada uma vira cobrança no Asaas. Centavos ficam na 1ª parcela.

drop function public.cobrar_irmaos(uuid, uuid[], text, uuid, numeric, date);
create function public.cobrar_irmaos(p_loja uuid, p_irmaos uuid[], p_descricao text, p_categoria uuid,
                                     p_valor numeric, p_vencimento date, p_parcelas int default 1)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int := 0;
  i record;
  k int;
  v_parc numeric(12,2);
  v_primeira numeric(12,2);
  v_grupo uuid;
  v_venc date;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro lança cobranças'; end if;
  if coalesce(trim(p_descricao), '') = '' then raise exception 'Informe a descrição'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor'; end if;
  if p_parcelas is null or p_parcelas < 1 or p_parcelas > 24 then raise exception 'Parcelas: de 1 a 24'; end if;
  if not exists (select 1 from public.categorias_financeiras where id = p_categoria and loja_id = p_loja and tipo = 'receita') then
    raise exception 'Escolha uma categoria de receita';
  end if;
  v_parc := trunc(p_valor / p_parcelas, 2);
  v_primeira := p_valor - v_parc * (p_parcelas - 1);
  for i in select id from public.irmaos
           where loja_id = p_loja and id = any (p_irmaos) and situacao in ('ativo', 'licenciado', 'irregular')
  loop
    v_grupo := gen_random_uuid();
    for k in 1..p_parcelas loop
      v_venc := (p_vencimento + make_interval(months => k - 1))::date;
      insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia,
                                  grupo_id, parcela, total_parcelas)
      values (p_loja, 'receber',
              trim(p_descricao) || case when p_parcelas > 1 then format(' (%s/%s)', k, p_parcelas) else '' end,
              p_categoria, i.id, case when k = 1 then v_primeira else v_parc end, v_venc,
              date_trunc('month', v_venc)::date, v_grupo, k, p_parcelas);
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function public.cobrar_irmaos from public, anon;
grant execute on function public.cobrar_irmaos to authenticated;
