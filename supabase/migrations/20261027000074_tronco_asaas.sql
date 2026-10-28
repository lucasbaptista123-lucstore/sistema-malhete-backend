-- Sistema Malhete: TRONCO AUTOMÁTICO pelo Asaas. O irmão gera um PIX (cobrança Asaas com externalReference
-- tronco:<id>); quando é pago, o webhook/varredura lança a receita do Tronco na conta Asaas (categoria tronco,
-- documento = id do pagamento, tarifa separada) e confirma a contribuição sem o Tesoureiro conferir.

alter table public.tronco_contribuicoes add column origem text not null default 'pix_chave' check (origem in ('pix_chave', 'asaas'));
alter table public.tronco_contribuicoes add column asaas_id text unique;
alter table public.tronco_contribuicoes drop constraint tronco_contribuicoes_status_check;
alter table public.tronco_contribuicoes add constraint tronco_contribuicoes_status_check
  check (status in ('aguardando', 'informada', 'confirmada', 'nao_localizada'));

create function private.tronco_asaas(p_loja uuid, p_evento text, p_pg jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
  c public.tronco_contribuicoes;
  v_id uuid;
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja);
  v_valor numeric(12,2) := (p_pg->>'value')::numeric;
  v_liquido numeric(12,2) := coalesce(nullif(p_pg->>'netValue', '')::numeric, (p_pg->>'value')::numeric);
  v_data date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date, current_date);
  v_lanc uuid;
  v_nome text;
begin
  begin v_id := substr(p_pg->>'externalReference', 8)::uuid; exception when others then return 'tronco: referência inválida'; end;
  select * into c from public.tronco_contribuicoes where id = v_id and loja_id = p_loja for update;
  if c.id is null then return 'tronco: contribuição não encontrada'; end if;
  if p_evento in ('PAYMENT_RECEIVED', 'PAYMENT_CONFIRMED') or (p_evento = 'VARREDURA' and p_pg->>'status' in ('RECEIVED', 'CONFIRMED')) then
    if c.status = 'confirmada' then return 'tronco: já lançado'; end if;
    if v_conta is null then return 'tronco: integração sem conta'; end if;
    perform set_config('malhete.sistema', 'on', true);
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento, irmao_id)
    values (p_loja, v_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tronco'),
            'receita', v_valor, v_data, v_data, 'Tronco de Beneficência (PIX)', p_pg->>'id', c.irmao_id)
    returning id into v_lanc;
    if v_liquido < v_valor then
      insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
      values (p_loja, v_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
              'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas: Tronco de Beneficência', p_pg->>'id');
    end if;
    perform set_config('malhete.sistema', 'off', true);
    update public.tronco_contribuicoes set status = 'confirmada', valor = v_valor, decidido_em = now(), lancamento_id = v_lanc
    where id = c.id;
    select nome into v_nome from public.irmaos where id = c.irmao_id;
    perform private.notificar(p_loja, c.irmao_id, 'baixa', c.id,
      format('Olá, %s! Recebemos sua contribuição de %s ao Tronco de Beneficência. Obrigado.', private.primeiro_nome(v_nome), private.moeda(v_valor)));
    return 'tronco: lançado';
  elsif p_evento in ('PAYMENT_DELETED', 'PAYMENT_OVERDUE') and c.status = 'aguardando' then
    update public.tronco_contribuicoes set status = 'nao_localizada', decidido_em = now() where id = c.id;
    return 'tronco: não pago';
  end if;
  return 'tronco: sem mudança';
end $$;
revoke execute on function private.tronco_asaas from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.asaas_espelhar_pagamento(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_conectado date := (select criado_em::date from public.integracoes_asaas where loja_id = p_loja);
  v_quando date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date,
                            nullif(p_pg->>'dateCreated', '')::date, current_date);
  v_res text;
begin
  -- histórico (antes da conexão): espelha em silêncio
  if v_conectado is not null and v_quando < v_conectado then
    perform set_config('malhete.sem_avisos', 'on', true);
  end if;
  -- PIX do Tronco gerado pelo sistema (externalReference tronco:<contribuição>)
  if coalesce(p_pg->>'externalReference', '') like 'tronco:%' then
    v_res := private.tronco_asaas(p_loja, p_evento, p_pg);
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  v_res := private.asaas_espelhar_base(p_loja, p_evento, p_pg, p_cliente);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_res;
end $function$;
