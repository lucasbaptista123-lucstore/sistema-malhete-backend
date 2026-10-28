-- Sistema Malhete — financeiro completo (modelo Conta Azul/Omie, adaptado à loja):
-- plano de contas em grupos de DRE, fornecedores/clientes, centros de custo,
-- contas a pagar/receber (parcelas, recorrência, baixa parcial com juros/desconto),
-- mensalidades viram contas a receber, comprovantes anexos e funções de relatório
-- (DRE caixa/competência, fluxo de caixa realizado + previsto, saldos em data).
--
-- A tabela mensalidades (Fase 2) estava vazia em produção e é substituída por títulos.

-- =========================================================
-- Sai o modelo de mensalidades da Fase 2
-- =========================================================

drop view public.inadimplencia;
drop function public.gerar_mensalidades(uuid, date, numeric, date);
drop function public.registrar_pagamento(uuid, uuid, date, numeric);
drop function public.cancelar_mensalidade(uuid, text);
drop table public.mensalidades;

-- =========================================================
-- Plano de contas: grupos da DRE (catálogo global) e categorias da loja
-- =========================================================

create table public.grupos_dre (
  codigo text primary key,
  nome text not null,
  tipo text not null check (tipo in ('receita', 'despesa')),
  ordem int not null
);

insert into public.grupos_dre (codigo, nome, tipo, ordem) values
  ('receitas_associativas',    'Receitas associativas',          'receita', 10),
  ('receitas_eventos',         'Receitas de eventos',            'receita', 20),
  ('doacoes',                  'Doações e contribuições',        'receita', 30),
  ('outras_receitas',          'Outras receitas',                'receita', 40),
  ('obrigacoes_potencia',      'Obrigações com a Potência',      'despesa', 50),
  ('despesas_templo',          'Templo e instalações',           'despesa', 60),
  ('despesas_administrativas', 'Despesas administrativas',       'despesa', 70),
  ('despesas_ritualisticas',   'Despesas ritualísticas',         'despesa', 80),
  ('eventos_agapes',           'Eventos e ágapes',               'despesa', 90),
  ('beneficencia',             'Beneficência',                   'despesa', 100),
  ('outras_despesas',          'Outras despesas',                'despesa', 110),
  ('receitas_financeiras',     'Receitas financeiras',           'receita', 120),
  ('despesas_financeiras',     'Despesas financeiras',           'despesa', 130),
  ('investimentos',            'Investimentos (bens e equipamentos)', 'despesa', 140);

alter table public.grupos_dre enable row level security;
create policy leitura on public.grupos_dre for select to authenticated using (true);

alter table public.categorias_financeiras add column grupo text references public.grupos_dre(codigo);

update public.categorias_financeiras set grupo = case codigo
  when 'mensalidades' then 'receitas_associativas'
  when 'joias' then 'receitas_associativas'
  when 'taxas_graus' then 'receitas_associativas'
  when 'tronco' then 'doacoes'
  when 'doacoes' then 'doacoes'
  when 'eventos' then 'receitas_eventos'
  when 'capitacao' then 'obrigacoes_potencia'
  when 'templo' then 'despesas_templo'
  when 'contas_consumo' then 'despesas_templo'
  when 'agapes' then 'eventos_agapes'
  when 'ritualistico' then 'despesas_ritualisticas'
  when 'beneficencia' then 'beneficencia'
  when 'tarifas' then 'despesas_financeiras'
  else case tipo when 'receita' then 'outras_receitas' else 'outras_despesas' end
end;

alter table public.categorias_financeiras alter column grupo set not null;
create index on public.categorias_financeiras (grupo);

