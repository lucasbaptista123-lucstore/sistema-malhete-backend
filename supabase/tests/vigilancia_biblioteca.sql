-- Vigilância e Biblioteca: cada Vigilante avalia só o seu grau; acesso pela graduação do cadastro.
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
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, '1º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015466', 'i154x6700@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v2, '2º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015547', 'i155x6700@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015628', 'i156x6700@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, co, 'Irmão Companheiro', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000015709', 'i157x6700@teste.com') returning id into i_co;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v1, 'primeiro_vigilante'), (i_v2, 'segundo_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;

  -- Biblioteca (publicada pelo 1º Vigilante)
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.biblioteca (loja_id, titulo, descricao, grau_minimo) values
    (l, 'Para aprendizes', 'x', 1), (l, 'Para companheiros', 'x', 2), (l, 'Para mestres', 'x', 3);
  r := r || 'Vigilante publica na biblioteca=ok | ';
  reset role;

  -- Aprendiz e Companheiro enviam trabalhos
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, status) values (l, i_co, 3, 'O malhete', 'texto', 'aprovado') returning id into t_ap;
  select irmao_id = i_ap and grau = 1 and status = 'enviado' into strict t from public.trabalhos where id = t_ap;
  r := r || format('autor/grau/status vêm do sistema=%s | ', t);
  select count(*) into n from public.biblioteca;
  r := r || format('aprendiz vê biblioteca=%s (esperado 1) | ', n);
  begin
    insert into public.biblioteca (loja_id, titulo, descricao) values (l, 'x', 'x');
    r := r || 'aprendiz publica=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz publica=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', co, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto) values (l, i_co, 2, 'A régua', 'texto') returning id into t_co;
  select count(*) into n from public.trabalhos;
  r := r || format('companheiro vê trabalhos=%s (esperado 1, o dele) | ', n);
  select count(*) into n from public.biblioteca;
  r := r || format('companheiro vê biblioteca=%s (esperado 2) | ', n);
  reset role;

  -- 2º Vigilante (aprendizes): avalia o do aprendiz, não vê o do companheiro
  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.trabalhos;
  r := r || format('2º Vigilante vê trabalhos=%s (esperado 1, do aprendiz) | ', n);
  update public.trabalhos set status = 'ajustes', parecer = 'Desenvolva a conclusão' where id = t_ap;
  update public.trabalhos set status = 'aprovado' where id = t_co;
  get diagnostics n = row_count;
  r := r || format('2º Vigilante avalia companheiro=%s linhas (esperado 0) | ', n);
  reset role;

  -- Aprendiz reenvia; não consegue se aprovar
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set texto = 'texto revisto' where id = t_ap;
  select status into t from public.trabalhos where id = t_ap;
  r := r || format('aprendiz reenvia → status=%s (esperado enviado) | ', t);
  begin
    update public.trabalhos set status = 'aprovado' where id = t_ap;
    r := r || 'aprendiz se aprova=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprendiz se aprova=bloqueado | ';
  end;
  reset role;

  -- 1º Vigilante (companheiros) aprova o do companheiro
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'aprovado', parecer = 'Muito bom' where id = t_co;
  select status || ' / avaliado_por ok=' || (avaliado_por = v1) into t from public.trabalhos where id = t_co;
  r := r || format('1º Vigilante aprova=%s | ', t);
  reset role;

  -- Venerável vê todos; companheiro não apaga aprovado
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.trabalhos;
  r := r || format('Venerável vê trabalhos=%s (esperado 2) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', co, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    delete from public.trabalhos where id = t_co;
    r := r || 'apaga aprovado=PERMITIU (ERRO)';
  exception when others then r := r || 'apaga aprovado=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
