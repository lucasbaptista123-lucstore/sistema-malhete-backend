-- Tronco anônimo: o irmão informa e vê a própria contribuição; o Tesoureiro vê valor e status, mas não consegue ler
-- quem foi (irmao_id); o lançamento do Tronco não guarda o irmão.
do $$
declare vm uuid := gen_random_uuid(); te uuid := gen_random_uuid(); ir uuid := gen_random_uuid(); l uuid; i_te uuid; i_ir uuid; g uuid;
  c uuid; r text := ''; n int; v text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'tavm@t.com', 'authenticated', 'authenticated', now()), (te, 'tate@t.com', 'authenticated', 'authenticated', now()), (ir, 'tair@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Tronco', '7', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, te, 'Tesoureiro Ta', 3, 'TA1', '2015-01-01', '39053344705', 'tate@teste.com') returning id into i_te;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ir, 'Irmão Doador', 2, 'TA2', '2020-01-01', '86288366757', 'tair@teste.com') returning id into i_ir;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_te, cg.id, current_date - 1, current_date + 300 from public.loja_cargos cg where cg.loja_id = l and cg.codigo = 'tesoureiro';
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ir, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status) values (l, i_ir, 50, 'TRONCOX1', 'informada') returning id into c;
  select count(*) into n from public.tronco_contribuicoes where loja_id = l;
  r := r || format('irmão vê a sua=%s | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', te, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select valor::text || ' ' || status into v from public.tronco_contribuicoes where id = c;
  r := r || format('tesoureiro vê valor/status=%s | ', v);
  begin select irmao_id::text into v from public.tronco_contribuicoes where id = c; r := r || 'tesoureiro lê quem foi=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureiro lê quem foi=bloqueado | '; end;
  perform public.decidir_tronco(c, true, current_date);
  reset role;
  select count(*) into n from public.lancamentos where loja_id = l and irmao_id is not null and conta_id in (select id from public.contas_financeiras where loja_id = l and tipo = 'tronco');
  r := r || format('lançamento do Tronco com irmão=%s | agradecimento=%s', n,
    (select count(*) from public.notificacoes where irmao_id = i_ir and mensagem ilike '%Tronco%'));
  raise exception 'RESULTADO: %', r;
end $$;
