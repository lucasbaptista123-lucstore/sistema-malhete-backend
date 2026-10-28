-- WhatsApp + sistema: confirmação de presença, motivo, justificativa da falta, ciência do Venerável.
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
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ch, 'Irmão Chanceler', 3, '12 99999-0001', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012955', 'i129x8334@teste.com') returning id into i_ch;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, '(12) 99999-0003', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013099', 'i130x8334@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, m2, 'Mestre 2', 3, '12999990004', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013170', 'i131x8334@teste.com') returning id into i_m2;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, 'Mestre 3', 3, '12999990005', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013250', 'i132x8334@teste.com') returning id into i_m3;
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

  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := r || format('Venerável configura WhatsApp=%s (esperado t) | ', public.whatsapp_pode_configurar(l));
  begin
    select token into t from public.whatsapp_credenciais(l);
    r := r || 'Venerável lê token=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Venerável lê token=bloqueado | ';
  end;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 3) returning id into s;
  v_env := public.criar_envio(l, 'convocacao', 'Convocação', s, null, 'whatsapp');
  select count(*) into n from public.envio_destinatarios where envio_id = v_env and status = 'pendente';
  r := r || format('convocação WhatsApp para=%s (esperado 4 com telefone; V sem) | ', n);
  select token into tok_ap from public.envio_destinatarios where envio_id = v_env and irmao_id = i_ap;
  select token into tok_ch from public.envio_destinatarios where envio_id = v_env and irmao_id = i_ch;

  -- ---- respostas pelo WhatsApp (como o webhook)
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  t := public.whatsapp_botao(l, '5512999990003@s.whatsapp.net', 'rsvp:sim:' || tok_ap);
  r := r || format('botão Vou responde=%s | ', left(t, 30));
  t := public.whatsapp_botao(l, '551299990001@s.whatsapp.net', 'rsvp:nao:' || tok_ch); -- WhatsApp sem o 9
  t := public.whatsapp_texto(l, '551299990001@s.whatsapp.net', 'Viagem a trabalho');
  select resposta || ' / ' || coalesce(motivo, '-') || ' / ' || canal into t from public.confirmacoes where sessao_id = s and irmao_id = i_ch;
  r := r || format('Chanceler pelo WhatsApp=%s (esperado nao_vou / Viagem a trabalho / whatsapp) | ', t);
  t := public.whatsapp_texto(l, '5512999990003@s.whatsapp.net', 'oi');
  r := r || format('texto sem conversa aberta responde=%s (esperado nada) | ', coalesce(t, 'nada'));
  t := public.whatsapp_botao(l, '5512999990003@s.whatsapp.net', 'rsvp:sim:tokenfalso');
  r := r || format('token falso=%s (esperado nada) | ', coalesce(t, 'nada'));
  reset role;

  -- ---- resposta pelo sistema (Mestre 2 logado)
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.responder_convocacao(s, 'vou');
  select count(*) into n from public.confirmacoes;
  r := r || format('Mestre 2 vê confirmações=%s (esperado 1, a dele) | ', n);
  reset role;

  -- ---- sessão acontece: Chanceler marca presença; Mestre 3 e Aprendiz faltam
  perform set_config('request.jwt.claims', json_build_object('sub', ch, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) filter (where resposta = 'vou') || '/' || count(*) filter (where resposta = 'nao_vou') into t from public.confirmacoes where sessao_id = s;
  r := r || format('Chanceler vê vão/não vão=%s (esperado 2/1) | ', t);
  update public.sessoes set data = current_date - 1 where id = s;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s, i_m2, 'presente');
  update public.sessoes set status = 'realizada' where id = s;
  v_just := public.pedir_justificativas(l, s, 'Sentimos sua falta');
  select count(*) into n from public.envio_destinatarios where envio_id = v_just;
  r := r || format('pedido de justificativa para=%s (esperado 4: V, Ch, Ap, M3) | ', n);
  select token into tok_m3 from public.envio_destinatarios where envio_id = v_just and irmao_id = i_m3;
  reset role;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  t := public.whatsapp_botao(l, '5512999990005@s.whatsapp.net', 'just:ok:' || tok_m3);
  t := public.whatsapp_texto(l, '5512999990005@s.whatsapp.net', 'Estava doente');
  select situacao || ' / ' || justificativa || ' / ' || justificada_via into t from public.presencas where sessao_id = s and irmao_id = i_m3;
  r := r || format('Mestre 3 justificou pelo WhatsApp=%s | ', t);
  reset role;

  -- Aprendiz justifica pelo sistema
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.justificar_falta(s, 'Plantão no hospital');
  select justificada_via into t from public.presencas where sessao_id = s and irmao_id = i_ap;
  r := r || format('Aprendiz justificou pelo sistema=%s | ', t);
  begin
    perform public.tomar_ciencia((select id from public.presencas where sessao_id = s and irmao_id = i_ap));
    r := r || 'Aprendiz toma ciência=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Aprendiz toma ciência=bloqueado | ';
  end;
  reset role;

  -- Mestre 2 (presente) não consegue justificar
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.justificar_falta(s, 'x');
    r := r || 'presente justifica=PERMITIU (ERRO) | ';
  exception when others then r := r || 'presente justifica=bloqueado | ';
  end;
  reset role;

  -- Venerável toma ciência
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.presencas where sessao_id = s and justificada_pelo_irmao and ciente_em is null;
  r := r || format('Venerável vê justificativas pendentes=%s (esperado 2) | ', n);
  perform public.tomar_ciencia((select id from public.presencas where sessao_id = s and irmao_id = i_m3));
  select count(*) into n from public.presencas where sessao_id = s and ciente_em is not null;
  r := r || format('ciência registrada=%s (esperado 1) | ', n);
  r := r || format('chave do telefone=%s / %s (esperado iguais)', public.tel_chave('5512999990001@s.whatsapp.net'), public.tel_chave('(12) 9999-90001'));

  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
