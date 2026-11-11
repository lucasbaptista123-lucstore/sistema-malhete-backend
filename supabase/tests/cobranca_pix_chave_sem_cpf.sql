-- Irmão sem CPF recebe a cobrança com o PIX da chave da Loja (0116, 09/11).
-- A) conta nova de irmão SEM CPF (Asaas criando cobranças): aviso sai na hora, com botões.
-- B) conta nova de irmão COM CPF: não avisa na criação (espera a cobrança do Asaas, como antes).
-- C) botão "Pagar com PIX": devolve chave, titular e valor atualizado.
-- D) "Enviar cobrança" do Tesoureiro aceita conta sem cobrança no Asaas.
-- E) o PIX cai no nome dele: baixa e o CPF do pagador fica no cadastro.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; cx uuid; cat uuid; isem uuid; icom uuid; ts uuid; tc uuid;
  nA int; nB int; b text[]; p jsonb; nD int; r text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tcob@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'Sao Paulo', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone) values
    (l, 'Marcos de Oliveira', 3, '1', '2020-01-01', 'ativo', '11999990001') returning id into isem;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone, cpf) values
    (l, 'Joao Com Cpf', 3, '2', '2020-01-01', 'ativo', '11999990002', '11144477735') returning id into icom;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.tesouraria_config (loja_id, pix_chave, pix_titular) values (l, 'tesouraria@loja.org', 'Loja Teste')
    on conflict (loja_id) do update set pix_chave = excluded.pix_chave, pix_titular = excluded.pix_titular;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final, criar_cobrancas)
    values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx', true);
  select id into cat from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades';
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
    values (l, 'receber', 'Mensalidade 12/2026', cat, isem, 250, current_date + 5, current_date, 'mensalidade') returning id into ts;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
    values (l, 'receber', 'Mensalidade 12/2026', cat, icom, 250, current_date + 5, current_date, 'mensalidade') returning id into tc;
  select count(*), max(botoes) into nA, b from public.notificacoes where referencia = ts and tipo = 'cobranca';
  select count(*) into nB from public.notificacoes where referencia = tc and tipo = 'cobranca';
  if nA <> 1 or b is null then raise exception 'FALHOU A: avisos=% botoes=%', nA, b; end if;
  if nB <> 0 then raise exception 'FALHOU B: avisou antes da cobrança do Asaas'; end if;

  p := public.whatsapp_pagamento(l, '5511999990001',
         (select token from public.notificacoes where referencia = ts and tipo = 'cobranca'));
  if p->>'chave' <> 'tesouraria@loja.org' or (p->'titulos'->0->>'atualizado')::numeric <> 250 or p->>'titular' <> 'Loja Teste' then
    raise exception 'FALHOU C: %', p;
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.avisar_cobranca(ts);
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select count(*) into nD from public.notificacoes where referencia = ts and tipo = 'cobranca' and botoes is not null;
  if nD <> 2 then raise exception 'FALHOU D: avisos com botão=%', nD; end if;

  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_E', 'value', 250, 'netValue', 250, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_E', 'name', 'MARCOS DE OLIVEIRA', 'cpfCnpj', '531.757.001-87'));
  if (select valor_pago from public.titulos where id = ts) <> 250
     or (select cpf from public.irmaos where id = isem) is distinct from '53175700187' then
    raise exception 'FALHOU E: % pago=% cpf=%', r, (select valor_pago from public.titulos where id = ts), (select cpf from public.irmaos where id = isem);
  end if;
  raise exception 'OK: A aviso com botões=% | B com CPF espera o Asaas | C chave=% valor=% | D reenviar ok | E %, CPF gravado',
    b, p->>'chave', p->'titulos'->0->>'atualizado', r;
end $$;
