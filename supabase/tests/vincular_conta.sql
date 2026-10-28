-- Saída avulsa vinculada à conta a pagar: estorna o avulso e baixa a conta; saldo da conta bancária não muda.
do $$ declare t uuid := gen_random_uuid(); l uuid; cx uuid; lan uuid; tit uuid; r text := ''; s0 numeric; s1 numeric; s text; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'vc@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia)
  values (l, 'pagar', 'Aluguel do templo', (select id from public.categorias_financeiras where loja_id = l and codigo = 'templo'), 1200, current_date, current_date) returning id into tit;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao)
  values (l, cx, (select id from public.categorias_financeiras where loja_id = l and codigo = 'outras_desp'), 'despesa', 1250, 'PIX enviado') returning id into lan;
  select saldo into s0 from public.contas_saldo where conta_id = cx;
  select string_agg(descricao || '/' || exato, ',') into s from public.sugestoes_para_lancamento(lan);
  r := r || format('sugestões=%s | ', s);
  perform public.vincular_lancamento_titulo(lan, tit);
  select saldo into s1 from public.contas_saldo where conta_id = cx;
  select format('%s pago=%s', (case when valor_pago >= valor then 'quitado' else 'aberto' end), valor_pago) into s from public.titulos where id = tit;
  r := r || format('aluguel=%s | saldo antes/depois=%s/%s (iguais) | ', s, s0, s1);
  begin perform public.vincular_lancamento_titulo(lan, tit); r := r || 'vincular de novo=PERMITIU (ERRO)';
  exception when others then r := r || 'vincular de novo=bloqueado'; end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
