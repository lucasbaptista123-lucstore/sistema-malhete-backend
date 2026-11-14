-- Sistema Malhete: TODAS AS COBRANÇAS POR PIX PELO QR ESTÁTICO DO ASAAS (14/11, pedido do Lucas depois do Tronco).
-- O QR estático do Asaas não tem taxa de cobrança (testado: R$ 20 do Tronco, sem tarifa no extrato) e o Asaas aceita
-- (ele recusa código montado fora dele). Contas a receber deixam de virar cobrança no Asaas (criar_cobrancas = falso);
-- na hora de pagar, o sistema pede ao Asaas um QR com o valor do dia (multa e juros inclusos), válido até o fim do dia,
-- e guarda as partes em pix_qr. O pagamento chega com pixQrCodeId e dá baixa nas contas (quitar_titulo), com ou sem CPF.
-- As cobranças abertas que o PRÓPRIO SISTEMA criou no Asaas podem ser soltas (botão no Asaas da Tesouraria): ficam em
-- asaas_cobrancas_soltas e o aviso de "removida" do Asaas é ignorado (senão a conta seria cancelada aqui).
-- Cobranças que vieram de fora (assinaturas antigas, vendas de terceiros) e as já confirmadas ficam como estão.

create table public.pix_qr (
  id text primary key,                         -- id do QR estático no Asaas
  loja_id uuid not null references public.lojas(id) on delete cascade,
  partes jsonb not null,                       -- [{"titulo": uuid, "valor": valor do dia}], ordem de vencimento
  valor numeric(12,2) not null check (valor > 0),
  payload text not null,
  expira_em timestamptz not null,
  criado_em timestamptz not null default now(),
  pago_em timestamptz,
  pagamento_id text
);
create index on public.pix_qr (loja_id);
alter table public.pix_qr enable row level security;   -- sem política: só as funções do servidor

create table public.asaas_cobrancas_soltas (
  pagamento_id text primary key,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  titulo_id uuid references public.titulos(id) on delete set null,
  solto_por uuid references auth.users(id),
  solto_em timestamptz not null default now()
);
create index on public.asaas_cobrancas_soltas (loja_id);
create index on public.asaas_cobrancas_soltas (titulo_id);
create index on public.asaas_cobrancas_soltas (solto_por);
alter table public.asaas_cobrancas_soltas enable row level security;

-- daqui em diante as contas não viram cobrança no Asaas (a Loja ainda pode religar na tela, se quiser)
alter table public.integracoes_asaas alter column criar_cobrancas set default false;
update public.integracoes_asaas set criar_cobrancas = false where criar_cobrancas;

