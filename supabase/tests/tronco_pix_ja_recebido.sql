-- Tronco sem contar duas vezes (0119, 13/11): PIX do Tronco que o Asaas não reconheceu (pago da conta da esposa).
-- A) "Confirmar no Tronco" usa o "PIX recebido" que já entrou: estorno + Tronco anônimo na mesma conta, conta
--    automática cancelada, contribuição confirmada, nada na conta Tronco, saldo do Asaas igual ao PIX (50).
-- B) Sem PIX no Asaas, confirma lançando na conta Tronco (como antes).
-- C) Movimentações → "É do Tronco" num PIX sem dono e sem contribuição: vira Tronco; irmão sem cargo não consegue.
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

  -- B
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.decidir_tronco(c20, true);
  reset role;
  if not exists (select 1 from public.lancamentos x join public.tronco_contribuicoes c on c.lancamento_id = x.id
                 where c.id = c20 and x.conta_id = ctr and x.valor = 20) then
    raise exception 'FALHOU B: sem PIX no Asaas não lançou na conta Tronco';
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

  raise exception 'OK: Tronco sem contar duas vezes (Confirmar usa o PIX do Asaas; É do Tronco; sem Asaas lança na conta Tronco)';
end $$;
