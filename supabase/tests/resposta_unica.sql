-- Resposta: repetir é bloqueado (o outro canal só informa); mudar de ideia é permitido até a sessão.
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
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ch, 'Irmão Chanceler', 3, '12 99999-0001', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014141', 'i141x1201@teste.com') returning id into i_ch;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, '(12) 99999-0003', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014222', 'i142x1201@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, m2, 'Mestre 2', 3, '12999990004', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014303', 'i143x1201@teste.com') returning id into i_m2;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, 'Mestre 3', 3, '12999990005', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014494', 'i144x1201@teste.com') returning id into i_m3;
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
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 3) returning id into s;
  v_env := public.criar_envio(l, 'convocacao', 'Convocação', s, null, 'whatsapp');
  select token into tok_ap from public.envio_destinatarios where envio_id = v_env and irmao_id = i_ap;
  select token into tok_ch from public.envio_destinatarios where envio_id = v_env and irmao_id = i_m2;
  reset role;
  -- Aprendiz confirma pelo WhatsApp
  set local role service_role;
  t := public.whatsapp_botao(l, '5512999990003@s.whatsapp.net', 'rsvp:sim:' || tok_ap);
  t := public.whatsapp_botao(l, '5512999990003@s.whatsapp.net', 'rsvp:sim:' || tok_ap);
  r := r || format('WhatsApp Sim repetido=%s | ', left(t, 40));
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.responder_convocacao(s, 'vou');
    r := r || 'Sim pelo sistema depois do Sim no WhatsApp=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Sim pelo sistema depois do Sim no WhatsApp=bloqueado | ';
  end;
  perform public.responder_convocacao(s, 'nao_vou', 'Surgiu um compromisso');
  reset role;
  select resposta || '/' || canal || '/' || resposta_anterior into t from public.confirmacoes where sessao_id = s and irmao_id = i_ap;
  r := r || format('mudou de ideia pelo sistema=%s (esperado nao_vou/sistema/vou) | ', t);
  -- Mestre 2 responde "não vou" pelo sistema sem motivo; depois manda o motivo pelo WhatsApp
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.responder_convocacao(s, 'nao_vou');
  reset role;
  set local role service_role;
  t := public.whatsapp_botao(l, '5512999990004@s.whatsapp.net', 'rsvp:nao:' || tok_ch);
  r := r || format('WhatsApp Não repetido=%s | ', left(t, 40));
  t := public.whatsapp_texto(l, '5512999990004@s.whatsapp.net', 'Plantão no hospital');
  reset role;
  select resposta || '/' || canal || '/' || coalesce(motivo, '-') into t from public.confirmacoes where sessao_id = s and irmao_id = i_m2;
  r := r || format('Mestre 2=%s (esperado nao_vou/sistema/Plantão no hospital) | ', t);
  set local role service_role;
  t := public.whatsapp_botao(l, '5512999990004@s.whatsapp.net', 'rsvp:sim:' || tok_ch);
  reset role;
  select resposta || '/' || canal || '/' || coalesce(motivo, '-') into t from public.confirmacoes where sessao_id = s and irmao_id = i_m2;
  r := r || format('Mestre 2 mudou para Sim no WhatsApp=%s (esperado vou/whatsapp/-)', t);
  raise exception 'RESULTADO: %', r;
end $$;
