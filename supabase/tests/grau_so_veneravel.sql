-- Só o Venerável define o grau; Secretário cadastra como Aprendiz; admin não é promovido por outros.
do $$
declare
  v uuid := gen_random_uuid(); se uuid := gen_random_uuid();
  l uuid; i_v uuid; i_se uuid; i_x uuid; g uuid; r text := ''; n smallint; t text;
begin
  insert into auth.users (id, email, aud, role) values (v, 'v@t.com', 'authenticated', 'authenticated'), (se, 'se@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V', 3::smallint);
  select id, grau into i_v, n from public.irmaos where loja_id = l and user_id = v;
  r := r || format('quem cadastrou a loja entra como=%s (esperado 3) | ', n);
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, se, 'Irmão Secretário', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013684', 'i136x6572@teste.com') returning id, grau into i_se, n;
  r := r || format('admin sem Venerável define grau=%s (esperado 3) | ', n);
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300 from (values (i_v, 'veneravel'), (i_se, 'secretario')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;

  -- Secretário
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.irmaos (loja_id, nome, grau, mestre_instalado, admin_loja, cim, data_iniciacao, cpf, email) values (l, 'Irmão Novo', 3, true, true, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013765', 'i137x6572@teste.com') returning id, grau || '/' || mestre_instalado || '/' || admin_loja into i_x, t;
  r := r || format('Secretário cadastra Mestre MI admin=%s (esperado 3/true/false) | ', t);
  update public.irmaos set telefone = '1', cim = '123' where id = i_x;
  r := r || 'Secretário edita outros dados=ok | ';
  update public.irmaos set grau = 2 where id = i_x;
  r := r || 'Secretário altera grau=ok | ';
  begin
    update public.irmaos set admin_loja = true where id = i_se;
    r := r || 'Secretário vira admin=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Secretário vira admin=bloqueado | ';
  end;
  reset role;

  -- Venerável
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.irmaos set grau = 3, mestre_instalado = true where id = i_x;
  select grau into n from public.irmaos where id = i_x;
  r := r || format('Venerável exalta=%s (esperado 3) | ', n);
  r := r || format('permissões do Venerável incluem graus.editar=%s', 'graus.editar' = any (public.minhas_permissoes(l)));
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;

-- Outro cargo (Tesoureiro, sem graus.editar): não altera grau nem o próprio.
do $$
declare t uuid := gen_random_uuid(); l uuid; i_t uuid; g uuid; r text := '';
begin
  insert into auth.users (id, email, aud, role) values (t, 't@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T', 1::smallint);
  select id into i_t from public.irmaos where loja_id = l and user_id = t;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_t, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
  reset role;
  update public.irmaos set admin_loja = false where id = i_t;
  insert into public.irmaos (loja_id, nome, cim, data_iniciacao, cpf, email) values (l, 'Venerável de verdade', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000013846', 'i138x6572@teste.com');
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, (select id from public.irmaos where loja_id = l and nome = 'Venerável de verdade'), id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'veneravel';
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.irmaos set grau = 3 where id = i_t;
    r := r || 'Tesoureiro se exalta=PERMITIU (ERRO)';
  exception when others then r := r || 'Tesoureiro se exalta=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO2: %', r;
end $$;
