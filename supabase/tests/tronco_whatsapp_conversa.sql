-- Tronco pelo WhatsApp, 2ª versão (0120, 14/11): "Outro valor" vira conversa; mensagem nova do convite.
-- A) convite: "Ir∴ Antonio, obrigado pela presença na sessão de hoje" + botões R$ 20 | R$ 50 | Outro valor.
-- B) "Outro valor": pergunta o valor e abre a conversa; a justificativa (whatsapp_texto) não a consome.
-- C) resposta que não é valor: pede de novo e a conversa continua; "R$ 35,50": devolve o PIX e cria a contribuição.
-- D) "cancelar" encerra; sem conversa, a função não responde (segue o fluxo normal).
-- E) leitura de valores escritos.
do $$ declare
  t uuid := gen_random_uuid(); l uuid; s uuid; ia uuid; r jsonb; tk text; msg text; bt text[];
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'twc@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'Sao Paulo', 'SP', 'T');
  reset role;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone) values
    (l, 'Antonio Presente', 3, '1', '2020-01-01', 'ativo', '11999990001') returning id into ia;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.tesouraria_config (loja_id, pix_chave, pix_titular) values (l, 'tesouraria@loja.org', 'Loja Teste')
    on conflict (loja_id) do update set pix_chave = excluded.pix_chave;
  insert into public.sessoes (loja_id, tipo, grau, data, hora, status)
    values (l, 'ordinaria', 1, (now() at time zone 'America/Sao_Paulo')::date, '20:00', 'realizada') returning id into s;

  -- A
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.tronco_enviar(s, array[ia]);
  reset role;
  select n.mensagem, n.botoes into msg, bt from public.notificacoes n where n.irmao_id = ia and n.tipo = 'tronco';
  select token into tk from public.tronco_convites where irmao_id = ia;
  if msg not like 'Ir∴ Antonio, obrigado pela presença na sessão de hoje.%' or msg like '%—%'
     or array_length(bt, 1) <> 3 or bt[3] not like 'Outro valor|tronco:outro:%' then
    raise exception 'FALHOU A: % | %', msg, bt;
  end if;

  -- B
  r := public.whatsapp_tronco(l, '5511999990001', tk, 'outro');
  if r->>'texto' not like 'Qual valor%' then raise exception 'FALHOU B pergunta: %', r; end if;
  if not exists (select 1 from public.whatsapp_conversas where loja_id = l and estado = 'tronco_valor') then
    raise exception 'FALHOU B: conversa não abriu';
  end if;
  if public.whatsapp_texto(l, '5511999990001', '30') is not null then raise exception 'FALHOU B: justificativa consumiu o valor'; end if;

  -- C
  r := public.whatsapp_tronco_texto(l, '5511999990001', 'quanto mesmo?');
  if r->>'texto' not like 'Não entendi%' or not exists (select 1 from public.whatsapp_conversas where loja_id = l) then
    raise exception 'FALHOU C não entendi: %', r;
  end if;
  r := public.whatsapp_tronco_texto(l, '5511999990001', 'R$ 35,50');
  if r->>'chave' <> 'tesouraria@loja.org' or (r->>'valor')::numeric <> 35.50 or r->>'token' <> tk then
    raise exception 'FALHOU C pix: %', r;
  end if;
  if exists (select 1 from public.whatsapp_conversas where loja_id = l)
     or not exists (select 1 from public.tronco_contribuicoes where irmao_id = ia and valor = 35.50 and status = 'aguardando') then
    raise exception 'FALHOU C: conversa ficou aberta ou contribuição não criada';
  end if;

  -- D
  if public.whatsapp_tronco_texto(l, '5511999990001', '40') is not null then raise exception 'FALHOU D: respondeu sem conversa'; end if;
  perform public.whatsapp_tronco(l, '5511999990001', tk, 'outro');
  r := public.whatsapp_tronco_texto(l, '5511999990001', 'Cancelar');
  if r->>'texto' not like 'Tudo bem%' or exists (select 1 from public.whatsapp_conversas where loja_id = l) then
    raise exception 'FALHOU D cancelar: %', r;
  end if;

  -- E
  if private.ler_valor_texto('30') <> 30 or private.ler_valor_texto('50 reais') <> 50
     or private.ler_valor_texto('1.000') <> 1000 or private.ler_valor_texto('25,5') <> 25.5
     or private.ler_valor_texto('10.50') <> 10.5 or private.ler_valor_texto('R$ 1.234,56') <> 1234.56
     or private.ler_valor_texto('não sei') is not null then
    raise exception 'FALHOU E leitura';
  end if;

  raise exception 'OK: Tronco pelo WhatsApp em conversa (mensagem, Outro valor, valor escrito, cancelar)';
end $$;
