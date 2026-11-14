-- Sistema Malhete: SALDO DO TRONCO E AUXÍLIO PAGO PELO ASAAS (14/11). O Tronco que entra por PIX fica na conta do Asaas
-- (categoria Tronco) e o dinheiro do saco na conta "Tronco de Beneficência"; a tela de auxílios olhava só o saldo dessa
-- conta (ficou negativo) e "Pagar pelo Tronco" lançava a saída nela, mesmo quando o Tesoureiro tinha pago pelo app do
-- Asaas (a saída já entrava como "Saída a classificar"): o mesmo pagamento contava duas vezes.
--  1) tronco_saldo: o Tronco é um fundo = tudo o que entrou na categoria Tronco (qualquer conta) menos os auxílios
--     (categoria Beneficência). Estornos entram negativos.
--  2) decidir_auxilio ganha p_lancamento: "já paguei", usa a saída que já existe (ex.: PIX no Asaas) e só a classifica
--     como Beneficência; sem ela, lança na conta escolhida (padrão: a do Tronco), como antes.
--  3) auxilio_trocar_lancamento: auxílio já pago em duplicidade passa a usar a saída real e o lançamento próprio é excluído.

create function public.tronco_saldo(p_loja uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when public.tem_permissao(p_loja, 'tronco.editar') or public.tem_permissao(p_loja, 'tesouraria.ler') then
    jsonb_build_object(
      'entradas', coalesce(sum(x.valor) filter (where k.codigo = 'tronco' and x.tipo = 'receita'), 0),
      'auxilios', coalesce(sum(x.valor) filter (where k.codigo = 'beneficencia' and x.tipo = 'despesa'), 0),
      'saldo', coalesce(sum(x.valor) filter (where k.codigo = 'tronco' and x.tipo = 'receita'), 0)
             - coalesce(sum(x.valor) filter (where k.codigo = 'beneficencia' and x.tipo = 'despesa'), 0))
  end
  from public.lancamentos x join public.categorias_financeiras k on k.id = x.categoria_id
  where x.loja_id = p_loja and k.codigo in ('tronco', 'beneficencia')
$$;
revoke execute on function public.tronco_saldo from public, anon;
grant execute on function public.tronco_saldo to authenticated;

/** A saída (despesa) que já existe pode ser o pagamento deste auxílio? Mesmo valor, sem conta vinculada, não estornada. */
create function private.auxilio_saida_valida(p_auxilio public.auxilios, p_lancamento uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.lancamentos l
    where l.id = p_lancamento and l.loja_id = p_auxilio.loja_id and l.tipo = 'despesa' and l.valor = p_auxilio.valor
      and l.estorno_de is null and l.titulo_id is null
      and not exists (select 1 from public.lancamentos e where e.estorno_de = l.id)
      and not exists (select 1 from public.auxilios a where a.lancamento_id = l.id and a.id <> p_auxilio.id))
$$;
revoke execute on function private.auxilio_saida_valida from public, anon, authenticated;

/** Classifica a saída como Beneficência (só a categoria muda, pelo caminho do reclassificar). */
create function private.auxilio_classificar(p_loja uuid, p_lancamento uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('malhete.reclassificar', 'on', true);
  update public.lancamentos
  set categoria_id = (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'beneficencia')
  where id = p_lancamento;
  perform set_config('malhete.reclassificar', 'off', true);
end $$;
revoke execute on function private.auxilio_classificar from public, anon, authenticated;

drop function public.decidir_auxilio(uuid, boolean, uuid, date, text);
create function public.decidir_auxilio(p_auxilio uuid, p_pagar boolean, p_conta uuid default null,
  p_data date default current_date, p_observacao text default null, p_lancamento uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.auxilios;
  v_conta uuid;
  v_cat uuid;
  v_lanc uuid;
begin
  select * into a from public.auxilios where id = p_auxilio for update;
  if a.id is null or not public.tem_permissao(a.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro paga auxílios do Tronco'; end if;
  if a.status <> 'solicitado' then raise exception 'Este pedido já foi decidido'; end if;
  if p_pagar and p_lancamento is not null then
    -- já pago (ex.: PIX feito no app do Asaas): usa a saída que existe, sem lançar outra
    if not private.auxilio_saida_valida(a, p_lancamento) then
      raise exception 'Esta saída não serve: precisa ter o mesmo valor do auxílio e não estar ligada a outra conta';
    end if;
    if not public.pode_lancar((select conta_id from public.lancamentos where id = p_lancamento)) then
      raise exception 'Sem permissão nessa conta';
    end if;
    perform private.auxilio_classificar(a.loja_id, p_lancamento);
    v_lanc := p_lancamento;
  elsif p_pagar then
    v_conta := coalesce(p_conta, (select id from public.contas_financeiras where loja_id = a.loja_id and tipo = 'tronco' and ativa limit 1));
    if v_conta is null or not public.pode_lancar(v_conta) then raise exception 'Conta inválida para o pagamento'; end if;
    select id into v_cat from public.categorias_financeiras where loja_id = a.loja_id and codigo = 'beneficencia';
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao)
    values (a.loja_id, v_conta, v_cat, 'despesa', a.valor, coalesce(p_data, current_date),
            'Auxílio (Hospitalaria): ' || a.beneficiario)
    returning id into v_lanc;
  end if;
  update public.auxilios
  set status = case when p_pagar then 'pago' else 'recusado' end, decidido_por = auth.uid(), decidido_em = now(),
      observacao = nullif(trim(p_observacao), ''), lancamento_id = v_lanc
  where id = a.id;
  if a.assistido_id is not null and p_pagar then
    insert into public.assistidos_registros (loja_id, assistido_id, data, tipo, anotacao)
    values (a.loja_id, a.assistido_id, coalesce(p_data, current_date), 'auxilio',
            format('Auxílio de %s pago pelo Tronco: %s', private.moeda(a.valor), a.motivo));
  end if;
end $$;
revoke execute on function public.decidir_auxilio from public, anon;
grant execute on function public.decidir_auxilio to authenticated;

/** Auxílio já pago que contou duas vezes: passa a usar a saída real (ex.: PIX no Asaas) e exclui o lançamento próprio. */
create function public.auxilio_trocar_lancamento(p_auxilio uuid, p_lancamento uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.auxilios;
  v_antigo uuid;
begin
  select * into a from public.auxilios where id = p_auxilio for update;
  if a.id is null or not public.tem_permissao(a.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro mexe nos auxílios do Tronco'; end if;
  if a.status <> 'pago' then raise exception 'Só auxílio pago'; end if;
  if a.lancamento_id = p_lancamento then return; end if;
  if not private.auxilio_saida_valida(a, p_lancamento) then
    raise exception 'Esta saída não serve: precisa ter o mesmo valor do auxílio e não estar ligada a outra conta';
  end if;
  v_antigo := a.lancamento_id;
  perform private.auxilio_classificar(a.loja_id, p_lancamento);
  update public.auxilios set lancamento_id = p_lancamento where id = a.id;
  if v_antigo is not null and not exists (select 1 from public.lancamentos e where e.estorno_de = v_antigo) then
    perform public.excluir_lancamento(v_antigo, 'Auxílio pago pelo PIX do Asaas (lançado em duplicidade)');
  end if;
end $$;
revoke execute on function public.auxilio_trocar_lancamento from public, anon;
grant execute on function public.auxilio_trocar_lancamento to authenticated;

/** Saídas que podem ser o pagamento do auxílio: mesmo valor, sem conta vinculada, até 10 dias do pedido. */
create function public.auxilio_saidas_candidatas(p_auxilio uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'data', l.data, 'descricao', l.descricao, 'conta', c.nome,
           'categoria', k.nome) order by l.data desc), '[]')
  from public.auxilios a
  join public.lancamentos l on l.loja_id = a.loja_id
  join public.contas_financeiras c on c.id = l.conta_id
  left join public.categorias_financeiras k on k.id = l.categoria_id
  where a.id = p_auxilio and public.tem_permissao(a.loja_id, 'tronco.editar')
    and l.id is distinct from a.lancamento_id
    and l.data between a.solicitado_em::date - 10 and coalesce(a.decidido_em, now())::date + 10
    and private.auxilio_saida_valida(a, l.id)
    and coalesce(k.codigo, '') <> 'beneficencia'
$$;
revoke execute on function public.auxilio_saidas_candidatas from public, anon;
grant execute on function public.auxilio_saidas_candidatas to authenticated;
