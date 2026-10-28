-- Sistema Malhete — espelhamento com o Asaas da loja:
--   * cobranças do Asaas ↔ contas a receber (criadas lá aparecem aqui; mensalidades daqui podem virar cobrança lá)
--   * pagamento recebido no Asaas (webhook) → baixa automática + tarifa como despesa
--   * linhas do extrato Asaas se conciliam sozinhas com esses lançamentos (pelo id do pagamento)
-- As funções chamadas pelas edge functions rodam como service_role (sem usuário): por isso
-- usam rotinas internas do schema private, sem a checagem de cargo das versões públicas.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- =========================================================
-- Colunas novas
-- =========================================================

alter table public.titulos
  add column asaas_id text,          -- id da cobrança no Asaas (pay_…)
  add column asaas_link text,        -- fatura para o irmão pagar (invoiceUrl)
  add column asaas_forma text,       -- billingType
  add column asaas_status text;
create unique index titulos_asaas_unq on public.titulos (loja_id, asaas_id) where asaas_id is not null;

alter table public.titulos drop constraint titulos_origem_check;
alter table public.titulos add constraint titulos_origem_check check (origem in ('manual', 'mensalidade', 'asaas'));

alter table public.irmaos add column asaas_cliente_id text;
alter table public.favorecidos add column asaas_cliente_id text;
create index on public.irmaos (loja_id, asaas_cliente_id) where asaas_cliente_id is not null;
create index on public.favorecidos (loja_id, asaas_cliente_id) where asaas_cliente_id is not null;
create index on public.lancamentos (documento) where documento is not null;
create index on public.extrato_itens (conta_id, referencia_externa) where referencia_externa is not null;

alter table public.integracoes_asaas
  add column webhook_id text,
  add column criar_cobrancas boolean not null default true,
  add column categoria_padrao_id uuid references public.categorias_financeiras(id);
create index on public.integracoes_asaas (categoria_padrao_id);
grant select (webhook_id, criar_cobrancas, categoria_padrao_id) on public.integracoes_asaas to authenticated;

-- view recriada para expor as colunas novas
drop view public.titulos_situacao;
create view public.titulos_situacao with (security_invoker = true) as
select t.*,
  t.valor - t.valor_pago as saldo,
  case
    when t.cancelado then 'cancelado'
    when t.valor_pago >= t.valor then 'pago'
    when t.vencimento < current_date then 'atrasado'
    when t.valor_pago > 0 then 'parcial'
    else 'aberto'
  end as situacao
from public.titulos t;

-- Campos do Asaas só mudam pelo sistema.
create or replace function public.validar_titulo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Título não pode ser apagado; cancele-o (sem baixa) ou estorne as baixas';
  end if;

  if tg_op = 'UPDATE' then
    new.atualizado_em := now();
    if current_setting('malhete.sistema', true) = 'on' then
      return new;
    end if;
    if old.cancelado then
      raise exception 'Título cancelado não pode ser alterado';
    end if;
    if new.loja_id is distinct from old.loja_id or new.natureza is distinct from old.natureza
       or new.origem is distinct from old.origem or new.valor_pago is distinct from old.valor_pago
       or new.cancelado is distinct from old.cancelado or new.motivo_cancelamento is distinct from old.motivo_cancelamento
       or new.grupo_id is distinct from old.grupo_id or new.parcela is distinct from old.parcela
       or new.total_parcelas is distinct from old.total_parcelas
       or new.asaas_id is distinct from old.asaas_id or new.asaas_link is distinct from old.asaas_link
       or new.asaas_forma is distinct from old.asaas_forma or new.asaas_status is distinct from old.asaas_status
       or new.criado_por is distinct from old.criado_por or new.criado_em is distinct from old.criado_em then
      raise exception 'Use as ações do sistema para baixar, cancelar ou estornar o título';
    end if;
    if old.valor_pago > 0 and (new.categoria_id is distinct from old.categoria_id
                               or new.irmao_id is distinct from old.irmao_id
                               or new.favorecido_id is distinct from old.favorecido_id) then
      raise exception 'Título com baixa não pode mudar de categoria nem de favorecido';
    end if;
    if new.valor < old.valor_pago then
      raise exception 'O valor não pode ficar menor que o já pago';
    end if;
  else
    new.valor_pago := 0;
    new.cancelado := false;
    new.motivo_cancelamento := null;
    new.criado_por := auth.uid();
    new.criado_em := now();
    new.atualizado_em := now();
    new.competencia := coalesce(new.competencia, new.vencimento);
    if current_setting('malhete.sistema', true) is distinct from 'on' then
      new.asaas_id := null; new.asaas_link := null; new.asaas_forma := null; new.asaas_status := null;
      if new.origem = 'asaas' then new.origem := 'manual'; end if;
    end if;
  end if;

  if not exists (select 1 from public.categorias_financeiras
                 where id = new.categoria_id and loja_id = new.loja_id
                   and tipo = case new.natureza when 'receber' then 'receita' else 'despesa' end) then
    raise exception 'Categoria não pertence à loja ou não combina com a conta (a receber → receita, a pagar → despesa)';
  end if;
  if new.favorecido_id is not null and not exists (select 1 from public.favorecidos where id = new.favorecido_id and loja_id = new.loja_id) then
    raise exception 'Fornecedor/cliente não pertence à loja';
  end if;
  if new.irmao_id is not null and not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Irmão não pertence à loja';
  end if;
  if new.centro_custo_id is not null and not exists (select 1 from public.centros_custo where id = new.centro_custo_id and loja_id = new.loja_id) then
    raise exception 'Centro de custo não pertence à loja';
  end if;
  return new;
