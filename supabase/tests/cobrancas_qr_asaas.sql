-- Cobranças pelo QR estático do Asaas (0123, 14/11).
-- A) dados do QR: só contas abertas sem cobrança no Asaas, valor do dia (multa e juros na vencida), total e reaproveitamento.
-- B) pagamento do QR (pixQrCodeId, irmão sem CPF): baixa nas duas contas, sem "PIX recebido"; varredura não duplica.
-- C) valor diferente do QR: não dá baixa sozinho (segue para conferir).
-- D) soltar cobrança que o sistema criou: some do Asaas sem cancelar a conta aqui (aviso de removida ignorado);
--    cobrança que veio de fora (origem asaas) não entra na lista; desfazer volta como estava.
-- E) integração nova nasce sem criar cobrança no Asaas.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; cx uuid; cat uuid; ia uuid; t1 uuid; t2 uuid; t3 uuid; t4 uuid; t5 uuid;
  d jsonb; tot numeric; r text; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tcq@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  select id into cat from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades';
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao) values
    (l, 'Marcos Sem Cpf', 3, '1', '2020-01-01', 'ativo') returning id into ia;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  -- E
  if (select criar_cobrancas from public.integracoes_asaas where loja_id = l) then raise exception 'FALHOU E: integração nova cria cobrança'; end if;
  insert into public.tesouraria_config (loja_id, pix_chave, multa_percentual, juros_mensal) values (l, 'loja@teste.org', 2, 1)
    on conflict (loja_id) do update set pix_chave = excluded.pix_chave, multa_percentual = 2, juros_mensal = 1;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'Mensalidade 10/2026', cat, ia, 250, current_date - 30, current_date - 30) returning id into t1;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'Mensalidade 11/2026', cat, ia, 250, current_date + 5, current_date) returning id into t2;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'Jóia', cat, ia, 100, current_date + 5, current_date) returning id into t3;

  -- A
  d := public.pix_qr_titulos_dados(l, array[t2, t1]);
  tot := (d->>'total')::numeric;
  if not (d->>'automatico')::boolean or d->>'chave' <> 'loja@teste.org' or jsonb_array_length(d->'partes') <> 2
     or (d->'partes'->0->>'titulo')::uuid <> t1 or (d->'partes'->0->>'valor')::numeric <= 250
     or (d->'partes'->1->>'valor')::numeric <> 250 or d->>'descricao' <> '2 contas da Loja' then
    raise exception 'FALHOU A: %', d;
  end if;
  perform public.pix_qr_guardar('qr_1', l, d->'partes', tot, 'PAYLOAD-1', now() + interval '1 day');
  if public.pix_qr_titulos_dados(l, array[t1, t2])->>'reaproveitar' <> 'PAYLOAD-1' then raise exception 'FALHOU A: não reaproveitou'; end if;

  -- B
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_B', 'value', tot, 'netValue', tot, 'status', 'RECEIVED', 'billingType', 'PIX',
      'pixQrCodeId', 'qr_1', 'paymentDate', current_date, 'dueDate', current_date, 'description', '2 contas da Loja'),
    jsonb_build_object('id', 'cus_B', 'name', 'Esposa Do Marcos', 'cpfCnpj', '52998224725'));
  if (select count(*) from public.titulos where id in (t1, t2) and valor_pago >= valor) <> 2 then raise exception 'FALHOU B: % ', r; end if;
  if exists (select 1 from public.titulos where loja_id = l and asaas_id = 'pay_B') then raise exception 'FALHOU B: criou PIX recebido'; end if;
  if (select sum(valor) from public.lancamentos where loja_id = l and documento = 'pay_B') <> tot then raise exception 'FALHOU B: soma'; end if;
  perform public.asaas_espelhar_pagamento(l, 'VARREDURA',
    jsonb_build_object('id', 'pay_B', 'value', tot, 'netValue', tot, 'status', 'RECEIVED', 'pixQrCodeId', 'qr_1',
      'paymentDate', current_date), null);
  select count(*) into n from public.lancamentos where loja_id = l and documento = 'pay_B';
  if n <> 2 then raise exception 'FALHOU B: varredura duplicou (%)', n; end if;

  -- C
  d := public.pix_qr_titulos_dados(l, array[t3]);
  perform public.pix_qr_guardar('qr_3', l, d->'partes', 100, 'PAYLOAD-3', now() + interval '1 day');
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_C', 'value', 90, 'netValue', 90, 'status', 'RECEIVED', 'billingType', 'PIX',
      'pixQrCodeId', 'qr_3', 'paymentDate', current_date, 'dueDate', current_date),
    jsonb_build_object('id', 'cus_C', 'name', 'Outra Pessoa', 'cpfCnpj', '11144477735'));
  if (select valor_pago from public.titulos where id = t3) <> 0 then raise exception 'FALHOU C: baixou com valor diferente'; end if;

  -- D
  perform set_config('malhete.sistema', 'on', true);
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem, asaas_id, asaas_status)
    values (l, 'receber', 'Captação', cat, ia, 220, current_date + 1, current_date, 'manual', 'pay_old', 'PENDING') returning id into t4;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem, asaas_id, asaas_status)
    values (l, 'receber', 'Assinatura antiga', cat, ia, 277, current_date + 1, current_date, 'asaas', 'pay_sub', 'PENDING') returning id into t5;
  perform set_config('malhete.sistema', 'off', true);
  d := public.asaas_cobrancas_do_sistema(l);
  if jsonb_array_length(d) <> 1 or (d->0->>'titulo')::uuid <> t4 then raise exception 'FALHOU D lista: %', d; end if;
  perform public.asaas_soltar_cobranca(t4, t);
  if (select asaas_id from public.titulos where id = t4) is not null then raise exception 'FALHOU D: não soltou'; end if;
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_DELETED',
    jsonb_build_object('id', 'pay_old', 'value', 220, 'status', 'PENDING', 'externalReference', t4::text, 'deleted', true), null);
  if (select cancelado from public.titulos where id = t4) or r not like 'ignorado%' then raise exception 'FALHOU D: cancelou a conta (%)', r; end if;
  perform public.asaas_soltar_cobranca(t4, t, 'pay_old');
  if (select asaas_id from public.titulos where id = t4) <> 'pay_old'
     or exists (select 1 from public.asaas_cobrancas_soltas where pagamento_id = 'pay_old') then
    raise exception 'FALHOU D: desfazer';
  end if;

  raise exception 'OK: cobranças pelo QR do Asaas (dados, baixa de 2 contas, valor diferente, soltar sem cancelar, desfazer)';
end $$;
