-- Sistema Malhete — Fase 1: fundação
-- Multi-tenant (loja = tenant), ritos como modelo, cadastro de irmãos,
-- gestões/mandatos (acesso vem do cargo vigente) e log de auditoria.

-- =========================================================
-- Estrutura: Potência → Oriente estadual → Loja
-- =========================================================

create table public.potencias (
  id uuid primary key default gen_random_uuid(),
  sigla text not null unique,
  nome text not null
);

create table public.orientes (
  id uuid primary key default gen_random_uuid(),
  potencia_id uuid not null references public.potencias(id),
  uf char(2) not null,
  nome text not null,
  unique (potencia_id, uf)
);

create table public.ritos (
  id uuid primary key default gen_random_uuid(),
  sigla text not null unique,
  nome text not null,
  ativo boolean not null default false -- só ritos com modelo de cargos pronto ficam ativos
);

-- Modelo de cargos de cada rito. Copiado para a loja no cadastro.
-- grau_acompanhado: grau que o cargo acompanha (vigilantes → trabalhos).
-- permissoes: códigos como 'tesouraria.editar'; '*' = acesso total.
create table public.rito_cargos (
  id uuid primary key default gen_random_uuid(),
  rito_id uuid not null references public.ritos(id) on delete cascade,
  codigo text not null,
  nome text not null,
  ordem int not null default 0,
  grau_acompanhado smallint check (grau_acompanhado between 1 and 3),
  permissoes text[] not null default '{}',
  unique (rito_id, codigo)
);

create table public.lojas (
  id uuid primary key default gen_random_uuid(),
  oriente_id uuid not null references public.orientes(id),
  rito_id uuid not null references public.ritos(id),
  nome text not null,
  numero text,
  cidade text,
  uf char(2),
  cnpj text,
  ativa boolean not null default true,
  criado_em timestamptz not null default now(),
  criado_por uuid references auth.users(id)
);

create table public.loja_cargos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  rito_cargo_id uuid references public.rito_cargos(id),
  codigo text not null,
  nome text not null,
  ordem int not null default 0,
  grau_acompanhado smallint check (grau_acompanhado between 1 and 3),
  permissoes text[] not null default '{}',
  unique (loja_id, codigo)
);

-- Assinatura da loja na plataforma (cobrança da plataforma, não da loja).
create table public.assinaturas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null unique references public.lojas(id) on delete cascade,
  plano text not null default 'teste',
  status text not null default 'teste' check (status in ('teste', 'ativa', 'atrasada', 'cancelada')),
  teste_ate date not null default (current_date + 30),
  criado_em timestamptz not null default now()
);

-- =========================================================
-- Pessoas
-- =========================================================

create type public.situacao_irmao as enum ('ativo', 'irregular', 'licenciado', 'quite_placet', 'falecido', 'desligado');

-- Um irmão filiado a duas lojas tem um registro em cada (dados por tenant).
create table public.irmaos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  admin_loja boolean not null default false, -- quem cadastrou a loja; acesso total até a gestão estar montada
  nome text not null,
  cpf text,
  cim text,
  email text,
  telefone text,
  data_nascimento date,
  grau smallint not null default 1 check (grau between 1 and 3),
  mestre_instalado boolean not null default false,
  data_iniciacao date,
  data_elevacao date,
  data_exaltacao date,
  situacao public.situacao_irmao not null default 'ativo',
  endereco jsonb,
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (loja_id, user_id),
  unique (loja_id, cpf)
);
create index on public.irmaos (user_id);

create table public.familiares (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  nome text not null,
  parentesco text not null,
  data_nascimento date,
  telefone text
);
create index on public.familiares (irmao_id);

-- =========================================================
-- Gestões e mandatos
-- =========================================================

create table public.gestoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  nome text not null,
  inicio date not null,
  fim date not null,
  check (fim > inicio)
);

create table public.mandatos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  gestao_id uuid not null references public.gestoes(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  cargo_id uuid not null references public.loja_cargos(id),
  inicio date not null,
  fim date not null,
  check (fim >= inicio)
);
create index on public.mandatos (irmao_id, inicio, fim);

-- =========================================================
-- Admins da plataforma (dona do SaaS). Sem acesso a dados de loja por padrão.
-- =========================================================

create table public.plataforma_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- =========================================================
-- Auditoria
-- =========================================================

create table public.audit_log (
  id bigint generated always as identity primary key,
  loja_id uuid,
  user_id uuid default auth.uid(),
  tabela text not null,
  registro_id uuid,
  acao text not null,
  antes jsonb,
  depois jsonb,
  em timestamptz not null default now()
);
create index on public.audit_log (loja_id, em desc);