end $$;

-- =========================================================
-- Log de eventos do webhook (idempotência + transparência)
-- =========================================================

create table public.asaas_eventos (
  id text primary key,          -- id do evento no Asaas
  loja_id uuid not null references public.lojas(id) on delete cascade,
  evento text not null,
  payment_id text,
  recebido_em timestamptz not null default now(),
  resultado text,
  erro text
);
create index on public.asaas_eventos (loja_id, recebido_em desc);
alter table public.asaas_eventos enable row level security;
create policy le on public.asaas_eventos for select to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));

-- =========================================================
-- Rotinas internas (sem checagem de cargo; só chamadas pelas funções do sistema)
-- =========================================================

-- Liga linhas pendentes do extrato da conta ao lançamento com o mesmo documento (id do pagamento) e efeito.
create function private.auto_conciliar(p_conta uuid, p_ref text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  e record;
  v_lanc uuid;
  n int := 0;
begin
  for e in select * from public.extrato_itens
           where conta_id = p_conta and situacao = 'pendente' and referencia_externa = p_ref
           order by data, id
  loop
    select l.id into v_lanc
    from public.lancamentos l
    where l.documento = p_ref and (l.conta_id = p_conta or l.conta_destino_id = p_conta)
      and l.estorno_de is null and public.efeito_na_conta(l, p_conta) = e.valor
      and not exists (select 1 from public.extrato_itens x where x.lancamento_id = l.id)
      and not exists (select 1 from public.lancamentos s where s.estorno_de = l.id)
    order by l.criado_em
    limit 1;
    if v_lanc is not null then
      update public.extrato_itens
      set situacao = 'conciliado', lancamento_id = v_lanc, motivo = null, conciliado_por = null, conciliado_em = now()
      where id = e.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Quita o título com o valor recebido: diferença para mais = juros, para menos = desconto.
create function private.quitar_titulo(p_titulo uuid, p_conta uuid, p_data date, p_valor numeric, p_doc text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  t public.titulos;
  v_saldo numeric(12,2);
  v_id uuid;
begin
  select * into t from public.titulos where id = p_titulo for update;
  v_saldo := t.valor - t.valor_pago;
  if t.cancelado or v_saldo <= 0 or p_valor <= 0 then
    return null;
  end if;
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento)
  values (t.loja_id, p_conta, t.categoria_id, case t.natureza when 'receber' then 'receita' else 'despesa' end,
          p_valor, p_data, t.competencia, t.descricao, t.irmao_id, t.favorecido_id, t.centro_custo_id, p_doc, t.id, v_saldo)
  returning id into v_id;
  return v_id;
end $$;

-- Irmão (ou fornecedor/cliente) dono do cliente do Asaas: pelo id já vinculado, CPF, e-mail; senão cria cliente.
create function private.asaas_pessoa(p_loja uuid, p_cliente jsonb, out irmao_id uuid, out favorecido_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  v_id text := p_cliente->>'id';
  v_doc text := nullif(regexp_replace(coalesce(p_cliente->>'cpfCnpj', ''), '\D', '', 'g'), '');
  v_email text := nullif(lower(trim(coalesce(p_cliente->>'email', ''))), '');
begin
  if v_id is null then
    return;
  end if;
  select i.id into irmao_id from public.irmaos i
  where i.loja_id = p_loja and (
    i.asaas_cliente_id = v_id
    or i.id::text = p_cliente->>'externalReference'
    or (v_doc is not null and regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g') = v_doc)
    or (v_email is not null and lower(i.email) = v_email))
  order by (i.asaas_cliente_id = v_id) desc nulls last, (i.situacao = 'ativo') desc
  limit 1;
  if irmao_id is not null then
    update public.irmaos set asaas_cliente_id = v_id where id = irmao_id and asaas_cliente_id is distinct from v_id;
    return;
  end if;

  select f.id into favorecido_id from public.favorecidos f
  where f.loja_id = p_loja and (f.asaas_cliente_id = v_id
    or (v_doc is not null and regexp_replace(coalesce(f.documento, ''), '\D', '', 'g') = v_doc))
  limit 1;
  if favorecido_id is null then
    insert into public.favorecidos (loja_id, nome, tipo, documento, email, telefone, asaas_cliente_id, observacoes)
    values (p_loja,
            coalesce(nullif(trim(p_cliente->>'name'), ''), 'Cliente Asaas ' || v_id)
              || case when exists (select 1 from public.favorecidos where loja_id = p_loja and nome = trim(p_cliente->>'name')) then ' (' || v_id || ')' else '' end,
            'cliente', p_cliente->>'cpfCnpj', v_email, coalesce(p_cliente->>'mobilePhone', p_cliente->>'phone'), v_id,
            'Criado automaticamente a partir do Asaas')
    returning id into favorecido_id;
  else
    update public.favorecidos set asaas_cliente_id = v_id where id = favorecido_id and asaas_cliente_id is distinct from v_id;
  end if;
end $$;

-- =========================================================
-- Funções para as edge functions (só service_role)
-- =========================================================

-- Espelha um pagamento do Asaas (evento do webhook ou varredura). p_pg = objeto "payment";
-- p_cliente = cliente do Asaas (id, name, cpfCnpj, email, externalReference) — usado só se o título ainda não existe.
create function public.asaas_espelhar_pagamento(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  integ public.integracoes_asaas;
  t public.titulos;
  v_pid text := p_pg->>'id';
  v_valor numeric(12,2) := (p_pg->>'value')::numeric;
  v_liquido numeric(12,2) := nullif(p_pg->>'netValue', '')::numeric;
  v_status text := p_pg->>'status';
  v_data date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date, current_date);
  v_pessoa record;
  v_cat uuid;
  v_lanc uuid;
  v_res text := 'sem alteração';
  l record;
begin
  select * into integ from public.integracoes_asaas where loja_id = p_loja and ativo;
  if integ.loja_id is null or v_pid is null then
    return 'integração inativa';
  end if;
  perform set_config('malhete.sistema', 'on', true);

  select * into t from public.titulos where loja_id = p_loja and asaas_id = v_pid;
  if t.id is null and (p_pg->>'externalReference') ~ '^[0-9a-f-]{36}$' then
    select * into t from public.titulos
    where loja_id = p_loja and id = (p_pg->>'externalReference')::uuid and natureza = 'receber' and asaas_id is null;
    if t.id is not null then
      update public.titulos set asaas_id = v_pid where id = t.id;
    end if;
  end if;

  -- cobrança nova no Asaas (inclui PIX/TED recebidos) → conta a receber espelhada
  if t.id is null then
    if p_evento in ('PAYMENT_DELETED', 'PAYMENT_REFUNDED', 'PAYMENT_PARTIALLY_REFUNDED', 'PAYMENT_RECEIVED_IN_CASH_UNDONE')
       or coalesce((p_pg->>'deleted')::boolean, false) or v_valor is null or v_valor <= 0 then
      perform set_config('malhete.sistema', 'off', true);
      return 'ignorado (cobrança desconhecida)';
    end if;
    select * into v_pessoa from private.asaas_pessoa(p_loja, p_cliente);
    v_cat := coalesce(integ.categoria_padrao_id,
                      (select id from public.categorias_financeiras where loja_id = p_loja
                       and codigo = case when v_pessoa.irmao_id is not null then 'mensalidades' else 'outras_rec' end));
    insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, favorecido_id, valor, vencimento,
                                competencia, documento, origem, asaas_id)
    values (p_loja, 'receber', coalesce(nullif(trim(p_pg->>'description'), ''), 'Cobrança Asaas'), v_cat,
            v_pessoa.irmao_id, v_pessoa.favorecido_id,
            coalesce(nullif(p_pg->>'originalValue', '')::numeric, v_valor),
            (p_pg->>'dueDate')::date, (p_pg->>'dueDate')::date, v_pid, 'asaas', v_pid)
    returning * into t;
    v_res := 'conta a receber criada';
  end if;

  update public.titulos
  set asaas_link = coalesce(p_pg->>'invoiceUrl', asaas_link), asaas_forma = coalesce(p_pg->>'billingType', asaas_forma),
      asaas_status = coalesce(v_status, asaas_status)
  where id = t.id;

  -- alteração de valor/vencimento no Asaas (só sem baixa)
  if p_evento = 'PAYMENT_UPDATED' and t.valor_pago = 0 and not t.cancelado then
    update public.titulos
    set valor = coalesce(nullif(p_pg->>'originalValue', '')::numeric, v_valor, valor), vencimento = coalesce((p_pg->>'dueDate')::date, vencimento)
    where id = t.id;
    v_res := 'atualizada';
  end if;

  -- recebido com saldo disponível → baixa + tarifa
  if (p_evento = 'PAYMENT_RECEIVED' or (p_evento = 'VARREDURA' and v_status in ('RECEIVED', 'RECEIVED_IN_CASH')))
     and not t.cancelado then
    select * into t from public.titulos where id = t.id;
    if t.valor_pago < t.valor and not exists (
         select 1 from public.lancamentos x where x.titulo_id = t.id and x.documento = v_pid and x.estorno_de is null
           and not exists (select 1 from public.lancamentos s where s.estorno_de = x.id)) then
      v_lanc := private.quitar_titulo(t.id, integ.conta_id, v_data, v_valor, v_pid);
      if v_lanc is not null and v_status <> 'RECEIVED_IN_CASH' and v_liquido is not null and v_valor - v_liquido > 0 then
        insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
        values (p_loja, integ.conta_id,
                (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
                'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas — ' || t.descricao, v_pid);
      end if;
      perform private.auto_conciliar(integ.conta_id, v_pid);
      v_res := case when v_status = 'RECEIVED_IN_CASH' then 'baixa (recebido em dinheiro)' else 'baixa automática' end;
    end if;
  end if;

  -- removida no Asaas → cancela aqui (se não houve baixa)
  if p_evento = 'PAYMENT_DELETED' and not t.cancelado then
    if t.valor_pago = 0 then
      update public.titulos set cancelado = true, motivo_cancelamento = 'Cobrança removida no Asaas' where id = t.id;
      v_res := 'cancelada';
    else
      v_res := 'removida no Asaas, mas já tinha baixa — confira';
    end if;
  end if;

  -- estorno/recebimento desfeito → estorna as baixas desse pagamento (e a tarifa)
  if p_evento in ('PAYMENT_REFUNDED', 'PAYMENT_RECEIVED_IN_CASH_UNDONE') then
    for l in select * from public.lancamentos x
             where x.documento = v_pid and x.loja_id = p_loja and x.estorno_de is null
               and not exists (select 1 from public.lancamentos s where s.estorno_de = x.id)
    loop
      insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia,
                                      descricao, irmao_id, favorecido_id, centro_custo_id, titulo_id, abatimento,
                                      estorno_de, motivo_estorno, documento)
      values (l.loja_id, l.conta_id, l.conta_destino_id, l.categoria_id, l.tipo, -l.valor, current_date, l.competencia,
              'Estorno: ' || l.descricao, l.irmao_id, l.favorecido_id, l.centro_custo_id, l.titulo_id, -l.abatimento,
              l.id, 'Estornado no Asaas', v_pid);
    end loop;
    v_res := 'baixa estornada';
  end if;
  if p_evento = 'PAYMENT_PARTIALLY_REFUNDED' then
    v_res := 'estorno parcial no Asaas — ajuste manual na Tesouraria';
  end if;

  perform set_config('malhete.sistema', 'off', true);
  return v_res;
end $$;

-- Mensalidades/contas a receber de irmãos que ainda não viraram cobrança no Asaas.
create function public.asaas_cobrancas_pendentes(p_loja uuid)
returns table (titulo_id uuid, descricao text, valor numeric, vencimento date, irmao_id uuid, nome text, cpf text,
               email text, telefone text, asaas_cliente_id text)
language sql stable security definer set search_path = '' as $$
  select t.id, t.descricao, t.valor - t.valor_pago, t.vencimento, i.id, i.nome, i.cpf, i.email, i.telefone, i.asaas_cliente_id
  from public.titulos t
  join public.irmaos i on i.id = t.irmao_id
  join public.integracoes_asaas g on g.loja_id = t.loja_id and g.ativo and g.criar_cobrancas
  where t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado and t.asaas_id is null
    and t.valor_pago < t.valor and t.vencimento >= current_date - 60
  order by t.vencimento
  limit 300
$$;

create function public.asaas_vincular(p_loja uuid, p_titulo uuid, p_irmao uuid, p_cliente_id text, p_pg jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('malhete.sistema', 'on', true);
  if p_irmao is not null and p_cliente_id is not null then
    update public.irmaos set asaas_cliente_id = p_cliente_id where id = p_irmao and loja_id = p_loja;
  end if;
  if p_titulo is not null and p_pg is not null then
    update public.titulos
    set asaas_id = p_pg->>'id', asaas_link = p_pg->>'invoiceUrl', asaas_forma = p_pg->>'billingType', asaas_status = p_pg->>'status'
    where id = p_titulo and loja_id = p_loja and asaas_id is null;
  end if;
  perform set_config('malhete.sistema', 'off', true);
end $$;

create function public.asaas_registrar_webhook(p_loja uuid, p_webhook_id text) returns text
language sql security definer set search_path = '' as $$
  update public.integracoes_asaas set webhook_id = p_webhook_id where loja_id = p_loja returning webhook_token
$$;

-- Configurações da integração (Tesoureiro).
create function public.asaas_configurar(p_loja uuid, p_criar_cobrancas boolean, p_categoria uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para configurar a integração';
  end if;
  if p_categoria is not null and not exists (
       select 1 from public.categorias_financeiras where id = p_categoria and loja_id = p_loja and tipo = 'receita') then
    raise exception 'Categoria inválida';
  end if;
  update public.integracoes_asaas set criar_cobrancas = p_criar_cobrancas, categoria_padrao_id = p_categoria where loja_id = p_loja;
end $$;

-- Título com cobrança no Asaas: dados para a edge function atualizar/remover lá depois de editado aqui.
create function public.asaas_cobranca_do_titulo(p_titulo uuid)
returns table (loja_id uuid, asaas_id text, valor numeric, vencimento date, descricao text, cancelado boolean, valor_pago numeric)
language sql stable security definer set search_path = '' as $$
  select loja_id, asaas_id, valor, vencimento, descricao, cancelado, valor_pago from public.titulos where id = p_titulo and asaas_id is not null
$$;

-- Importação passa a conciliar sozinha as linhas do Asaas que já têm baixa (mesmo id de pagamento).
create or replace function public.importar_extrato(
  p_loja uuid, p_conta uuid, p_origem text, p_arquivo text, p_itens jsonb,
  p_saldo numeric default null, p_saldo_em date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_imp uuid;
  v_total int := jsonb_array_length(coalesce(p_itens, '[]'::jsonb));
  v_novos int;
  v_auto int := 0;
  r record;
begin
  if not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = p_loja) or not public.pode_lancar(p_conta) then
    raise exception 'Sem permissão ou conta inválida';
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

-- =========================================================
-- Permissões
-- =========================================================

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.asaas_espelhar_pagamento, public.asaas_cobrancas_pendentes, public.asaas_vincular,
  public.asaas_registrar_webhook, public.asaas_cobranca_do_titulo from public, anon, authenticated;
grant execute on function public.asaas_espelhar_pagamento, public.asaas_cobrancas_pendentes, public.asaas_vincular,
  public.asaas_registrar_webhook, public.asaas_cobranca_do_titulo to service_role;
revoke execute on function public.asaas_configurar from public, anon;
grant execute on function public.asaas_configurar to authenticated;
