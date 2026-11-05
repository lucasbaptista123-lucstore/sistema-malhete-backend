-- Gerar mensalidades escolhendo irmãos; isento não entra no "todos"; só a Tesouraria marca isento.
do $$ declare t uuid := gen_random_uuid(); l uuid; a uuid; b uuid; c uuid; r text := ''; n int; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tme@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao) values (l, 'Irmão Ana Silva', 3, 'E1', '2015-01-01') returning id into a;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao) values (l, 'Irmão Beto Silva', 3, 'E2', '2015-01-01') returning id into b;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao) values (l, 'Irmão Caio Silva', 3, 'E3', '2015-01-01') returning id into c;
  n := public.gerar_mensalidades(l, '2026-12-01', 100, '2026-12-10', array[a, b]);
  r := r || format('escolhidos=%s (esperado 2) | Caio tem=%s (esperado 0) | ', n, (select count(*) from public.titulos where irmao_id = c));
  perform public.definir_isento_mensalidade(c, true, 'Remido');
  n := public.gerar_mensalidades(l, '2027-01-01', 100, '2027-01-10');
  r := r || format('todos sem isento=%s (esperado 3: fundador, Ana, Beto) | Caio tem=%s (esperado 0) | ', n, (select count(*) from public.titulos where irmao_id = c));
  n := public.gerar_mensalidades(l, '2027-01-01', 100, '2027-01-10', array[c]);
  r := r || format('isento escolhido à mão=%s (esperado 1) | ', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
