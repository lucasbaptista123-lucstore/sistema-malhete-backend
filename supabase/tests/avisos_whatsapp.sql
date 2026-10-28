-- Avisos automáticos: cobrança com link, baixa, trabalho recebido/avaliado, débitos e configuração.
do $$
declare
  v uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); v2 uuid := gen_random_uuid();
  l uuid; i_v uuid; i_ap uuid; i_v2 uuid; i_sem uuid; g uuid; v_tit uuid; v_tr uuid; v_caixa uuid;
  r text := ''; n int; t text;
begin
  insert into auth.users (id, email, aud, role) values (v, 'v@t.com', 'authenticated', 'authenticated'), (ap, 'ap@t.com', 'authenticated', 'authenticated'), (v2, 'v2@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, ap, 'João Aprendiz', 1, '12999990001', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014575', 'i145x1299@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values (l, v2, '2º Vig', 3, '12999990002', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014656', 'i146x1299@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Sem Telefone', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014737', 'i147x1299@teste.com') returning id into i_sem;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 60, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 60, current_date + 300 from (values (i_v, 'tesoureiro'), (i_v2, 'segundo_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  select id into v_caixa from public.contas_financeiras where loja_id = l and tipo = 'caixa';
  reset role;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'x', 'tok');
  perform public.whatsapp_atualizar(l, 'conectado', null, null, null);
  reset role;

  -- mensalidade vira cobrança no Asaas → aviso com link
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.gerar_mensalidades(l, date_trunc('month', current_date)::date, 1234.5, current_date - 10);
  select id into v_tit from public.titulos where irmao_id = i_ap;
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.asaas_vincular(l, v_tit, i_ap, 'cus_1', '{"id":"pay_1","invoiceUrl":"https://asaas/i/1","status":"PENDING"}'::jsonb);
  reset role;
  select mensagem into t from public.notificacoes where irmao_id = i_ap and tipo = 'cobranca';
  r := r || format('cobrança=%s | ', replace(t, E'\n', ' / '));

  -- débitos: rotina diária (vencida há 10 dias); não repete dentro do intervalo
  n := public.gerar_avisos_debito();
  r := r || format('avisos de débito gerados=%s (esperado 4: V, Ap, Vig e Sem Telefone) | ', n);
  n := public.gerar_avisos_debito();
  r := r || format('rodar de novo=%s (esperado 0) | ', n);
  select status into t from public.notificacoes where irmao_id = i_sem and tipo = 'debito';
  r := r || format('sem telefone fica=%s | ', t);

  -- baixa → aviso de pagamento
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.baixar_titulo(v_tit, v_caixa);
  reset role;
  select mensagem into t from public.notificacoes where irmao_id = i_ap and tipo = 'baixa';
  r := r || format('baixa=%s | ', t);

  -- trabalho recebido e avaliado
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_ap, 1, 'O prumo', 'x') returning id into v_tr;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'ajustes', parecer = 'Cite as fontes' where id = v_tr;
  reset role;
  select string_agg(tipo, ',' order by criado_em) into t from public.notificacoes where irmao_id = i_ap and tipo like 'trabalho%';
  r := r || format('trabalho=%s (esperado trabalho_recebido,trabalho_avaliado) | ', t);

  -- loja desliga o aviso de baixa
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.avisos_config (loja_id, baixa) values (l, false);
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao, irmao_id)
    values (l, v_caixa, (select id from public.categorias_financeiras where loja_id = l and codigo = 'doacoes'), 'receita', 5, 'Doação', i_ap);
  perform public.baixar_titulo((select id from public.titulos where irmao_id = i_v2), v_caixa);
  reset role;
  select count(*) into n from public.notificacoes where irmao_id = i_v2 and tipo = 'baixa';
  r := r || format('com aviso de baixa desligado=%s (esperado 0) | ', n);

  -- a fila para a edge function
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  select count(*) into n from public.notificacoes_proximas(10);
  r := r || format('na fila para enviar=%s', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
