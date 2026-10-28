-- Tema de grau anterior: trabalho vai para o Vigilante do grau do tema.
do $$
declare
  v uuid := gen_random_uuid(); v1 uuid := gen_random_uuid(); v2 uuid := gen_random_uuid();
  ap uuid := gen_random_uuid(); co uuid := gen_random_uuid();
  l uuid; i_v uuid; i_v1 uuid; i_v2 uuid; i_ap uuid; i_co uuid; g uuid; t_ap uuid; t_co uuid;
  r text := ''; n int; t text; tm uuid;
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'v@t.com', 'authenticated', 'authenticated'), (v1, 'v1@t.com', 'authenticated', 'authenticated'), (v2, 'v2@t.com', 'authenticated', 'authenticated'),
    (ap, 'ap@t.com', 'authenticated', 'authenticated'), (co, 'co@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, '1º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000010820', 'i108x8117@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v2, '2º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000010901', 'i109x8117@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000011045', 'i110x8117@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, co, 'Irmão Companheiro', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000011126', 'i111x8117@teste.com') returning id into i_co;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v1, 'primeiro_vigilante'), (i_v2, 'segundo_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;

  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.temas_trabalho (loja_id, grau, titulo) values (l, 1, 'Pedra bruta') returning id into tm;
  reset role;
  -- o Companheiro (já elevado) faz o tema de Aprendiz que ficou pendente
  perform set_config('request.jwt.claims', json_build_object('sub', co, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id) values (l, i_co, 2, 'Pendência', 'x', tm) returning id into t_co;
  select grau into n from public.trabalhos where id = t_co;
  r := r || format('grau do trabalho=%s (esperado 1, o do tema) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'aprovado' where id = t_co;
  get diagnostics n = row_count;
  r := r || format('2º Vigilante avalia=%s (esperado 1) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.trabalhos_aprovados(l);
  r := r || format('Aprendiz vê na biblioteca=%s (esperado 1)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
