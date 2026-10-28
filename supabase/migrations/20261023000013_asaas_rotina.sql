-- Sistema Malhete — ajustes do espelhamento Asaas + sincronização automática.
-- 1) "Recebido em dinheiro" (confirmado manualmente no Asaas) dá baixa no Caixa, não na conta Asaas.
-- 2) Importação do extrato com caminho interno (sem usuário) para a rotina agendada.
-- 3) pg_cron chama a edge function a cada 6 horas (segredo da rotina no Vault: 'malhete_cron_secret').

-- ---- 1
create or replace function private.conta_da_baixa(p_loja uuid, p_status text, p_conta_asaas uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select case when p_status = 'RECEIVED_IN_CASH'
    then coalesce((select id from public.contas_financeiras where loja_id = p_loja and tipo = 'caixa' and ativa order by criado_em limit 1), p_conta_asaas)
    else p_conta_asaas end
$$;

do $$
declare
  v_def text := pg_get_functiondef('public.asaas_espelhar_pagamento(uuid, text, jsonb, jsonb)'::regprocedure);
begin
  v_def := replace(v_def,
    'v_lanc := private.quitar_titulo(t.id, integ.conta_id, v_data, v_valor, v_pid);',
    'v_lanc := private.quitar_titulo(t.id, private.conta_da_baixa(p_loja, v_status, integ.conta_id), v_data, v_valor, v_pid);');
  if position('private.conta_da_baixa' in v_def) = 0 then
    raise exception 'trecho da baixa não encontrado';
  end if;
  execute v_def;
end $$;

-- ---- 2: corpo da importação vira rotina interna; a pública só confere o cargo
create function private.importar_extrato(
  p_loja uuid, p_conta uuid, p_origem text, p_arquivo text, p_itens jsonb, p_saldo numeric, p_saldo_em date
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_imp uuid;
  v_total int := jsonb_array_length(coalesce(p_itens, '[]'::jsonb));
  v_novos int;
  v_auto int := 0;
  r record;
begin
  if not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = p_loja) then
    raise exception 'Conta inválida';
  end if;
  if v_total > 5000 then
    raise exception 'Arquivo grande demais; importe um período menor';
  end if;

  insert into public.extrato_importacoes (loja_id, conta_id, origem, arquivo, de, ate, total, saldo_banco, saldo_em)
  select p_loja, p_conta, p_origem, p_arquivo, min((x->>'data')::date), max((x->>'data')::date), v_total, p_saldo, p_saldo_em
  from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) x
  returning id into v_imp;

  insert into public.extrato_itens (loja_id, conta_id, importacao_id, origem, id_externo, data, valor, descricao, tipo_externo, referencia_externa)
  select p_loja, p_conta, v_imp, p_origem, left(x->>'id_externo', 200), (x->>'data')::date, round((x->>'valor')::numeric, 2),
         left(coalesce(x->>'descricao', ''), 500), left(x->>'tipo', 100), left(x->>'referencia', 200)
  from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) x
  where coalesce(x->>'id_externo', '') <> '' and round((x->>'valor')::numeric, 2) <> 0
  on conflict (conta_id, id_externo) do nothing;
  get diagnostics v_novos = row_count;

  for r in select distinct referencia_externa from public.extrato_itens
           where importacao_id = v_imp and referencia_externa is not null loop
    v_auto := v_auto + private.auto_conciliar(p_conta, r.referencia_externa);
  end loop;

  update public.extrato_importacoes set novos = v_novos where id = v_imp;
  return jsonb_build_object('importacao_id', v_imp, 'total', v_total, 'novos', v_novos, 'conciliados', v_auto);
end $$;

create or replace function public.importar_extrato(
  p_loja uuid, p_conta uuid, p_origem text, p_arquivo text, p_itens jsonb,
  p_saldo numeric default null, p_saldo_em date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = p_loja) or not public.pode_lancar(p_conta) then
    raise exception 'Sem permissão ou conta inválida';
  end if;
  return private.importar_extrato(p_loja, p_conta, p_origem, p_arquivo, p_itens, p_saldo, p_saldo_em);
end $$;

-- Só a edge function (service_role): extrato do Asaas na conta da integração.
create function public.asaas_importar_extrato(p_loja uuid, p_itens jsonb, p_arquivo text, p_saldo numeric, p_saldo_em date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  v_res jsonb;
begin
  if v_conta is null then
    raise exception 'Integração inativa';
  end if;
  v_res := private.importar_extrato(p_loja, v_conta, 'asaas', p_arquivo, p_itens, p_saldo, p_saldo_em);
  update public.integracoes_asaas set ultima_sincronizacao = now(), ultimo_erro = null where loja_id = p_loja;
  return v_res;
end $$;

create function public.asaas_lojas_ativas() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select loja_id from public.integracoes_asaas where ativo order by ultima_sincronizacao nulls first
$$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.asaas_importar_extrato, public.asaas_lojas_ativas from public, anon, authenticated;
grant execute on function public.asaas_importar_extrato, public.asaas_lojas_ativas to service_role;

-- ---- 3: rotina a cada 6 horas
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('malhete-asaas-sincronizar', '17 */6 * * *', $cron$
  select net.http_post(
    url := 'https://heblivnebprikxcjsuan.supabase.co/functions/v1/asaas',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_Ge7-D-NsdDZgZCHirtTpeA_lfAs0um8',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'malhete_cron_secret')),
    body := '{"acao":"sincronizar_todas"}'::jsonb,
    timeout_milliseconds := 120000)
$cron$);
