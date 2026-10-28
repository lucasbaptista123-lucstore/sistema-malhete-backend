-- Biblioteca: ata aprovada é lida pelo irmão do grau; grau acima não; Secretaria tira da Biblioteca.
do $$ declare t uuid := gen_random_uuid(); a uuid := gen_random_uuid(); l uuid; a1 uuid; a3 uuid; r text := ''; n int; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'bm@t.com', 'authenticated', 'authenticated', now()),
    (a, 'bma@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, a, 'Aprendiz A', 1, 'BA', '2025-01-01', '52998224725', 'ba@teste.com');
  insert into public.atas (loja_id, importada, data_sessao, grau, numero, texto) values (l, true, '2025-03-01', 1, 1, 'Ata de Aprendiz') returning id into a1;
  insert into public.atas (loja_id, importada, data_sessao, grau, numero, texto) values (l, true, '2025-04-01', 3, 2, 'Ata de Mestre') returning id into a3;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.atas;
  r := r || format('aprendiz vê atas=%s (esperado 1) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.atas set na_biblioteca = false where id = a1;
  begin update public.atas set texto = 'mudou' where id = a1; r := r || 'altera ata aprovada=PERMITIU (ERRO) | ';
  exception when others then r := r || 'altera ata aprovada=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.atas;
  r := r || format('depois de tirar da Biblioteca=%s (esperado 0)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
