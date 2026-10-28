-- Chancelaria e Secretaria: quem faz o quê, presença por grau, frequência, atas, expediente, envios.
do $$
declare
  v uuid := gen_random_uuid(); -- Venerável (cadastrou a loja)
  ch uuid := gen_random_uuid(); -- Chanceler
  se uuid := gen_random_uuid(); -- Secretário
  ap uuid := gen_random_uuid(); -- Aprendiz
  l uuid; i_v uuid; i_ch uuid; i_se uuid; i_ap uuid; i_m uuid; g uuid;
  s1 uuid; s2 uuid; s3 uuid; v_ata uuid; v_env uuid; v_dest uuid;
  r text := ''; n int; t text; x numeric;
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'v@t.com', 'authenticated', 'authenticated'), (ch, 'ch@t.com', 'authenticated', 'authenticated'),
    (se, 'se@t.com', 'authenticated', 'authenticated'), (ap, 'ap@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ch, 'Irmão Chanceler', 3, '(12) 99999-0001', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012521', 'i125x9534@teste.com') returning id into i_ch;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, se, 'Irmão Secretário', 3, '12 99999-0002', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012602', 'i126x9534@teste.com') returning id into i_se;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, data_nascimento, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, '1299990003', make_date(1990, extract(month from current_date)::int, 5), 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012793', 'i127x9534@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Mestre sem telefone', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012874', 'i128x9534@teste.com') returning id into i_m;
  insert into public.familiares (loja_id, irmao_id, nome, parentesco, data_nascimento) values (l, i_ap, 'Cunhada', 'esposa', make_date(1992, extract(month from current_date)::int, 9));
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 60, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.irmao, c.id, current_date - 60, current_date + 300
    from (values (i_v, 'veneravel'), (i_ch, 'chanceler'), (i_se, 'secretario')) x(irmao, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;
  set local role authenticated;

  -- ---- Venerável: agenda e convoca; não registra presença nem escreve ata
  insert into public.sessoes (loja_id, tipo, grau, data, pauta) values (l, 'ordinaria', 1, current_date - 14, 'Expediente') returning id into s1;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date - 7) returning id into s2;
  insert into public.sessoes (loja_id, tipo, finalidade, grau, data) values (l, 'magna', 'Exaltação', 3, current_date + 7) returning id into s3;
  r := r || 'Venerável agenda=ok | ';
  v_env := public.criar_envio(l, 'convocacao', 'Prezado irmão, reunião dia X.', s3);
  select count(*) filter (where status = 'pendente') || '/' || count(*) filter (where status = 'sem_telefone') into t from public.envio_destinatarios where envio_id = v_env;
  r := r || format('convocação grau 3: pendentes/sem telefone=%s (esperado 2/2: V e M sem tel.) | ', t);
  begin
    insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s1, i_ap, 'presente');
    r := r || 'Venerável marca presença=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Venerável marca presença=bloqueado | ';
  end;
  begin
    insert into public.atas (loja_id, sessao_id, texto) values (l, s1, 'x');
    r := r || 'Venerável escreve ata=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Venerável escreve ata=bloqueado | ';
  end;

  -- ---- Chanceler: presença, visitante, sessão realizada
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s1, i_ap, 'presente'), (l, s1, i_ch, 'presente');
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao, justificativa) values (l, s2, i_ap, 'justificada', 'Viagem');
  update public.sessoes set status = 'realizada' where id in (s1, s2);
  insert into public.visitantes (loja_id, sessao_id, nome, grau, loja_origem, numero_loja, potencia) values (l, s1, 'Visitante', 3, 'Loja Y', '123', 'GOB');
  r := r || 'Chanceler registra presença e visitante=ok | ';
  begin
    insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s3, i_ap, 'presente');
    r := r || 'aprendiz em sessão de grau 3=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz em sessão de grau 3=bloqueado | ';
  end;
  begin
    insert into public.atas (loja_id, sessao_id, texto) values (l, s1, 'x');
    r := r || 'Chanceler escreve ata=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Chanceler escreve ata=bloqueado | ';
  end;
  select percentual into x from public.frequencia(l, extract(year from current_date)::int) where irmao_id = i_ap;
  r := r || format('frequência do aprendiz=%s%% (esperado 100: 1 presença, 1 justificada) | ', x);
  select percentual into x from public.frequencia(l, extract(year from current_date)::int) where irmao_id = i_se;
  r := r || format('frequência do secretário=%s%% (esperado 0) | ', x);
  select count(*) into n from public.envio_destinatarios where envio_id = v_env;
  select id into v_dest from public.envio_destinatarios where envio_id = v_env and status = 'pendente' limit 1;
  perform public.marcar_enviado(v_dest);
  r := r || 'Chanceler marca enviado=ok | ';

  -- ---- Secretário: ata, aprovação, expediente
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.atas (loja_id, sessao_id, texto, numero, grau) values (l, s1, 'Rascunho', 99, 3) returning id into v_ata;
  select numero || '/' || grau into t from public.atas where id = v_ata;
  r := r || format('ata número/grau=%s (esperado 1/1, vindos do sistema) | ', t);
  update public.atas set texto = 'Texto final' where id = v_ata;
  update public.atas set status = 'aprovada', aprovada_em_sessao_id = s2, aprovada_em = current_date - 7 where id = v_ata;
  begin
    update public.atas set texto = 'mudança' where id = v_ata;
    r := r || 'altera ata aprovada=PERMITIU (ERRO) | ';
  exception when others then r := r || 'altera ata aprovada=bloqueado | ';
  end;
  begin
    delete from public.atas where id = v_ata;
    r := r || 'apaga ata aprovada=PERMITIU (ERRO) | ';
  exception when others then r := r || 'apaga ata aprovada=bloqueado | ';
  end;
  insert into public.expediente (loja_id, sentido, correspondente, assunto) values (l, 'expedida', 'GOB-SP', 'Ofício 1'), (l, 'expedida', 'Loja Y', 'Ofício 2');
  select string_agg(numero, ',' order by numero) into t from public.expediente where loja_id = l;
  r := r || format('pranchas expedidas=%s (esperado 001/2026,002/2026) | ', t);
  insert into public.documentos_emitidos (loja_id, tipo, irmao_id) values (l, 'Declaração de regularidade', i_ap);
  select numero into t from public.documentos_emitidos where loja_id = l;
  r := r || format('documento=%s | ', t);
  begin
    insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s1, i_se, 'presente');
    r := r || 'Secretário marca presença=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Secretário marca presença=bloqueado | ';
  end;

  -- ---- Venerável lê a ata, não altera
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.atas where loja_id = l;
  r := r || format('Venerável lê atas=%s (esperado 1) | ', n);

  -- ---- Aprendiz
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.sessoes where loja_id = l;
  r := r || format('aprendiz vê sessões=%s (esperado 2, não a de grau 3) | ', n);
  select count(*) into n from public.frequencia(l, extract(year from current_date)::int);
  r := r || format('aprendiz vê frequência de=%s irmão(s) (esperado 1) | ', n);
  select count(*) into n from public.atas;
  r := r || format('aprendiz vê atas=%s (esperado 0) | ', n);
  select count(*) || ' / familiar=' || count(*) filter (where tipo = 'familiar') into t from public.aniversariantes(l, extract(month from current_date)::int);
  r := r || format('aniversários que o aprendiz vê=%s (esperado 1 / familiar=0) | ', t);
  begin
    perform public.criar_envio(l, 'convocacao', 'x', s3);
    r := r || 'aprendiz convoca=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz convoca=bloqueado | ';
  end;

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) filter (where tipo = 'familiar') into n from public.aniversariantes(l, extract(month from current_date)::int);
  r := r || format('Chanceler vê aniversário de familiar=%s (esperado 1)', n);

  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
