-- Lembrete no dia da sessão: só para convocados pelo WhatsApp que não responderam; uma vez por sessão.
do $$
declare
  se uuid := gen_random_uuid(); l uuid; i_a uuid; i_b uuid; i_c uuid; s uuid; e uuid; r text := ''; ids uuid[]; n int; t text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (se, 'lem@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Sec');
  reset role;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values
    (l, 'A respondeu', 3, '12999990001', 'L1', '2020-01-01', '00000013331', 'i133x5654@teste.com') returning id into i_a;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values
    (l, 'B calado', 3, '12999990002', 'L2', '2020-01-01', '00000013412', 'i134x5654@teste.com') returning id into i_b;
  insert into public.irmaos (loja_id, nome, grau, telefone, cim, data_iniciacao, cpf, email) values
    (l, 'C sem envio', 3, '12999990003', 'L3', '2020-01-01', '00000013501', 'i135x5654@teste.com') returning id into i_c;
  insert into public.sessoes (loja_id, tipo, grau, data, hora) values (l, 'ordinaria', 1, (now() at time zone 'America/Sao_Paulo')::date, '20:00') returning id into s;
  insert into public.envios (loja_id, tipo, sessao_id, canal, mensagem) values (l, 'convocacao', s, 'whatsapp', 'Sessão hoje às 20h') returning id into e;
  insert into public.envio_destinatarios (envio_id, loja_id, irmao_id, telefone, status) values
    (e, l, i_a, '12999990001', 'enviado'), (e, l, i_b, '12999990002', 'enviado');
  insert into public.confirmacoes (loja_id, sessao_id, irmao_id, resposta, canal) values (l, s, i_a, 'vou', 'whatsapp');

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'x', 'tok');
  perform public.whatsapp_atualizar(l, 'conectado', null, null, null);
  ids := public.criar_lembretes_sessao();
  r := r || format('lembretes criados=%s (esperado 1) | ', coalesce(array_length(ids, 1), 0));
  reset role;
  select string_agg(i.nome, ',') into t from public.envio_destinatarios d join public.irmaos i on i.id = d.irmao_id where d.envio_id = ids[1];
  r := r || format('vai para=%s (esperado B calado) | ', t);
  select left(mensagem, 30) into t from public.envios where id = ids[1];
  r := r || format('mensagem=%s | ', t);
  set local role service_role;
  ids := public.criar_lembretes_sessao();
  r := r || format('rodar de novo=%s (esperado 0)', coalesce(array_length(ids, 1), 0));
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