create function public.registrar_auditoria() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_linha jsonb := to_jsonb(coalesce(new, old));
begin
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

create trigger auditoria after insert or update or delete on public.lojas for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.loja_cargos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.irmaos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.familiares for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.gestoes for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.mandatos for each row execute function public.registrar_auditoria();

-- =========================================================
-- Funções de acesso (usadas pelas políticas RLS)
-- =========================================================

-- Lojas em que o usuário logado é irmão ativo/licenciado.
create function public.minhas_lojas() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select loja_id from public.irmaos
  where user_id = auth.uid() and situacao in ('ativo', 'licenciado', 'irregular')
$$;

create function public.meu_irmao_id(p_loja uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select id from public.irmaos where loja_id = p_loja and user_id = auth.uid()
$$;

create function public.meu_grau(p_loja uuid) returns smallint
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select grau from public.irmaos
     where loja_id = p_loja and user_id = auth.uid()
       and situacao in ('ativo', 'licenciado', 'irregular')),
    0::smallint)
$$;

-- Permissão vem de: admin_loja, ou cargo com mandato vigente hoje.
-- 'x.ler' é satisfeita também por 'x.editar'.
create function public.tem_permissao(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.irmaos i
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
      and (
        i.admin_loja
        or exists (
          select 1 from public.mandatos m
          join public.loja_cargos c on c.id = m.cargo_id
          where m.irmao_id = i.id
            and current_date between m.inicio and m.fim
            and (
              '*' = any (c.permissoes)
              or p_perm = any (c.permissoes)
              or (p_perm like '%.ler' and replace(p_perm, '.ler', '.editar') = any (c.permissoes))
            )
        )
      )
  )
$$;

-- Conteúdo com grau mínimo: irmão vê o próprio grau e os abaixo.
create function public.pode_ver_grau(p_loja uuid, p_grau_minimo smallint) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.meu_grau(p_loja) >= p_grau_minimo
$$;

-- Diretório da loja: dados básicos de todos os irmãos, sem dados pessoais.
create function public.diretorio(p_loja uuid)
returns table (id uuid, nome text, grau smallint, mestre_instalado boolean, situacao public.situacao_irmao)
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.grau, i.mestre_instalado, i.situacao
  from public.irmaos i
  where i.loja_id = p_loja
    and p_loja in (select public.minhas_lojas())
  order by i.nome
$$;

-- Obreiro editando o próprio cadastro não muda campos controlados pela loja.
create function public.proteger_campos_irmao() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  if auth.uid() is null or public.tem_permissao(old.loja_id, 'cadastro.editar') then
    return new;
  end if;
  if new.loja_id is distinct from old.loja_id
     or new.user_id is distinct from old.user_id
     or new.admin_loja is distinct from old.admin_loja
     or new.cim is distinct from old.cim
     or new.grau is distinct from old.grau
     or new.mestre_instalado is distinct from old.mestre_instalado
     or new.data_iniciacao is distinct from old.data_iniciacao
     or new.data_elevacao is distinct from old.data_elevacao
     or new.data_exaltacao is distinct from old.data_exaltacao
     or new.situacao is distinct from old.situacao
     or new.observacoes is distinct from old.observacoes then
    raise exception 'Somente a Secretaria pode alterar esses campos do cadastro';
  end if;
  return new;
end $$;

create trigger proteger_campos before update on public.irmaos
for each row execute function public.proteger_campos_irmao();

-- =========================================================
-- Cadastro de loja (onboarding): cria loja, copia cargos do rito,
-- cria o irmão de quem cadastrou como admin_loja e abre a assinatura de teste.
-- =========================================================

