-- Gerar o ano todo com Asaas: só a cobrança que vence em até 20 dias manda aviso na criação.
do $$
declare vm uuid := gen_random_uuid(); l uuid; i_b uuid; t uuid; k int; r text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (vm, 'aclvm@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Lote', '8', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Bento Lote', 3, 'LO1', '2015-01-01', '39053344705', 'bl@teste.com', '12999990000') returning id into i_b;
  reset role;
  for k in 0..11 loop
    insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id, origem)
    values (l, 'receber', 'Mensalidade ' || k, (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 100,
            (date_trunc('month', current_date) + make_interval(months => k) + interval '9 days')::date,
            (date_trunc('month', current_date) + make_interval(months => k))::date, i_b, 'mensalidade') returning id into t;
    perform public.asaas_vincular(l, t, i_b, 'cus_x', jsonb_build_object('id', 'pay_' || k, 'invoiceUrl', 'https://x/' || k, 'billingType', 'PIX', 'status', 'PENDING'));
  end loop;
  r := format('avisos de cobrança criados=%s (de 12 cobranças)', (select count(*) from public.notificacoes where irmao_id = i_b and tipo = 'cobranca'));
  raise exception 'RESULTADO: %', r;
end $$;
