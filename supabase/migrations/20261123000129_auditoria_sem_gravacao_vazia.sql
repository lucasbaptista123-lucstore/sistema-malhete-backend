-- Sistema Malhete: AUDITORIA SEM GRAVAÇÃO VAZIA E HISTÓRICO DAS ROTINAS LIMPO (23/11, varredura antes de rodar de vez).
-- No oficial, a sincronização do Asaas (a cada 10 min) regrava as mesmas contas sem mudar nada além de
-- atualizado_em, e marca integracoes_asaas.ultima_sincronizacao: de 1.104 registros de auditoria de contas em 2 dias,
-- 1.096 eram vazios (76 MB de 97 MB do audit_log), mais ~1.000 por semana da integração.
-- 1) A auditoria ignora UPDATE em que só mudou a hora (atualizado_em, ultima_sincronizacao). Qualquer outra mudança
--    continua registrada como antes, com a linha inteira de antes e depois.
-- 2) O histórico de execução das rotinas (cron.job_run_details, ~11 mil linhas por semana, nunca limpo) passa a
--    guardar só os últimos 7 dias, limpo todo dia às 3h30 de Brasília.

create or replace function public.registrar_auditoria() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_linha jsonb := to_jsonb(coalesce(new, old));
  v_so_hora constant text[] := array['atualizado_em', 'ultima_sincronizacao'];
begin
  if tg_op = 'UPDATE' and (to_jsonb(old) - v_so_hora) = (to_jsonb(new) - v_so_hora) then
    return new;
  end if;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois)
  values (
    case when tg_table_name = 'lojas' then (v_linha->>'id')::uuid else (v_linha->>'loja_id')::uuid end,
    tg_table_name,
    (v_linha->>'id')::uuid,
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

select cron.schedule('malhete-limpar-historico-rotinas', '30 6 * * *', $c$
  delete from cron.job_run_details where end_time < now() - interval '7 days'
$c$);
