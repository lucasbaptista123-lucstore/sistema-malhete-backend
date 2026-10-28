-- Sistema Malhete — Fase 2: tesouraria MVP.
-- Contas (caixa, banco, tronco), categorias, lançamentos imutáveis (correção só por estorno),
-- mensalidades com baixa que gera o lançamento, saldos e inadimplência.

-- =========================================================
-- Contas e categorias
-- =========================================================

-- Tronco de beneficência é conta à parte: quem mexe nela é o Hospitaleiro (tronco.editar).
create table public.contas_financeiras (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  nome text not null,
  tipo text not null check (tipo in ('caixa', 'banco', 'tronco')),
  saldo_inicial numeric(12,2) not null default 0,
  ativa boolean not null default true,
  criado_em timestamptz not null default now(),
  unique (loja_id, nome)
);

-- codigo identifica as categorias que o sistema usa (ex.: 'mensalidades'); as criadas pela loja ficam sem código.
create table public.categorias_financeiras (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  codigo text,
  nome text not null,
  tipo text not null check (tipo in ('receita', 'despesa')),
  ativa boolean not null default true,
  unique (loja_id, codigo),
  unique (loja_id, tipo, nome)
);

-- =========================================================
-- Lançamentos (nunca editados nem apagados; erro se corrige com estorno)
-- =========================================================

-- Transferência: sai de conta_id e entra em conta_destino_id, sem categoria.
-- Estorno: mesma conta/tipo/categoria do original com valor negativo.
create table public.lancamentos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  conta_id uuid not null references public.contas_financeiras(id),
  conta_destino_id uuid references public.contas_financeiras(id),
  categoria_id uuid references public.categorias_financeiras(id),
  tipo text not null check (tipo in ('receita', 'despesa', 'transferencia')),
  valor numeric(12,2) not null check (valor <> 0),
  data date not null default current_date,
  descricao text not null,
  irmao_id uuid references public.irmaos(id),
  documento text,
  estorno_de uuid unique references public.lancamentos(id),
  motivo_estorno text,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now(),
  check ((tipo = 'transferencia') = (conta_destino_id is not null)),
  check (conta_destino_id is distinct from conta_id),
  check (tipo = 'transferencia' or categoria_id is not null),
  check ((estorno_de is null and valor > 0) or (estorno_de is not null and valor < 0 and motivo_estorno is not null))
);
create index on public.lancamentos (loja_id, data desc);
create index on public.lancamentos (conta_id);
create index on public.lancamentos (conta_destino_id);
create index on public.lancamentos (categoria_id);
create index on public.lancamentos (irmao_id);
create index on public.lancamentos (criado_por);

-- =========================================================
-- Mensalidades
-- =========================================================

create table public.mensalidades (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  competencia date not null check (extract(day from competencia) = 1), -- 1º dia do mês
  valor numeric(12,2) not null check (valor > 0),
  vencimento date not null,
  status text not null default 'aberta' check (status in ('aberta', 'paga', 'cancelada')),
  lancamento_id uuid unique references public.lancamentos(id),
  motivo_cancelamento text,
  cobranca_externa_id text, -- id da cobrança no Asaas da loja (preenchido pelo n8n)
  criado_em timestamptz not null default now(),
  unique (irmao_id, competencia),
  check ((status = 'paga') = (lancamento_id is not null)),
  check (status <> 'cancelada' or motivo_cancelamento is not null)
);
create index on public.mensalidades (loja_id, status, vencimento);

-- =========================================================
-- Funções de acesso
-- =========================================================

-- Tronco usa tronco.*; caixa e banco usam tesouraria.*.
create function public.pode_ler_conta(p_conta uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select public.tem_permissao(c.loja_id, case when c.tipo = 'tronco' then 'tronco.ler' else 'tesouraria.ler' end)
    from public.contas_financeiras c where c.id = p_conta), false)
$$;

