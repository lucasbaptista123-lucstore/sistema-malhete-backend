-- Lembretes diários (0132): sessão que passou e não foi encerrada avisa o Chanceler (e o Venerável do 3º dia em diante),
-- uma vez por dia, até encerrar; prazo do tema lembra, sete dias antes e na véspera, só quem ainda não enviou.
do $$
declare
  v uuid := gen_random_uuid();
  l uuid; i_v uuid; i_ch uuid; i_a uuid; i_b uuid; g uuid; s1 uuid; s2 uuid; s3 uuid; tema uuid; r jsonb; n int; msg text; ok text := '';
begin
  insert into auth.users (id, email, aud, role) values (v, 'ld@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  update public.irmaos set telefone = '11988887777' where id = i_v;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Chanceler Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'ch@teste.com', '11977776666') returning id into i_ch;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Aprendiz Fez', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 60, '00000017752', 'a@teste.com', '11966665555') returning id into i_a;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Aprendiz Nao Fez', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 60, '00000017833', 'b@teste.com', '11955554444') returning id into i_b;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 10, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 10, current_date + 300
    from (values (i_v, 'veneravel'), (i_ch, 'chanceler')) x(i, cargo) join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  -- sessões: ontem (aberta, 1 dia), há 4 dias (aberta, 4 dias), ontem realizada; sessão do futuro não conta
  insert into public.sessoes (loja_id, data, hora, tipo, grau) values (l, private.hoje_sp() - 1, '20:00', 'ordinaria', 1) returning id into s1;
  insert into public.sessoes (loja_id, data, hora, tipo, grau) values (l, private.hoje_sp() - 4, '20:00', 'ordinaria', 1) returning id into s2;
  insert into public.sessoes (loja_id, data, hora, tipo, grau, status) values (l, private.hoje_sp() - 1, '20:00', 'magna', 1, 'realizada') returning id into s3;
  -- tema de Aprendiz com prazo em 7 dias; um aprendiz já enviou
  insert into public.temas_trabalho (loja_id, grau, titulo, prazo) values (l, 1, 'A Pedra Bruta', private.hoje_sp() + 7) returning id into tema;
  -- o aprendiz que já fez envia pelo próprio login (o trabalho é sempre de quem envia)
  insert into auth.users (id, email, aud, role) values (gen_random_uuid(), 'ldap@t.com', 'authenticated', 'authenticated');
  update public.irmaos set user_id = (select id from auth.users where email = 'ldap@t.com') where id = i_a;
  perform set_config('request.jwt.claims', json_build_object('sub', (select id from auth.users where email = 'ldap@t.com'), 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id) values (l, i_a, 1, 'Minha Pedra Bruta', 'texto', tema);
  reset role;

  r := private.lembretes_diarios();

  -- sessão aberta: Chanceler recebe das duas; Venerável só da de 4 dias; a realizada não
  select count(*) into n from public.notificacoes where tipo = 'sessao_aberta' and irmao_id = i_ch and referencia in (s1, s2);
  if n <> 2 then raise exception 'FALHOU: Chanceler recebeu % avisos (esperado 2)', n; end if;
  if exists (select 1 from public.notificacoes where tipo = 'sessao_aberta' and referencia = s3) then raise exception 'FALHOU: avisou sessão realizada'; end if;
  if (select count(*) from public.notificacoes where tipo = 'sessao_aberta' and irmao_id = i_v) <> 1
     or not exists (select 1 from public.notificacoes where tipo = 'sessao_aberta' and irmao_id = i_v and referencia = s2) then
    raise exception 'FALHOU: Venerável devia receber só a de 4 dias';
  end if;
  select mensagem into msg from public.notificacoes where tipo = 'sessao_aberta' and irmao_id = i_ch and referencia = s2;
  if msg !~ 'já são 4 dias' or msg !~ ('/app/chancelaria/sessoes/' || s2 || '$') then raise exception 'FALHOU: texto do aviso: %', msg; end if;
  ok := ok || 'Chanceler avisado, Venerável do 3º dia, realizada fora | ';

  -- rodar de novo no mesmo dia não repete
  r := private.lembretes_diarios();
  if (select count(*) from public.notificacoes where tipo = 'sessao_aberta' and referencia in (s1, s2)) <> 3 then raise exception 'FALHOU: repetiu no mesmo dia'; end if;
  ok := ok || 'uma vez por dia | ';

  -- prazo do tema: só quem não enviou
  if not exists (select 1 from public.notificacoes where tipo = 'prazo_tema' and irmao_id = i_b and referencia = tema and mensagem ~ 'em sete dias') then raise exception 'FALHOU: quem não enviou não foi lembrado'; end if;
  if exists (select 1 from public.notificacoes where tipo = 'prazo_tema' and irmao_id = i_a) then raise exception 'FALHOU: lembrou quem já enviou: % / trabalhos dele: %', (select string_agg(mensagem || ' ref=' || referencia, ' ; ') from public.notificacoes where tipo = 'prazo_tema' and irmao_id = i_a), (select string_agg(coalesce(tema_id::text,'sem tema') || ' grau ' || grau, ',') from public.trabalhos where irmao_id = i_a); end if;
  if (select count(*) from public.notificacoes where tipo = 'prazo_tema' and referencia = tema) <> 1 then raise exception 'FALHOU: lembrou gente de outro grau'; end if;
  ok := ok || 'prazo lembra só quem não enviou | ';

  -- Loja desliga: nada novo
  insert into public.avisos_config (loja_id, sessao_aberta, prazo_tema) values (l, false, false)
    on conflict (loja_id) do update set sessao_aberta = false, prazo_tema = false;
  delete from public.notificacoes where tipo in ('sessao_aberta', 'prazo_tema') and loja_id = l;
  r := private.lembretes_diarios();
  if exists (select 1 from public.notificacoes where tipo in ('sessao_aberta', 'prazo_tema') and loja_id = l) then raise exception 'FALHOU: avisou com a chave desligada'; end if;
  ok := ok || 'chave da Loja desliga';

  raise exception 'OK: %', ok;
end $$;
