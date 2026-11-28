-- 0135 (28/11): PIX do Tronco pago digitando a chave, depois das 21h de Brasília (já é o dia seguinte em UTC).
-- A contribuição "aguardando" foi criada às 22h17 de 27/11 (01h17 de 28/11 em UTC) e o Asaas manda paymentDate 27/11:
-- o PIX tem de virar Tronco sozinho, como faz quando o QR é usado.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; cx uuid; ia uuid; c20 uuid; st text; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tdb@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, cpf) values
    (l, 'Fulano Com Cpf', 3, '1', '2020-01-01', 'ativo', '52998224725') returning id into ia;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem, informado_em)
    values (l, ia, 20, 'TRONCODB', 'aguardando', 'pix_chave', '2026-11-28 01:17:35+00') returning id into c20;

  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_DB', 'value', 20, 'netValue', 20, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', '2026-11-27', 'dueDate', '2026-11-27', 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_DB', 'name', 'Fulano Com Cpf', 'cpfCnpj', '52998224725'));
  select status into st from public.tronco_contribuicoes where id = c20;
  if st <> 'confirmada' then raise exception 'FALHOU: PIX das 22h17 não virou Tronco (status %)', st; end if;
  select count(*) into n from public.titulos where loja_id = l and not cancelado;
  if n <> 0 then raise exception 'FALHOU: ficou conta automática do PIX (%)', n; end if;

  -- o mesmo PIX de dia seguinte de verdade (4 dias depois) continua fora
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem, informado_em)
    values (l, ia, 30, 'TRONCODC', 'aguardando', 'pix_chave', '2026-11-20 23:00:00+00') returning id into c20;
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_DC', 'value', 30, 'netValue', 30, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', '2026-11-27', 'dueDate', '2026-11-27', 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_DB', 'name', 'Fulano Com Cpf', 'cpfCnpj', '52998224725'));
  select status into st from public.tronco_contribuicoes where id = c20;
  if st <> 'aguardando' then raise exception 'FALHOU: contribuição de 7 dias antes virou Tronco (status %)', st; end if;
  raise notice 'OK tronco_pix_data_brasilia';
  raise exception 'ROLLBACK_OK';
end $$;