-- Categorias novas do plano padrão, também nas lojas que já existem.
create function public.categorias_extras(p_loja uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.categorias_financeiras (loja_id, codigo, nome, tipo, grupo)
  select p_loja, c.codigo, c.nome, c.tipo, c.grupo
  from (values
    ('rendimentos',  'Rendimentos de aplicações', 'receita', 'receitas_financeiras'),
    ('expediente',   'Material de expediente',    'despesa', 'despesas_administrativas'),
    ('servicos',     'Contabilidade e serviços',  'despesa', 'despesas_administrativas'),
    ('juros_multas', 'Juros e multas pagos',      'despesa', 'despesas_financeiras'),
    ('equipamentos', 'Bens e equipamentos',       'despesa', 'investimentos')
  ) as c(codigo, nome, tipo, grupo)
  on conflict do nothing
$$;
select public.categorias_extras(id) from public.lojas;

-- Grupo tem que ser do mesmo tipo da categoria; sem grupo, cai em "outras".
create or replace function public.proteger_categoria() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.grupo is null then
    new.grupo := case new.tipo when 'receita' then 'outras_receitas' else 'outras_despesas' end;
  end if;
  if not exists (select 1 from public.grupos_dre where codigo = new.grupo and tipo = new.tipo) then
    raise exception 'O grupo da DRE precisa ser do mesmo tipo da categoria';
  end if;
  if tg_op = 'UPDATE' then
    if new.loja_id is distinct from old.loja_id
       or new.tipo is distinct from old.tipo
       or new.codigo is distinct from old.codigo then
      raise exception 'Tipo e código da categoria não podem ser alterados; crie uma nova categoria';
    end if;
    if old.codigo = 'mensalidades' and not new.ativa then
      raise exception 'A categoria de mensalidades é usada pelo sistema e não pode ser desativada';
    end if;
  end if;
  return new;
end $$;

drop trigger proteger on public.categorias_financeiras;
create trigger proteger before insert or update on public.categorias_financeiras
for each row execute function public.proteger_categoria();

-- Loja nova: contas, categorias padrão (agora com grupo) e as extras.
create or replace function public.criar_tesouraria_padrao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.contas_financeiras (loja_id, nome, tipo) values
    (new.id, 'Caixa', 'caixa'),
    (new.id, 'Banco', 'banco'),
    (new.id, 'Tronco de Beneficência', 'tronco');

  insert into public.categorias_financeiras (loja_id, codigo, nome, tipo, grupo)
  select new.id, c.codigo, c.nome, c.tipo, c.grupo
  from (values
    ('mensalidades',  'Mensalidades',                   'receita', 'receitas_associativas'),
    ('joias',         'Jóias e taxas de iniciação',     'receita', 'receitas_associativas'),
    ('taxas_graus',   'Taxas de elevação e exaltação',  'receita', 'receitas_associativas'),
    ('tronco',        'Tronco de beneficência',         'receita', 'doacoes'),
    ('doacoes',       'Doações',                        'receita', 'doacoes'),
    ('eventos',       'Eventos e ágapes',               'receita', 'receitas_eventos'),
    ('outras_rec',    'Outras receitas',                'receita', 'outras_receitas'),
    ('capitacao',     'Capitação (GOB / Oriente)',      'despesa', 'obrigacoes_potencia'),
    ('templo',        'Aluguel e manutenção do templo', 'despesa', 'despesas_templo'),
    ('contas_consumo','Água, luz e internet',           'despesa', 'despesas_templo'),
    ('agapes',        'Ágapes',                         'despesa', 'eventos_agapes'),
    ('ritualistico',  'Material ritualístico',          'despesa', 'despesas_ritualisticas'),
    ('beneficencia',  'Beneficência',                   'despesa', 'beneficencia'),
    ('tarifas',       'Tarifas bancárias',              'despesa', 'despesas_financeiras'),
    ('outras_desp',   'Outras despesas',                'despesa', 'outras_despesas')
  ) as c(codigo, nome, tipo, grupo);

  perform public.categorias_extras(new.id);
  return new;
end $$;

-- =========================================================
-- Fornecedores/clientes e centros de custo
-- =========================================================

create table public.favorecidos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  nome text not null,
  tipo text not null default 'fornecedor' check (tipo in ('fornecedor', 'cliente', 'ambos')),
  documento text, -- CPF ou CNPJ
  email text,
  telefone text,
  chave_pix text,
  observacoes text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  unique (loja_id, nome)
);

create table public.centros_custo (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  nome text not null,
  ativo boolean not null default true,
  unique (loja_id, nome)
);

-- =========================================================
-- Contas a pagar e a receber (títulos)
-- =========================================================

