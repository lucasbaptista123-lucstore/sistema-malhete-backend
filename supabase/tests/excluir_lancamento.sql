-- Excluir lançamento: some do saldo no próprio período, extrato volta a pendente, só quem lança exclui.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; cx uuid; la uuid; e uuid; s0 numeric; s1 numeric; r text := ''; d date := current_date - 40; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'tel@t.com', 'authenticated', 'authenticated', now()),
    (x, 'telx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  select saldo into s0 from public.contas_saldo where conta_id = cx;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao)
  values (l, cx, (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 'receita', 48, d, d, 'duplicado')
  returning id into la;
  reset role;
  insert into public.extrato_itens (loja_id, conta_id, origem, id_externo, data, valor, descricao, situacao, lancamento_id)
  values (l, cx, 'asaas', 'ft_x', d, 48, 'Cobrança recebida', 'conciliado', la) returning id into e;
  -- outro usuário sem cargo não exclui
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.excluir_lancamento(la, 'teste'); r := r || 'estranho excluiu=SIM (erro) | ';
  exception when others then r := r || 'estranho excluiu=não | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.excluir_lancamento(la, 'Duplicidade');
  select saldo into s1 from public.contas_saldo where conta_id = cx;
  r := r || format('saldo volta=%s | estorno na mesma data=%s | extrato=%s | de novo=',
    case when s1 = s0 then 'sim' else 'não' end,
    (select count(*) from public.lancamentos where estorno_de = la and data = d),
    (select situacao from public.extrato_itens where id = e));
  begin perform public.excluir_lancamento(la, 'x'); r := r || 'excluiu 2x (erro)';
  exception when others then r := r || 'bloqueado'; end;
  reset role;
  raise exception 'RESULTADO: % (esperado: não | sim | 1 | pendente | bloqueado)', r;
end $$;