/** Para o servidor pedir o QR: contas abertas SEM cobrança no Asaas, com o valor do dia, e um QR igual ainda válido. */
create function public.pix_qr_titulos_dados(p_loja uuid, p_titulos uuid[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  with t as (
    select t.id, t.descricao, t.vencimento, t.parcela, t.valor - t.valor_pago as saldo
    from public.titulos t
    where t.loja_id = p_loja and t.id = any (p_titulos) and t.natureza = 'receber' and not t.cancelado
      and t.valor_pago < t.valor and t.asaas_id is null
  ), p as (
    select id, descricao, vencimento, parcela,
           round(saldo + case when vencimento < current_date then private.encargos(p_loja, saldo, vencimento) else 0 end, 2) as valor
    from t
  ), j as (
    select coalesce(jsonb_agg(jsonb_build_object('titulo', id, 'valor', valor) order by vencimento, parcela, id), '[]') as partes,
           coalesce(sum(valor), 0) as total, count(*) as n, min(descricao) as descricao
    from p
  )
  select jsonb_build_object(
    'automatico', exists (select 1 from public.integracoes_asaas a where a.loja_id = p_loja and a.ativo),
    'chave', (select nullif(trim(c.pix_chave), '') from public.tesouraria_config c where c.loja_id = p_loja),
    'partes', j.partes, 'total', j.total,
    'descricao', case when j.n = 1 then left(j.descricao, 100) else j.n || ' contas da Loja' end,
    'reaproveitar', (select q.payload from public.pix_qr q
                     where q.loja_id = p_loja and q.pago_em is null and q.expira_em > now() + interval '10 minutes'
                       and q.partes = j.partes order by q.criado_em desc limit 1))
  from j
$$;
revoke execute on function public.pix_qr_titulos_dados from public, anon, authenticated;
grant execute on function public.pix_qr_titulos_dados to service_role;

create function public.pix_qr_guardar(p_id text, p_loja uuid, p_partes jsonb, p_valor numeric, p_payload text, p_expira timestamptz)
returns void language sql security definer set search_path = '' as $$
  insert into public.pix_qr (id, loja_id, partes, valor, payload, expira_em)
  values (p_id, p_loja, p_partes, p_valor, p_payload, p_expira)
  on conflict (id) do nothing
$$;
revoke execute on function public.pix_qr_guardar from public, anon, authenticated;
grant execute on function public.pix_qr_guardar to service_role;

/** Pagamento de um QR de contas: dá baixa em cada conta com o valor do dia. Se algo mudou (valor, conta já paga),
    devolve nulo e o PIX segue o caminho normal (vira "PIX recebido" para o Tesoureiro conferir). */
create function private.pix_qr_baixar(p_loja uuid, p_pg jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
  q public.pix_qr;
  v_pid text := p_pg->>'id';
  v_valor numeric(12,2) := (p_pg->>'value')::numeric;
  v_liquido numeric(12,2) := coalesce(nullif(p_pg->>'netValue', '')::numeric, (p_pg->>'value')::numeric);
  v_data date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date, current_date);
  v_conta uuid := (select conta_id from public.integracoes_asaas where loja_id = p_loja and ativo);
  p record;
  n int := 0;
begin
  select * into q from public.pix_qr where loja_id = p_loja and id = p_pg->>'pixQrCodeId' for update;
  if q.id is null or v_pid is null or v_conta is null then return null; end if;
  if exists (select 1 from public.lancamentos where loja_id = p_loja and documento = v_pid) then return 'qr: já lançado'; end if;
  if v_valor is distinct from q.valor
     or exists (select 1 from jsonb_array_elements(q.partes) e join public.titulos t on t.id = (e->>'titulo')::uuid
                where t.cancelado or t.valor_pago >= t.valor) then
    return null;
  end if;
  perform set_config('malhete.sistema', 'on', true);
  for p in select (e->>'titulo')::uuid as tit, (e->>'valor')::numeric as val from jsonb_array_elements(q.partes) e loop
    perform private.quitar_titulo(p.tit, v_conta, v_data, p.val, v_pid);
    n := n + 1;
  end loop;
  if v_liquido < v_valor then
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao, documento)
    values (p_loja, v_conta, (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'tarifas'),
            'despesa', v_valor - v_liquido, v_data, v_data, 'Tarifa Asaas: PIX pelo QR', v_pid);
  end if;
  perform set_config('malhete.sistema', 'off', true);
  update public.pix_qr set pago_em = now(), pagamento_id = v_pid where id = q.id;
  perform private.auto_conciliar(v_conta, v_pid);
  return format('baixa de %s conta(s) pelo QR do Asaas', n);
end $$;
revoke execute on function private.pix_qr_baixar from public, anon, authenticated;

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
  -- cobrança que o sistema soltou no Asaas para passar ao QR estático: o aviso de "removida" não cancela a conta
  if exists (select 1 from public.asaas_cobrancas_soltas s where s.loja_id = p_loja and s.pagamento_id = p_pg->>'id') then
    perform set_config('malhete.sem_avisos', 'off', true);
    return 'ignorado (cobrança passada para o QR estático)';
  end if;
  -- conta(s) paga(s) pelo QR estático que o sistema pediu ao Asaas: baixa direta nas contas do QR
  if coalesce(p_pg->>'pixQrCodeId', '') <> ''
     and exists (select 1 from public.pix_qr q where q.loja_id = p_loja and q.id = p_pg->>'pixQrCodeId') then
    if p_evento in ('PAYMENT_RECEIVED', 'PAYMENT_CONFIRMED')
       or (p_evento = 'VARREDURA' and p_pg->>'status' in ('RECEIVED', 'CONFIRMED')) then
      v_res := private.pix_qr_baixar(p_loja, p_pg);
    else
      v_res := 'qr: sem mudança';
    end if;
    if v_res is not null then
      perform set_config('malhete.sem_avisos', 'off', true);
      return v_res;
    end if;
  end if;
  -- PIX do Tronco pelo QR estático que o sistema pediu ao Asaas: o pagamento traz o pixQrCodeId do QR
  if coalesce(p_pg->>'externalReference', '') = '' and coalesce(p_pg->>'pixQrCodeId', '') <> '' then
    select 'tronco:' || id into v_res from public.tronco_contribuicoes
    where loja_id = p_loja and asaas_qr_id = p_pg->>'pixQrCodeId' limit 1;
    if v_res is not null then
      p_pg := p_pg || jsonb_build_object('externalReference', v_res);
      v_res := null;
    end if;
  end if;
  -- PIX do Tronco gerado pelo sistema (externalReference tronco:<contribuição>)
  if coalesce(p_pg->>'externalReference', '') like 'tronco:%' then
    v_res := private.tronco_asaas(p_loja, p_evento, p_pg);
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  -- PIX direto na chave da Loja vindo de um irmão (CPF): Tronco ou baixa das contas abertas dele, sem cobrança e sem taxa
  v_res := private.pix_irmao(p_loja, p_evento, p_pg, p_cliente);
  if v_res is not null then
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  v_res := private.asaas_espelhar_base(p_loja, p_evento, p_pg, p_cliente);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_res;
end $function$;

/** Cobranças abertas que o PRÓPRIO SISTEMA criou no Asaas (contas de irmão), que podem passar para o QR estático.
    Fora: as que vieram de fora (origem asaas: assinaturas, vendas de terceiros) e as já pagas ou confirmadas. */
create function public.asaas_cobrancas_do_sistema(p_loja uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('titulo', t.id, 'asaas_id', t.asaas_id, 'descricao', t.descricao,
           'irmao', i.nome, 'valor', t.valor - t.valor_pago, 'vencimento', t.vencimento) order by t.vencimento), '[]')
  from public.titulos t join public.irmaos i on i.id = t.irmao_id
  where t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor
    and t.asaas_id is not null and t.origem in ('manual', 'mensalidade')
    and coalesce(t.asaas_status, '') not in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH')
