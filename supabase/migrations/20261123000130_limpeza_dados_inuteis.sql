-- Sistema Malhete: LIMPEZA DE DADOS INÚTEIS, AGORA E TODO DIA (23/11, pedido do Lucas: "pode limpar e não deixe
-- acumular dados inúteis").
-- `private.limpar_dados_inuteis()` apaga só o que não guarda informação nenhuma:
-- 1) auditoria de gravação que não mudou nada além da hora (atualizado_em, ultima_sincronizacao): antes da 0129 a
--    sincronização do Asaas criava ~1.100 por semana (76 MB no oficial). Daqui em diante a 0129 já não grava; a
--    limpeza diária fica como garantia.
-- 2) histórico de execução das rotinas (cron.job_run_details): só os últimos 7 dias.
-- 3) leituras do Asaas sem nada novo (extrato_importacoes origem asaas, novos = 0, sem linha de extrato ligada) com
--    mais de 30 dias: uma por sincronização, a cada 10 min (2.722 de 2.783 no oficial). Fica sempre a última de cada
--    conta com saldo, que é a que a tela da Conciliação mostra. Importação de OFX feita pelo Tesoureiro nunca é apagada.
-- 4) marcas de mensagem do WhatsApp já processada com mais de 30 dias (servem só para não processar duas vezes; o
--    webhook já limpava ao receber, isto cobre Loja que parou de receber).
-- Não entram: lançamentos, títulos, notificações enviadas, acessos (painel e Marco Civil) nem auditoria com mudança.
-- A rotina `malhete-limpeza` (6h30 UTC = 3h30 de Brasília) substitui a `malhete-limpar-historico-rotinas` da 0129.

create or replace function private.limpar_dados_inuteis() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_so_hora constant text[] := array['atualizado_em', 'ultima_sincronizacao'];
  n_aud int; n_rot int; n_imp int; n_wpp int;
begin
  delete from public.audit_log
  where acao = 'update' and antes is not null and depois is not null
    and (antes - v_so_hora) = (depois - v_so_hora);
  get diagnostics n_aud = row_count;

  delete from cron.job_run_details where end_time < now() - interval '7 days';
  get diagnostics n_rot = row_count;

  delete from public.extrato_importacoes e
  where e.origem = 'asaas' and e.novos = 0 and e.criado_em < now() - interval '30 days'
    and not exists (select 1 from public.extrato_itens i where i.importacao_id = e.id)
    and e.id is distinct from (
      select u.id from public.extrato_importacoes u
      where u.conta_id = e.conta_id and u.saldo_banco is not null
      order by u.saldo_em desc, u.criado_em desc
      limit 1);
  get diagnostics n_imp = row_count;

  delete from public.whatsapp_mensagens where recebida_em < now() - interval '30 days';
  get diagnostics n_wpp = row_count;

  return jsonb_build_object('auditoria_vazia', n_aud, 'historico_rotinas', n_rot,
                            'leituras_asaas_sem_novidade', n_imp, 'marcas_whatsapp', n_wpp);
end $$;
revoke all on function private.limpar_dados_inuteis() from public, anon, authenticated;

select cron.unschedule('malhete-limpar-historico-rotinas');
select cron.schedule('malhete-limpeza', '30 6 * * *', $c$ select private.limpar_dados_inuteis() $c$);

select private.limpar_dados_inuteis();
