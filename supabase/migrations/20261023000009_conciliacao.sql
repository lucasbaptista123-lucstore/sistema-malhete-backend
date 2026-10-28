-- Sistema Malhete — conciliação bancária.
-- Extrato do banco (arquivo OFX importado pelo app ou extrato do Asaas puxado pela edge function)
-- é conferido linha a linha contra a Tesouraria: cada linha vira par de um lançamento existente,
-- baixa de conta a pagar/receber, lançamento novo, transferência, ou é ignorada com motivo.
-- Integração Asaas: a chave de cada loja fica no Vault; só o service_role (edge function) a lê.

-- =========================================================
-- Integração Asaas (uma por loja)
-- =========================================================

create table public.integracoes_asaas (
  loja_id uuid primary key references public.lojas(id) on delete cascade,
  ambiente text not null check (ambiente in ('producao', 'sandbox')),
  conta_id uuid not null references public.contas_financeiras(id), -- conta da Tesouraria que espelha o saldo no Asaas
  segredo_id uuid not null,                                        -- vault.secrets (chave da API)
  chave_final text not null,                                       -- últimos caracteres, só para exibir
  webhook_token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  ativo boolean not null default true,
  ultima_sincronizacao timestamptz,
  ultimo_erro text,
  criado_por uuid references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.integracoes_asaas (conta_id);
create index on public.integracoes_asaas (criado_por);

alter table public.integracoes_asaas enable row level security;
create policy le on public.integracoes_asaas for select to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));
-- segredo e token do webhook nunca saem pela API
revoke select on public.integracoes_asaas from anon, authenticated;
grant select (loja_id, ambiente, conta_id, chave_final, ativo, ultima_sincronizacao, ultimo_erro, criado_em)
  on public.integracoes_asaas to authenticated;

