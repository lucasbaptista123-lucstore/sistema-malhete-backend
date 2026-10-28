-- PIX na chave com multa e juros: mensalidade vencida há 30 dias (R$ 100, multa 2%, juros 1% a.m.) paga com R$ 103.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; cx uuid; ix uuid; r text := ''; s text;
  cli jsonb := '{"id":"cus_y","name":"Irmão Atrasado","cpfCnpj":"52998224725"}';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'pe@t.com', 'authenticated', 'authenticated', now()),
    (x, 'pex@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Atrasado', 3, 'PE', '2015-01-01', '52998224725', 'pe@teste.com') returning id into ix;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id) values
    (l, 'receber', 'Mensalidade 09/2026', (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 100, current_date - 30, current_date - 30, ix);
  reset role;
  insert into public.tesouraria_config (loja_id, multa_percentual, juros_mensal) values (l, 2, 1)
    on conflict (loja_id) do update set multa_percentual = 2, juros_mensal = 1;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final, criado_em) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx', now() - interval '1 day');
  r := r || format('valor atualizado=%s | ', 100 + private.encargos(l, 100, current_date - 30));
  s := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED', jsonb_build_object('id', 'pay_e', 'value', 103, 'netValue', 103, 'status', 'RECEIVED', 'paymentDate', current_date::text, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'), cli);
  r := r || format('PIX 103=%s | ', s);
  select case when valor_pago >= valor then 'paga' else 'aberta' end into s from public.titulos where irmao_id = ix;
  r := r || format('mensalidade=%s | lançado=%s', s, (select sum(valor) from public.lancamentos where documento = 'pay_e'));
  raise exception 'RESULTADO: %', r;
end $$;
