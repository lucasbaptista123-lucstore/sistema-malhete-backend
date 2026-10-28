-- Hospitalaria: Hospitaleiro acompanha e pede auxílio; Tesoureiro paga pelo Tronco; outros não veem.
do $$
declare
  v uuid := gen_random_uuid(); h uuid := gen_random_uuid(); t uuid := gen_random_uuid(); x uuid := gen_random_uuid();
  l uuid; i_v uuid; i_h uuid; i_t uuid; g uuid; a uuid; aux uuid; r text := ''; n int; s text; sal numeric;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (v, 'hv@t.com', 'authenticated', 'authenticated', now()), (h, 'hh@t.com', 'authenticated', 'authenticated', now()),
    (t, 'ht@t.com', 'authenticated', 'authenticated', now()), (x, 'hx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, h, 'Irmão Hosp', 'H1', '2020-01-01', '00000018210', 'i182x1530@teste.com') returning id into i_h;
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, t, 'Irmão Tes', 'H2', '2020-01-01', '00000018309', 'i183x1530@teste.com') returning id into i_t;
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Comum', 'H3', '2020-01-01', '00000018481', 'i184x1530@teste.com');
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, z.i, c.id, current_date - 1, current_date + 300 from (values (i_v, 'veneravel'), (i_h, 'hospitaleiro'), (i_t, 'tesoureiro')) z(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = z.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;
  -- Tronco com saldo: Tesoureiro lança receita
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao)
  select l, (select id from public.contas_financeiras where loja_id = l and tipo = 'tronco'),
         (select id from public.categorias_financeiras where loja_id = l and codigo = 'tronco'), 'receita', 500, 'Tronco da sessão';
  reset role;
  -- Hospitaleiro cadastra assistido, registra visita e pede auxílio
  perform set_config('request.jwt.claims', json_build_object('sub', h, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.assistidos (loja_id, nome, vinculo, situacao, descricao) values (l, 'Viúva do Ir. João', 'viuva', 'dificuldade', 'Precisa de ajuda com remédios') returning id into a;
  insert into public.assistidos_registros (loja_id, assistido_id, tipo, anotacao) values (l, a, 'visita', 'Visitei, está bem');
  insert into public.auxilios (loja_id, assistido_id, beneficiario, valor, motivo) values (l, a, 'Viúva do Ir. João', 200, 'Remédios') returning id into aux;
  r := r || 'Hospitaleiro cadastra, visita e pede=ok | ';
  select saldo into sal from public.contas_saldo where loja_id = l and tipo = 'tronco';
  r := r || format('Hospitaleiro vê saldo do Tronco=%s | ', sal);
  begin
    perform public.decidir_auxilio(aux, true);
    r := r || 'Hospitaleiro paga=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Hospitaleiro paga=bloqueado | ';
  end;
  reset role;
  -- Tesoureiro vê o pedido (não o cadastro) e paga
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.assistidos;
  r := r || format('Tesoureiro vê assistidos=%s (esperado 0) | ', n);
  perform public.decidir_auxilio(aux, true);
  select saldo into sal from public.contas_saldo where loja_id = l and tipo = 'tronco';
  r := r || format('saldo do Tronco após pagar=%s (esperado 300.00) | ', sal);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', h, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select status into s from public.auxilios where id = aux;
  select count(*) into n from public.assistidos_registros where assistido_id = a;
  r := r || format('Hospitaleiro vê=%s e %s registros (esperado pago e 2) | ', s, n);
  reset role;
  -- Venerável vê tudo; irmão comum nada
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.assistidos;
  r := r || format('Venerável vê assistidos=%s (esperado 1) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select (select count(*) from public.assistidos) + (select count(*) from public.auxilios) into n;
  r := r || format('irmão comum vê=%s (esperado 0)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
