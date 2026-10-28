-- Situação das mensalidades por irmão e aviso pelo WhatsApp.
do $$
declare
  t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; i_a uuid; i_b uuid; banco uuid; tit uuid;
  r text := ''; n int; s text; ano int := extract(year from current_date)::int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'mi@t.com', 'authenticated', 'authenticated', now()), (x, 'mx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, nome, telefone, cim, data_iniciacao, cpf, email) values (l, 'Antonio Pago', '12999990001', 'M1', '2020-01-01', '00000015202', 'i152x5353@teste.com') returning id into i_a;
  insert into public.irmaos (loja_id, user_id, nome, telefone, cim, data_iniciacao, cpf, email) values (l, x, 'Bento Devedor', '12999990002', 'M2', '2020-01-01', '00000015385', 'i153x5353@teste.com') returning id into i_b;
  select id into banco from public.contas_financeiras where loja_id = l and tipo = 'banco';
  perform public.gerar_mensalidades(l, make_date(ano, 1, 1), 100, make_date(ano, 1, 10));
  perform public.gerar_mensalidades(l, make_date(ano, 2, 1), 100, make_date(ano, 2, 10));
  select id into tit from public.titulos where irmao_id = i_a and competencia = make_date(ano, 1, 1);
  perform public.baixar_titulo(tit, banco, make_date(ano, 1, 9));
  select id into tit from public.titulos where irmao_id = i_a and competencia = make_date(ano, 2, 1);
  perform public.baixar_titulo(tit, banco, make_date(ano, 2, 9));
  select format('%s/%s/%s', total_atrasado, meses_atrasados, array_to_string(meses[1:3], ',')) into s
  from public.situacao_mensalidades(l, ano) where irmao_id = i_b;
  r := r || format('Bento=%s (esperado 200.00/2/atrasado,atrasado,nenhum) | ', s);
  select format('%s/%s', total_aberto, array_to_string(meses[1:2], ',')) into s
  from public.situacao_mensalidades(l, ano) where irmao_id = i_a;
  r := r || format('Antonio=%s (esperado 0/pago,pago) | ', s);
  n := public.cobrar_irmaos(l, array[i_a, i_b], 'Captação reforma do templo', (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao'), 50, current_date + 10);
  r := r || format('cobrança em grupo=%s (esperado 2) | ', n);
  n := public.cobrar_irmaos(l, array[i_a], 'Captação GOB', (select id from public.categorias_financeiras where loja_id = l and codigo = 'captacao'), 300, current_date + 5, 5);
  select string_agg(valor::text || '@' || to_char(vencimento, 'MM'), ',' order by parcela) into s from public.titulos where irmao_id = i_a and descricao like 'Captação GOB%';
  r := r || format('parcelado=%s títulos: %s | ', n, s);
  select format('%s/%s', outros_aberto, outros_qtd) into s from public.situacao_mensalidades(l, ano) where irmao_id = i_a;
  r := r || format('Antonio outras pendências=%s (esperado 350.00/6) | ', s);
  insert into public.tesouraria_config (loja_id, multa_percentual, juros_mensal) values (l, 2, 1);
  n := public.avisar_mensalidades(l, array[i_b], 'Irmão {nome}, há {valor} em aberto ({meses} meses).');
  select mensagem into s from public.notificacoes where irmao_id = i_b and tipo = 'debito' order by criado_em desc limit 1;
  r := r || format('aviso=%s | ', replace(s, E'\n', ' / '));
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform * from public.situacao_mensalidades(l, ano);
    r := r || 'irmão comum vê=PERMITIU (ERRO)';
  exception when others then r := r || 'irmão comum vê=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
