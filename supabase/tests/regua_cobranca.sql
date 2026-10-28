-- Régua: etapas padrão criadas; uma mensagem por irmão por etapa; Tesouraria avisada aos 60 dias; não repete.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; ix uuid; cat uuid; r text := ''; n int; m text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'rg@t.com', 'authenticated', 'authenticated', now()),
    (x, 'rgx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Teste', '9', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select count(*) into n from public.regua_etapas where loja_id = l;
  r := r || format('etapas padrão=%s | ', n);
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, telefone, cpf, email) values (l, x, 'Carlos André Souza', 3, 'R1', '2015-01-01', '12999990000', '00000013927', 'i139x1111@teste.com') returning id into ix;
  update public.irmaos set telefone = '12988887777' where loja_id = l and user_id = t;
  cat := (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao');
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id) values
    (l, 'receber', 'Captação 1/3', cat, 60, current_date + 3, current_date, ix),
    (l, 'receber', 'Taxa GOB', cat, 40, current_date + 3, current_date, ix),
    (l, 'receber', 'Captação 2/3', cat, 60, current_date, current_date, ix),
    (l, 'receber', 'Captação antiga', cat, 100, current_date - 5, current_date, ix),
    (l, 'receber', 'Jóia', cat, 300, current_date - 60, current_date, ix);
  reset role;
  insert into public.integracoes_whatsapp (loja_id, instancia, segredo_id, status) values (l, 'teste', gen_random_uuid(), 'conectado');
  n := public.rodar_regua();
  r := r || format('envios 1ª rodada=%s | ', n);
  select string_agg(format('[%s] %s', (select nome from public.irmaos where id = q.irmao_id), left(replace(q.mensagem, E'\n', ' / '), 140)), ' || ' order by q.criado_em)
    into m from public.notificacoes q where q.loja_id = l;
  r := r || m || ' | ';
  n := public.rodar_regua();
  r := r || format('2ª rodada=%s (esperado 0)', n);
  raise exception 'RESULTADO: %', r;
end $$;
