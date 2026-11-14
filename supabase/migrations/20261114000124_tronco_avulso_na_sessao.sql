-- Sistema Malhete: PIX DO TRONCO PAGO À MÃO ENTRA NO TOTAL DA SESSÃO (14/11). Os 5 irmãos que pagaram o Tronco de
-- 13/11 digitando a chave foram passados para o Tronco ("É do Tronco"), mas o total da sessão soma CONTRIBUIÇÕES ligadas
-- a ela, e esses PIX não tinham contribuição. Agora o "É do Tronco" liga o lançamento à sessão mais recente até a data do
-- PIX (até 7 dias antes, sessão não cancelada): usa a contribuição confirmada dele ou cria uma anônima (sem irmão).
-- Os já convertidos são ligados aqui mesmo.

-- contribuição do Tronco pode não ter irmão (PIX pago à mão, de quem não se sabe): o Tronco é anônimo
alter table public.tronco_contribuicoes alter column irmao_id drop not null;

/** Liga um lançamento de receita do Tronco à sessão (a dada ou a mais recente até a data dele). Devolve a sessão. */
create function private.tronco_somar_na_sessao(p_lancamento uuid, p_sessao uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_sessao uuid := p_sessao;
  v_ts uuid;
  v_contrib uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or l.tipo <> 'receita' or l.estorno_de is not null
     or not exists (select 1 from public.categorias_financeiras k where k.id = l.categoria_id and k.codigo = 'tronco') then
    return null;
  end if;
  if v_sessao is null then
    select s.id into v_sessao from public.sessoes s
    where s.loja_id = l.loja_id and s.status <> 'cancelada' and s.data between l.data - 7 and l.data
    order by s.data desc, s.hora desc nulls last limit 1;
  end if;
  if v_sessao is null then return null; end if;
  insert into public.tronco_sessoes (loja_id, sessao_id) values (l.loja_id, v_sessao) on conflict (sessao_id) do nothing;
  select id into v_ts from public.tronco_sessoes where sessao_id = v_sessao;
  select id into v_contrib from public.tronco_contribuicoes where lancamento_id = l.id limit 1;
  if v_contrib is not null then
    update public.tronco_contribuicoes set tronco_sessao_id = v_ts where id = v_contrib and tronco_sessao_id is null;
  else
    insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem, informado_em,
                                             decidido_por, decidido_em, lancamento_id, tronco_sessao_id)
    values (l.loja_id, null, l.valor, 'PIXAVULSO', 'confirmada', 'pix_chave', l.criado_em,
            auth.uid(), now(), l.id, v_ts);
  end if;
  return v_sessao;
end $$;
revoke execute on function private.tronco_somar_na_sessao from public, anon, authenticated;

CREATE OR REPLACE FUNCTION private.tronco_do_lancamento(p_lancamento uuid, p_contrib uuid) returns uuid
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
  -- Tronco é anônimo: o recebimento antigo, o estorno e a conta automática deixam de mostrar quem pagou
  perform set_config('malhete.anonimizar', 'on', true);
  update public.lancamentos set irmao_id = null, favorecido_id = null
  where (id = l.id or (estorno_de = l.id and loja_id = l.loja_id)) and (irmao_id is not null or favorecido_id is not null);
  perform set_config('malhete.anonimizar', 'off', true);
  if v_auto is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set irmao_id = null, favorecido_id = null where id = v_auto;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  if p_contrib is not null then
    update public.tronco_contribuicoes
    set status = 'confirmada', decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_novo
    where id = p_contrib and status <> 'confirmada';
  end if;
  -- soma no Tronco da sessão mais recente até a data do PIX (o total da sessão conta as contribuições)
  perform private.tronco_somar_na_sessao(v_novo, null);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_novo;
end $$;

-- os que já foram passados para o Tronco pelo "É do Tronco" (estorno com esse motivo) entram na sessão deles
do $$ declare r record; begin
  for r in
    select n.id from public.lancamentos n
    join public.categorias_financeiras k on k.id = n.categoria_id and k.codigo = 'tronco'
    where n.tipo = 'receita' and n.estorno_de is null and n.documento is not null
      and not exists (select 1 from public.lancamentos e where e.estorno_de = n.id)
      and exists (select 1 from public.lancamentos o
                  join public.lancamentos e on e.estorno_de = o.id and e.motivo_estorno = 'É do Tronco de Beneficência'
                  where o.loja_id = n.loja_id and o.documento = n.documento and o.id <> n.id)
  loop
    perform private.tronco_somar_na_sessao(r.id, null);
  end loop;
end $$;