-- valor_pago é mantido pelo sistema a cada baixa/estorno (o irmão vê o próprio título
-- sem enxergar os lançamentos). Título não se apaga: cancela (sem baixa) ou estorna a baixa.
create table public.titulos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  natureza text not null check (natureza in ('receber', 'pagar')),
  descricao text not null,
  categoria_id uuid not null references public.categorias_financeiras(id),
  centro_custo_id uuid references public.centros_custo(id),
  favorecido_id uuid references public.favorecidos(id),
  irmao_id uuid references public.irmaos(id),
  valor numeric(12,2) not null check (valor > 0),
  valor_pago numeric(12,2) not null default 0,
  vencimento date not null,
  competencia date not null,
  documento text,
  observacoes text,
  parcela smallint not null default 1,
  total_parcelas smallint not null default 1,
  grupo_id uuid, -- parcelas/recorrências criadas juntas
  origem text not null default 'manual' check (origem in ('manual', 'mensalidade')),
  cancelado boolean not null default false,
  motivo_cancelamento text,
  criado_por uuid references auth.users(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (parcela between 1 and total_parcelas),
  check (not cancelado or motivo_cancelamento is not null),
  check (valor_pago >= 0 and valor_pago <= valor),
  check (favorecido_id is null or irmao_id is null)
);
create index on public.titulos (loja_id, natureza, vencimento);
create index on public.titulos (irmao_id);
create index on public.titulos (favorecido_id);
create index on public.titulos (categoria_id);
create index on public.titulos (centro_custo_id);
create index on public.titulos (grupo_id);
create index on public.titulos (criado_por);
create unique index titulos_mensalidade_unq on public.titulos (irmao_id, competencia) where origem = 'mensalidade';

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

create function public.validar_titulo() returns trigger
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

-- competencia tem default no trigger; a coluna aceita null só na entrada.
alter table public.titulos alter column competencia drop not null;
create trigger validar before insert or update or delete on public.titulos
for each row execute function public.validar_titulo();
alter table public.titulos add constraint titulos_competencia_nn check (competencia is not null);

-- =========================================================
-- Lançamentos ganham: título baixado, competência, favorecido, centro de custo
-- =========================================================

alter table public.lancamentos
  add column titulo_id uuid references public.titulos(id),
  add column abatimento numeric(12,2), -- quanto do título esta baixa quita (negativo no estorno)
  add column competencia date,
  add column favorecido_id uuid references public.favorecidos(id),
  add column centro_custo_id uuid references public.centros_custo(id);

alter table public.lancamentos disable trigger validar;
update public.lancamentos set competencia = data;
alter table public.lancamentos enable trigger validar;
alter table public.lancamentos add constraint lancamentos_competencia_nn check (competencia is not null);
alter table public.lancamentos add constraint lancamentos_titulo_abatimento check ((titulo_id is null) = (abatimento is null));
alter table public.lancamentos add constraint lancamentos_favorecido_ou_irmao check (favorecido_id is null or irmao_id is null);
create index on public.lancamentos (titulo_id);
create index on public.lancamentos (favorecido_id);
create index on public.lancamentos (centro_custo_id);
create index on public.lancamentos (loja_id, competencia);

create or replace function public.validar_lancamento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_orig public.lancamentos;
  v_tit public.titulos;
  v_tipo text;
