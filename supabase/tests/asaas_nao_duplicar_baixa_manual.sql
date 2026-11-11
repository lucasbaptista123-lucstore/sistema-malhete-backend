-- Boleto pago no Asaas com baixa dada à mão antes de o débito aparecer no extrato: não pode lançar de novo.
-- Caso 1 (o da Orvalho, 06/11): conta de 1.584 vencida, baixa à mão de 1.584; o Asaas debita 1.608,44 (juros).
--   Esperado: concilia com a baixa, lança só 24,44 de juros; a conta do mês seguinte (1.584) continua aberta.
-- Caso 2: PIX de 500 lançado à mão; débito de 500 no extrato: só concilia.
-- Caso 3: débito de 300 sem nada à mão: lança como antes ("Saída a classificar").
do $$ declare t uuid := gen_random_uuid(); l uuid; cx uuid; t1 uuid; t2 uuid; j jsonb; s0 numeric; s1 numeric; r text; cat uuid; fav uuid; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tdup@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  select id into cat from public.categorias_financeiras where loja_id = l and tipo = 'despesa' order by nome limit 1;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia)
    values (l, 'pagar', 'CAPTACAO SET', cat, 1584, current_date - 47, current_date - 47) returning id into t1;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia)
    values (l, 'pagar', 'CAPTACAO OUT', cat, 1584, current_date - 17, current_date - 17) returning id into t2;
  -- Tesoureiro dá baixa à mão ontem na conta do Asaas
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, titulo_id, abatimento)
    values (l, cx, cat, 'despesa', 1584, current_date - 1, current_date - 47, 'CAPTACAO SET', t1, 1584);
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao)
    values (l, cx, cat, 'despesa', 500, current_date - 2, current_date, 'PIX ao fornecedor');
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  select saldo into s0 from public.contas_saldo where conta_id = cx;
  insert into public.extrato_itens (loja_id, conta_id, origem, id_externo, data, valor, descricao, tipo_externo, situacao) values
    (l, cx, 'asaas', 'ftn_1', current_date, -1608.44, 'Pagamento de conta', 'BILL_PAYMENT', 'pendente'),
    (l, cx, 'asaas', 'ftn_2', current_date, -500, 'Transação via Pix', 'PIX', 'pendente'),
    (l, cx, 'asaas', 'ftn_3', current_date, -300, 'Transação via Pix', 'PIX', 'pendente');
  j := public.asaas_concluir_sincronizacao(l, null, false);
  select saldo into s1 from public.contas_saldo where conta_id = cx;
  r := format('%s | saldo antes=%s depois=%s (esperado -324.44) | set pago=%s out pago=%s (esperado 1584 e 0) | juros=%s | motivos=%s',
    j, s0, s1 - s0,
    (select valor_pago from public.titulos where id = t1), (select valor_pago from public.titulos where id = t2),
    (select string_agg(valor::text, ',') from public.lancamentos where conta_id = cx and descricao like 'Juros e multa:%'),
    (select string_agg(id_externo || '=' || motivo, ', ' order by id_externo) from public.extrato_itens where conta_id = cx));
  if s1 - s0 <> -324.44 or (select valor_pago from public.titulos where id = t2) <> 0 then raise exception 'FALHOU: %', r; end if;
  raise exception 'OK: %', r;
end $$;
