-- WhatsApp sem botões: "1"/"2" na convocação; texto direto vira justificativa; mensagem repetida ignorada.
do $$
declare
  v uuid := gen_random_uuid(); l uuid; i_v uuid; i_a uuid; i_b uuid; g uuid; s uuid; s2 uuid; v_env uuid;
  r text := ''; t text; ok1 boolean; ok2 boolean;
begin
  insert into auth.users (id, email, aud, role) values (v, 'v@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, 'Irmão A', 3, '12999990011', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000018058', 'i180x124@teste.com') returning id into i_a;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, 'Irmão B', 3, '12999990012', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000018139', 'i181x124@teste.com') returning id into i_b;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 60, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_v, id, current_date - 60, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'chanceler';
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'x', 'tok');
  perform public.whatsapp_atualizar(l, 'conectado', null, null, null);
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 2) returning id into s;
  perform public.criar_envio(l, 'convocacao', 'C', s, null, 'whatsapp');
  insert into public.sessoes (loja_id, tipo, grau, data, status) values (l, 'ordinaria', 1, current_date - 1, 'agendada') returning id into s2;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s2, i_a, 'presente');
  update public.sessoes set status = 'realizada' where id = s2;
  v_env := public.pedir_justificativas(l, s2, 'Sentimos sua falta');
  reset role;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_abrir_justificativas(v_env);
  t := public.whatsapp_texto(l, '5512999990011@s.whatsapp.net', '1');
  select resposta into t from public.confirmacoes where sessao_id = s and irmao_id = i_a;
  r := r || format('A respondeu "1"=%s (esperado vou) | ', t);
  t := public.whatsapp_texto(l, '5512999990012@s.whatsapp.net', 'Tive um compromisso de família');
  select situacao || ' / ' || justificativa into t from public.presencas where sessao_id = s2 and irmao_id = i_b;
  r := r || format('B respondeu texto direto=%s | ', t);
  t := public.whatsapp_texto(l, '5512999990012@s.whatsapp.net', '2');
  select resposta into t from public.confirmacoes where sessao_id = s and irmao_id = i_b;
  r := r || format('B depois respondeu "2"=%s (esperado nao_vou) | ', t);
  -- B ainda tem justificativa em aberto? (não: já respondeu). Abre de novo e manda "1": vai para a convocação
  perform public.whatsapp_abrir_justificativas(v_env);
  t := public.whatsapp_texto(l, '5512999990012@s.whatsapp.net', '1');
  select resposta into t from public.confirmacoes where sessao_id = s and irmao_id = i_b;
  r := r || format('"1" depois de "2" muda a resposta=%s (esperado vou) | ', t);
  ok1 := public.whatsapp_nova_mensagem(l, 'MSG1');
  ok2 := public.whatsapp_nova_mensagem(l, 'MSG1');
  r := r || format('mensagem repetida=%s/%s (esperado t/f)', ok1, ok2);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