begin
  if tg_op <> 'INSERT' then
    raise exception 'Lançamento não pode ser alterado nem apagado; use o estorno';
  end if;

  new.competencia := coalesce(new.competencia, new.data);

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
  if new.irmao_id is not null and not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Irmão não pertence à loja';
  end if;
  if new.favorecido_id is not null and not exists (select 1 from public.favorecidos where id = new.favorecido_id and loja_id = new.loja_id) then
    raise exception 'Fornecedor/cliente não pertence à loja';
  end if;
  if new.centro_custo_id is not null and not exists (select 1 from public.centros_custo where id = new.centro_custo_id and loja_id = new.loja_id) then
    raise exception 'Centro de custo não pertence à loja';
  end if;

  if new.estorno_de is not null then
    select * into v_orig from public.lancamentos where id = new.estorno_de;
    if v_orig.id is null or v_orig.estorno_de is not null
       or v_orig.loja_id <> new.loja_id or v_orig.conta_id <> new.conta_id
       or v_orig.conta_destino_id is distinct from new.conta_destino_id
       or v_orig.categoria_id is distinct from new.categoria_id
       or v_orig.titulo_id is distinct from new.titulo_id
       or v_orig.abatimento is distinct from -new.abatimento
       or v_orig.tipo <> new.tipo or new.valor <> -v_orig.valor then
      raise exception 'Estorno não confere com o lançamento original';
    end if;
  elsif new.titulo_id is not null then
    select * into v_tit from public.titulos where id = new.titulo_id;
    if v_tit.id is null or v_tit.loja_id <> new.loja_id or v_tit.cancelado then
      raise exception 'Título inválido ou cancelado';
    end if;
    v_tipo := case v_tit.natureza when 'receber' then 'receita' else 'despesa' end;
    if new.tipo <> v_tipo or new.categoria_id is distinct from v_tit.categoria_id then
      raise exception 'Baixa não confere com o título';
    end if;
    if new.abatimento <= 0 or new.abatimento > v_tit.valor - v_tit.valor_pago then
      raise exception 'Valor da baixa maior que o saldo do título';
    end if;
  end if;

  new.criado_por := auth.uid();
  new.criado_em := now();
  return new;
end $$;

-- Cada baixa/estorno atualiza o valor pago do título.
create function public.atualizar_valor_pago() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.titulo_id is not null then
    perform set_config('malhete.sistema', 'on', true);
    update public.titulos set valor_pago = valor_pago + new.abatimento where id = new.titulo_id;
    perform set_config('malhete.sistema', 'off', true);
  end if;
  return new;
end $$;

create trigger valor_pago after insert on public.lancamentos
for each row execute function public.atualizar_valor_pago();

-- Lançamento avulso direto pela API não baixa título (baixa só por baixar_titulo).
drop policy lanca on public.lancamentos;
create policy lanca on public.lancamentos for insert to authenticated
  with check (estorno_de is null and titulo_id is null
              and public.pode_lancar(conta_id)
              and (conta_destino_id is null or public.pode_lancar(conta_destino_id)));

create or replace function public.estornar_lancamento(p_lancamento uuid, p_motivo text) returns uuid
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

  insert into public.lancamentos (loja_id, conta_id, conta_destino_id, categoria_id, tipo, valor, data, competencia,
                                  descricao, irmao_id, favorecido_id, centro_custo_id, titulo_id, abatimento,
                                  estorno_de, motivo_estorno)
  values (v_orig.loja_id, v_orig.conta_id, v_orig.conta_destino_id, v_orig.categoria_id, v_orig.tipo, -v_orig.valor,
          current_date, v_orig.competencia, 'Estorno: ' || v_orig.descricao, v_orig.irmao_id, v_orig.favorecido_id,
          v_orig.centro_custo_id, v_orig.titulo_id, -v_orig.abatimento, v_orig.id, p_motivo)
  returning id into v_id;

  return v_id;
end $$;

-- =========================================================
-- Ações sobre títulos
-- =========================================================

