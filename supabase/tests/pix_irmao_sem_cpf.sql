-- PIX na chave da Loja de irmão sem CPF no cadastro (caso Marcos, 09/11) e o "É uma conta" para a conta
-- automática do Asaas. Mais o acesso total por exceção (admin_total).
-- A) "Marcos de Oliveira" sem CPF paga mensalidade atrasada + encargos; o Asaas manda "Marcos De Oliveira" com CPF:
--    reconhece pelo nome, dá baixa na conta dele, grava o cliente do Asaas no irmão, sem conta automática.
-- B) Pagador com outro nome (esposa): vira conta automática de favorecido; "É uma conta" leva o recebimento
--    para a mensalidade do irmão, cancela a automática, saldo não muda, nova varredura não lança nada.
-- C) Homônimo com CPF diferente no cadastro: não é ele.
-- D) admin_total: administrador sem grau passa a ter graus.editar; pela tela não se liga.
do $$ declare
  t uuid := gen_random_uuid(); u uuid := gen_random_uuid(); l uuid; cx uuid; cat uuid;
  im uuid; ifa uuid; ih uuid; tm uuid; tf uuid; th uuid; v numeric; lb uuid; auto uuid; s0 numeric; s1 numeric;
  n0 int; n1 int; r text; g0 boolean; g1 boolean; erro text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'tpix@t.com', 'authenticated', 'authenticated', now()), (u, 'upix@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  perform set_config('request.jwt.claims', '', true);   -- daqui em diante: webhook (sem usuário)
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao) values
    (l, 'Marcos de Oliveira', 3, '1', '2020-01-01', 'ativo') returning id into im;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao) values
    (l, 'Fábio da Conceição Lima', 3, '2', '2020-01-01', 'ativo') returning id into ifa;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, cpf) values
    (l, 'Carlos Homonimo', 3, '3', '2020-01-01', 'ativo', '11144477735') returning id into ih;
  perform set_config('malhete.sistema', 'off', true);
  select id into cat from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades';
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'MENSALIDADE ATRASADA MARCOS', cat, im, 250, current_date - 20, current_date - 20) returning id into tm;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'MENSALIDADE FABIO', cat, ifa, 250, current_date - 5, current_date - 5) returning id into tf;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia)
    values (l, 'receber', 'MENSALIDADE CARLOS', cat, ih, 250, current_date - 5, current_date - 5) returning id into th;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');

  -- A
  v := 250 + private.encargos(l, 250, current_date - 20);
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_A', 'value', v, 'netValue', v, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_A', 'name', 'Marcos De Oliveira', 'cpfCnpj', '531.757.001-87'));
  if (select valor_pago from public.titulos where id = tm) <> 250
     or (select asaas_cliente_id from public.irmaos where id = im) is distinct from 'cus_A'
     or exists (select 1 from public.titulos where loja_id = l and asaas_id = 'pay_A' and id <> tm) then
    raise exception 'FALHOU A: % pago=% cliente=%', r, (select valor_pago from public.titulos where id = tm),
      (select asaas_cliente_id from public.irmaos where id = im);
  end if;

  -- C (homônimo com CPF diferente)
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_C', 'value', 250, 'netValue', 250, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_C', 'name', 'Carlos Homonimo', 'cpfCnpj', '52998224725'));
  if (select valor_pago from public.titulos where id = th) <> 0 then raise exception 'FALHOU C: baixou o homônimo'; end if;

  -- B
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_B', 'value', 250, 'netValue', 250, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_B', 'name', 'Maria Esposa Lima', 'cpfCnpj', '39053344705'));
  select id into auto from public.titulos where loja_id = l and asaas_id = 'pay_B';
  select id into lb from public.lancamentos where titulo_id = auto and estorno_de is null;
  if auto is null or lb is null then raise exception 'FALHOU B (montagem): % auto=% lanc=%', r, auto, lb; end if;
  select saldo into s0 from public.contas_saldo where conta_id = cx;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if not exists (select 1 from public.sugestoes_para_lancamento(lb) s where s.titulo_id = tf) then
    raise exception 'FALHOU B: a mensalidade do Fábio não aparece nas sugestões';
  end if;
  perform public.vincular_lancamento_titulo(lb, tf);
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select saldo into s1 from public.contas_saldo where conta_id = cx;
  select count(*) into n0 from public.lancamentos where loja_id = l;
  r := public.asaas_espelhar_pagamento(l, 'VARREDURA',
    jsonb_build_object('id', 'pay_B', 'value', 250, 'netValue', 250, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_B', 'name', 'Maria Esposa Lima', 'cpfCnpj', '39053344705'));
  select count(*) into n1 from public.lancamentos where loja_id = l;
  if (select valor_pago from public.titulos where id = tf) <> 250 or not (select cancelado from public.titulos where id = auto)
     or s1 <> s0 or n1 <> n0 or (select asaas_cliente_id from public.irmaos where id = ifa) is distinct from 'cus_B' then
    raise exception 'FALHOU B: fabio pago=% auto cancelado=% saldo %→% lancs %→% (%) cliente=%',
      (select valor_pago from public.titulos where id = tf), (select cancelado from public.titulos where id = auto),
      s0, s1, n0, n1, r, (select asaas_cliente_id from public.irmaos where id = ifa);
  end if;

  -- D (admin_total)
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, user_id, admin_loja, admin_implantacao)
    values (l, 'Admin Excecao', 3, '9', '2020-01-01', 'ativo', u, true, false);
  -- Venerável nomeado (ocupa graus.editar): o administrador comum fica sem essa permissão
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 30, current_date + 700);
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, (select id from public.gestoes where loja_id = l), im,
           (select id from public.loja_cargos where loja_id = l and codigo = 'veneravel'), current_date - 30, current_date + 700;
  perform set_config('malhete.sistema', 'off', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  g0 := public.tem_permissao(l, 'graus.editar');
  begin
    update public.irmaos set admin_total = true where user_id = u and loja_id = l;
    erro := 'ligou pela tela';
  exception when others then erro := null;
  end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  update public.irmaos set admin_total = true where user_id = u and loja_id = l;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  g1 := public.tem_permissao(l, 'graus.editar');
  update public.irmaos set grau = 2 where id = ifa;
  reset role;
  if g0 or not g1 or erro is not null or (select grau from public.irmaos where id = ifa) <> 2 then
    raise exception 'FALHOU D: antes=% depois=% tela=% grau=%', g0, g1, erro, (select grau from public.irmaos where id = ifa);
  end if;

  raise exception 'OK: A baixa pelo nome (% com encargos), C homônimo intacto, B religado (saldo %→%, varredura sem lançar), D graus antes=% depois=%',
    v, s0, s1, g0, g1;
end $$;
