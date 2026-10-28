-- Trocar a categoria de lançamento avulso: só a categoria muda; valor continua imutável.
do $$ declare t uuid := gen_random_uuid(); l uuid; cx uuid; lan uuid; cat2 uuid; r text := ''; s text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'rc@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'caixa';
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao)
  values (l, cx, (select id from public.categorias_financeiras where loja_id = l and codigo = 'outras_desp'), 'despesa', 100, 'X') returning id into lan;
  select id into cat2 from public.categorias_financeiras where loja_id = l and codigo = 'templo';
  perform public.reclassificar_lancamento(lan, cat2);
  select c.codigo into s from public.lancamentos x join public.categorias_financeiras c on c.id = x.categoria_id where x.id = lan;
  r := r || format('nova categoria=%s | ', s);
  reset role;
  begin update public.lancamentos set valor = 1 where id = lan; r := r || 'muda valor (direto no banco)=PERMITIU (ERRO) | ';
  exception when others then r := r || 'muda valor=bloqueado | '; end;
  set local role authenticated;
  begin perform public.reclassificar_lancamento(lan, (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'));
    r := r || 'categoria de receita=PERMITIU (ERRO)';
  exception when others then r := r || 'categoria de receita=bloqueado'; end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
