-- Sistema Malhete — o Tesoureiro pode TROCAR A CATEGORIA de um lançamento avulso (ex.: "Saída a classificar
-- (Asaas)" → Aluguel). Valor, data, conta e o resto continuam imutáveis; a troca fica na auditoria.

create or replace function public.validar_lancamento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_orig public.lancamentos;
  v_tit public.titulos;
  v_tipo text;
begin
  -- única alteração permitida: trocar a categoria (pela função reclassificar_lancamento)
  if tg_op = 'UPDATE' and current_setting('malhete.reclassificar', true) = 'on'
     and (to_jsonb(new) - 'categoria_id') = (to_jsonb(old) - 'categoria_id') then
    if new.categoria_id is not null and not exists (
         select 1 from public.categorias_financeiras where id = new.categoria_id and loja_id = new.loja_id and tipo = new.tipo) then
      raise exception 'Categoria não pertence à loja ou não é do tipo do lançamento';
    end if;
    return new;
  end if;
  if tg_op <> 'INSERT' then
    raise exception 'Lançamento não pode ser alterado nem apagado; use o estorno';
  end if;

  new.competencia := coalesce(new.competencia, new.data);

  if not exists (select 1 from public.contas_financeiras where id = new.conta_id and loja_id = new.loja_id)
     or (new.conta_destino_id is not null and not exists (
           select 1 from public.contas_financeiras where id = new.conta_destino_id and loja_id = new.loja_id)) then
    raise exception 'Conta não pertence à loja';
  end if;
  if new.categoria_id is not null and not exists (
       select 1 from public.categorias_financeiras
       where id = new.categoria_id and loja_id = new.loja_id and tipo = new.tipo) then
    raise exception 'Categoria não pertence à loja ou não é do tipo do lançamento';
  end if;
  if new.irmao_id is not null and not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Irmão não pertence à loja';
  end if;
  if new.favorecido_id is not null and not exists (select 1 from public.favorecidos where id = new.favorecido_id and loja_id = new.loja_id) then
    raise exception 'Fornecedor/cliente não pertence à loja';
  end if;
  if new.centro_custo_id is not null and not exists (select 1 from public.centros_custo where id = new.centro_custo_id and loja_id = new.loja_id) then
    raise exception 'Centro de custo não pertence à loja';
  end if;

  if new.estorno_de is not null then
    select * into v_orig from public.lancamentos where id = new.estorno_de;
    if v_orig.id is null or v_orig.estorno_de is not null
       or v_orig.loja_id <> new.loja_id or v_orig.conta_id <> new.conta_id
       or v_orig.conta_destino_id is distinct from new.conta_destino_id
       or v_orig.categoria_id is distinct from new.categoria_id
       or v_orig.titulo_id is distinct from new.titulo_id
       or v_orig.abatimento is distinct from -new.abatimento
       or v_orig.tipo <> new.tipo or new.valor <> -v_orig.valor then
      raise exception 'Estorno não confere com o lançamento original';
    end if;
  elsif new.titulo_id is not null then
    select * into v_tit from public.titulos where id = new.titulo_id;
    if v_tit.id is null or v_tit.loja_id <> new.loja_id or v_tit.cancelado then
      raise exception 'Título inválido ou cancelado';
    end if;
    v_tipo := case v_tit.natureza when 'receber' then 'receita' else 'despesa' end;
    if new.tipo <> v_tipo or new.categoria_id is distinct from v_tit.categoria_id then
      raise exception 'Baixa não confere com o título';
    end if;
    if new.abatimento <= 0 or new.abatimento > v_tit.valor - v_tit.valor_pago then
      raise exception 'Valor da baixa maior que o saldo do título';
    end if;
  end if;

  new.criado_por := auth.uid();
  new.criado_em := now();
  return new;
end $$;

create function public.reclassificar_lancamento(p_lancamento uuid, p_categoria uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão para alterar este lançamento'; end if;
  if l.titulo_id is not null then raise exception 'Baixa de conta: troque a categoria na própria conta a pagar/receber'; end if;
  if l.estorno_de is not null or exists (select 1 from public.lancamentos s where s.estorno_de = l.id) then
    raise exception 'Lançamento estornado não muda de categoria';
  end if;
  if l.tipo = 'transferencia' then raise exception 'Transferência não tem categoria'; end if;
  perform set_config('malhete.reclassificar', 'on', true);
  update public.lancamentos set categoria_id = p_categoria where id = l.id;
  perform set_config('malhete.reclassificar', 'off', true);
end $$;
revoke execute on function public.reclassificar_lancamento from public, anon;
grant execute on function public.reclassificar_lancamento to authenticated;