create function public.criar_loja(
  p_nome text,
  p_numero text,
  p_oriente_id uuid,
  p_rito_id uuid,
  p_cidade text,
  p_uf char(2),
  p_meu_nome text,
  p_meu_grau smallint default 3
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_loja uuid;
begin
  if auth.uid() is null then
    raise exception 'Faça login para cadastrar a loja';
  end if;
  if not exists (select 1 from public.ritos where id = p_rito_id and ativo) then
    raise exception 'Rito ainda não disponível';
  end if;

  insert into public.lojas (oriente_id, rito_id, nome, numero, cidade, uf, criado_por)
  values (p_oriente_id, p_rito_id, p_nome, p_numero, p_cidade, p_uf, auth.uid())
  returning id into v_loja;

  insert into public.loja_cargos (loja_id, rito_cargo_id, codigo, nome, ordem, grau_acompanhado, permissoes)
  select v_loja, id, codigo, nome, ordem, grau_acompanhado, permissoes
  from public.rito_cargos where rito_id = p_rito_id;

  insert into public.irmaos (loja_id, user_id, admin_loja, nome, email, grau)
  values (v_loja, auth.uid(), true, p_meu_nome,
          (select email from auth.users where id = auth.uid()), p_meu_grau);

  insert into public.assinaturas (loja_id) values (v_loja);

  return v_loja;
end $$;

-- =========================================================
-- RLS
-- =========================================================

alter table public.potencias enable row level security;
alter table public.orientes enable row level security;
alter table public.ritos enable row level security;
alter table public.rito_cargos enable row level security;
alter table public.lojas enable row level security;
alter table public.loja_cargos enable row level security;
alter table public.assinaturas enable row level security;
alter table public.irmaos enable row level security;
alter table public.familiares enable row level security;
alter table public.gestoes enable row level security;
alter table public.mandatos enable row level security;
alter table public.plataforma_admins enable row level security;
alter table public.audit_log enable row level security;

-- Catálogos: leitura para quem está logado; escrita só via migration.
create policy leitura on public.potencias for select to authenticated using (true);
create policy leitura on public.orientes for select to authenticated using (true);
create policy leitura on public.ritos for select to authenticated using (true);
create policy leitura on public.rito_cargos for select to authenticated using (true);

-- Lojas
create policy membros_leem on public.lojas for select to authenticated
  using (id in (select public.minhas_lojas()));
create policy config_edita on public.lojas for update to authenticated
  using (public.tem_permissao(id, 'loja.config'))
  with check (public.tem_permissao(id, 'loja.config'));

-- Cargos da loja
create policy membros_leem on public.loja_cargos for select to authenticated
  using (loja_id in (select public.minhas_lojas()));
create policy loja_config_edita on public.loja_cargos for all to authenticated
  using (public.tem_permissao(loja_id, 'loja.config'))
  with check (public.tem_permissao(loja_id, 'loja.config'));

-- Assinatura: só leitura pelo Venerável/admin; alteração só pelo backend.
create policy config_le on public.assinaturas for select to authenticated
  using (public.tem_permissao(loja_id, 'loja.config'));

-- Irmãos: cada um vê o seu; cargos com cadastro.ler veem todos (os demais usam diretorio()).
create policy proprio_ou_cadastro_le on public.irmaos for select to authenticated
  using (user_id = auth.uid() or public.tem_permissao(loja_id, 'cadastro.ler'));
create policy proprio_edita on public.irmaos for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy cadastro_edita on public.irmaos for all to authenticated
  using (public.tem_permissao(loja_id, 'cadastro.editar'))
  with check (public.tem_permissao(loja_id, 'cadastro.editar'));

-- Familiares
create policy proprio_ou_cadastro_le on public.familiares for select to authenticated
  using (irmao_id = public.meu_irmao_id(loja_id) or public.tem_permissao(loja_id, 'cadastro.ler'));
create policy proprio_edita on public.familiares for all to authenticated
  using (irmao_id = public.meu_irmao_id(loja_id))
  with check (irmao_id = public.meu_irmao_id(loja_id));
create policy cadastro_edita on public.familiares for all to authenticated
  using (public.tem_permissao(loja_id, 'cadastro.editar'))
  with check (public.tem_permissao(loja_id, 'cadastro.editar'));

-- Gestões e mandatos: todos da loja veem; Secretaria/Venerável editam.
create policy membros_leem on public.gestoes for select to authenticated
  using (loja_id in (select public.minhas_lojas()));
create policy cargos_edita on public.gestoes for all to authenticated
  using (public.tem_permissao(loja_id, 'cargos.editar'))
  with check (public.tem_permissao(loja_id, 'cargos.editar'));

create policy membros_leem on public.mandatos for select to authenticated
  using (loja_id in (select public.minhas_lojas()));
create policy cargos_edita on public.mandatos for all to authenticated
  using (public.tem_permissao(loja_id, 'cargos.editar'))
  with check (public.tem_permissao(loja_id, 'cargos.editar'));

-- plataforma_admins: sem políticas = ninguém lê pela API.

-- Auditoria: só leitura, por quem tem auditoria.ler (Venerável, Orador).
create policy auditoria_le on public.audit_log for select to authenticated
  using (loja_id is not null and public.tem_permissao(loja_id, 'auditoria.ler'));

-- Funções: só usuários logados chamam.
revoke execute on function public.criar_loja, public.diretorio, public.minhas_lojas,
  public.meu_irmao_id, public.meu_grau, public.tem_permissao, public.pode_ver_grau from public, anon;
grant execute on function public.criar_loja, public.diretorio, public.minhas_lojas,
  public.meu_irmao_id, public.meu_grau, public.tem_permissao, public.pode_ver_grau to authenticated;
revoke execute on function public.registrar_auditoria, public.proteger_campos_irmao from public, anon, authenticated;