$$;
revoke execute on function public.asaas_cobrancas_do_sistema from public, anon, authenticated;
grant execute on function public.asaas_cobrancas_do_sistema to service_role;

/** Solta a conta da cobrança do Asaas (antes de apagá-la lá); p_desfazer volta como estava se o Asaas recusar. */
create function public.asaas_soltar_cobranca(p_titulo uuid, p_usuario uuid, p_desfazer text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.titulos;
begin
  perform set_config('malhete.sistema', 'on', true);
  if p_desfazer is not null then
    update public.titulos set asaas_id = p_desfazer where id = p_titulo and asaas_id is null;
    delete from public.asaas_cobrancas_soltas where pagamento_id = p_desfazer;
  else
    select * into t from public.titulos where id = p_titulo for update;
    if t.asaas_id is not null then
      insert into public.asaas_cobrancas_soltas (pagamento_id, loja_id, titulo_id, solto_por)
      values (t.asaas_id, t.loja_id, t.id, p_usuario) on conflict do nothing;
      update public.titulos set asaas_id = null, asaas_link = null, asaas_status = null, pix_copia_cola = null where id = t.id;
    end if;
  end if;
  perform set_config('malhete.sistema', 'off', true);
end $$;
revoke execute on function public.asaas_soltar_cobranca from public, anon, authenticated;
grant execute on function public.asaas_soltar_cobranca to service_role;