create function public.pode_lancar(p_conta uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select c.ativa and public.tem_permissao(c.loja_id, case when c.tipo = 'tronco' then 'tronco.editar' else 'tesouraria.editar' end)
    from public.contas_financeiras c where c.id = p_conta), false)
$$;

-- =========================================================
-- Regras dos lançamentos
-- =========================================================

create function public.validar_lancamento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_orig public.lancamentos;
begin
  if tg_op <> 'INSERT' then
    raise exception 'Lançamento não pode ser alterado nem apagado; use o estorno';
  end if;

  if not exists (select 1 from public.contas_financeiras where id = new.conta_id and loja_id = new.loja_id)
     or (new.conta_destino_id is not null and not exists (
           select 1 from public.contas_financeiras where id = new.conta_destino_id and loja_id = new.loja_id)) then
    raise exception 'Conta não pertence à loja';
  end if;

  if new.categoria_id is not null and not exists (
       select 1 from public.categorias_financeiras
       where id = new.categoria_id and loja_id = new.loja_id and tipo = new.tipo) then
    raise exception 'Categoria não pertence à loja ou não é do tipo do lançamento';
  end if;

  if new.irmao_id is not null and not exists (
       select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Irmão não pertence à loja';
  end if;

  if new.estorno_de is not null then
    select * into v_orig from public.lancamentos where id = new.estorno_de;
    if v_orig.id is null or v_orig.estorno_de is not null
       or v_orig.loja_id <> new.loja_id or v_orig.conta_id <> new.conta_id
       or v_orig.conta_destino_id is distinct from new.conta_destino_id
       or v_orig.categoria_id is distinct from new.categoria_id
       or v_orig.tipo <> new.tipo or new.valor <> -v_orig.valor then
      raise exception 'Estorno não confere com o lançamento original';
    end if;
  end if;

  new.criado_por := auth.uid();
  new.criado_em := now();
  return new;
end $$;

create trigger validar before insert or update or delete on public.lancamentos
for each row execute function public.validar_lancamento();

-- Estorno: lança o valor negativo e reabre a mensalidade que ele tinha quitado.
create function public.estornar_lancamento(p_lancamento uuid, p_motivo text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig public.lancamentos;
  v_id uuid;
begin
  select * into v_orig from public.lancamentos where id = p_lancamento;
  if v_orig.id is null then
    raise exception 'Lançamento não encontrado';
  end if;
  if not public.pode_lancar(v_orig.conta_id)
     or (v_orig.conta_destino_id is not null and not public.pode_lancar(v_orig.conta_destino_id)) then
    raise exception 'Sem permissão para estornar este lançamento';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo do estorno';
  end if;
  if v_orig.estorno_de is not null then
    raise exception 'Estorno não pode ser estornado';
  end if;
  if exists (select 1 from public.lancamentos where estorno_de = p_lancamento) then
    raise exception 'Lançamento já estornado';
  end if;

  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data,
                                  descricao, irmao_id, estorno_de, motivo_estorno)
  values (v_orig.loja_id, v_orig.conta_id, v_orig.conta_destino_id, v_orig.categoria_id, v_orig.tipo, -v_orig.valor,
          current_date, 'Estorno: ' || v_orig.descricao, v_orig.irmao_id, v_orig.id, p_motivo)
  returning id into v_id;

  update public.mensalidades set status = 'aberta', lancamento_id = null where lancamento_id = p_lancamento;

  return v_id;
end $$;

-- =========================================================
-- Mensalidades: gerar, dar baixa, cancelar
-- =========================================================

-- Gera a mensalidade do mês para os irmãos ativos que ainda não têm. Retorna quantas criou.
create function public.gerar_mensalidades(p_loja uuid, p_competencia date, p_valor numeric, p_vencimento date)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para gerar mensalidades';
  end if;

  insert into public.mensalidades (loja_id, irmao_id, competencia, valor, vencimento)
  select p_loja, i.id, date_trunc('month', p_competencia)::date, p_valor, p_vencimento
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo'
  on conflict (irmao_id, competencia) do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- Baixa: lança a receita na conta escolhida e marca a mensalidade como paga.
create function public.registrar_pagamento(p_mensalidade uuid, p_conta uuid,
                                           p_data date default current_date, p_valor numeric default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_mens public.mensalidades;
  v_nome text;
  v_lanc uuid;
begin
  select * into v_mens from public.mensalidades where id = p_mensalidade for update;
  if v_mens.id is null then
    raise exception 'Mensalidade não encontrada';
  end if;
  if v_mens.status <> 'aberta' then
    raise exception 'Mensalidade não está em aberto';
  end if;
  if not public.pode_lancar(p_conta)
     or not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = v_mens.loja_id and tipo <> 'tronco') then
    raise exception 'Sem permissão ou conta inválida para receber mensalidade';
  end if;

  select nome into v_nome from public.irmaos where id = v_mens.irmao_id;

  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao, irmao_id)
  values (v_mens.loja_id, p_conta,
          (select id from public.categorias_financeiras where loja_id = v_mens.loja_id and codigo = 'mensalidades'),
          'receita', coalesce(p_valor, v_mens.valor), p_data,
          'Mensalidade ' || to_char(v_mens.competencia, 'MM/YYYY') || ' — ' || v_nome, v_mens.irmao_id)
  returning id into v_lanc;

  update public.mensalidades set status = 'paga', lancamento_id = v_lanc where id = p_mensalidade;
  return v_lanc;