-- Cria 1..120 títulos. 'parcelar' divide o valor (centavos que sobram na 1ª parcela, mesma competência);
-- 'repetir' repete o valor todo mês (cada um na própria competência). Retorna o grupo.
create function public.criar_titulos(
  p_loja uuid, p_natureza text, p_descricao text, p_categoria uuid, p_valor numeric, p_vencimento date,
  p_parcelas int default 1, p_modo text default 'parcelar', p_competencia date default null,
  p_favorecido uuid default null, p_irmao uuid default null, p_centro uuid default null,
  p_documento text default null, p_observacoes text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_grupo uuid := gen_random_uuid();
  v_base numeric(12,2);
  v_venc date;
  i int;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para lançar contas a pagar/receber';
  end if;
  if p_parcelas is null or p_parcelas < 1 or p_parcelas > 120 then
    raise exception 'Número de parcelas deve ser de 1 a 120';
  end if;
  if p_modo not in ('parcelar', 'repetir') then
    raise exception 'Modo inválido';
  end if;
  if coalesce(trim(p_descricao), '') = '' then
    raise exception 'Informe a descrição';
  end if;

  v_base := case when p_modo = 'parcelar' then trunc(p_valor / p_parcelas, 2) else p_valor end;

  for i in 1..p_parcelas loop
    v_venc := (p_vencimento + make_interval(months => i - 1))::date;
    insert into public.titulos (loja_id, natureza, descricao, categoria_id, centro_custo_id, favorecido_id, irmao_id,
                                valor, vencimento, competencia, documento, observacoes, parcela, total_parcelas, grupo_id)
    values (p_loja, p_natureza,
            trim(p_descricao) || case when p_parcelas > 1 then format(' (%s/%s)', i, p_parcelas) else '' end,
            p_categoria, p_centro, p_favorecido, p_irmao,
            case when p_modo = 'parcelar' and i = 1 then p_valor - v_base * (p_parcelas - 1) else v_base end,
            v_venc,
            case when p_modo = 'parcelar' then coalesce(p_competencia, p_vencimento)
                 else coalesce(p_competencia + make_interval(months => i - 1), v_venc)::date end,
            p_documento, p_observacoes, i, p_parcelas, v_grupo);
  end loop;

  return v_grupo;
end $$;

-- Baixa (total ou parcial): lança na conta o valor abatido + juros/multa − desconto.
create function public.baixar_titulo(
  p_titulo uuid, p_conta uuid, p_data date default current_date,
  p_abatimento numeric default null, p_juros numeric default 0, p_desconto numeric default 0
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_tit public.titulos;
  v_abat numeric(12,2);
  v_valor numeric(12,2);
  v_id uuid;
begin
  select * into v_tit from public.titulos where id = p_titulo for update;
  if v_tit.id is null then
    raise exception 'Título não encontrado';
  end if;
  if v_tit.cancelado then
    raise exception 'Título cancelado';
  end if;
  if not public.pode_lancar(p_conta)
     or not exists (select 1 from public.contas_financeiras where id = p_conta and loja_id = v_tit.loja_id) then
    raise exception 'Sem permissão ou conta inválida';
  end if;
  if v_tit.origem = 'mensalidade' and exists (select 1 from public.contas_financeiras where id = p_conta and tipo = 'tronco') then
    raise exception 'Mensalidade não pode ser recebida no tronco';
  end if;

  v_abat := coalesce(p_abatimento, v_tit.valor - v_tit.valor_pago);
  v_valor := v_abat + coalesce(p_juros, 0) - coalesce(p_desconto, 0);
  if coalesce(p_juros, 0) < 0 or coalesce(p_desconto, 0) < 0 or v_valor <= 0 then
    raise exception 'Valores da baixa inválidos';
  end if;

  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, competencia, descricao,
                                  irmao_id, favorecido_id, centro_custo_id, documento, titulo_id, abatimento)
  values (v_tit.loja_id, p_conta, v_tit.categoria_id,
          case v_tit.natureza when 'receber' then 'receita' else 'despesa' end,
          v_valor, coalesce(p_data, current_date), v_tit.competencia,
          v_tit.descricao || case when v_abat < v_tit.valor - v_tit.valor_pago then ' — baixa parcial' else '' end,
          v_tit.irmao_id, v_tit.favorecido_id, v_tit.centro_custo_id, v_tit.documento, v_tit.id, v_abat)
  returning id into v_id;

  return v_id;
end $$;

-- Cancela o título (sem baixa). Com p_seguintes, cancela também as parcelas/recorrências
-- seguintes do mesmo grupo que ainda não tiveram baixa.
create function public.cancelar_titulo(p_titulo uuid, p_motivo text, p_seguintes boolean default false) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_tit public.titulos;
  n int;
begin
  select * into v_tit from public.titulos where id = p_titulo;
  if v_tit.id is null or not public.tem_permissao(v_tit.loja_id, 'tesouraria.editar') then
    raise exception 'Título não encontrado ou sem permissão';
  end if;
  if v_tit.cancelado then
    raise exception 'Título já cancelado';
  end if;
  if v_tit.valor_pago <> 0 then
    raise exception 'Título com baixa não pode ser cancelado; estorne a baixa antes';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo do cancelamento';
  end if;

  perform set_config('malhete.sistema', 'on', true);
  update public.titulos set cancelado = true, motivo_cancelamento = p_motivo
  where not cancelado and valor_pago = 0
    and (id = p_titulo
         or (p_seguintes and v_tit.grupo_id is not null and grupo_id = v_tit.grupo_id and parcela > v_tit.parcela));
  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $$;

-- Mensalidades = contas a receber do irmão (origem 'mensalidade'), uma por irmão ativo e mês.
create function public.gerar_mensalidades(p_loja uuid, p_competencia date, p_valor numeric, p_vencimento date)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_comp date := date_trunc('month', p_competencia)::date;
  n int;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para gerar mensalidades';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor da mensalidade';
  end if;

  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
  select p_loja, 'receber', 'Mensalidade ' || to_char(v_comp, 'MM/YYYY'),
         (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'mensalidades'),
         i.id, p_valor, p_vencimento, v_comp, 'mensalidade'
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo'
  on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;

  get diagnostics n = row_count;
  return n;
end $$;

-- Inadimplência: títulos a receber vencidos com saldo (irmãos e clientes). Nome resolvido no app.
create view public.inadimplencia with (security_invoker = true) as
select t.loja_id, t.irmao_id, t.favorecido_id,
  count(*) as titulos_atrasados,
  sum(t.valor - t.valor_pago) as total_atrasado,
  min(t.vencimento) as vencimento_mais_antigo
from public.titulos t
where t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor and t.vencimento < current_date
group by t.loja_id, t.irmao_id, t.favorecido_id;

-- =========================================================
-- Comprovantes (Storage privado; caminho = <loja_id>/<arquivo>)
-- =========================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

-- Primeira pasta do caminho = loja; nome fora do padrão não dá acesso.
create function public.loja_do_caminho(p_nome text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return split_part(p_nome, '/', 1)::uuid;
exception when others then
  return null;
end $$;

create policy comprovantes_le on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes' and public.tem_permissao(public.loja_do_caminho(name), 'tesouraria.ler'));
create policy comprovantes_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes' and public.tem_permissao(public.loja_do_caminho(name), 'tesouraria.editar'));

create table public.anexos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  lancamento_id uuid references public.lancamentos(id),
  titulo_id uuid references public.titulos(id),
  caminho text not null unique,
  nome_arquivo text not null,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now(),
  check ((lancamento_id is null) <> (titulo_id is null)),
  check (public.loja_do_caminho(caminho) = loja_id)
);
create index on public.anexos (lancamento_id);
create index on public.anexos (titulo_id);
create index on public.anexos (loja_id);
create index on public.anexos (criado_por);

-- =========================================================
-- Relatórios (security invoker: respeitam o RLS de quem consulta)
-- =========================================================

-- Saldo de cada conta ao fim do dia p_data.
create function public.saldos_em(p_loja uuid, p_data date)
returns table (conta_id uuid, nome text, tipo text, saldo numeric)
language sql stable set search_path = '' as $$
  select c.id, c.nome, c.tipo,
    c.saldo_inicial + coalesce((
      select sum(case
                   when l.tipo = 'receita' then l.valor
                   when l.tipo = 'despesa' then -l.valor
                   when l.conta_id = c.id then -l.valor
                   else l.valor
                 end)
      from public.lancamentos l
      where (l.conta_id = c.id or l.conta_destino_id = c.id) and l.data <= p_data), 0)
  from public.contas_financeiras c
  where c.loja_id = p_loja
  order by c.nome
$$;

-- DRE por categoria e mês. Caixa: lançamentos pela data do pagamento.
-- Competência: títulos (não cancelados) pela competência + lançamentos avulsos pela competência.
create function public.rel_dre(p_loja uuid, p_de date, p_ate date, p_regime text default 'caixa')
returns table (grupo text, categoria_id uuid, mes date, valor numeric)
language sql stable set search_path = '' as $$
  with base as (
    select l.categoria_id, l.data as dia, l.valor
    from public.lancamentos l
    where p_regime = 'caixa' and l.loja_id = p_loja and l.tipo <> 'transferencia' and l.data between p_de and p_ate
    union all
    select t.categoria_id, t.competencia, t.valor
    from public.titulos t
    where p_regime = 'competencia' and t.loja_id = p_loja and not t.cancelado and t.competencia between p_de and p_ate
    union all
    select l.categoria_id, l.competencia, l.valor
    from public.lancamentos l
    where p_regime = 'competencia' and l.loja_id = p_loja and l.tipo <> 'transferencia' and l.titulo_id is null
      and l.competencia between p_de and p_ate
  )
  select c.grupo, b.categoria_id, date_trunc('month', b.dia)::date, sum(b.valor)
  from base b
  join public.categorias_financeiras c on c.id = b.categoria_id
  group by c.grupo, b.categoria_id, date_trunc('month', b.dia)
$$;

-- Fluxo de caixa diário (todas as contas, sem transferências internas):
-- realizado = lançamentos; previsto = saldo dos títulos em aberto (vencidos contam hoje).
create function public.rel_fluxo_caixa(p_loja uuid, p_de date, p_ate date)
returns table (dia date, entradas numeric, saidas numeric, entradas_previstas numeric, saidas_previstas numeric)
language sql stable set search_path = '' as $$
  with mov as (
    select l.data as dia,
      case when l.tipo = 'receita' then l.valor else 0 end as e,
      case when l.tipo = 'despesa' then l.valor else 0 end as s,
      0::numeric as ep, 0::numeric as sp
    from public.lancamentos l
    where l.loja_id = p_loja and l.tipo <> 'transferencia' and l.data between p_de and p_ate
    union all
    select greatest(t.vencimento, current_date), 0, 0,
      case when t.natureza = 'receber' then t.valor - t.valor_pago else 0 end,
      case when t.natureza = 'pagar' then t.valor - t.valor_pago else 0 end
    from public.titulos t
    where t.loja_id = p_loja and not t.cancelado and t.valor_pago < t.valor
      and greatest(t.vencimento, current_date) between p_de and p_ate
  )
  select dia, sum(e), sum(s), sum(ep), sum(sp) from mov group by dia order by dia
$$;

-- =========================================================
-- Auditoria e RLS
-- =========================================================

create trigger auditoria after insert or update or delete on public.favorecidos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.centros_custo for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.titulos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.anexos for each row execute function public.registrar_auditoria();

alter table public.favorecidos enable row level security;
alter table public.centros_custo enable row level security;
alter table public.titulos enable row level security;
alter table public.anexos enable row level security;

create policy le on public.favorecidos for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler') or public.tem_permissao(loja_id, 'tronco.ler'));
create policy tesouraria_cria on public.favorecidos for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));
create policy tesouraria_edita on public.favorecidos for update to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.editar'))
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

