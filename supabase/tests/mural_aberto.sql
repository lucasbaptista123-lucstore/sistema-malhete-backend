-- Mural aberto: irmão sem cargo publica no próprio grau; não publica acima do grau, não fixa, não manda WhatsApp;
-- apaga o próprio; não apaga o dos outros; Venerável apaga qualquer um.
do $$
declare vm uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); me uuid := gen_random_uuid(); l uuid; i_ap uuid; i_me uuid; m1 uuid; m2 uuid; r text := ''; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'mvm@t.com', 'authenticated', 'authenticated', now()), (ap, 'map@t.com', 'authenticated', 'authenticated', now()), (me, 'mme@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Mural', '4', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Aprendiz Silva', 1, 'MU1', '2025-01-01', '39053344705', 'map@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, me, 'Mestre Souza', 3, 'MU2', '2015-01-01', '86288366757', 'mme@teste.com') returning id into i_me;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.mural (loja_id, titulo, texto, grau_minimo) values (l, 'Carona para a sessão', 'Saio do centro às 19h', 1) returning id into m1;
  r := r || format('aprendiz publica=ok (autor=%s) | ', (select nome from public.irmaos where id = (select autor_id from public.mural where id = m1)));
  begin insert into public.mural (loja_id, titulo, grau_minimo) values (l, 'Só Mestres', 3); r := r || 'publica acima do grau=PERMITIU (ERRO) | ';
  exception when others then r := r || 'publica acima do grau=bloqueado | '; end;
  begin insert into public.mural (loja_id, titulo, grau_minimo, fixado) values (l, 'Fixado', 1, true); r := r || 'fixa=PERMITIU (ERRO) | ';
  exception when others then r := r || 'fixa=bloqueado | '; end;
  begin perform public.mural_whatsapp(m1); r := r || 'manda WhatsApp=PERMITIU (ERRO) | ';
  exception when others then r := r || 'manda WhatsApp=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.mural (loja_id, titulo, grau_minimo) values (l, 'Livro para doar', 1) returning id into m2;
  delete from public.mural where id = m1; get diagnostics n = row_count;
  r := r || format('mestre apaga o do aprendiz=%s linhas | ', n);
  delete from public.mural where id = m2; get diagnostics n = row_count;
  r := r || format('mestre apaga o próprio=%s | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  delete from public.mural where id = m1; get diagnostics n = row_count;
  r := r || format('Venerável apaga o do aprendiz=%s', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
