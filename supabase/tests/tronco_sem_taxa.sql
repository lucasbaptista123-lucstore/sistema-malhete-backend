-- Tronco sem taxa: PIX direto na chave (extrato sem cobrança) com o valor da contribuição aguardando vira Tronco.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; cx uuid; ix uuid; c1 uuid; r text := ''; s text; j jsonb; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tst@t.com', 'authenticated', 'authenticated', now()),
    (x, 'tstx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Doador', 3, 'TS', '2015-01-01', '52998224725', 'ts@teste.com') returning id into ix;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status) values (l, ix, 4, 'TRONCOA', 'aguardando') returning id into c1;
  reset role;
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  insert into public.extrato_itens (loja_id, conta_id, origem, id_externo, data, valor, descricao) values
    (l, cx, 'asaas', 'ft_1', current_date, 4, 'Pix recebido de IRMAO DOADOR'),
    (l, cx, 'asaas', 'ft_2', current_date, 70, 'Pix recebido de FULANO');
  j := public.asaas_concluir_sincronizacao(l, null, false);
  select status into s from public.tronco_contribuicoes where id = c1;
  r := r || format('contribuição=%s | ', s);
  select string_agg((select codigo from public.categorias_financeiras k where k.id = categoria_id) || ' ' || valor, ', ' order by valor) into s
    from public.lancamentos where documento in ('ft_1', 'ft_2');
  r := r || format('lançamentos=%s | taxa=%s', s, (select count(*) from public.lancamentos where loja_id = l and descricao like 'Tarifa%'));
  raise exception 'RESULTADO: %', r;
end $$;
