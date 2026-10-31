-- Sessões de estudo: o 1º Vigilante cria (online, com link), convoca e marca presença numa sessão de estudo; não cria
-- nem convoca ordinária; irmão comum não cria; a presença conta na frequência.
do $$
declare vm uuid := gen_random_uuid(); v1 uuid := gen_random_uuid(); ir uuid := gen_random_uuid(); l uuid; i_v1 uuid; i_ir uuid; g uuid;
  s1 uuid; s2 uuid; env uuid; r text := ''; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'evm@t.com', 'authenticated', 'authenticated', now()), (v1, 'ev1@t.com', 'authenticated', 'authenticated', now()), (ir, 'eir@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Estudos', '5', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, 'Vigilante Lima', 3, 'ES1', '2015-01-01', '39053344705', 'ev1@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ir, 'Companheiro Reis', 2, 'ES2', '2024-01-01', '86288366757', 'eir@teste.com') returning id into i_ir;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_v1, c.id, current_date - 1, current_date + 300 from public.loja_cargos c where c.loja_id = l and c.codigo = 'primeiro_vigilante';
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.sessoes (loja_id, tipo, grau, data, hora, modalidade, link_online, pauta)
  values (l, 'estudos', 2, current_date, '20:00', 'online', 'https://meet.google.com/abc', 'Instrução do 2º grau') returning id into s1;
  r := r || 'vigilante cria estudo online=ok | ';
  begin insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 7); r := r || 'vigilante cria ordinária=PERMITIU (ERRO) | ';
  exception when others then r := r || 'vigilante cria ordinária=bloqueado | '; end;
  env := public.criar_envio(l, 'convocacao', 'Prezado irmão {nome}, sessão de estudos online', s1, null, 'manual');
  r := r || format('vigilante convoca estudo=ok (%s destinatários) | ', (select count(*) from public.envio_destinatarios where envio_id = env));
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s1, i_ir, 'presente');
  update public.sessoes set status = 'realizada' where id = s1;
  r := r || 'vigilante marca presença e conclui=ok | ';
  reset role;
  -- Venerável cria uma ordinária; o vigilante não convoca nela
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 7) returning id into s2;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.criar_envio(l, 'convocacao', 'x', s2, null, 'manual'); r := r || 'vigilante convoca ordinária=PERMITIU (ERRO) | ';
  exception when others then r := r || 'vigilante convoca ordinária=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ir, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'estudos', 1, current_date + 3); r := r || 'irmão comum cria estudo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'irmão comum cria estudo=bloqueado | '; end;
  reset role;
  select presentes into n from public.frequencia(l, extract(year from current_date)::int) where irmao_id = i_ir;
  r := r || format('presença conta na frequência=%s', n);
  raise exception 'RESULTADO: %', r;
end $$;
