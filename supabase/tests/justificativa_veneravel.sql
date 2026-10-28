-- Justificativa vai ao Venerável: aceita ou não aceita; avisos para ele e para o irmão.
do $$
declare
  v uuid := gen_random_uuid(); ch uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); m2 uuid := gen_random_uuid();
  l uuid; i_v uuid; i_ch uuid; i_ap uuid; i_m2 uuid; i_m3 uuid; g uuid; s uuid; v_env uuid; v_just uuid;
  tok_ap text; tok_ch text; tok_m3 text; r text := ''; t text; n int;
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'v@t.com', 'authenticated', 'authenticated'), (ch, 'ch@t.com', 'authenticated', 'authenticated'),
    (ap, 'ap@t.com', 'authenticated', 'authenticated'), (m2, 'm2@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ch, 'Irmão Chanceler', 3, '12 99999-0001', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014818', 'i148x8345@teste.com') returning id into i_ch;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, '(12) 99999-0003', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014907', 'i149x8345@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, m2, 'Mestre 2', 3, '12999990004', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015032', 'i150x8345@teste.com') returning id into i_m2;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, 'Mestre 3', 3, '12999990005', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015113', 'i151x8345@teste.com') returning id into i_m3;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 60, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 60, current_date + 300 from (values (i_v, 'veneravel'), (i_ch, 'chanceler')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;
  -- instância já criada (caminho do teste) guardada pela edge function
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'malhete-teste', 'token-da-instancia-teste');
  perform public.whatsapp_atualizar(l, 'conectado', '5512999990000', 'Loja', null);
  reset role;

  update public.irmaos set telefone = '12999990009' where id = i_v;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 3) returning id into s;
  reset role;
  -- Aprendiz avisa pelo sistema que não vai, com motivo
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.responder_convocacao(s, 'nao_vou', 'Viagem a trabalho');
  reset role;
  select count(*) into n from public.notificacoes where tipo = 'justificativa' and irmao_id = i_v;
  r := r || format('Venerável avisado=%s (esperado 1) | ', n);
  select left(mensagem, 70) into t from public.notificacoes where tipo = 'justificativa' and irmao_id = i_v;
  r := r || format('texto=%s | ', replace(t, E'\n', ' '));
  -- Aprendiz não aceita a própria; Venerável vê e não aceita
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.avaliar_justificativa('confirmacao', (select id from public.confirmacoes where sessao_id = s and irmao_id = i_ap), true);
    r := r || 'irmão aceita a própria=PERMITIU (ERRO) | ';
  exception when others then r := r || 'irmão aceita a própria=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.justificativas(l);
  r := r || format('pendentes do Venerável=%s (esperado 1) | ', n);
  perform public.avaliar_justificativa('confirmacao', (select id from public.justificativas(l) limit 1), false, 'Viagem não justifica');
  select count(*) into n from public.justificativas(l);
  r := r || format('pendentes depois=%s (esperado 0) | ', n);
  reset role;
  select left(mensagem, 60) into t from public.notificacoes where tipo = 'justificativa' and irmao_id = i_ap;
  r := r || format('irmão recebe=%s | ', t);
  -- Chanceler preenche a presença pelas respostas: a recusa vira falta
  perform set_config('request.jwt.claims', json_build_object('sub', ch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao, justificativa) values (l, s, i_ap, 'justificada', 'Viagem a trabalho');
  select situacao into t from public.presencas where sessao_id = s and irmao_id = i_ap;
  r := r || format('presença do recusado=%s (esperado ausente) | ', t);
  update public.sessoes set status = 'realizada' where id = s;
  reset role;
  -- Mestre 3 justifica a falta depois (WhatsApp) → Venerável aceita
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform private.registrar_justificativa(l, s, i_m3, 'Estava doente', 'whatsapp');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.avaliar_justificativa('presenca', (select id from public.presencas where sessao_id = s and irmao_id = i_m3), true);
  reset role;
  select situacao || '/' || aceita into t from public.presencas where sessao_id = s and irmao_id = i_m3;
  r := r || format('falta justificada aceita=%s (esperado justificada/true) | ', t);
  -- Chanceler registra justificativa dada pessoalmente pelo Mestre 2 → vai ao Venerável, sem duplicar a do Aprendiz
  perform set_config('request.jwt.claims', json_build_object('sub', ch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao, justificativa) values (l, s, i_m2, 'justificada', 'Avisou pessoalmente: plantão');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select string_agg(irmao || ':' || via, ',') into t from public.justificativas(l);
  r := r || format('pendentes=%s (esperado Mestre 2:chanceler)', t);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