end $$;

create function public.cancelar_mensalidade(p_mensalidade uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_mens public.mensalidades;
begin
  select * into v_mens from public.mensalidades where id = p_mensalidade for update;
  if v_mens.id is null or not public.tem_permissao(v_mens.loja_id, 'tesouraria.editar') then
    raise exception 'Mensalidade não encontrada ou sem permissão';
  end if;
  if v_mens.status <> 'aberta' then
    raise exception 'Só mensalidade em aberto pode ser cancelada (paga: estorne o pagamento antes)';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo do cancelamento';
  end if;
  update public.mensalidades set status = 'cancelada', motivo_cancelamento = p_motivo where id = p_mensalidade;
end $$;

-- =========================================================
-- Contas e categorias padrão em toda loja nova
-- =========================================================

create function public.criar_tesouraria_padrao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.contas_financeiras (loja_id, nome, tipo) values
    (new.id, 'Caixa', 'caixa'),
    (new.id, 'Banco', 'banco'),
    (new.id, 'Tronco de Beneficência', 'tronco');

  insert into public.categorias_financeiras (loja_id, codigo, nome, tipo)
  select new.id, c.codigo, c.nome, c.tipo
  from (values
    ('mensalidades',  'Mensalidades',                   'receita'),
    ('joias',         'Jóias e taxas de iniciação',     'receita'),
    ('taxas_graus',   'Taxas de elevação e exaltação',  'receita'),
    ('tronco',        'Tronco de beneficência',         'receita'),
    ('doacoes',       'Doações',                        'receita'),
    ('eventos',       'Eventos e ágapes',               'receita'),
    ('outras_rec',    'Outras receitas',                'receita'),
    ('capitacao',     'Capitação (GOB / Oriente)',      'despesa'),
    ('templo',        'Aluguel e manutenção do templo', 'despesa'),
    ('contas_consumo','Água, luz e internet',           'despesa'),
    ('agapes',        'Ágapes',                         'despesa'),
    ('ritualistico',  'Material ritualístico',          'despesa'),
    ('beneficencia',  'Beneficência',                   'despesa'),
    ('tarifas',       'Tarifas bancárias',              'despesa'),
    ('outras_desp',   'Outras despesas',                'despesa')
  ) as c(codigo, nome, tipo);

  return new;
end $$;

create trigger tesouraria_padrao after insert on public.lojas
for each row execute function public.criar_tesouraria_padrao();

-- =========================================================
-- Consultas: saldos e inadimplência (respeitam o RLS de quem consulta)
-- =========================================================

create view public.contas_saldo with (security_invoker = true) as
select c.id as conta_id, c.loja_id, c.nome, c.tipo, c.ativa,
  c.saldo_inicial + coalesce((
    select sum(case
                 when l.tipo = 'receita' then l.valor
                 when l.tipo = 'despesa' then -l.valor
                 when l.conta_id = c.id then -l.valor   -- transferência saindo
                 else l.valor                           -- transferência entrando
               end)
    from public.lancamentos l
    where l.conta_id = c.id or l.conta_destino_id = c.id), 0) as saldo
from public.contas_financeiras c;

create view public.inadimplencia with (security_invoker = true) as
select m.loja_id, m.irmao_id, i.nome,
  count(*) as mensalidades_atrasadas,
  sum(m.valor) as total_atrasado,
  min(m.vencimento) as vencimento_mais_antigo
from public.mensalidades m
join public.irmaos i on i.id = m.irmao_id
where m.status = 'aberta' and m.vencimento < current_date
group by m.loja_id, m.irmao_id, i.nome;

-- =========================================================
-- Auditoria
-- =========================================================

create trigger auditoria after insert or update or delete on public.contas_financeiras for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.categorias_financeiras for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.lancamentos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.mensalidades for each row execute function public.registrar_auditoria();

-- =========================================================
-- RLS
-- =========================================================

alter table public.contas_financeiras enable row level security;
alter table public.categorias_financeiras enable row level security;
alter table public.lancamentos enable row level security;
alter table public.mensalidades enable row level security;

-- Contas: quem lê a tesouraria (ou o tronco, para a conta do tronco); só a Tesouraria cria/edita.
-- Sem política de delete: conta se desativa (ativa = false).
create policy le on public.contas_financeiras for select to authenticated
  using (public.pode_ler_conta(id));
create policy tesouraria_cria on public.contas_financeiras for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));
create policy tesouraria_edita on public.contas_financeiras for update to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.editar'))
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

