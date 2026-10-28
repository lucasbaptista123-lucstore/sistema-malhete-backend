-- Atas: importação de antigas, liberação para leitura, confirmação pelo irmão do grau.
do $$
declare
  se uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); me uuid := gen_random_uuid();
  l uuid; i_ap uuid; i_me uuid; a1 uuid; a3 uuid; r text := ''; n int; s text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'al@t.com', 'authenticated', 'authenticated', now()), (ap, 'ala@t.com', 'authenticated', 'authenticated', now()),
    (me, 'alm@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'S');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, 'AL1', '2025-01-01', '00000017400', 'i174x9593@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, me, 'Irmão Mestre', 3, 'AL2', '2015-01-01', '00000017590', 'i175x9593@teste.com') returning id into i_me;
  insert into public.atas (loja_id, grau, data_sessao, numero_original, texto) values (l, 1, '2024-03-10', '1.234', 'Ata antiga de aprendiz') returning id into a1;
  insert into public.atas (loja_id, grau, data_sessao, numero_original, texto) values (l, 3, '2024-03-17', '1.235', 'Ata antiga de mestre') returning id into a3;
  select string_agg(status || '/' || importada, ',') into s from public.atas where loja_id = l;
  r := r || format('importadas=%s | ', s);
  update public.atas set para_leitura = true where loja_id = l;
  r := r || 'liberar aprovada=ok | ';
  begin update public.atas set texto = 'mudei' where id = a1; r := r || 'editar aprovada=PERMITIU (ERRO) | ';
  exception when others then r := r || 'editar aprovada=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.atas where loja_id = l;
  r := r || format('aprendiz vê=%s (esperado 1) | ', n);
  perform public.confirmar_leitura_ata(a1);
  begin perform public.confirmar_leitura_ata(a3); r := r || 'aprendiz lê ata de mestre=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz lê ata de mestre=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.atas where loja_id = l;
  r := r || format('mestre vê=%s (esperado 2) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.ata_leituras where ata_id = a1;
  r := r || format('secretário vê leituras=%s (esperado 1)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
