-- Tronco sem contar duas vezes (0119, 13/11): PIX do Tronco que o Asaas não reconheceu (pago da conta da esposa).
-- A) "Confirmar no Tronco" usa o "PIX recebido" que já entrou: estorno + Tronco anônimo na mesma conta, conta
--    automática cancelada, contribuição confirmada, nada na conta Tronco, saldo do Asaas igual ao PIX (50).
-- B) Com Asaas e sem o PIX, não confirma (0120); sem Asaas, lança na conta Tronco (como antes).
-- C) Movimentações → "É do Tronco" num PIX sem dono e sem contribuição: vira Tronco; irmão sem cargo não consegue.
-- D) PIX de irmão identificado pelo CPF (conta automática com o nome dele): "É do Tronco" aceita e apaga o nome (0122).
do $$ declare
  t uuid := gen_random_uuid(); u uuid := gen_random_uuid(); l uuid; cx uuid; ctr uuid; ia uuid; c50 uuid; c20 uuid;
  lp uuid; lp3 uuid; novo uuid; auto uuid; soma numeric; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'ttp@t.com', 'authenticated', 'authenticated', now()), (u, 'utp@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  select id into ctr from public.contas_financeiras where loja_id = l and tipo = 'tronco' and ativa;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao) values
    (l, 'Fulano Sem Cpf', 3, '1', '2020-01-01', 'ativo') returning id into ia;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, user_id) values
    (l, 'Beltrano Sem Cargo', 3, '2', '2020-01-01', 'ativo', u);
  perform set_config('malhete.sistema', 'off', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem)
    values (l, ia, 50, 'TRONCOA', 'informada', 'pix_chave') returning id into c50;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem)
    values (l, ia, 20, 'TRONCOB', 'informada', 'pix_chave') returning id into c20;

  -- PIX de R$ 50 da esposa (CPF que não é de irmão): o Asaas vira "PIX recebido" (conta automática)
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_E', 'value', 50, 'netValue', 50, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_E', 'name', 'Maria Esposa', 'cpfCnpj', '52998224725'));
  select id, private.conta_automatica_de_pix(id) into lp, auto from public.lancamentos
  where loja_id = l and documento = 'pay_E' and tipo = 'receita' and estorno_de is null;
  if lp is null or auto is null then raise exception 'FALHOU preparo: PIX recebido não virou conta automática (%/%)', lp, auto; end if;

  -- A
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_tronco(c50, true);
  reset role;
  select lancamento_id into novo from public.tronco_contribuicoes where id = c50 and status = 'confirmada';
  if novo is null then raise exception 'FALHOU A: contribuição não confirmada'; end if;
  if (select k.codigo from public.lancamentos x join public.categorias_financeiras k on k.id = x.categoria_id where x.id = novo) <> 'tronco'
     or (select conta_id from public.lancamentos where id = novo) <> cx
     or (select irmao_id is not null or favorecido_id is not null from public.lancamentos where id = novo) then
    raise exception 'FALHOU A: lançamento do Tronco errado';
  end if;
  if not exists (select 1 from public.lancamentos where estorno_de = lp) then raise exception 'FALHOU A: PIX recebido não saiu'; end if;
  if not (select cancelado from public.titulos where id = auto) then raise exception 'FALHOU A: conta automática ficou'; end if;
  if exists (select 1 from public.lancamentos where conta_id = ctr and valor = 50) then raise exception 'FALHOU A: contou duas vezes (conta Tronco)'; end if;
  select sum(valor) into soma from public.lancamentos where loja_id = l and documento = 'pay_E';
  if soma <> 50 then raise exception 'FALHOU A: saldo do PIX = %', soma; end if;

  -- B) com Asaas e sem o PIX: não confirma (0120); sem Asaas: lança na conta Tronco
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.decidir_tronco(c20, true);
    raise exception 'FALHOU B: confirmou sem PIX no Asaas';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
    if sqlerrm not like 'Não achei um PIX de R$ 20,00 no Asaas%' then raise exception 'FALHOU B mensagem: %', sqlerrm; end if;
  end;
  reset role;
  update public.integracoes_asaas set ativo = false where loja_id = l;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_tronco(c20, true);
  reset role;
  update public.integracoes_asaas set ativo = true where loja_id = l;
  if not exists (select 1 from public.lancamentos x join public.tronco_contribuicoes c on c.lancamento_id = x.id
                 where c.id = c20 and x.conta_id = ctr and x.valor = 20) then
    raise exception 'FALHOU B: sem Asaas não lançou na conta Tronco';
  end if;

  -- C
  perform set_config('request.jwt.claims', '', true);
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_F', 'value', 30, 'netValue', 30, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_F', 'name', 'Outra Pessoa', 'cpfCnpj', '11144477735'));
  select id into lp3 from public.lancamentos where loja_id = l and documento = 'pay_F' and tipo = 'receita' and estorno_de is null;
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.tronco_e_do_tronco(lp3);
    raise exception 'FALHOU C: irmão sem cargo mexeu no Tronco';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  novo := public.tronco_e_do_tronco(lp3);
  reset role;
  select count(*) into n from public.lancamentos x join public.categorias_financeiras k on k.id = x.categoria_id
  where x.loja_id = l and x.documento = 'pay_F' and k.codigo = 'tronco' and x.estorno_de is null;
  if n <> 1 or (select sum(valor) from public.lancamentos where loja_id = l and documento = 'pay_F') <> 30 then
    raise exception 'FALHOU C: n=%', n;
  end if;
  -- de novo no mesmo lançamento (já estornado) não pode
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
    set local role authenticated;
    perform public.tronco_e_do_tronco(lp3);
    raise exception 'FALHOU C: transformou duas vezes';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
  end;
  reset role;

  -- D) irmão identificado pelo CPF paga o Tronco digitando a chave (sessão de 13/11): "É do Tronco" aceita e apaga o nome
  declare ic uuid; ld uuid; aut uuid; begin
    perform set_config('malhete.sistema', 'on', true);
    insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, cpf) values
      (l, 'Carlos Com Cpf', 3, '9', '2020-01-01', 'ativo', '11144477735') returning id into ic;
    perform set_config('malhete.sistema', 'off', true);
    perform set_config('request.jwt.claims', '', true);
    perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
      jsonb_build_object('id', 'pay_D', 'value', 130, 'netValue', 130, 'status', 'RECEIVED', 'billingType', 'PIX',
        'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
      jsonb_build_object('id', 'cus_D', 'name', 'Carlos Com Cpf', 'cpfCnpj', '111.444.777-35'));
    select x.id, x.titulo_id into ld, aut from public.lancamentos x where x.loja_id = l and x.documento = 'pay_D' and x.estorno_de is null;
    if (select irmao_id from public.titulos where id = aut) is distinct from ic then raise exception 'FALHOU D preparo: conta automática sem o irmão'; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
    set local role authenticated;
    perform public.tronco_e_do_tronco(ld);
    reset role;
    if (select count(*) from public.lancamentos x join public.categorias_financeiras k on k.id = x.categoria_id
        where x.loja_id = l and x.documento = 'pay_D' and k.codigo = 'tronco' and x.estorno_de is null) <> 1 then
      raise exception 'FALHOU D: não virou Tronco';
    end if;
    if exists (select 1 from public.lancamentos where loja_id = l and documento = 'pay_D' and (irmao_id is not null or favorecido_id is not null))
       or (select irmao_id from public.titulos where id = aut) is not null then
      raise exception 'FALHOU D: ficou o nome do irmão';
    end if;
    if (select sum(valor) from public.lancamentos where loja_id = l and documento = 'pay_D') <> 130 then raise exception 'FALHOU D: saldo'; end if;
  end;

  raise exception 'OK: Tronco sem contar duas vezes (Confirmar usa o PIX do Asaas; É do Tronco; sem Asaas lança na conta Tronco)';
end $$;