create policy le on public.centros_custo for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler') or public.tem_permissao(loja_id, 'tronco.ler'));
create policy tesouraria_cria on public.centros_custo for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));
create policy tesouraria_edita on public.centros_custo for update to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.editar'))
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

-- Títulos: Tesouraria vê todos; o irmão vê os que ele deve (a receber em nome dele).
-- Criação pela função criar_titulos (ou insert direto de 1 título); edição de dados básicos pela Tesouraria.
create policy le on public.titulos for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler')
         or (natureza = 'receber' and irmao_id is not null and irmao_id = public.meu_irmao_id(loja_id)));
create policy tesouraria_cria on public.titulos for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));
create policy tesouraria_edita on public.titulos for update to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.editar'))
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

create policy le on public.anexos for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler'));
create policy tesouraria_anexa on public.anexos for insert to authenticated
  with check (public.tem_permissao(loja_id, 'tesouraria.editar'));

revoke execute on function public.criar_titulos, public.baixar_titulo, public.cancelar_titulo, public.gerar_mensalidades,
  public.saldos_em, public.rel_dre, public.rel_fluxo_caixa from public, anon;
grant execute on function public.criar_titulos, public.baixar_titulo, public.cancelar_titulo, public.gerar_mensalidades,
  public.saldos_em, public.rel_dre, public.rel_fluxo_caixa to authenticated;
revoke execute on function public.validar_titulo, public.atualizar_valor_pago, public.categorias_extras
  from public, anon, authenticated;
