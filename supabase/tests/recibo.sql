-- Recibo: o irmão gera o do próprio título pago; outro irmão não; título em aberto não tem recibo.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); y uuid := gen_random_uuid();
  l uuid; cx uuid; ix uuid; tit uuid; tit2 uuid; r text := ''; j jsonb; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'rc@t.com', 'authenticated', 'authenticated', now()),
    (x, 'rcx@t.com', 'authenticated', 'authenticated', now()), (y, 'rcy@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 3, 'RX', '2015-01-01', '52998224725', 'i172x4871@teste.com') returning id into ix;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, y, 'Irmão Y', 3, 'RY', '2015-01-01', '00000017329', 'i173x4871@teste.com');
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id)
  values (l, 'receber', 'Captação 1/2', (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao'), 150, current_date, current_date, ix) returning id into tit;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id)
  values (l, 'receber', 'Captação 2/2', (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao'), 150, current_date + 30, current_date + 30, ix) returning id into tit2;
  perform public.baixar_titulo(tit, cx, current_date);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  j := public.recibo_titulo(tit);
  r := r || format('irmão: %s pago %s em %s pagamento(s), quitado=%s, cpf=%s | ', j->>'descricao', j->>'valor_pago', jsonb_array_length(j->'pagamentos'), j->>'quitado', j#>>'{irmao,cpf}');
  begin perform public.recibo_titulo(tit2); r := r || 'em aberto=PERMITIU (ERRO) | ';
  exception when others then r := r || 'em aberto=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', y, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.recibo_titulo(tit); r := r || 'outro irmão=PERMITIU (ERRO)';
  exception when others then r := r || 'outro irmão=bloqueado'; end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
