-- Saldo do Tronco e auxílio pago pelo Asaas (0125, 14/11, caso Euclides/Lar dos meninos e meninas).
-- Tronco: R$ 50 no saco (conta Tronco) + R$ 420 de PIX no Asaas (categoria Tronco) = R$ 470.
-- A) saldo do Tronco é o fundo (R$ 470), não o saldo da conta Tronco (R$ 50).
-- B) auxílio de R$ 470 pago "pelo Tronco" E por PIX no Asaas (duplicidade): trocar pelo PIX do Asaas exclui o lançamento
--    próprio, classifica o PIX como Beneficência; saldo do Tronco = 0, conta Tronco volta a R$ 50.
-- C) "já paguei": outro auxílio usa direto a saída do Asaas, sem lançar outra.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; cx uuid; ctr uuid; cat_t uuid; cat_s uuid; a1 uuid; a2 uuid; pix1 uuid; pix2 uuid; r jsonb; c jsonb;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tsa2@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  select id into ctr from public.contas_financeiras where loja_id = l and tipo = 'tronco' and ativa;
  select id into cat_t from public.categorias_financeiras where loja_id = l and codigo = 'tronco';
  insert into public.categorias_financeiras (loja_id, codigo, nome, tipo, grupo) values (l, 'saida_teste', 'Saída a classificar', 'despesa', 'outras_despesas') returning id into cat_s;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao) values
    (l, ctr, cat_t, 'receita', 50, current_date, 'Tronco (dinheiro)'),
    (l, cx, cat_t, 'receita', 420, current_date, 'Tronco (PIX)');
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao)
    values (l, cx, cat_s, 'despesa', 470, current_date, 'Asaas: Transação via Pix com chave para Euclides') returning id into pix1;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao)
    values (l, cx, cat_s, 'despesa', 80, current_date, 'Asaas: Transação via Pix para Lar') returning id into pix2;
  insert into public.auxilios (loja_id, beneficiario, valor, motivo, solicitado_por) values (l, 'Lar dos meninos', 470, 'Ajuda', t) returning id into a1;
  insert into public.auxilios (loja_id, beneficiario, valor, motivo, solicitado_por) values (l, 'Lar 2', 80, 'Ajuda', t) returning id into a2;

  set local role authenticated;
  -- A
  r := public.tronco_saldo(l);
  if (r->>'saldo')::numeric <> 470 then raise exception 'FALHOU A: %', r; end if;
  -- B: pagou pelo Tronco (como antes) e também pelo Asaas
  perform public.decidir_auxilio(a1, true);
  c := public.auxilio_saidas_candidatas(a1);
  if jsonb_array_length(c) <> 1 or (c->0->>'id')::uuid <> pix1 then raise exception 'FALHOU B candidatas: %', c; end if;
  perform public.auxilio_trocar_lancamento(a1, pix1);
  r := public.tronco_saldo(l);
  reset role;
  if (r->>'saldo')::numeric <> 0 or (r->>'auxilios')::numeric <> 470 then raise exception 'FALHOU B saldo: %', r; end if;
  if (select saldo from public.contas_saldo where conta_id = ctr) <> 50 then raise exception 'FALHOU B: conta Tronco = %', (select saldo from public.contas_saldo where conta_id = ctr); end if;
  if (select lancamento_id from public.auxilios where id = a1) <> pix1
     or (select k.codigo from public.lancamentos x join public.categorias_financeiras k on k.id = x.categoria_id where x.id = pix1) <> 'beneficencia' then
    raise exception 'FALHOU B: auxílio não ficou com o PIX';
  end if;
  -- C
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_auxilio(a2, true, null, current_date, null, pix2);
  reset role;
  if (select lancamento_id from public.auxilios where id = a2) <> pix2
     or (select count(*) from public.lancamentos where loja_id = l and valor = 80 and tipo = 'despesa') <> 1 then
    raise exception 'FALHOU C';
  end if;
  raise exception 'OK: saldo do Tronco é o fundo; auxílio pago pelo Asaas sem duplicar; "já paguei" usa a saída existente';
end $$;
