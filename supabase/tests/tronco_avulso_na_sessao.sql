-- PIX do Tronco pago à mão entra no total da sessão (0124, 14/11): irmão com CPF paga digitando a chave depois da
-- sessão de ontem; "É do Tronco" lança no Tronco e soma na sessão (contribuição anônima, sem irmão); sessão cancelada
-- e sessão de mais de 7 dias não contam.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; cx uuid; ic uuid; s1 uuid; s0 uuid; ld uuid; r jsonb;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tav@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, cpf) values
    (l, 'Carlos Com Cpf', 3, '9', '2020-01-01', 'ativo', '11144477735') returning id into ic;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  insert into public.sessoes (loja_id, tipo, grau, data, hora, status) values (l, 'ordinaria', 1, current_date - 1, '20:00', 'realizada') returning id into s1;
  insert into public.sessoes (loja_id, tipo, grau, data, hora, status, motivo_cancelamento) values (l, 'ordinaria', 1, current_date, '20:00', 'cancelada', 'x') returning id into s0;

  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_A', 'value', 130, 'netValue', 130, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_A', 'name', 'Carlos Com Cpf', 'cpfCnpj', '111.444.777-35'));
  select id into ld from public.lancamentos where loja_id = l and documento = 'pay_A' and estorno_de is null;

  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.tronco_e_do_tronco(ld);
  r := public.tronco_da_sessao(s1);
  reset role;
  if (r->'recebido'->>'valor')::numeric <> 130 or (r->'recebido'->>'quantidade')::int <> 1 then
    raise exception 'FALHOU: não somou na sessão de ontem: %', r->'recebido';
  end if;
  if exists (select 1 from public.tronco_contribuicoes c join public.tronco_sessoes ts on ts.id = c.tronco_sessao_id
             where ts.sessao_id = s0) then
    raise exception 'FALHOU: somou na sessão cancelada';
  end if;
  if exists (select 1 from public.tronco_contribuicoes where loja_id = l and irmao_id is not null) then
    raise exception 'FALHOU: contribuição avulsa com irmão';
  end if;
  raise exception 'OK: PIX pago à mão entra no total da sessão (anônimo; sessão cancelada não conta)';
end $$;
