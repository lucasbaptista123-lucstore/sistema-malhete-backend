-- Limpeza diária de dados inúteis (0130): apaga só o que não guarda informação e preserva o resto.
-- Auditoria: some a gravação que só mudou a hora; fica a com mudança, o insert e o delete.
-- Leituras do Asaas: some a antiga sem novidade; ficam a recente, a com linha de extrato, a última com saldo e o OFX.
do $$
declare
  l uuid; c uuid; i_vazia bigint; i_hora bigint; i_real bigint;
  imp_velha uuid; imp_recente uuid; imp_com_item uuid; imp_saldo uuid; imp_ofx uuid;
  r jsonb; ok text := '';
begin
  select id into l from public.lojas limit 1;
  select id into c from public.contas_financeiras where loja_id = l limit 1;

  -- auditoria (inserida direto, como o gatilho faria antes da 0129)
  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois, em) values
    (l, 'titulos', gen_random_uuid(), 'update', '{"id":1,"valor":10,"atualizado_em":"2026-11-01"}', '{"id":1,"valor":10,"atualizado_em":"2026-11-02"}', now() - interval '20 days')
    returning id into i_vazia;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois, em) values
    (l, 'integracoes_asaas', gen_random_uuid(), 'update', '{"id":2,"ultima_sincronizacao":"a"}', '{"id":2,"ultima_sincronizacao":"b"}', now() - interval '20 days')
    returning id into i_hora;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois, em) values
    (l, 'titulos', gen_random_uuid(), 'update', '{"id":3,"valor":10,"atualizado_em":"x"}', '{"id":3,"valor":12,"atualizado_em":"y"}', now() - interval '20 days')
    returning id into i_real;

  -- leituras do extrato
  insert into public.extrato_importacoes (loja_id, conta_id, origem, total, novos, criado_em) values (l, c, 'asaas', 5, 0, now() - interval '40 days') returning id into imp_velha;
  insert into public.extrato_importacoes (loja_id, conta_id, origem, total, novos, criado_em) values (l, c, 'asaas', 5, 0, now() - interval '2 days') returning id into imp_recente;
  insert into public.extrato_importacoes (loja_id, conta_id, origem, total, novos, criado_em) values (l, c, 'asaas', 5, 0, now() - interval '40 days') returning id into imp_com_item;
  insert into public.extrato_itens (loja_id, conta_id, importacao_id, origem, id_externo, data, valor, descricao)
    values (l, c, imp_com_item, 'asaas', 'teste-limpeza-' || gen_random_uuid(), current_date - 40, 1, 'teste');
  insert into public.extrato_importacoes (loja_id, conta_id, origem, total, novos, criado_em, saldo_banco, saldo_em)
    values (l, c, 'asaas', 5, 0, now() - interval '35 days', 123.45, current_date + 3650) returning id into imp_saldo;
  insert into public.extrato_importacoes (loja_id, conta_id, origem, arquivo, total, novos, criado_em) values (l, c, 'ofx', 'x.ofx', 5, 0, now() - interval '40 days') returning id into imp_ofx;

  r := private.limpar_dados_inuteis();

  if exists (select 1 from public.audit_log where id in (i_vazia, i_hora)) then raise exception 'FALHOU: auditoria vazia ficou'; end if;
  if not exists (select 1 from public.audit_log where id = i_real) then raise exception 'FALHOU: apagou auditoria com mudança'; end if;
  ok := ok || 'auditoria: só a vazia saiu | ';
  if exists (select 1 from public.extrato_importacoes where id = imp_velha) then raise exception 'FALHOU: leitura antiga sem novidade ficou'; end if;
  if (select count(*) from public.extrato_importacoes where id in (imp_recente, imp_com_item, imp_saldo, imp_ofx)) <> 4 then
    raise exception 'FALHOU: apagou leitura que devia ficar (recente %, com item %, saldo %, ofx %)',
      exists (select 1 from public.extrato_importacoes where id = imp_recente), exists (select 1 from public.extrato_importacoes where id = imp_com_item),
      exists (select 1 from public.extrato_importacoes where id = imp_saldo), exists (select 1 from public.extrato_importacoes where id = imp_ofx);
  end if;
  ok := ok || 'leituras: só a antiga sem novidade saiu (recente, com extrato, última com saldo e OFX ficaram) | ';
  if exists (select 1 from cron.job_run_details where end_time < now() - interval '7 days') then raise exception 'FALHOU: histórico de rotinas antigo ficou'; end if;
  if not exists (select 1 from cron.job where jobname = 'malhete-limpeza' and active) then raise exception 'FALHOU: rotina diária não está ligada'; end if;
  ok := ok || 'rotinas: 7 dias e limpeza diária ligada';

  raise exception 'OK: % %', ok, r;
end $$;
