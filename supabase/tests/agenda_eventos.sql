-- Agenda: Aprendiz não vê evento de Mestre; irmão confirma com acompanhantes e muda; só organizador vê a lista.
do $$ declare t uuid := gen_random_uuid(); a uuid := gen_random_uuid(); m uuid := gen_random_uuid();
  l uuid; e1 uuid; e2 uuid; r text := ''; n int; s text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'ev@t.com', 'authenticated', 'authenticated', now()),
    (a, 'eva@t.com', 'authenticated', 'authenticated', now()), (m, 'evm@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, a, 'Aprendiz A', 1, 'EA', '2025-01-01', '00000012360', 'i123x5944@teste.com'), (l, m, 'Mestre M', 3, 'EM', '2015-01-01', '00000012440', 'i124x5944@teste.com');
  insert into public.eventos (loja_id, titulo, data, familia) values (l, 'Jantar de fim de ano', current_date + 20, true) returning id into e1;
  insert into public.eventos (loja_id, titulo, data, grau_minimo) values (l, 'Palestra de Mestres', current_date + 10, 3) returning id into e2;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.eventos;
  r := r || format('aprendiz vê eventos=%s (esperado 1) | ', n);
  perform public.responder_evento(e1, true, 2);
  perform public.responder_evento(e1, true, 3);
  select format('%s/%s', vai, acompanhantes) into s from public.evento_respostas where evento_id = e1;
  r := r || format('resposta=%s | ', s);
  begin insert into public.eventos (loja_id, titulo, data) values (l, 'X', current_date); r := r || 'aprendiz cria=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz cria=bloqueado | '; end;
  select count(*) into n from public.evento_lista(e1);
  r := r || format('aprendiz vê lista=%s | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.responder_evento(e1, false);
  select count(*) into n from public.evento_respostas;
  r := r || format('mestre vê respostas dos outros=%s (esperado 1, só a dele) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(nome || ':' || vai || '+' || acompanhantes, ', ') into s from public.evento_lista(e1);
  r := r || format('organizador vê=%s', s);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
