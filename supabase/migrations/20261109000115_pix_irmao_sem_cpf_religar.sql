-- PIX do irmão na chave da Loja sem CPF no cadastro (09/11, caso real: Marcos de Oliveira pagou R$ 291,67 =
-- mensalidade de 20/10 + multa e juros pelo QR fixo; o Asaas criou "Cobrança gerada automaticamente a partir
-- de Pix recebido", o sistema não reconheceu o irmão e espelhou como conta nova de um favorecido, já paga,
-- e o "É uma conta" não aparecia porque o recebimento já estava ligado a essa conta automática).
--
-- 1) Reconhecer o irmão também pelo NOME (igual, sem acento e sem diferença de maiúscula) quando houver um
--    único irmão com esse nome e ele não tiver CPF no cadastro (ou o Asaas não mandou CPF). Com CPF diferente
--    não é ele. Reconhecido, o código de cliente do Asaas fica gravado no irmão e da próxima vez vale direto.
-- 2) PIX direto na chave usa a mesma identificação (antes só CPF ou código de cliente).
-- 3) "É uma conta" também para o recebimento preso numa conta automática de PIX: a conta automática é
--    cancelada, o recebimento vai para a conta escolhida e o cliente do Asaas passa a ser desse irmão.
-- 4) Sugestões: contas da mesma pessoa primeiro; valor com multa e juros do sistema conta como exato.

create or replace function private.nome_chave(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '\s+', ' ', 'g'), '')
$$;