-- Categorias: quem lê tesouraria ou tronco; Tesouraria cria/edita. Sem delete (desativar).
create policy le on public.categorias_financeiras for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler') or public.tem_permissao(loja_id, 'tronco.ler'));
create policy tesouraria_cria on public.categorias_financeiras for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));
create policy tesouraria_edita on public.categorias_financeiras for update to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.editar'))
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

-- Lançamentos: lê quem lê a conta (origem ou destino); lança quem pode lançar nas duas pontas.
-- Sem update/delete (o trigger também bloqueia).
create policy le on public.lancamentos for select to authenticated
  using (public.pode_ler_conta(conta_id) or (conta_destino_id is not null and public.pode_ler_conta(conta_destino_id)));
create policy lanca on public.lancamentos for insert to authenticated
  with check (estorno_de is null
              and public.pode_lancar(conta_id)
              and (conta_destino_id is null or public.pode_lancar(conta_destino_id)));

-- Mensalidades: o irmão vê as suas; quem lê a tesouraria vê todas.
-- Escrita só pelas funções (gerar, registrar_pagamento, cancelar).
create policy proprio_ou_tesouraria_le on public.mensalidades for select to authenticated
  using (irmao_id = public.meu_irmao_id(loja_id) or public.tem_permissao(loja_id, 'tesouraria.ler'));

-- =========================================================
-- Permissões das funções
-- =========================================================

revoke execute on function public.pode_ler_conta, public.pode_lancar, public.estornar_lancamento,
  public.gerar_mensalidades, public.registrar_pagamento, public.cancelar_mensalidade from public, anon;
grant execute on function public.pode_ler_conta, public.pode_lancar, public.estornar_lancamento,
  public.gerar_mensalidades, public.registrar_pagamento, public.cancelar_mensalidade to authenticated;
revoke execute on function public.validar_lancamento, public.criar_tesouraria_padrao from public, anon, authenticated;
