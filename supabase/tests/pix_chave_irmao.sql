-- PIX na chave vindo de irmão: Tronco, uma mensalidade, "pagar tudo" e valor que não bate.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; cx uuid; ix uuid; cat uuid; r text := ''; s text;
  cli jsonb := '{"id":"cus_x","name":"Irmão Pagador","cpfCnpj":"529.982.247-25"}';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'pc@t.com', 'authenticated', 'authenticated', now()),
    (x, 'pcx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Pagador', 3, 'PC', '2015-01-01', '52998224725', 'pc@teste.com') returning id into ix;
  cat := (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades');
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id) values
    (l, 'receber', 'Mensalidade 09/2026', cat, 100, current_date - 40, current_date - 40, ix),
    (l, 'receber', 'Mensalidade 10/2026', cat, 100, current_date - 10, current_date - 10, ix),
    (l, 'receber', 'Mensalidade 11/2026', cat, 100, current_date + 20, current_date + 20, ix),
    (l, 'receber', 'Mensalidade 12/2026', cat, 100, current_date + 50, current_date + 50, ix);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status) values (l, ix, 4, 'TRONCOB', 'aguardando');
  reset role;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final, criado_em) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx', now() - interval '1 day');
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_a', 'value', 4, 'netValue', 4, 'status', 'RECEIVED', 'paymentDate', current_date::text, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'), cli);
  r := r || format('PIX 4=%s | ', s);
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_b', 'value', 100, 'netValue', 100, 'status', 'RECEIVED', 'paymentDate', current_date::text, 'dueDate', current_date::text, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'), cli);
  r := r || format('PIX 100=%s | ', s);
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_c', 'value', 200, 'netValue', 200, 'status', 'RECEIVED', 'paymentDate', current_date::text, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'), cli);
  r := r || format('PIX 200=%s | ', s);
  s := public.asaas_espelhar_pagamento(l, 'VARREDURA', jsonb_build_object('id', 'pay_c', 'value', 200, 'netValue', 200, 'status', 'RECEIVED', 'paymentDate', current_date::text), cli);
  r := r || format('varredura repetida=%s | ', s);
  select string_agg(descricao || ':' || case when valor_pago >= valor then 'paga' else 'aberta' end, ', ' order by vencimento) into s
    from public.titulos where loja_id = l and irmao_id = ix and descricao like 'Mensalidade%';
  r := r || format('mensalidades=%s | ', s);
  select count(*)::text into s from public.titulos where loja_id = l and descricao like 'Cobrança gerada%';
  r := r || format('contas novas criadas=%s | ', s);
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_d', 'value', 37, 'netValue', 37, 'status', 'RECEIVED', 'paymentDate', current_date::text, 'dueDate', current_date::text, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'), cli);
  r := r || format('PIX 37 (não bate)=%s', s);
  raise exception 'RESULTADO: %', r;
end $$;
