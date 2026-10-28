-- Quitar parcelas: só o próprio irmão; parcela já paga fica; novas conta = soma das abertas.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); y uuid := gen_random_uuid();
  l uuid; cx uuid; ix uuid; g uuid; p1 uuid; r text := ''; j jsonb; s text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'qp@t.com', 'authenticated', 'authenticated', now()),
    (x, 'qpx@t.com', 'authenticated', 'authenticated', now()), (y, 'qpy@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 3, 'QX', '2015-01-01', '52998224725', 'qx@teste.com') returning id into ix;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, y, 'Irmão Y', 3, 'QY', '2015-01-01', '11144477735', 'qy@teste.com');
  perform public.cobrar_irmaos(l, array[ix], 'Captação do templo', (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao'), 300, current_date, 5);
  select grupo_id into g from public.titulos where irmao_id = ix limit 1;
  select id into p1 from public.titulos where grupo_id = g and parcela = 1;
  perform public.baixar_titulo(p1, cx, current_date);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', y, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.quitar_parcelas(g); r := r || 'outro irmão quita=PERMITIU (ERRO) | ';
  exception when others then r := r || 'outro irmão quita=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  j := public.quitar_parcelas(g);
  select descricao || ' = ' || valor into s from public.titulos where id = (j->>'titulo')::uuid;
  r := r || format('nova conta=%s (%s parcelas) | ', s, j->>'parcelas');
  select string_agg(parcela || ':' || case when cancelado then 'cancelada' when valor_pago >= valor then 'paga' else 'aberta' end, ',' order by parcela) into s
    from public.titulos where grupo_id = g;
  r := r || format('parcelas=%s | ', s);
  begin perform public.quitar_parcelas(g); r := r || 'de novo=PERMITIU (ERRO)';
  exception when others then r := r || 'de novo=bloqueado'; end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
