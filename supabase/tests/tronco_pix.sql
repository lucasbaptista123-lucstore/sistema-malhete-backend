-- Tronco por PIX: irmão informa; Tesoureiro confirma e cai na conta Tronco; outro irmão não vê.
do $$
declare
  t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); y uuid := gen_random_uuid(); l uuid; i_x uuid; c uuid;
  r text := ''; n int; v numeric;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'tp@t.com', 'authenticated', 'authenticated', now()), (x, 'tpx@t.com', 'authenticated', 'authenticated', now()),
    (y, 'tpy@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 'P1', '2020-01-01', '00000010588', 'i105x1036@teste.com') returning id into i_x;
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, y, 'Irmão Y', 'P2', '2020-01-01', '00000010669', 'i106x1036@teste.com');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid) values (l, i_x, 30, 'TRONCOAB12') returning id into c;
  r := r || 'irmão informa=ok | ';
  begin
    perform public.decidir_tronco(c, true);
    r := r || 'irmão confirma=PERMITIU (ERRO) | ';
  exception when others then r := r || 'irmão confirma=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', y, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.tronco_contribuicoes;
  r := r || format('outro irmão vê=%s (esperado 0) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_tronco(c, true);
  select saldo into v from public.contas_saldo where loja_id = l and tipo = 'tronco';
  r := r || format('saldo do Tronco=%s (esperado 30.00)', v);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
