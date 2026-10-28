-- Trabalho programado para o tempo de estudos: só aprovado; autor avisado; sessão lista o trabalho.
do $$
declare
  v uuid := gen_random_uuid(); v2 uuid := gen_random_uuid(); ap uuid := gen_random_uuid();
  l uuid; i_v uuid; i_v2 uuid; i_ap uuid; g uuid; t1 uuid; t2 uuid; s1 uuid; s2 uuid; s3 uuid; r text := ''; n int; x text;
begin
  insert into auth.users (id, email, aud, role) values (v, 'tsv@t.com', 'authenticated', 'authenticated'),
    (v2, 'tsv2@t.com', 'authenticated', 'authenticated'), (ap, 'tsap@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v2, 'Segundo Vigilante', 3, 'TS2', current_date - 400, '52998224725', 'ts2@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Pedro Aprendiz', 1, 'TS3', current_date - 100, '11144477735', 'ts3@teste.com') returning id into i_ap;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v2, 'segundo_vigilante')) x(i, cargo) join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  insert into public.sessoes (loja_id, tipo, grau, data, hora) values (l, 'ordinaria', 1, current_date + 20, '20:00') returning id into s1;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 2, current_date + 25) returning id into s2;
  insert into public.sessoes (loja_id, tipo, finalidade, grau, data) values (l, 'magna', 'Iniciação', 1, current_date + 30) returning id into s3;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_ap, 1, 'A Pedra Bruta', 'texto') returning id into t1;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_ap, 1, 'Rascunho', 'texto') returning id into t2;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'aprovado' where id = t1;
  begin update public.trabalhos set lido_em_sessao_id = s1 where id = t2; r := r || 'não aprovado na sessão=PERMITIU (ERRO) | ';
  exception when others then r := r || 'não aprovado na sessão=bloqueado | '; end;
  begin update public.trabalhos set lido_em_sessao_id = s2 where id = t1; r := r || 'aprendiz em sessão de companheiro=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz em sessão de companheiro=bloqueado | '; end;
  begin update public.trabalhos set lido_em_sessao_id = s3 where id = t1; r := r || 'aprendiz em magna=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz em magna=bloqueado | '; end;
  update public.trabalhos set lido_em_sessao_id = s1 where id = t1;
  reset role;
  select left(mensagem, 140) into x from public.notificacoes where irmao_id = i_ap and mensagem like '%programado%';
  r := r || format('aviso ao autor=%s | ', x);
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(titulo || ' / ' || autor, ', ') into x from public.trabalhos_da_sessao(s1);
  r := r || format('tempo de estudos=%s', x);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
