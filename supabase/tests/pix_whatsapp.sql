-- Cobrança no WhatsApp com botões: o aviso sai com "Pagar com PIX" / "Pagar pelo Malhete"; o botão só vale do
-- telefone de quem recebeu e devolve o código PIX; a régua faz o mesmo; conta paga não ganha botões.
do $$
declare vm uuid := gen_random_uuid(); l uuid; i_b uuid; t1 uuid; r text := ''; s text; e uuid;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (vm, 'pxw@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja PixW', '3', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Bento Alves', 3, 'PW1', '2015-01-01', '39053344705', 'bento@teste.com', '12999990000') returning id into i_b;
  reset role;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id, origem)
  values (l, 'receber', 'Mensalidade 11/2026', (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 120, current_date + 3, current_date, i_b, 'mensalidade')
  returning id into t1;
  perform public.asaas_vincular(l, t1, i_b, 'cus_1', jsonb_build_object('id', 'pay_1', 'invoiceUrl', 'https://asaas/x', 'billingType', 'PIX', 'status', 'PENDING',
    'pix_copia_cola', '00020101021226860014br.gov.bcb.pix2564qrpix.exemplo/abc520400005303986540512.005802BR5925LOJA6009SAO PAULO62070503***6304ABCD'));
  select count(*) || ' msg, botões=' || coalesce(array_to_string(max(botoes), ' / '), 'nenhum') || ' | ' || max(left(mensagem, 90)) into s
    from public.notificacoes where irmao_id = i_b;
  r := r || format('ao criar a cobrança: %s | ', s);
  r := r || format('botão do telefone certo=%s | outro telefone=%s | ',
    (select public.whatsapp_pagamento(l, '5512999990000', token)->'titulos'->0->>'pix' is not null from public.notificacoes where irmao_id = i_b limit 1),
    coalesce((select public.whatsapp_pagamento(l, '5511988887777', token)::text from public.notificacoes where irmao_id = i_b limit 1), 'recusado'));
  -- régua (só roda com o WhatsApp da Loja conectado): etapa de 3 dias antes
  insert into public.integracoes_whatsapp (loja_id, instancia, status, segredo_id) values (l, 'teste-pixw', 'conectado', gen_random_uuid());
  delete from public.notificacoes where irmao_id = i_b;
  select id into e from public.regua_etapas where loja_id = l and dias = -3;
  perform public.rodar_regua();
  select count(*) || ' msg, com botões=' || count(*) filter (where botoes is not null) into s from public.notificacoes where irmao_id = i_b;
  r := r || format('régua: %s | ', s);
  -- paga: código não vai mais
  delete from public.notificacoes where irmao_id = i_b;
  perform set_config('malhete.sistema', 'on', true);
  update public.titulos set valor_pago = 120 where id = t1;
  insert into public.notificacoes (loja_id, irmao_id, tipo, mensagem, telefone, status) values (l, i_b, 'cobranca', 'x', '12999990000', 'pendente');
  perform private.notificar_pix(l, i_b, 'cobranca', array[t1]);
  r := r || format('conta paga ganha botões=%s', (select count(*) from public.notificacoes where irmao_id = i_b and botoes is not null));
  raise exception 'RESULTADO: %', r;
end $$;
