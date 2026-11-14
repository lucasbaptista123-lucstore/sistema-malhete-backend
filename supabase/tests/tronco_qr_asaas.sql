-- Tronco pelo QR estático do Asaas (0121, 14/11): o pagamento chega com pixQrCodeId (sem externalReference) e de um
-- pagador que não é irmão (sem CPF no cadastro): entra no Tronco sozinho, anônimo, sem conta automática; a varredura
-- repetida não lança de novo; o QR fica guardado e só o dono (ou o token do convite) pode pedir.
do $$ declare
  t uuid := gen_random_uuid(); u uuid := gen_random_uuid(); l uuid; cx uuid; ia uuid; c1 uuid; r text; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'tqa@t.com', 'authenticated', 'authenticated', now()), (u, 'uqa@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, user_id) values
    (l, 'Irmao Sem Cpf', 3, '1', '2020-01-01', 'ativo', u) returning id into ia;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  insert into public.tesouraria_config (loja_id, pix_chave) values (l, 'loja@teste.org') on conflict (loja_id) do update set pix_chave = excluded.pix_chave;
  insert into public.tronco_contribuicoes (loja_id, irmao_id, valor, txid, status, origem)
    values (l, ia, 20, 'TRONCOQ', 'aguardando', 'pix_chave') returning id into c1;

  -- dados para o servidor pedir o QR e guardar
  if not (public.tronco_qr_dados(c1)->>'automatico')::boolean or public.tronco_qr_dados(c1)->>'chave' <> 'loja@teste.org' then
    raise exception 'FALHOU dados: %', public.tronco_qr_dados(c1);
  end if;
  perform public.tronco_qr_guardar(c1, 'qr_abc123', '00020126...PAYLOAD');
  -- permissão: o dono pode, outro usuário não, token falso não
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if public.tronco_qr_permitido(c1) is distinct from l then raise exception 'FALHOU: dono não pode pedir o QR'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  if public.tronco_qr_permitido(c1) is not null then raise exception 'FALHOU: outro usuário pediu o QR'; end if;
  if public.tronco_qr_permitido(c1, 'token-falso') is not null then raise exception 'FALHOU: token falso'; end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);

  -- pagamento do QR (pagador não é irmão, sem externalReference)
  r := public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_Q', 'value', 20, 'netValue', 20, 'status', 'RECEIVED', 'billingType', 'PIX',
      'pixQrCodeId', 'qr_abc123', 'paymentDate', current_date, 'dueDate', current_date, 'description', 'Tronco de Beneficência'),
    jsonb_build_object('id', 'cus_Q', 'name', 'Esposa Do Irmao', 'cpfCnpj', '52998224725'));
  if (select status from public.tronco_contribuicoes where id = c1) <> 'confirmada' then raise exception 'FALHOU: não confirmou (%)', r; end if;
  if exists (select 1 from public.lancamentos where loja_id = l and documento = 'pay_Q' and (irmao_id is not null or favorecido_id is not null)) then
    raise exception 'FALHOU: lançamento com nome';
  end if;
  if exists (select 1 from public.titulos where loja_id = l and asaas_id = 'pay_Q') then raise exception 'FALHOU: criou conta automática'; end if;
  r := public.asaas_espelhar_pagamento(l, 'VARREDURA',
    jsonb_build_object('id', 'pay_Q', 'value', 20, 'netValue', 20, 'status', 'RECEIVED', 'billingType', 'PIX',
      'pixQrCodeId', 'qr_abc123', 'paymentDate', current_date, 'dueDate', current_date), null);
  select count(*) into n from public.lancamentos where loja_id = l and documento = 'pay_Q';
  if n <> 1 then raise exception 'FALHOU: varredura lançou de novo (n=%, %)', n, r; end if;

  raise exception 'OK: Tronco pelo QR do Asaas (pixQrCodeId → Tronco anônimo, sem conta automática, sem duplicar)';
end $$;
