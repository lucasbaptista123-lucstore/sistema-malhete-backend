-- Avaliador avisado: 2º Vig (Aprendiz), 1º Vig (Companheiro), Venerável (Mestre).
do $$
declare
  v uuid := gen_random_uuid(); v1 uuid := gen_random_uuid(); v2 uuid := gen_random_uuid();
  ap uuid := gen_random_uuid(); co uuid := gen_random_uuid();
  l uuid; i_v uuid; i_v1 uuid; i_v2 uuid; i_ap uuid; i_co uuid; g uuid; t_ap uuid; t_co uuid;
  r text := ''; n int; t text;
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'v@t.com', 'authenticated', 'authenticated'), (v1, 'v1@t.com', 'authenticated', 'authenticated'), (v2, 'v2@t.com', 'authenticated', 'authenticated'),
    (ap, 'ap@t.com', 'authenticated', 'authenticated'), (co, 'co@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, '1º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000011983', 'i119x3099@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v2, '2º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012017', 'i120x3099@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012106', 'i121x3099@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, co, 'Irmão Companheiro', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000012289', 'i122x3099@teste.com') returning id into i_co;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v1, 'primeiro_vigilante'), (i_v2, 'segundo_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;

  update public.irmaos set telefone = '1299999000' || right(id::text, 1) where loja_id = l;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_ap, 1, 'T ap', 'x') returning id into t_ap;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', co, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_co, 2, 'T co', 'x') returning id into t_co;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_v1, 3, 'T mestre', 'x');
  reset role;
  select string_agg(i.nome || '←' || split_part(split_part(n2.mensagem, '“', 2), '”', 1), ', ' order by i.nome) into t
  from public.notificacoes n2 join public.irmaos i on i.id = n2.irmao_id
  where n2.loja_id = l and n2.mensagem like 'Irmão %para avaliar%';
  r := r || format('avisados=%s (esperado 2º Vig←T ap, 1º Vig←T co, V←T mestre)', t);
  raise exception 'RESULTADO: %', r;
end $$;
