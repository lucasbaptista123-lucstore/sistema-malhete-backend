-- Saldo inicial na 1ª sincronização do Asaas: recebimento de cobrança que fica pendente de conciliação
-- (referência de pagamento, sem conta aberta) não pode entrar duas vezes no saldo depois de conciliado.
-- Caso real (Orvalho, 04/11): saldo Asaas 1.094,03; extrato +48 (pendente), +250, -500, -1,99, -0,99.
do $$ declare t uuid := gen_random_uuid(); l uuid; cx uuid; j jsonb; s1 numeric; s2 numeric; r text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tsi@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  -- o +250 já virou lançamento pelo espelho da cobrança; o +48 ficou pendente
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
  values (l, cx, (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 'receita', 250, current_date, current_date, 'PIX', 'pay_b');
  insert into public.extrato_itens (loja_id, conta_id, origem, id_externo, data, valor, descricao, referencia_externa, situacao, lancamento_id) values
    (l, cx, 'asaas', 'ft_a', current_date, 48, 'Cobrança recebida', 'pay_a', 'pendente', null),
    (l, cx, 'asaas', 'ft_b', current_date, 250, 'Cobrança recebida', 'pay_b', 'conciliado', (select id from public.lancamentos where documento = 'pay_b' and loja_id = l)),
    (l, cx, 'asaas', 'ft_c', current_date, -500, 'Transação via Pix', null, 'pendente', null),
    (l, cx, 'asaas', 'ft_d', current_date, -1.99, 'Taxa de boleto', 'pay_a', 'pendente', null),
    (l, cx, 'asaas', 'ft_e', current_date, -0.99, 'Taxa de mensageria', 'pay_a', 'pendente', null);
  j := public.asaas_concluir_sincronizacao(l, 1094.03, true);
  select saldo into s1 from public.contas_saldo where conta_id = cx;
  -- Tesoureiro concilia o +48 depois (lançamento novo)
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
  values (l, cx, (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 'receita', 48, current_date, current_date, 'conciliado à mão', 'ft_a');
  select saldo into s2 from public.contas_saldo where conta_id = cx;
  r := format('antes de conciliar=%s (esperado 1046.03) | depois=%s (esperado 1094.03)', s1, s2);
  if s2 <> 1094.03 then raise exception 'FALHOU: %', r; end if;
  raise exception 'OK: %', r;
end $$;
