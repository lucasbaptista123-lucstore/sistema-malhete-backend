-- Tronco pelo Asaas: pagamento confirmado lança receita (bruto) + tarifa na conta Asaas, confirma e não repete.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; cx uuid; ix uuid; c uuid; r text := ''; s text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'ta@t.com', 'authenticated', 'authenticated', now()),
    (x, 'tax@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Doador', 3, 'TX', '2015-01-01', '52998224725', 'tx@teste.com') returning id into ix;
  reset role;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final, criado_em) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx', now() - interval '1 day');
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem, asaas_id) values (l, ix, 50, 'TRONCOX', 'aguardando', 'asaas', 'pay_tr1') returning id into c;
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_tr1', 'value', 50, 'netValue', 49.01, 'paymentDate', current_date::text, 'externalReference', 'tronco:' || c, 'status', 'RECEIVED'));
  r := r || format('webhook=%s | ', s);
  select string_agg(tipo || ' ' || valor || ' ' || (select codigo from public.categorias_financeiras k where k.id = categoria_id), ', ' order by tipo desc) into s from public.lancamentos where documento = 'pay_tr1';
  r := r || format('lançamentos=%s | ', s);
  select status into s from public.tronco_contribuicoes where id = c;
  r := r || format('contribuição=%s | ', s);
  s := public.asaas_espelhar_pagamento(l, 'VARREDURA', jsonb_build_object('id', 'pay_tr1', 'value', 50, 'netValue', 49.01, 'externalReference', 'tronco:' || c, 'status', 'RECEIVED'));
  r := r || format('varredura de novo=%s | ', s);
  select count(*)::text into s from public.titulos where loja_id = l;
  r := r || format('títulos criados=%s (esperado 0)', s);
  raise exception 'RESULTADO: %', r;
end $$;