-- Conecta (ou troca a chave). A edge function valida a chave no Asaas antes de chamar.
-- Sem conta informada, usa/cria a conta "Asaas" (tipo banco) na Tesouraria.
create function public.asaas_conectar(p_loja uuid, p_chave text, p_ambiente text, p_conta uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_conta uuid := p_conta;
  v_atual public.integracoes_asaas;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para configurar a integração';
  end if;
  if coalesce(length(trim(p_chave)), 0) < 20 then
    raise exception 'Chave do Asaas inválida';
  end if;
  if p_ambiente not in ('producao', 'sandbox') then
    raise exception 'Ambiente inválido';
  end if;

  if v_conta is null then
    select id into v_conta from public.contas_financeiras where loja_id = p_loja and nome = 'Asaas';
    if v_conta is null then
      insert into public.contas_financeiras (loja_id, nome, tipo) values (p_loja, 'Asaas', 'banco') returning id into v_conta;
    end if;
  elsif not exists (select 1 from public.contas_financeiras where id = v_conta and loja_id = p_loja and tipo <> 'tronco') then
    raise exception 'Conta inválida para a integração';
  end if;

  select * into v_atual from public.integracoes_asaas where loja_id = p_loja;
  if v_atual.loja_id is null then
    insert into public.integracoes_asaas (loja_id, ambiente, conta_id, segredo_id, chave_final, criado_por)
    values (p_loja, p_ambiente, v_conta,
            vault.create_secret(trim(p_chave), 'asaas_' || p_loja, 'Chave da API Asaas da loja'),
            right(trim(p_chave), 4), auth.uid());
  else
    perform vault.update_secret(v_atual.segredo_id, trim(p_chave));
    update public.integracoes_asaas
    set ambiente = p_ambiente, conta_id = v_conta, chave_final = right(trim(p_chave), 4), ativo = true, ultimo_erro = null
    where loja_id = p_loja;
  end if;
  return v_conta;
end $$;

create function public.asaas_desconectar(p_loja uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_segredo uuid;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para configurar a integração';
  end if;
  delete from public.integracoes_asaas where loja_id = p_loja returning segredo_id into v_segredo;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end $$;

-- Só para a edge function (service_role): chave em claro + conta + última sincronização.
create function public.asaas_credenciais(p_loja uuid)
returns table (chave text, ambiente text, conta_id uuid, ultima_sincronizacao timestamptz)
language sql security definer set search_path = '' as $$
  select s.decrypted_secret, i.ambiente, i.conta_id, i.ultima_sincronizacao
  from public.integracoes_asaas i
  join vault.decrypted_secrets s on s.id = i.segredo_id
  where i.loja_id = p_loja and i.ativo
    and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
$$;

-- =========================================================
-- Extrato bancário importado
-- =========================================================

create table public.extrato_importacoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  conta_id uuid not null references public.contas_financeiras(id),
  origem text not null check (origem in ('ofx', 'asaas')),
  arquivo text,
  de date,
  ate date,
  total int not null default 0,
  novos int not null default 0,
  saldo_banco numeric(12,2), -- saldo informado pelo banco/Asaas ao fim do período
  saldo_em date,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.extrato_importacoes (loja_id, conta_id, criado_em desc);
create index on public.extrato_importacoes (conta_id);
create index on public.extrato_importacoes (criado_por);

-- valor com sinal, do ponto de vista da conta: + entrou, − saiu.
create table public.extrato_itens (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  conta_id uuid not null references public.contas_financeiras(id),
  importacao_id uuid references public.extrato_importacoes(id),
  origem text not null check (origem in ('ofx', 'asaas')),
  id_externo text not null,
  data date not null,
  valor numeric(12,2) not null check (valor <> 0),
  descricao text not null default '',
  tipo_externo text,
  referencia_externa text, -- ex.: paymentId do Asaas
  situacao text not null default 'pendente' check (situacao in ('pendente', 'conciliado', 'ignorado')),
  lancamento_id uuid unique references public.lancamentos(id),
  motivo text,
  conciliado_por uuid references auth.users(id),
  conciliado_em timestamptz,
  criado_em timestamptz not null default now(),
  unique (conta_id, id_externo),
  check ((situacao = 'conciliado') = (lancamento_id is not null)),
  check (situacao <> 'ignorado' or motivo is not null)
);
create index on public.extrato_itens (loja_id, conta_id, situacao, data);
create index on public.extrato_itens (importacao_id);
create index on public.extrato_itens (conciliado_por);

alter table public.extrato_importacoes enable row level security;
alter table public.extrato_itens enable row level security;
create policy le on public.extrato_importacoes for select to authenticated
  using ((select public.pode_ler_conta(conta_id)));
create policy le on public.extrato_itens for select to authenticated
  using ((select public.pode_ler_conta(conta_id)));
-- escrita só pelas funções abaixo

create trigger auditoria after insert or update or delete on public.extrato_itens for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.integracoes_asaas for each row execute function public.registrar_auditoria();

-- Efeito de um lançamento no saldo de uma conta (mesma regra de contas_saldo).
create function public.efeito_na_conta(l public.lancamentos, p_conta uuid) returns numeric
language sql immutable set search_path = '' as $$
  select case
    when l.tipo = 'receita' then l.valor
    when l.tipo = 'despesa' then -l.valor
    when l.conta_id = p_conta then -l.valor
    else l.valor
  end
$$;

-- Importa linhas (repetidas pelo id_externo são puladas). p_itens: [{id_externo, data, valor, descricao, tipo, referencia}]
create function public.importar_extrato(
  p_loja uuid, p_conta uuid, p_origem text, p_arquivo text, p_itens jsonb,
  p_saldo numeric default null, p_saldo_em date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_imp uuid;
  v_total int := jsonb_array_length(coalesce(p_itens, '[]'::jsonb));
  v_novos int;
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

  update public.extrato_importacoes set novos = v_novos where id = v_imp;
  return jsonb_build_object('importacao_id', v_imp, 'total', v_total, 'novos', v_novos);
end $$;

-- ---- conciliação

create function public.item_para_conciliar(p_item uuid) returns public.extrato_itens
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens;
begin
  select * into v from public.extrato_itens where id = p_item for update;
  if v.id is null or not public.pode_lancar(v.conta_id) then
    raise exception 'Linha do extrato não encontrada ou sem permissão';
  end if;
  if v.situacao <> 'pendente' then
    raise exception 'Esta linha do extrato já foi tratada';
  end if;
  return v;
end $$;

create function public.marcar_conciliado(p_item uuid, p_lancamento uuid) returns void
language sql security definer set search_path = '' as $$
  update public.extrato_itens
  set situacao = 'conciliado', lancamento_id = p_lancamento, motivo = null, conciliado_por = auth.uid(), conciliado_em = now()
  where id = p_item
$$;

-- Par com lançamento existente: mesma conta e mesmo efeito no saldo.
create function public.conciliar(p_item uuid, p_lancamento uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens := public.item_para_conciliar(p_item);
  l public.lancamentos;
begin
  select * into l from public.lancamentos where id = p_lancamento;
  if l.id is null or l.loja_id <> v.loja_id or (l.conta_id <> v.conta_id and l.conta_destino_id is distinct from v.conta_id) then
    raise exception 'Lançamento não é desta conta';
  end if;
  if public.efeito_na_conta(l, v.conta_id) <> v.valor then
    raise exception 'Valor do lançamento não confere com o extrato';
  end if;
  if exists (select 1 from public.extrato_itens where lancamento_id = p_lancamento) then
    raise exception 'Este lançamento já está conciliado com outra linha';
  end if;
  perform public.marcar_conciliado(p_item, p_lancamento);
end $$;

-- Baixa de conta a pagar/receber pela linha do extrato. Valor maior que o saldo: a diferença vira juros.
create function public.conciliar_titulo(p_item uuid, p_titulo uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens := public.item_para_conciliar(p_item);
  t public.titulos;
  v_abs numeric(12,2) := abs(v.valor);
  v_saldo numeric(12,2);
  v_lanc uuid;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or t.loja_id <> v.loja_id or t.cancelado then
    raise exception 'Conta a pagar/receber inválida';
  end if;
  if (v.valor > 0) <> (t.natureza = 'receber') then
    raise exception 'Entrada no extrato só baixa conta a receber; saída, conta a pagar';
  end if;
  v_saldo := t.valor - t.valor_pago;
  if v_saldo <= 0 then
    raise exception 'Esta conta já está quitada';
  end if;
  v_lanc := public.baixar_titulo(p_titulo, v.conta_id, v.data, least(v_abs, v_saldo), greatest(v_abs - v_saldo, 0), 0);
  perform public.marcar_conciliado(p_item, v_lanc);
  return v_lanc;
end $$;

-- Lançamento avulso novo a partir da linha (ex.: tarifa, tronco depositado).
create function public.conciliar_novo_lancamento(
  p_item uuid, p_categoria uuid, p_descricao text,
  p_irmao uuid default null, p_favorecido uuid default null, p_centro uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens := public.item_para_conciliar(p_item);
  v_lanc uuid;
begin
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento)
  values (v.loja_id, v.conta_id, p_categoria, case when v.valor > 0 then 'receita' else 'despesa' end, abs(v.valor),
          v.data, v.data, coalesce(nullif(trim(p_descricao), ''), v.descricao), p_irmao, p_favorecido, p_centro, v.id_externo)
  returning id into v_lanc;
  perform public.marcar_conciliado(p_item, v_lanc);
  return v_lanc;
end $$;

-- Transferência entre contas a partir da linha (ex.: depósito do caixa no banco, saque do Asaas).
create function public.conciliar_transferencia(p_item uuid, p_outra_conta uuid, p_descricao text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens := public.item_para_conciliar(p_item);
  v_lanc uuid;
begin
  if not public.pode_lancar(p_outra_conta)
     or not exists (select 1 from public.contas_financeiras where id = p_outra_conta and loja_id = v.loja_id and id <> v.conta_id) then
    raise exception 'Conta de origem/destino inválida';
  end if;
  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, tipo, valor, data, competencia, descricao, documento)
  values (v.loja_id,
          case when v.valor > 0 then p_outra_conta else v.conta_id end,
          case when v.valor > 0 then v.conta_id else p_outra_conta end,
          'transferencia', abs(v.valor), v.data, v.data,
          coalesce(nullif(trim(p_descricao), ''), v.descricao), v.id_externo)
  returning id into v_lanc;
  perform public.marcar_conciliado(p_item, v_lanc);
  return v_lanc;
end $$;

create function public.ignorar_extrato(p_item uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens := public.item_para_conciliar(p_item);
begin
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo';
  end if;
  update public.extrato_itens
  set situacao = 'ignorado', motivo = p_motivo, conciliado_por = auth.uid(), conciliado_em = now()
  where id = v.id;
end $$;

-- Desfaz o vínculo (o lançamento criado continua; para anulá-lo, estorne em Movimentações).
create function public.desconciliar(p_item uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.extrato_itens;
begin
  select * into v from public.extrato_itens where id = p_item for update;
  if v.id is null or not public.pode_lancar(v.conta_id) then
    raise exception 'Linha do extrato não encontrada ou sem permissão';
  end if;
  update public.extrato_itens
  set situacao = 'pendente', lancamento_id = null, motivo = null, conciliado_por = null, conciliado_em = null
  where id = p_item;
end $$;

-- Sugestões para as linhas pendentes de uma conta (respeita o RLS de quem consulta).
-- Lançamentos: mesmo efeito no saldo, até 7 dias de diferença, ainda sem par.
-- Contas a pagar/receber: saldo igual ao valor, até 15 dias do vencimento.
create function public.sugestoes_conciliacao(p_conta uuid)
returns table (item_id uuid, tipo text, alvo_id uuid, descricao text, data date, valor numeric, pontuacao int)
language sql stable set search_path = '' as $$
  with pend as (
    select * from public.extrato_itens where conta_id = p_conta and situacao = 'pendente'
  ),
  cand as (
    select p.id as item_id, 'lancamento'::text as tipo, l.id as alvo_id, l.descricao, l.data,
           public.efeito_na_conta(l, p_conta) as valor, 100 - 5 * abs(l.data - p.data) as pontuacao
    from pend p
    join public.lancamentos l on (l.conta_id = p_conta or l.conta_destino_id = p_conta)
     and public.efeito_na_conta(l, p_conta) = p.valor
     and abs(l.data - p.data) <= 7
    where not exists (select 1 from public.extrato_itens e where e.lancamento_id = l.id)
    union all
    select p.id, 'titulo', t.id, t.descricao, t.vencimento, t.valor - t.valor_pago, 80 - 2 * abs(t.vencimento - p.data)
    from pend p
    join public.titulos t on t.loja_id = p.loja_id and not t.cancelado
     and t.valor - t.valor_pago = abs(p.valor)
     and t.natureza = case when p.valor > 0 then 'receber' else 'pagar' end
     and abs(t.vencimento - p.data) <= 15
  )
  select item_id, tipo, alvo_id, descricao, data, valor, pontuacao
  from (select c.*, row_number() over (partition by c.item_id order by c.pontuacao desc) as n from cand c) x
  where n <= 3
$$;

create index on public.lancamentos (conta_id, data);

-- =========================================================
-- Permissões
-- =========================================================

revoke execute on function public.asaas_conectar, public.asaas_desconectar, public.importar_extrato, public.conciliar,
  public.conciliar_titulo, public.conciliar_novo_lancamento, public.conciliar_transferencia, public.ignorar_extrato,
  public.desconciliar, public.sugestoes_conciliacao from public, anon;
grant execute on function public.asaas_conectar, public.asaas_desconectar, public.importar_extrato, public.conciliar,
  public.conciliar_titulo, public.conciliar_novo_lancamento, public.conciliar_transferencia, public.ignorar_extrato,
  public.desconciliar, public.sugestoes_conciliacao to authenticated;
revoke execute on function public.asaas_credenciais from public, anon, authenticated;
grant execute on function public.asaas_credenciais to service_role;
revoke execute on function public.item_para_conciliar, public.marcar_conciliado from public, anon, authenticated;
