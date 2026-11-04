-- Ritmo do WhatsApp: até 2 por Loja por rodada (1 min), 25 s mínimo desde a última, 60 por dia; convite em lote só para quem tem telefone.
do $$ declare t uuid := gen_random_uuid(); l uuid; r text := ''; j jsonb; n int; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'twr@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, telefone) values
    (l, 'Irmão Um Silva', 3, 'W1', '2015-01-01', '12999990001'), (l, 'Irmão Dois Silva', 3, 'W2', '2015-01-01', '12999990002'),
    (l, 'Irmão Tres Silva', 3, 'W3', '2015-01-01', null);
  j := public.convidar_todos(l);
  r := r || format('lote=%s | de novo=%s | ', j, public.convidar_todos(l));
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'x', 'tok');
  perform public.whatsapp_atualizar(l, 'conectado', null, null, null);
  select count(*) into n from public.notificacoes_proximas(4) where loja_id = l;
  r := r || format('rodada pede 4, sai=%s (esperado 2) | ', n);
  update public.notificacoes set status = 'enviado', enviado_em = now() where id = (select id from public.notificacoes_proximas(1) where loja_id = l);
  select count(*) into n from public.notificacoes_proximas(1) where loja_id = l;
  r := r || format('logo depois=%s (esperado 0) | ', n);
  update public.notificacoes set enviado_em = now() - interval '40 seconds' where loja_id = l and status = 'enviado';
  select count(*) into n from public.notificacoes_proximas(1) where loja_id = l;
  r := r || format('40 s depois=%s (esperado 1)', n);
  reset role;
  raise exception 'RESULTADO: % (lote esperado na_fila 2, sem_telefone 1; de novo 0/1)', r;
end $$;
