-- Teste da conciliação bancária. Roda tudo numa transação e desfaz no final
-- (o resultado volta na mensagem de erro proposital "RESULTADO").
do $$
declare
  a uuid := gen_random_uuid(); -- Tesoureira da Loja 1
  b uuid := gen_random_uuid(); -- aprendiz da Loja 1
  c uuid := gen_random_uuid(); -- admin da Loja 2
  l1 uuid; l2 uuid; v_irmao_a uuid; v_irmao_b uuid; v_gestao uuid;
  v_caixa uuid; v_banco uuid; v_asaas uuid; v_cat_tarifa uuid; v_cat_aluguel uuid;
  v_tit uuid; v_mens uuid; v_lanc uuid; v_res jsonb;
  i_mens uuid; i_aluguel uuid; i_tarifa uuid; i_dep uuid; i_dup uuid; i_lanc uuid;
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
    (c, 'c@teste.local', 'authenticated', 'authenticated');

  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l2 := public.criar_loja('Loja Teste 2', '99', ori, rito, 'Campinas', 'SP', 'Irmão C');

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l1 := public.criar_loja('Loja Teste 1', '1234', ori, rito, 'São Paulo', 'SP', 'Irmã A');
  select id into v_caixa from public.contas_financeiras where loja_id = l1 and tipo = 'caixa';
  select id into v_banco from public.contas_financeiras where loja_id = l1 and tipo = 'banco';
  select id into v_cat_tarifa from public.categorias_financeiras where loja_id = l1 and codigo = 'tarifas';
  select id into v_cat_aluguel from public.categorias_financeiras where loja_id = l1 and codigo = 'templo';
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l1, b, 'Irmão B', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000011398', 'i113x1629@teste.com') returning id into v_irmao_b;
  select id into v_irmao_a from public.irmaos where loja_id = l1 and user_id = a;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l1, 'G', current_date - 30, current_date + 300) returning id into v_gestao;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l1, v_gestao, v_irmao_a, id, current_date - 30, current_date + 300 from public.loja_cargos where loja_id = l1 and codigo = 'tesoureiro';
  reset role;
  update public.irmaos set admin_loja = false where id = v_irmao_a;
  set local role authenticated;

  -- contas a pagar/receber que o extrato vai quitar
  perform public.criar_titulos(l1, 'pagar', 'Aluguel', v_cat_aluguel, 1000, current_date - 2);
  select id into v_tit from public.titulos where loja_id = l1 and descricao = 'Aluguel';
  perform public.gerar_mensalidades(l1, date_trunc('month', current_date)::date, 80, current_date - 3);
  select id into v_mens from public.titulos where irmao_id = v_irmao_b;
  -- lançamento já existente no sistema (depósito do caixa no banco)
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, tipo, valor, data, descricao)
    values (l1, v_caixa, v_banco, 'transferencia', 300, current_date - 1, 'Depósito') returning id into v_lanc;

  -- ---- importação OFX
  v_res := public.importar_extrato(l1, v_banco, 'ofx', 'extrato.ofx', jsonb_build_array(
    jsonb_build_object('id_externo', 'F1', 'data', current_date - 3, 'valor', 80, 'descricao', 'PIX RECEBIDO IRMAO B'),
    jsonb_build_object('id_externo', 'F2', 'data', current_date - 2, 'valor', -1050, 'descricao', 'TED ALUGUEL'),
    jsonb_build_object('id_externo', 'F3', 'data', current_date - 2, 'valor', -12.5, 'descricao', 'TARIFA PACOTE'),
    jsonb_build_object('id_externo', 'F4', 'data', current_date - 1, 'valor', 300, 'descricao', 'DEPOSITO'),
    jsonb_build_object('id_externo', 'F5', 'data', current_date, 'valor', 200, 'descricao', 'SAQUE ASAAS')
  ), 1517.50, current_date);
  r := r || format('importou=%s/%s (esperado 5/5) | ', v_res->>'novos', v_res->>'total');
  v_res := public.importar_extrato(l1, v_banco, 'ofx', 'extrato.ofx', jsonb_build_array(
    jsonb_build_object('id_externo', 'F5', 'data', current_date, 'valor', 200, 'descricao', 'SAQUE ASAAS'),
    jsonb_build_object('id_externo', 'F6', 'data', current_date, 'valor', 5, 'descricao', 'ESTORNO TARIFA')
  ));
  r := r || format('reimportou=%s novos (esperado 1) | ', v_res->>'novos');
  select id into i_mens from public.extrato_itens where conta_id = v_banco and id_externo = 'F1';
  select id into i_aluguel from public.extrato_itens where conta_id = v_banco and id_externo = 'F2';
  select id into i_tarifa from public.extrato_itens where conta_id = v_banco and id_externo = 'F3';
  select id into i_lanc from public.extrato_itens where conta_id = v_banco and id_externo = 'F4';
  select id into i_dep from public.extrato_itens where conta_id = v_banco and id_externo = 'F5';
  select id into i_dup from public.extrato_itens where conta_id = v_banco and id_externo = 'F6';

  -- ---- sugestões
  select count(*) into n from public.sugestoes_conciliacao(v_banco) where item_id = i_mens and tipo = 'titulo' and alvo_id = v_mens;
  r := r || format('sugere mensalidade p/ PIX=%s (esperado 1) | ', n);
  select count(*) into n from public.sugestoes_conciliacao(v_banco) where item_id = i_lanc and tipo = 'lancamento' and alvo_id = v_lanc;
  r := r || format('sugere depósito existente=%s (esperado 1) | ', n);

  -- ---- conciliações
  perform public.conciliar_titulo(i_mens, v_mens);
  select situacao into t from public.titulos_situacao where id = v_mens;
  r := r || format('mensalidade após conciliar=%s (esperado pago) | ', t);
  perform public.conciliar_titulo(i_aluguel, v_tit);
  select situacao into t from public.titulos_situacao where id = v_tit;
  select l.valor into s from public.lancamentos l join public.extrato_itens e on e.lancamento_id = l.id where e.id = i_aluguel;
  r := r || format('aluguel 1050 p/ conta 1000=%s, lançado %s (esperado pago, 1050) | ', t, s);
  perform public.conciliar_novo_lancamento(i_tarifa, v_cat_tarifa, null);
  r := r || 'tarifa vira lançamento=ok | ';
  perform public.conciliar(i_lanc, v_lanc);
  r := r || 'depósito pareado=ok | ';
  begin
    perform public.conciliar(i_dep, v_lanc);
    r := r || 'mesmo lançamento 2x=PERMITIU (ERRO) | ';
  exception when others then r := r || 'mesmo lançamento 2x=bloqueado | ';
  end;
  begin
    perform public.conciliar_titulo(i_dep, v_tit);
    r := r || 'entrada baixando conta a pagar=PERMITIU (ERRO) | ';
  exception when others then r := r || 'entrada baixando conta a pagar=bloqueado | ';
  end;
  perform public.conciliar_transferencia(i_dep, v_caixa, 'Saque');
  select saldo into s from public.contas_saldo where conta_id = v_caixa;
  r := r || format('caixa após transferências=%s (esperado -500) | ', s);
  perform public.ignorar_extrato(i_dup, 'Estorno de tarifa já compensado');
  select count(*) into n from public.extrato_itens where conta_id = v_banco and situacao = 'pendente';
  r := r || format('pendentes=%s (esperado 0) | ', n);
  select saldo into s from public.contas_saldo where conta_id = v_banco;
  r := r || format('saldo banco sistema=%s (esperado -482.50) | ', s);
  perform public.desconciliar(i_tarifa);
  select situacao into t from public.extrato_itens where id = i_tarifa;
  r := r || format('desconciliar=%s (esperado pendente) | ', t);
  begin
    perform public.conciliar(i_tarifa, v_lanc);
    r := r || 'valor diferente=PERMITIU (ERRO) | ';
  exception when others then r := r || 'valor diferente=bloqueado | ';
  end;

  -- ---- Asaas: chave no cofre
  v_asaas := public.asaas_conectar(l1, '$aact_hmlg_0000000000000000000000000000TESTE', 'sandbox');
  select nome into t from public.contas_financeiras where id = v_asaas;
  r := r || format('conta criada=%s (esperado Asaas) | ', t);
  select chave_final into t from public.integracoes_asaas where loja_id = l1;
  r := r || format('mostra só o final=%s (esperado ESTE) | ', t);
  begin
    select segredo_id::text into t from public.integracoes_asaas where loja_id = l1;
    r := r || 'tesoureira lê segredo_id=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureira lê segredo_id=bloqueado | ';
  end;
  begin
    select chave into t from public.asaas_credenciais(l1);
    r := r || 'tesoureira lê chave=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureira lê chave=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  select chave into t from public.asaas_credenciais(l1);
  r := r || format('service_role lê chave=%s (esperado sim) | ', case when t like '$aact_hmlg_%' then 'sim' else 'não' end);

  -- ---- aprendiz não vê extrato nem integração
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.extrato_itens;
  r := r || format('B vê extrato=%s (esperado 0) | ', n);
  select count(*) into n from public.integracoes_asaas;
  r := r || format('B vê integração=%s (esperado 0) | ', n);
  begin
    perform public.importar_extrato(l1, v_banco, 'ofx', 'x', '[]'::jsonb);
    r := r || 'B importa=PERMITIU (ERRO) | ';
  exception when others then r := r || 'B importa=bloqueado | ';
  end;

  -- ---- Loja 2 não vê nada
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.extrato_itens where loja_id = l1;
  r := r || format('C vê extrato L1=%s (esperado 0) | ', n);
  begin
    perform public.ignorar_extrato(i_tarifa, 'x');
    r := r || 'C mexe no extrato L1=PERMITIU (ERRO) | ';
  exception when others then r := r || 'C mexe no extrato L1=bloqueado | ';
  end;
  begin
    perform public.asaas_conectar(l1, '$aact_hmlg_000000000000000000000000000000000', 'sandbox');
    r := r || 'C troca chave da L1=PERMITIU (ERRO) | ';
  exception when others then r := r || 'C troca chave da L1=bloqueado | ';
  end;

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.asaas_desconectar(l1);
  reset role;
  select count(*) into n from vault.secrets where name = 'asaas_' || l1;
  r := r || format('desconectar apaga a chave=%s (esperado 0)', n);

  raise exception 'RESULTADO: %', r;
end $$;
