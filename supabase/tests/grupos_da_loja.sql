-- Grupos próprios da loja no plano de contas.
do $$
declare
  a uuid := gen_random_uuid(); c uuid := gen_random_uuid();
  l uuid; l2 uuid; v_a uuid; g uuid; v_grupo text; v_cat uuid; v_caixa uuid;
  r text := ''; n int; s numeric; t text;
begin
  insert into auth.users (id, email, aud, role) values (a, 'a@t.com', 'authenticated', 'authenticated'), (c, 'c@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l2 := public.criar_loja('L2', '2', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'C');
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'A');
  select id into v_caixa from public.contas_financeiras where loja_id = l and tipo = 'caixa';

  insert into public.grupos_dre (loja_id, nome, tipo, codigo, ordem) values (l, '  Campanhas  ', 'receita', 'x', 1);
  select codigo, nome || '/' || ordem into v_grupo, t from public.grupos_dre where loja_id = l;
  r := r || format('grupo criado=%s código do sistema=%s (esperado Campanhas/115 t) | ', t, v_grupo like 'g\_%');
  insert into public.categorias_financeiras (loja_id, nome, tipo, grupo) values (l, 'Rifa de Natal', 'receita', v_grupo) returning id into v_cat;
  r := r || 'conta no grupo novo=ok | ';
  begin
    insert into public.categorias_financeiras (loja_id, nome, tipo, grupo) values (l, 'x', 'despesa', v_grupo);
    r := r || 'despesa em grupo de receita=PERMITIU (ERRO) | ';
  exception when others then r := r || 'despesa em grupo de receita=bloqueado | ';
  end;
  begin
    update public.grupos_dre set tipo = 'despesa' where codigo = v_grupo;
    r := r || 'muda tipo do grupo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'muda tipo do grupo=bloqueado | ';
  end;
  update public.grupos_dre set nome = 'Campanhas e rifas' where codigo = v_grupo;
  get diagnostics n = row_count;
  r := r || format('renomeia=%s (esperado 1) | ', n);
  update public.grupos_dre set nome = 'x' where codigo = 'receitas_associativas';
  get diagnostics n = row_count;
  r := r || format('mexe em grupo padrão=%s linhas (esperado 0) | ', n);
  begin
    update public.grupos_dre set ativo = false where codigo = v_grupo;
    r := r || 'desativa grupo com conta ativa=PERMITIU (ERRO) | ';
  exception when others then r := r || 'desativa grupo com conta ativa=bloqueado | ';
  end;

  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao) values (l, v_caixa, v_cat, 'receita', 120, 'Rifa');
  select sum(valor) into s from public.rel_dre(l, current_date - 1, current_date + 1, 'caixa') where grupo = v_grupo;
  r := r || format('DRE mostra o grupo=%s (esperado 120) | ', s);

  -- outra loja não vê nem usa
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.grupos_dre where codigo = v_grupo;
  r := r || format('L2 vê o grupo=%s (esperado 0) | ', n);
  begin
    insert into public.categorias_financeiras (loja_id, nome, tipo, grupo) values (l2, 'y', 'receita', v_grupo);
    r := r || 'L2 usa grupo da L=PERMITIU (ERRO) | ';
  exception when others then r := r || 'L2 usa grupo da L=bloqueado | ';
  end;
  begin
    insert into public.grupos_dre (loja_id, nome, tipo) values (l, 'invasão', 'receita');
    r := r || 'L2 cria grupo na L=PERMITIU (ERRO) | ';
  exception when others then r := r || 'L2 cria grupo na L=bloqueado | ';
  end;
  select count(*) into n from public.grupos_dre;
  r := r || format('L2 vê grupos=%s (esperado 14, só os padrão)', n);

  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
