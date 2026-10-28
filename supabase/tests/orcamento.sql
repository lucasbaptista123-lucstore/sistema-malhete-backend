-- Orçamento: Tesoureiro edita, copia o realizado do ano anterior com reajuste, aprova e trava; irmão comum não vê.
do $$
declare
  t uuid := gen_random_uuid(); b uuid := gen_random_uuid(); l uuid; cx uuid; cat uuid; r text := ''; n int; v numeric;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'orc@t.com', 'authenticated', 'authenticated', now()), (b, 'orcb@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'caixa';
  select id into cat from public.categorias_financeiras where loja_id = l and codigo = 'templo';
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao)
  values (l, cx, cat, 'despesa', 1000, make_date(extract(year from current_date)::int - 1, 3, 10), 'Aluguel');
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, b, 'Irmão B', 'O1', '2020-01-01', '00000016861', 'i168x6239@teste.com');
  n := public.orcamento_copiar_realizado(l, extract(year from current_date)::int, 10);
  select valor into v from public.orcamento_itens i join public.orcamentos o on o.id = i.orcamento_id
  where o.loja_id = l and i.categoria_id = cat and i.mes = 3;
  r := r || format('copiou do ano anterior +10%%=%s (esperado 1100.00) | ', v);
  perform public.orcamento_salvar(l, extract(year from current_date)::int, cat, array[100,100,100,100,100,100,100,100,100,100,100,100]::numeric[]);
  select sum(valor) into v from public.orcamento_itens i join public.orcamentos o on o.id = i.orcamento_id where o.loja_id = l and i.categoria_id = cat;
  r := r || format('salvou 12 meses=%s (esperado 1200.00) | ', v);
  update public.orcamentos set status = 'aprovado', aprovado_em = current_date where loja_id = l;
  begin
    perform public.orcamento_salvar(l, extract(year from current_date)::int, cat, array[1,1,1,1,1,1,1,1,1,1,1,1]::numeric[]);
    r := r || 'altera aprovado=PERMITIU (ERRO) | ';
  exception when others then r := r || 'altera aprovado=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.orcamento_itens;
  r := r || format('irmão comum vê itens=%s (esperado 0) | ', n);
  begin
    perform public.orcamento_salvar(l, extract(year from current_date)::int + 1, cat, array[1,1,1,1,1,1,1,1,1,1,1,1]::numeric[]);
    r := r || 'irmão comum edita=PERMITIU (ERRO)';
  exception when others then r := r || 'irmão comum edita=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
