-- Admissão: candidato preenche por link (anon), sindicância sigilosa, placet, iniciação cria o irmão.
do $$
declare
  se uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  l uuid; i_a uuid; i_b uuid; i_c uuid; p uuid; tk text; s_a uuid; s_b uuid; r text := ''; n int; t text; novo uuid;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'ad@t.com', 'authenticated', 'authenticated', now()), (a, 'ada@t.com', 'authenticated', 'authenticated', now()),
    (b, 'adb@t.com', 'authenticated', 'authenticated', now()), (c, 'adc@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'S');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, a, 'Irmão A', 3, 'A1', '2015-01-01', '00000016357', 'i163x9779@teste.com') returning id into i_a;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, b, 'Irmão B', 3, 'B1', '2015-01-01', '00000016438', 'i164x9779@teste.com') returning id into i_b;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, c, 'Irmão C', 1, 'C1', '2024-01-01', '00000016519', 'i165x9779@teste.com') returning id into i_c;
  reset role;
  -- Aprendiz não propõe; Mestre propõe e vira proponente
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.abrir_processo(l, 'iniciacao', 'Fulano'); r := r || 'aprendiz propõe=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz propõe=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  p := public.abrir_processo(l, 'iniciacao', 'João Candidato', 'j@x.com', '11999990000');
  reset role;
  select token into tk from public.processos where id = p;
  -- candidato sem login
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  select count(*) into n from public.processos;
  r := r || format('anon lista processos=%s | ', n);
  perform public.salvar_ficha_candidato(tk, '{"cpf":"123.456.789-00","data_nascimento":"1990-05-01","profissao":"Engenheiro"}', true);
  begin perform public.salvar_ficha_candidato(tk, '{}', false); r := r || 'altera após enviar=PERMITIU (ERRO) | ';
  exception when others then r := r || 'altera após enviar=bloqueado | '; end;
  select tipo || '/' || enviada into t from public.ficha_candidato(tk);
  r := r || format('ficha=%s | ', t);
  reset role;
  -- Venerável designa A? não: A é proponente
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.designar_sindicantes(p, array[i_a]); r := r || 'proponente sindicante=PERMITIU (ERRO) | ';
  exception when others then r := r || 'proponente sindicante=bloqueado | '; end;
  perform public.designar_sindicantes(p, array[i_b]);
  reset role;
  select id into s_b from public.sindicancias where processo_id = p;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.enviar_parecer(s_b, 'favoravel', 'Visitei a família, tudo em ordem.');
  reset role;
  -- proponente vê o processo mas não o parecer
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.sindicancias;
  select coalesce(parecer, 'oculto') into t from public.processo_sindicantes(p);
  r := r || format('proponente lê parecer=%s linhas, andamento=%s | ', n, t);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.processos;
  r := r || format('outro irmão vê processo=%s | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select parecer into t from public.sindicancias where id = s_b;
  r := r || format('Venerável lê=%s | ', t);
  perform public.encerrar_sindicancia(p, true);
  perform public.registrar_placet(p, '123/2026', current_date);
  novo := public.concluir_processo(p, current_date);
  select format('%s grau %s cpf %s cim %s', nome, grau, cpf, coalesce(cim, 'depois')) into t from public.irmaos where id = novo;
  r := r || format('irmão criado=%s | ', t);
  select count(*) into n from public.processo_eventos where processo_id = p;
  r := r || format('eventos=%s', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
