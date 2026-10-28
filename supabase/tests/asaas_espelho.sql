-- Espelhamento Asaas: simula os eventos que a edge function repassa (como service_role).
do $$
declare
  a uuid := gen_random_uuid(); -- Tesoureira
  l uuid; v_a uuid; v_b uuid; g uuid; v_asaas uuid; v_tit_b uuid; v_tit uuid; v_res jsonb;
  r text := ''; t text; n int; s numeric;
begin
  insert into auth.users (id, email, aud, role) values (a, 'a@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'A');
  select id into v_a from public.irmaos where loja_id = l and user_id = a;
  insert into public.irmaos (loja_id, nome, cpf, email, cim, data_iniciacao) values (l, 'Irmão B', '529.982.247-25', 'b@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 400) returning id into v_b;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, v_a, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
  v_asaas := public.asaas_conectar(l, '$aact_hmlg_0000000000000000000000000000TESTE', 'sandbox');
  perform public.gerar_mensalidades(l, date_trunc('month', current_date)::date, 80, current_date + 5);
  select id into v_tit_b from public.titulos where irmao_id = v_b;

  begin
    update public.titulos set asaas_id = 'pay_x' where id = v_tit_b;
    r := r || 'tesoureira mexe em asaas_id=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureira mexe em asaas_id=bloqueado | ';
  end;
  begin
    perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', '{"id":"pay_x","value":1}'::jsonb);
    r := r || 'tesoureira chama função do webhook=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureira chama função do webhook=bloqueado | ';
  end;

  -- ---- a partir daqui, como a edge function
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  select count(*) into n from public.asaas_cobrancas_pendentes(l);
  r := r || format('cobranças a enviar=%s (esperado 2: A e B) | ', n);
  perform public.asaas_vincular(l, v_tit_b, v_b, 'cus_b', '{"id":"pay_1","invoiceUrl":"https://asaas/i/1","billingType":"UNDEFINED","status":"PENDING"}'::jsonb);
  select count(*) into n from public.asaas_cobrancas_pendentes(l);
  r := r || format('depois de enviar a do B=%s (esperado 1) | ', n);

  -- irmão paga: 80 com 1,99 de tarifa
  t := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_1', 'value', 80, 'netValue', 78.01, 'status', 'RECEIVED', 'paymentDate', current_date, 'billingType', 'PIX'));
  r := r || format('webhook=%s | ', t);
  select situacao into t from public.titulos_situacao where id = v_tit_b;
  r := r || format('mensalidade=%s (esperado pago) | ', t);
  select saldo into s from public.contas_saldo where conta_id = v_asaas;
  r := r || format('saldo Asaas=%s (esperado 78.01) | ', s);
  t := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_1', 'value', 80, 'netValue', 78.01, 'status', 'RECEIVED', 'paymentDate', current_date));
  select count(*) into n from public.lancamentos where documento = 'pay_1';
  r := r || format('aviso repetido=%s lançamentos (esperado 2) | ', n);

  -- PIX de fora, sem cobrança prévia
  t := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_3', 'value', 50, 'netValue', 50, 'status', 'RECEIVED', 'paymentDate', current_date, 'dueDate', current_date, 'description', 'Pix recebido'),
    jsonb_build_object('id', 'cus_9', 'name', 'Fulano de Tal', 'cpfCnpj', '99988877766'));
  select f.nome || ' / ' || ts.situacao into t from public.titulos_situacao ts join public.favorecidos f on f.id = ts.favorecido_id where ts.asaas_id = 'pay_3';
  r := r || format('PIX de fora=%s (esperado Fulano de Tal / pago) | ', t);

  -- cobrança criada direto no Asaas para o irmão B (casada pelo CPF)
  t := public.asaas_espelhar_pagamento(l, 'PAYMENT_CREATED',
    jsonb_build_object('id', 'pay_2', 'value', 150, 'status', 'PENDING', 'dueDate', current_date + 10, 'description', 'Jóia'),
    jsonb_build_object('id', 'cus_outro', 'name', 'B', 'cpfCnpj', '52998224725'));
  select coalesce((select nome from public.irmaos where id = ts.irmao_id), '?') || ' / ' || ts.origem || ' / ' || ts.valor into t from public.titulos_situacao ts where asaas_id = 'pay_2';
  r := r || format('cobrança do Asaas=%s (esperado Irmão B / asaas / 150) | ', t);
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_UPDATED', jsonb_build_object('id', 'pay_2', 'value', 160, 'status', 'PENDING', 'dueDate', current_date + 12));
  select valor into s from public.titulos where asaas_id = 'pay_2';
  r := r || format('atualizada=%s (esperado 160) | ', s);
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_DELETED', jsonb_build_object('id', 'pay_2', 'value', 160, 'deleted', true));
  select situacao into t from public.titulos_situacao where asaas_id = 'pay_2';
  r := r || format('removida no Asaas=%s (esperado cancelado) | ', t);

  -- extrato chega antes do aviso de pagamento (pay_4) e depois (pay_1)
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.criar_titulos(l, 'receber', 'Doação X', (select id from public.categorias_financeiras where loja_id = l and codigo = 'doacoes'), 30, current_date);
  select id into v_tit from public.titulos where descricao = 'Doação X';
  v_res := public.importar_extrato(l, v_asaas, 'asaas', 'Asaas', jsonb_build_array(
    jsonb_build_object('id_externo', 'ftn_1', 'data', current_date, 'valor', 80, 'tipo', 'PAYMENT_RECEIVED', 'referencia', 'pay_1'),
    jsonb_build_object('id_externo', 'ftn_2', 'data', current_date, 'valor', -1.99, 'tipo', 'PAYMENT_FEE', 'referencia', 'pay_1'),
    jsonb_build_object('id_externo', 'ftn_3', 'data', current_date, 'valor', 30, 'tipo', 'PAYMENT_RECEIVED', 'referencia', 'pay_4')));
  r := r || format('extrato importado: conciliou sozinho=%s (esperado 2) | ', v_res->>'conciliados');
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.asaas_vincular(l, v_tit, null, null, '{"id":"pay_4","status":"PENDING"}'::jsonb);
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_4', 'value', 30, 'netValue', 30, 'status', 'RECEIVED', 'paymentDate', current_date));
  select situacao into t from public.extrato_itens where id_externo = 'ftn_3';
  r := r || format('aviso depois do extrato concilia=%s (esperado conciliado) | ', t);

  -- estorno no Asaas
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_REFUNDED', jsonb_build_object('id', 'pay_1', 'value', 80, 'status', 'REFUNDED'));
  select situacao into t from public.titulos_situacao where id = v_tit_b;
  r := r || format('após estorno=%s (esperado aberto) | ', t);
  select saldo into s from public.contas_saldo where conta_id = v_asaas;
  r := r || format('saldo Asaas=%s (esperado 80.00 = 50 + 30) | ', s);

  -- recebido em dinheiro (confirmado no Asaas) cai no Caixa, sem tarifa
  perform public.asaas_vincular(l, (select id from public.titulos where irmao_id = v_a and origem = 'mensalidade'), null, null, '{"id":"pay_5","status":"PENDING"}'::jsonb);
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_5', 'value', 80, 'netValue', 80, 'status', 'RECEIVED_IN_CASH', 'paymentDate', current_date));
  select c.nome into t from public.lancamentos x join public.contas_financeiras c on c.id = x.conta_id where x.documento = 'pay_5';
  r := r || format('recebido em dinheiro foi para=%s (esperado Caixa) | ', t);

  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