create or replace function private.irmao_pelo_nome(p_loja uuid, p_nome text, p_doc text) returns uuid
language sql stable security definer set search_path = '' as $$
  select (array_agg(i.id))[1] from public.irmaos i
  where i.loja_id = p_loja and private.nome_chave(i.nome) = trim(private.nome_chave(p_nome))
    and (p_doc is null or nullif(regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g'), '') is null)
  having count(*) = 1
$$;
revoke execute on function private.irmao_pelo_nome from public, anon, authenticated;

create or replace function private.asaas_pessoa(p_loja uuid, p_cliente jsonb, out irmao_id uuid, out favorecido_id uuid)
returns record language plpgsql security definer set search_path = '' as $$
declare
  v_id text := p_cliente->>'id';
  v_doc text := nullif(regexp_replace(coalesce(p_cliente->>'cpfCnpj', ''), '\D', '', 'g'), '');
  v_email text := nullif(lower(trim(coalesce(p_cliente->>'email', ''))), '');
begin
  if v_id is null then
    return;
  end if;
  select i.id into irmao_id from public.irmaos i
  where i.loja_id = p_loja and (
    i.asaas_cliente_id = v_id
    or i.id::text = p_cliente->>'externalReference'
    or (v_doc is not null and regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g') = v_doc)
    or (v_email is not null and lower(i.email) = v_email))
  order by (i.asaas_cliente_id = v_id) desc nulls last, (i.situacao = 'ativo') desc
  limit 1;
  if irmao_id is null then
    irmao_id := private.irmao_pelo_nome(p_loja, p_cliente->>'name', v_doc);
  end if;
  if irmao_id is not null then
    update public.irmaos set asaas_cliente_id = v_id where id = irmao_id and asaas_cliente_id is distinct from v_id;
    return;
  end if;

  select f.id into favorecido_id from public.favorecidos f
  where f.loja_id = p_loja and (f.asaas_cliente_id = v_id
    or (v_doc is not null and regexp_replace(coalesce(f.documento, ''), '\D', '', 'g') = v_doc))
  limit 1;
  if favorecido_id is null then
    insert into public.favorecidos (loja_id, nome, tipo, documento, email, telefone, asaas_cliente_id, observacoes)
    values (p_loja,
            coalesce(nullif(trim(p_cliente->>'name'), ''), 'Cliente Asaas ' || v_id)
              || case when exists (select 1 from public.favorecidos where loja_id = p_loja and nome = trim(p_cliente->>'name')) then ' (' || v_id || ')' else '' end,
            'cliente', p_cliente->>'cpfCnpj', v_email, coalesce(p_cliente->>'mobilePhone', p_cliente->>'phone'), v_id,
            'Criado automaticamente a partir do Asaas')
    returning id into favorecido_id;
  else
    update public.favorecidos set asaas_cliente_id = v_id where id = favorecido_id and asaas_cliente_id is distinct from v_id;
  end if;
end $$;

create or replace function private.pix_irmao(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb)
returns text language plpgsql security definer set search_path = '' as $$
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

  -- CPF, código de cliente, e-mail ou nome (único, irmão sem CPF): a mesma identificação das cobranças
  select i.id into v_irmao from public.irmaos i
  where i.loja_id = p_loja and ((v_doc is not null and regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g') = v_doc)
                                or i.asaas_cliente_id = p_cliente->>'id')
  order by (i.situacao = 'ativo') desc limit 1;
  if v_irmao is null and p_cliente is not null then
    v_irmao := private.irmao_pelo_nome(p_loja, p_cliente->>'name', v_doc);
    if v_irmao is not null and p_cliente->>'id' is not null then
      update public.irmaos set asaas_cliente_id = p_cliente->>'id' where id = v_irmao and asaas_cliente_id is null;
    end if;
  end if;
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
end $$;

-- conta criada sozinha pelo Asaas para um PIX recebido na chave, paga só por este recebimento
create or replace function private.conta_automatica_de_pix(p_lancamento uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select t.id from public.lancamentos l join public.titulos t on t.id = l.titulo_id
  where l.id = p_lancamento and t.origem = 'asaas' and t.natureza = 'receber' and not t.cancelado
    and t.irmao_id is null and coalesce(t.asaas_forma, 'PIX') = 'PIX'
    and t.descricao ilike 'Cobrança gerada automaticamente a partir de Pix%'
    and t.valor_pago = coalesce(l.abatimento, l.valor)
    and not exists (select 1 from public.lancamentos o where o.titulo_id = t.id and o.id <> l.id)
$$;
revoke execute on function private.conta_automatica_de_pix from public, anon, authenticated;

create or replace function public.vincular_lancamento_titulo(p_lancamento uuid, p_titulo uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  l public.lancamentos;
  t public.titulos;
  v_auto uuid;
  v_cliente text;
  v_saldo numeric(12,2);
  v_abat numeric(12,2);
  v_novo uuid;
begin
  select * into l from public.lancamentos where id = p_lancamento for update;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão para alterar este lançamento'; end if;
  v_auto := private.conta_automatica_de_pix(l.id);
  if (l.titulo_id is not null and v_auto is null) or l.estorno_de is not null or l.tipo = 'transferencia'
     or exists (select 1 from public.lancamentos s where s.estorno_de = l.id) then
    raise exception 'Só um lançamento avulso (sem conta vinculada) pode ser vinculado';
  end if;
  select * into t from public.titulos where id = p_titulo for update;
  if t.id is null or t.loja_id <> l.loja_id or t.cancelado or t.id = v_auto then raise exception 'Conta inválida'; end if;
  if (l.tipo = 'receita') <> (t.natureza = 'receber') then raise exception 'Saída só quita conta a pagar; entrada, conta a receber'; end if;
  v_saldo := t.valor - t.valor_pago;
  if v_saldo <= 0 then raise exception 'Esta conta já está quitada'; end if;
  v_abat := least(l.valor, v_saldo);

  perform set_config('malhete.sem_avisos', 'on', true);
  -- tira o avulso (estorno idêntico; se estava na conta automática do PIX, a baixa dela sai junto) …
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento,
                                  estorno_de, motivo_estorno)
  values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, l.data, l.competencia,
          'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.documento,
          l.titulo_id, case when l.titulo_id is not null then -l.abatimento end, l.id,
          'Vinculado à conta: ' || t.descricao);
  -- … e lança a baixa da conta com o mesmo valor, data e conta
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento)
  values (l.loja_id, l.conta_id, t.categoria_id, l.tipo, l.valor, l.data, t.competencia, t.descricao,
          t.irmao_id, t.favorecido_id, t.centro_custo_id, l.documento, t.id, v_abat)
  returning id into v_novo;
  -- a linha do extrato passa a apontar para a baixa
  update public.extrato_itens set lancamento_id = v_novo, motivo = 'vinculado à conta' where lancamento_id = l.id;

  if v_auto is not null then
    perform set_config('malhete.sistema', 'on', true);
    -- a conta automática some (cancelada, a sincronização não lança de novo)
    update public.titulos set cancelado = true,
           motivo_cancelamento = left('PIX recebido ligado à conta: ' || t.descricao, 250)
     where id = v_auto
     returning (select f.asaas_cliente_id from public.favorecidos f where f.id = titulos.favorecido_id) into v_cliente;
    -- quem pagou passa a ser reconhecido como este irmão nos próximos PIX
    if t.irmao_id is not null and v_cliente is not null then
      update public.irmaos set asaas_cliente_id = v_cliente where id = t.irmao_id and asaas_cliente_id is null;
    end if;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_novo;
end $$;

create or replace function public.sugestoes_para_lancamento(p_lancamento uuid)
returns table (titulo_id uuid, descricao text, vencimento date, saldo numeric, pessoa text, exato boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  l public.lancamentos;
  v_nome text;
  v_cliente text;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or not public.pode_lancar(l.conta_id) then raise exception 'Sem permissão'; end if;
  select private.nome_chave(f.nome), f.asaas_cliente_id into v_nome, v_cliente
    from public.favorecidos f where f.id = l.favorecido_id;
  return query
  with c as (
    select t.*, t.valor - t.valor_pago as s,
           coalesce(i.nome, f.nome) as quem,
           (t.irmao_id = l.irmao_id
            or (t.favorecido_id is not null and t.favorecido_id = l.favorecido_id)
            or (i.id is not null and (i.asaas_cliente_id = v_cliente or private.nome_chave(i.nome) = v_nome))) as mesma
    from public.titulos t
    left join public.irmaos i on i.id = t.irmao_id
    left join public.favorecidos f on f.id = t.favorecido_id
    where t.loja_id = l.loja_id and not t.cancelado and t.valor_pago < t.valor
      and t.id is distinct from l.titulo_id
      and t.natureza = case when l.tipo = 'receita' then 'receber' else 'pagar' end
      and t.vencimento <= l.data + 45
  ), e as (
    select c.*, (c.s = l.valor
                 or (l.tipo = 'receita' and c.vencimento < l.data
                     and c.s + private.encargos(l.loja_id, c.s, c.vencimento) = l.valor)) as ex
    from c
  )
  select e.id, e.descricao, e.vencimento, e.s, e.quem, e.ex
  from e
  order by coalesce(e.mesma, false) desc,
           e.ex desc,
           abs(e.s - l.valor),
           (e.vencimento > l.data),
           case when e.vencimento <= l.data then e.vencimento end,
           e.vencimento
  limit 12;
end $$;
revoke execute on function public.sugestoes_para_lancamento from public, anon;
grant execute on function public.sugestoes_para_lancamento to authenticated;
