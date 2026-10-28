-- Pedidos do irmão: licença e regularidade; Secretaria decide; irmão vê a própria declaração.
do $$
declare
  se uuid := gen_random_uuid(); x uuid := gen_random_uuid(); y uuid := gen_random_uuid();
  l uuid; i_x uuid; p1 uuid; p2 uuid; r text := ''; n int; s text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'pd@t.com', 'authenticated', 'authenticated', now()), (x, 'pdx@t.com', 'authenticated', 'authenticated', now()),
    (y, 'pdy@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'S');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 3, 'PX', '2015-01-01', '00000010154', 'i101x8965@teste.com') returning id into i_x;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, y, 'Irmão Y', 3, 'PY', '2015-01-01', '00000010235', 'i102x8965@teste.com');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.pedidos (loja_id, irmao_id, tipo, motivo, inicio, fim) values (l, i_x, 'licenca', 'Viagem a trabalho', current_date, current_date + 90) returning id into p1;
  insert into public.pedidos (loja_id, irmao_id, tipo, motivo) values (l, i_x, 'regularidade', 'Visitar outra loja') returning id into p2;
  begin perform public.decidir_pedido(p2, true); r := r || 'irmão aprova o próprio=PERMITIU (ERRO) | ';
  exception when others then r := r || 'irmão aprova o próprio=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', y, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.pedidos;
  r := r || format('outro irmão vê=%s (esperado 0) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_pedido(p1, true);
  perform public.decidir_pedido(p2, true);
  select situacao::text into s from public.irmaos where id = i_x;
  r := r || format('situação após licença=%s | ', s);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select numero || ' / ' || (conteudo->>'finalidade') into s from public.documentos_emitidos where irmao_id = i_x;
  r := r || format('irmão vê declaração=%s', s);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
