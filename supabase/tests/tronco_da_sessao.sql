-- Tronco da sessão (0118, 12/11): o Tesoureiro manda pelo WhatsApp o convite do Tronco aos presentes.
-- A) envio: quem tem telefone vai para a fila com os botões dos 2 primeiros valores + "Outro valor"; sem telefone fica
--    marcado; mandar de novo não repete; só o Tesoureiro envia.
-- B) botão de valor: cria a contribuição "aguardando" da sessão (toque repetido não duplica) e devolve a chave;
--    telefone de outro irmão não serve; "Outro valor" devolve o link da página.
-- C) página sem login: info, escolher valor, "Já paguei"; o convite não é legível pelo app.
-- D) PIX do irmão no Asaas com o valor escolhido: entra no Tronco sozinho, sem nome no lançamento.
-- E) totais da sessão sem nomes; dinheiro do saco lança na conta Tronco uma vez só.
-- F) agendamento: não sai antes da hora; desfazer cancela e permite mandar de novo.
do $$ declare
  t uuid := gen_random_uuid(); u uuid := gen_random_uuid(); l uuid; cx uuid; s uuid;
  ia uuid; ib uuid; ic uuid; r jsonb; tk text; tkc text; n int; bt text[]; cid uuid; lanc uuid; erro text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'ttr@t.com', 'authenticated', 'authenticated', now()), (u, 'utr@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'Sao Paulo', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone, cpf) values
    (l, 'Antonio Presente', 3, '1', '2020-01-01', 'ativo', '11999990001', '52998224725') returning id into ia;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao) values
    (l, 'Bruno Sem Telefone', 3, '2', '2020-01-01', 'ativo') returning id into ib;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone, user_id) values
    (l, 'Carlos Agendado', 3, '3', '2020-01-01', 'ativo', '11999990003', u) returning id into ic;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.tesouraria_config (loja_id, pix_chave, pix_titular) values (l, 'tesouraria@loja.org', 'Loja Teste')
    on conflict (loja_id) do update set pix_chave = excluded.pix_chave;
  insert into public.sessoes (loja_id, tipo, grau, data, hora, status) values (l, 'ordinaria', 1, current_date, '20:00', 'realizada')
    returning id into s;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s, ia, 'presente');

  -- A) envio pelo Tesoureiro
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.tronco_definir_valores(l, array[20, 50, 100]);
  r := public.tronco_enviar(s, array[ia, ib]);
  if (r->>'na_fila')::int <> 1 or (r->>'sem_telefone')::int <> 1 then raise exception 'FALHOU A envio: %', r; end if;
  r := public.tronco_enviar(s, array[ia, ib]);
  if (r->>'ja_recebiam')::int <> 2 or (r->>'na_fila')::int <> 0 then raise exception 'FALHOU A repetido: %', r; end if;
  reset role;
  select n.botoes into bt from public.notificacoes n join public.tronco_convites c on c.notificacao_id = n.id where c.irmao_id = ia;
  select token into tk from public.tronco_convites where irmao_id = ia;
  if array_length(bt, 1) <> 3 or bt[1] <> 'R$ 20|tronco:20.00:' || tk or bt[3] not like 'Outro valor|tronco:outro:%' then
    raise exception 'FALHOU A botões: %', bt;
  end if;
  -- outro usuário (sem tronco.editar) não envia
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.tronco_enviar(s, array[ic]);
    raise exception 'FALHOU A: irmão sem cargo enviou';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
  end;
  -- C) o app não lê os convites (o token é a chave da página)
  if exists (select 1 from public.tronco_convites) then raise exception 'FALHOU C: convite legível pelo app'; end if;
  reset role;

  -- B) botões no WhatsApp (função do webhook)
  r := public.whatsapp_tronco(l, '5511999990001', tk, '50.00');
  if r->>'chave' <> 'tesouraria@loja.org' or (r->>'valor')::numeric <> 50 then raise exception 'FALHOU B valor: %', r; end if;
  r := public.whatsapp_tronco(l, '5511999990001', tk, '50.00');
  select count(*) into n from public.tronco_contribuicoes where irmao_id = ia and status = 'aguardando' and valor = 50
    and tronco_sessao_id is not null;
  if n <> 1 then raise exception 'FALHOU B duplicou: %', n; end if;
  if public.whatsapp_tronco(l, '5511988887777', tk, '20.00') is not null then raise exception 'FALHOU B outro telefone'; end if;
  r := public.whatsapp_tronco(l, '5511999990001', tk, 'outro');
  if r->>'link' not like '%/tronco/' || tk then raise exception 'FALHOU B link: %', r; end if;

  -- C) página sem login
  set local role anon;
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  r := public.tronco_convite_info(tk);
  if not (r->>'valido')::boolean or r->>'primeiro_nome' <> 'Antonio' or jsonb_array_length(r->'valores') <> 3 then
    raise exception 'FALHOU C info: %', r;
  end if;
  r := public.tronco_convite_valor(tk, 35);
  cid := (r->>'id')::uuid;
  perform public.tronco_convite_ja_paguei(tk, cid);
  if (public.tronco_convite_info('nao-existe')->>'valido')::boolean then raise exception 'FALHOU C token falso'; end if;
  reset role;
  if (select status from public.tronco_contribuicoes where id = cid) <> 'informada' then raise exception 'FALHOU C já paguei'; end if;

  -- D) PIX de R$ 50 do Antonio no Asaas (CPF dele): entra no Tronco sozinho, sem nome
  perform set_config('request.jwt.claims', '', true);
  insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final) values (l, 'sandbox', cx, gen_random_uuid(), 'xxxx');
  perform public.asaas_espelhar_pagamento(l, 'PAYMENT_RECEIVED',
    jsonb_build_object('id', 'pay_T', 'value', 50, 'netValue', 50, 'status', 'RECEIVED', 'billingType', 'PIX',
      'paymentDate', current_date, 'dueDate', current_date, 'description', 'Cobrança gerada automaticamente a partir de Pix recebido.'),
    jsonb_build_object('id', 'cus_T', 'name', 'Antonio Presente', 'cpfCnpj', '529.982.247-25'));
  if (select status from public.tronco_contribuicoes where irmao_id = ia and valor = 50 and tronco_sessao_id is not null) <> 'confirmada' then
    raise exception 'FALHOU D: não entrou no Tronco';
  end if;
  if exists (select 1 from public.lancamentos where loja_id = l and documento = 'pay_T' and irmao_id is not null) then
    raise exception 'FALHOU D: lançamento com nome';
  end if;

  -- E) totais e dinheiro do saco
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  lanc := public.tronco_registrar_dinheiro(s, 120);
  begin
    perform public.tronco_registrar_dinheiro(s, 10);
    raise exception 'FALHOU E: lançou o dinheiro duas vezes';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
  end;
  r := public.tronco_da_sessao(s);
  if (r->'recebido'->>'valor')::numeric <> 50 or (r->'aguardando'->>'quantidade')::int <> 1 or (r->>'dinheiro')::numeric <> 120
     or not (r->>'dinheiro_lancado')::boolean or r::text like '%TRONCO%'
     or not exists (select 1 from jsonb_array_elements(r->'irmaos') x where x->>'nome' = 'Antonio Presente' and (x->>'presente')::boolean) then
    raise exception 'FALHOU E totais: %', r;
  end if;
  reset role;
  if (select c.tipo from public.lancamentos x join public.contas_financeiras c on c.id = x.conta_id where x.id = lanc) <> 'tronco' then
    raise exception 'FALHOU E: dinheiro fora da conta Tronco';
  end if;

  -- F) agendamento
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := public.tronco_enviar(s, array[ic], now() + interval '2 hours');
  reset role;
  insert into public.integracoes_whatsapp (loja_id, instancia, status, segredo_id) values (l, 'teste-tronco', 'conectado', gen_random_uuid());
  if exists (select 1 from public.notificacoes_proximas(2) p join public.tronco_convites c on c.notificacao_id = p.id where c.irmao_id = ic) then
    raise exception 'FALHOU F: saiu antes da hora';
  end if;
  if not exists (select 1 from public.notificacoes_proximas(2) p join public.tronco_convites c on c.notificacao_id = p.id where c.irmao_id = ia) then
    raise exception 'FALHOU F: o de agora não saiu';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := public.tronco_cancelar_agendamento(s);
  r := public.tronco_enviar(s, array[ic]);
  reset role;
  if n <> 1 or (r->>'na_fila')::int <> 1 or (select count(*) from public.notificacoes where irmao_id = ic and status = 'cancelado') <> 1 then
    raise exception 'FALHOU F cancelar: n=% r=%', n, r;
  end if;

  raise exception 'OK: tronco da sessão (envio, botões, página, Asaas, totais, dinheiro, agendamento)';
end $$;
