-- Teste do financeiro completo. Roda tudo numa transação e desfaz no final
-- (o resultado volta na mensagem de erro proposital "RESULTADO").
do $$
declare
  a uuid := gen_random_uuid(); -- Tesoureira da Loja 1
  b uuid := gen_random_uuid(); -- aprendiz da Loja 1
  h uuid := gen_random_uuid(); -- Hospitaleiro da Loja 1
  c uuid := gen_random_uuid(); -- admin da Loja 2
  l1 uuid; l2 uuid; v_irmao_a uuid; v_irmao_b uuid; v_irmao_h uuid; v_gestao uuid;
  v_caixa uuid; v_banco uuid; v_tronco uuid; v_caixa_l2 uuid;
  v_cat_aluguel uuid; v_cat_rec uuid; v_cat_tronco uuid; v_cat_l2 uuid;
  v_forn uuid; v_centro uuid; v_grupo uuid; v_tit uuid; v_baixa uuid; v_mens_b uuid; v_lanc uuid;
  rito uuid := (select id from public.ritos where sigla = 'REAA');
  ori uuid := (select id from public.orientes where uf = 'SP');
  r text := '';
  n int;
  s numeric;
  t text;
begin
  insert into auth.users (id, email, aud, role) values
    (a, 'a@teste.local', 'authenticated', 'authenticated'),
    (b, 'b@teste.local', 'authenticated', 'authenticated'),
    (h, 'h@teste.local', 'authenticated', 'authenticated'),
    (c, 'c@teste.local', 'authenticated', 'authenticated');

  -- ---- Loja 2 (isolamento)
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l2 := public.criar_loja('Loja Teste 2', '99', ori, rito, 'Campinas', 'SP', 'Irmão C');
  select id into v_caixa_l2 from public.contas_financeiras where loja_id = l2 and tipo = 'caixa';
  select id into v_cat_l2 from public.categorias_financeiras where loja_id = l2 and codigo = 'templo';

  -- ---- Loja 1: estrutura padrão
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l1 := public.criar_loja('Loja Teste 1', '1234', ori, rito, 'São Paulo', 'SP', 'Irmã A');
  select count(*) into n from public.categorias_financeiras where loja_id = l1;
  r := r || format('categorias padrão=%s (esperado 22) | ', n);
  select count(*) into n from public.categorias_financeiras where loja_id = l1 and grupo is null;
  r := r || format('categorias sem grupo=%s (esperado 0) | ', n);
  select id into v_caixa from public.contas_financeiras where loja_id = l1 and tipo = 'caixa';
  select id into v_banco from public.contas_financeiras where loja_id = l1 and tipo = 'banco';
  select id into v_tronco from public.contas_financeiras where loja_id = l1 and tipo = 'tronco';
  select id into v_cat_aluguel from public.categorias_financeiras where loja_id = l1 and codigo = 'templo';
  select id into v_cat_rec from public.categorias_financeiras where loja_id = l1 and codigo = 'doacoes';
  select id into v_cat_tronco from public.categorias_financeiras where loja_id = l1 and codigo = 'tronco';

  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l1, b, 'Irmão B', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000016608', 'i166x5954@teste.com') returning id into v_irmao_b;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l1, h, 'Irmão H', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000016780', 'i167x5954@teste.com') returning id into v_irmao_h;
  select id into v_irmao_a from public.irmaos where loja_id = l1 and user_id = a;
  insert into public.gestoes (loja_id, nome, inicio, fim)
    values (l1, 'Gestão', current_date - 30, current_date + 300) returning id into v_gestao;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l1, v_gestao, v_irmao_a, id, current_date - 30, current_date + 300 from public.loja_cargos where loja_id = l1 and codigo = 'tesoureiro';
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l1, v_gestao, v_irmao_h, id, current_date - 30, current_date + 300 from public.loja_cargos where loja_id = l1 and codigo = 'hospitaleiro';
  reset role;
  update public.irmaos set admin_loja = false where id = v_irmao_a;
  set local role authenticated;

  -- ---- Plano de contas
  insert into public.categorias_financeiras (loja_id, nome, tipo) values (l1, 'Rifa', 'receita');
  select grupo into t from public.categorias_financeiras where loja_id = l1 and nome = 'Rifa';
  r := r || format('categoria nova sem grupo vai para=%s (esperado outras_receitas) | ', t);
  begin
    update public.categorias_financeiras set grupo = 'beneficencia' where loja_id = l1 and nome = 'Rifa';
    r := r || 'grupo de despesa em receita=PERMITIU (ERRO) | ';
  exception when others then r := r || 'grupo de despesa em receita=bloqueado | ';
  end;
  update public.categorias_financeiras set grupo = 'receitas_eventos' where loja_id = l1 and nome = 'Rifa';
  get diagnostics n = row_count;
  r := r || format('reclassifica grupo=%s (esperado 1) | ', n);

  -- ---- Cadastros
  insert into public.favorecidos (loja_id, nome, tipo, documento) values (l1, 'Imobiliária X', 'fornecedor', '00.000.000/0001-00') returning id into v_forn;
  insert into public.centros_custo (loja_id, nome) values (l1, 'Reforma do templo') returning id into v_centro;

  -- ---- Contas a pagar: aluguel repetido 3 meses
  v_grupo := public.criar_titulos(l1, 'pagar', 'Aluguel', v_cat_aluguel, 1000, current_date - 5, 3, 'repetir',
                                  null, v_forn, null, v_centro);
  select count(*), sum(valor) into n, s from public.titulos where grupo_id = v_grupo;
  r := r || format('aluguel repetido=%s títulos / %s (esperado 3 / 3000) | ', n, s);
  select id into v_tit from public.titulos where grupo_id = v_grupo and parcela = 1;
  select situacao into t from public.titulos_situacao where id = v_tit;
  r := r || format('1º aluguel vencido=%s (esperado atrasado) | ', t);

  -- parcelado: 100 em 3 → 33,34 + 33,33 + 33,33
  v_grupo := public.criar_titulos(l1, 'pagar', 'Cadeiras', v_cat_aluguel, 100, current_date + 10, 3, 'parcelar');
  select string_agg(valor::text, ',' order by parcela) into t from public.titulos where grupo_id = v_grupo;
  r := r || format('parcelas=%s (esperado 33.34,33.33,33.33) | ', t);
  select count(distinct competencia) into n from public.titulos where grupo_id = v_grupo;
  r := r || format('parcelado competências=%s (esperado 1) | ', n);

  begin
    perform public.criar_titulos(l1, 'pagar', 'x', v_cat_rec, 10, current_date);
    r := r || 'pagar com categoria de receita=PERMITIU (ERRO) | ';
  exception when others then r := r || 'pagar com categoria de receita=bloqueado | ';
  end;
  begin
    perform public.criar_titulos(l1, 'pagar', 'x', v_cat_l2, 10, current_date);
    r := r || 'categoria da L2=PERMITIU (ERRO) | ';
  exception when others then r := r || 'categoria da L2=bloqueado | ';
  end;

  -- baixa parcial 400 com 10 de juros
  v_baixa := public.baixar_titulo(v_tit, v_banco, current_date, 400, 10, 0);
  select situacao || ' pago=' || valor_pago || ' saldo=' || saldo into t from public.titulos_situacao where id = v_tit;
  r := r || format('após parcial=%s (esperado atrasado pago=400 saldo=600) | ', t);
  select valor into s from public.lancamentos where id = v_baixa;
  r := r || format('lançamento da parcial=%s (esperado 410) | ', s);
  begin
    perform public.baixar_titulo(v_tit, v_banco, current_date, 700);
    r := r || 'baixa maior que saldo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'baixa maior que saldo=bloqueado | ';
  end;
  begin
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao, titulo_id, abatimento)
      values (l1, v_banco, v_cat_aluguel, 'despesa', 600, 'baixa direta', v_tit, 600);
    r := r || 'baixa sem a função=PERMITIU (ERRO) | ';
  exception when others then r := r || 'baixa sem a função=bloqueado | ';
  end;
  begin
    perform public.cancelar_titulo(v_tit, 'x');
    r := r || 'cancelar com baixa=PERMITIU (ERRO) | ';
  exception when others then r := r || 'cancelar com baixa=bloqueado | ';
  end;
  begin
    update public.titulos set valor_pago = 1000 where id = v_tit;
    r := r || 'mexer em valor_pago=PERMITIU (ERRO) | ';
  exception when others then r := r || 'mexer em valor_pago=bloqueado | ';
  end;

  -- quita o resto com 50 de desconto
  perform public.baixar_titulo(v_tit, v_banco, current_date, null, 0, 50);
  select situacao into t from public.titulos_situacao where id = v_tit;
  r := r || format('após quitar=%s (esperado pago) | ', t);
  select saldo into s from public.contas_saldo where conta_id = v_banco;
  r := r || format('saldo banco=%s (esperado -960) | ', s);

  -- estorno da 1ª baixa reabre 400
  perform public.estornar_lancamento(v_baixa, 'valor errado');
  select situacao || ' pago=' || valor_pago into t from public.titulos_situacao where id = v_tit;
  r := r || format('após estorno=%s (esperado atrasado pago=600) | ', t);

  -- edição de título em aberto (2º aluguel) e cancelamento das seguintes
  select id into v_tit from public.titulos where descricao like 'Aluguel%' and parcela = 2 and loja_id = l1;
  update public.titulos set valor = 1100, vencimento = vencimento + 1 where id = v_tit;
  get diagnostics n = row_count;
  r := r || format('edita título aberto=%s (esperado 1) | ', n);
  n := public.cancelar_titulo(v_tit, 'Mudamos de imóvel', true);
  r := r || format('cancela este e seguintes=%s (esperado 2) | ', n);
  begin
    update public.titulos set descricao = 'x' where id = v_tit;
    r := r || 'editar cancelado=PERMITIU (ERRO) | ';
  exception when others then r := r || 'editar cancelado=bloqueado | ';
  end;
  begin
    delete from public.titulos where id = v_tit;
    get diagnostics n = row_count;
    r := r || format('apagar título=%s linhas (esperado bloqueio/0) | ', n);
  exception when others then r := r || 'apagar título=bloqueado | ';
  end;

  -- ---- Mensalidades como contas a receber
  n := public.gerar_mensalidades(l1, date_trunc('month', current_date)::date, 80, current_date - 1);
  r := r || format('mensalidades geradas=%s (esperado 3) | ', n);
  n := public.gerar_mensalidades(l1, date_trunc('month', current_date)::date, 80, current_date - 1);
  r := r || format('gerar de novo=%s (esperado 0) | ', n);
  select count(*) into n from public.inadimplencia where loja_id = l1 and irmao_id is not null;
  r := r || format('irmãos inadimplentes=%s (esperado 3) | ', n);
  select id into v_mens_b from public.titulos where irmao_id = v_irmao_b and origem = 'mensalidade';
  perform public.baixar_titulo(v_mens_b, v_caixa);
  select count(*) into n from public.inadimplencia where loja_id = l1 and irmao_id is not null;
  r := r || format('inadimplentes após pagar=%s (esperado 2) | ', n);
  begin
    perform public.baixar_titulo((select id from public.titulos where irmao_id = v_irmao_h and origem = 'mensalidade'), v_tronco);
    r := r || 'mensalidade no tronco=PERMITIU (ERRO) | ';
  exception when others then r := r || 'mensalidade no tronco=bloqueado | ';
  end;

  -- avulso (sem título) e transferência
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao, competencia)
    values (l1, v_caixa, v_cat_rec, 'receita', 500, 'Doação', date_trunc('month', current_date)::date) returning id into v_lanc;
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, tipo, valor, descricao)
    values (l1, v_caixa, v_banco, 'transferencia', 200, 'Depósito');

  -- ---- Relatórios
  select coalesce(sum(saldo), 0) into s from public.saldos_em(l1, current_date);
  r := r || format('saldo total hoje=%s (esperado 30) | ', s);
  select coalesce(sum(valor), 0) into s from public.rel_dre(l1, date_trunc('month', current_date)::date - 60, current_date + 400, 'caixa') d
    join public.grupos_dre g on g.codigo = d.grupo where g.tipo = 'receita';
  r := r || format('DRE caixa receitas=%s (esperado 580) | ', s);
  select coalesce(sum(valor), 0) into s from public.rel_dre(l1, date_trunc('month', current_date)::date - 60, current_date + 400, 'competencia') d
    join public.grupos_dre g on g.codigo = d.grupo where g.tipo = 'receita';
  r := r || format('DRE competência receitas=%s (esperado 740 = 3x80 + 500) | ', s);
  select coalesce(sum(entradas_previstas), 0), coalesce(sum(saidas_previstas), 0) into s, n
    from public.rel_fluxo_caixa(l1, current_date, current_date + 400);
  r := r || format('fluxo previsto entradas=%s saídas=%s (esperado 160 / 500) | ', s, n);

  -- ---- Aprendiz B: vê só os próprios títulos a receber
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.titulos_situacao;
  r := r || format('B vê títulos=%s (esperado 1) | ', n);
  select situacao into t from public.titulos_situacao;
  r := r || format('B vê a dele como=%s (esperado pago) | ', t);
  select count(*) into n from public.lancamentos;
  r := r || format('B vê lançamentos=%s (esperado 0) | ', n);
  select count(*) into n from public.favorecidos;
  r := r || format('B vê fornecedores=%s (esperado 0) | ', n);
  select count(*) into n from public.rel_dre(l1, current_date - 400, current_date + 400, 'caixa');
  r := r || format('B vê DRE=%s linhas (esperado 0) | ', n);
  begin
    perform public.criar_titulos(l1, 'pagar', 'x', v_cat_aluguel, 10, current_date);
    r := r || 'B cria conta a pagar=PERMITIU (ERRO) | ';
  exception when others then r := r || 'B cria conta a pagar=bloqueado | ';
  end;

  -- ---- Hospitaleiro: só tronco
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', h, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao)
      values (l1, v_tronco, v_cat_tronco, 'receita', 50, 'Tronco da sessão');
    r := r || 'H lança no tronco=PERMITIU (ERRO) | ';
  exception when others then r := r || 'H lança no tronco=bloqueado (Tesouraria lança) | ';
  end;
  select count(*) into n from public.saldos_em(l1, current_date);
  r := r || format('H acompanha contas=%s (esperado 1, só o tronco) | ', n);
  select count(*) into n from public.titulos;
  r := r || format('H vê títulos=%s (esperado 1, a própria mensalidade) | ', n);

  -- ---- Loja 2 não vê nada da Loja 1
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.titulos where loja_id = l1;
  r := r || format('C vê títulos L1=%s (esperado 0) | ', n);
  select count(*) into n from public.rel_fluxo_caixa(l1, current_date - 400, current_date + 400);
  r := r || format('C vê fluxo L1=%s (esperado 0) | ', n);

  -- ---- anônimo
  reset role;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  begin
    select count(*) into n from public.titulos;
    r := r || format('anon vê títulos=%s (esperado 0) | ', n);
  exception when others then r := r || 'anon vê títulos=bloqueado | ';
  end;

  reset role;
  select count(*) into n from public.audit_log where loja_id = l1 and tabela = 'titulos';
  r := r || format('auditoria de títulos=%s', n);

  raise exception 'RESULTADO: %', r;
end $$;
