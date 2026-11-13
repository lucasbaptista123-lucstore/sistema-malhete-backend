-- Sistema Malhete: TRONCO SEM CONTAR DUAS VEZES (13/11, achado ao revisar a sessão do dia). Quando o PIX do Tronco
-- não é reconhecido sozinho (irmão sem CPF, pago da conta de outra pessoa), o Asaas já o lançou como "PIX recebido"
-- (conta automática) ou "Entrada a classificar". Antes, "Confirmar no Tronco" lançava OUTRA receita na conta Tronco:
-- o mesmo dinheiro contava duas vezes. Agora:
--  1) decidir_tronco procura primeiro esse PIX já recebido (mesmo valor, mesma janela) e o transforma em Tronco;
--     só lança na conta Tronco quando não há PIX no Asaas (Loja sem Asaas ou chave própria do Tronco);
--  2) em Movimentações, "É do Tronco" faz o mesmo a partir do lançamento (com ou sem contribuição aguardando).
-- A transformação segue o "É uma conta": estorno idêntico do recebimento, cancela a conta automática e lança a
-- receita do Tronco na mesma conta, data e documento, sem nome (anônimo).

/** Recebimento do Asaas ainda sem dono que pode virar Tronco: PIX recebido (conta automática) ou entrada a classificar. */
create function private.pix_sem_dono(p_lancamento uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.lancamentos l
    where l.id = p_lancamento and l.tipo = 'receita' and l.estorno_de is null
      and not exists (select 1 from public.lancamentos s where s.estorno_de = l.id)
      and l.conta_id = (select a.conta_id from public.integracoes_asaas a where a.loja_id = l.loja_id and a.ativo)
      and not exists (select 1 from public.categorias_financeiras k where k.id = l.categoria_id and k.codigo = 'tronco')
      and (private.conta_automatica_de_pix(l.id) is not null
           or (l.titulo_id is null and exists (select 1 from public.categorias_financeiras k
                                               where k.id = l.categoria_id and k.codigo = 'entrada_asaas'))))
$$;
revoke execute on function private.pix_sem_dono from public, anon, authenticated;

/** Transforma o recebimento em Tronco (anônimo) e confirma a contribuição, se houver. Devolve o lançamento novo. */
create function private.tronco_do_lancamento(p_lancamento uuid, p_contrib uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_auto uuid;
  v_novo uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento for update;
  if not private.pix_sem_dono(l.id) then raise exception 'Este lançamento não é um PIX sem dono no Asaas'; end if;
  v_auto := private.conta_automatica_de_pix(l.id);
  perform set_config('malhete.sem_avisos', 'on', true);
  -- tira o recebimento como estava (estorno idêntico; a baixa da conta automática sai junto) …
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento,
                                  estorno_de, motivo_estorno)
  values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, l.data, l.competencia,
          'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.documento,
          l.titulo_id, case when l.titulo_id is not null then -l.abatimento end, l.id,
          'É do Tronco de Beneficência');
  -- … e lança o Tronco com o mesmo valor, data, conta e documento, sem nome
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
  values (l.loja_id, l.conta_id, (select id from public.categorias_financeiras where loja_id = l.loja_id and codigo = 'tronco'),
          'receita', l.valor, l.data, l.data, 'Tronco de Beneficência (PIX)', l.documento)
  returning id into v_novo;
  update public.extrato_itens set lancamento_id = v_novo, motivo = 'Tronco de Beneficência' where lancamento_id = l.id;
  if v_auto is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set cancelado = true, motivo_cancelamento = 'PIX recebido era do Tronco de Beneficência'
    where id = v_auto;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  if p_contrib is not null then
    update public.tronco_contribuicoes
    set status = 'confirmada', decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_novo
    where id = p_contrib and status <> 'confirmada';
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_novo;
end $$;
revoke execute on function private.tronco_do_lancamento from public, anon, authenticated;

-- 1) "Confirmar no Tronco": usa o PIX que já entrou no Asaas, se houver; senão, lança na conta Tronco (como antes)
CREATE OR REPLACE FUNCTION public.decidir_tronco(p_id uuid, p_confirmar boolean, p_data date DEFAULT CURRENT_DATE)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.tronco_contribuicoes;
  v_conta uuid;
  v_lanc uuid;
  v_pix uuid;
begin
  select * into c from public.tronco_contribuicoes where id = p_id for update;
  if c.id is null or not public.tem_permissao(c.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro confirma o Tronco'; end if;
  if c.status = 'confirmada' then raise exception 'Já confirmada'; end if;
  if p_confirmar then
    -- o PIX já entrou pelo Asaas sem ser reconhecido: o mais antigo com o mesmo valor, de um dia antes a 5 dias depois
    select l.id into v_pix from public.lancamentos l
    where l.loja_id = c.loja_id and l.tipo = 'receita' and l.valor = c.valor
      and l.data between c.informado_em::date - 1 and c.informado_em::date + 5
      and private.pix_sem_dono(l.id)
    order by l.data, l.criado_em limit 1;
    if v_pix is not null then
      perform private.tronco_do_lancamento(v_pix, c.id);
      return;
    end if;
    select id into v_conta from public.contas_financeiras where loja_id = c.loja_id and tipo = 'tronco' and ativa limit 1;
    if v_conta is null then raise exception 'A loja não tem conta Tronco ativa'; end if;
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao, documento)
    values (c.loja_id, v_conta,
            (select id from public.categorias_financeiras where loja_id = c.loja_id and codigo = 'tronco'),
            'receita', c.valor, coalesce(p_data, current_date), 'Tronco de Beneficência (PIX)', c.txid)
    returning id into v_lanc;
  end if;
  update public.tronco_contribuicoes
  set status = case when p_confirmar then 'confirmada' else 'nao_localizada' end,
      decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_lanc
  where id = c.id;
end $function$;

-- 2) Movimentações → "É do Tronco": o PIX sem dono vira Tronco; confirma a contribuição aguardando do mesmo valor
create function public.tronco_e_do_tronco(p_lancamento uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_contrib uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.tem_permissao(l.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro lança o Tronco'; end if;
  select id into v_contrib from public.tronco_contribuicoes
  where loja_id = l.loja_id and status in ('aguardando', 'informada') and valor = l.valor
    and informado_em::date between l.data - 5 and l.data + 1
  order by (status = 'informada') desc, informado_em limit 1;
  return private.tronco_do_lancamento(l.id, v_contrib);
end $$;
revoke execute on function public.tronco_e_do_tronco from public, anon;
grant execute on function public.tronco_e_do_tronco to authenticated;
