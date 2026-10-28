-- Sistema Malhete — Chancelaria e Secretaria (+ fila de envios aos irmãos).
-- Chancelaria: sessões (ordinária/magna, grau), convocação, presença, visitantes, frequência, aniversários.
-- Secretaria: atas (balaústres), expediente (pranchas recebidas/expedidas), documentos emitidos.
-- Permissões: convocar = Venerável (*) ou Chanceler (sessoes.convocar); presença = só Chanceler;
-- atas/expediente/documentos = só Secretário. chancelaria.editar e secretaria.editar passam a ser
-- exclusivas como as da Tesouraria (o * do Venerável não as inclui; ele só vê).

-- =========================================================
-- Permissões exclusivas (uma lista só, usada pelas funções de acesso)
-- =========================================================

create function public.permissoes_exclusivas() returns text[]
language sql immutable set search_path = '' as $$
  select array['tesouraria.editar', 'tronco.editar', 'chancelaria.editar', 'secretaria.editar']
$$;

create or replace function public.tem_permissao(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  with exclusiva as (
    select p_perm = any (public.permissoes_exclusivas()) as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
      and (
        (i.admin_loja and (
           not x.sim
           or not exists (
             select 1 from public.mandatos m2
             join public.loja_cargos c2 on c2.id = m2.cargo_id
             where m2.loja_id = p_loja and current_date between m2.inicio and m2.fim
               and p_perm = any (c2.permissoes))))
        or exists (
          select 1 from public.mandatos m
          join public.loja_cargos c on c.id = m.cargo_id
          where m.irmao_id = i.id
            and current_date between m.inicio and m.fim
            and (
              ('*' = any (c.permissoes) and not x.sim)
              or p_perm = any (c.permissoes)
              or (p_perm like '%.ler' and replace(p_perm, '.ler', '.editar') = any (c.permissoes))
            )
        )
      )
  )
$$;

create or replace function public.minhas_permissoes(p_loja uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  with base as (
    select case
      when bool_or(i.admin_loja) then array['*']
      else coalesce(array_agg(distinct p) filter (where p is not null), '{}')
    end as perms
    from public.irmaos i
    left join public.mandatos m on m.irmao_id = i.id and current_date between m.inicio and m.fim
    left join public.loja_cargos c on c.id = m.cargo_id
    left join lateral unnest(c.permissoes) as p on true
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
  )
  select array(
    select distinct x from (
      select unnest(b.perms) as x from base b
      union all
      select e from unnest(public.permissoes_exclusivas()) e where public.tem_permissao(p_loja, e)
    ) t
    where x <> '' and (x <> all (public.permissoes_exclusivas()) or public.tem_permissao(p_loja, x))
  )
$$;

-- Chanceler convoca (o Venerável já convoca pelo '*').
update public.rito_cargos set permissoes = permissoes || array['sessoes.convocar']
where codigo = 'chanceler' and not 'sessoes.convocar' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['sessoes.convocar']
where codigo = 'chanceler' and not 'sessoes.convocar' = any (permissoes);

-- =========================================================
-- Chancelaria
-- =========================================================

create table public.sessoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tipo text not null check (tipo in ('ordinaria', 'magna')),
  finalidade text,                         -- magna: Iniciação, Elevação, Exaltação, Posse…
  grau smallint not null default 1 check (grau between 1 and 3),
  data date not null,
  hora time,
  local text,
  pauta text,                              -- ordem do dia
  status text not null default 'agendada' check (status in ('agendada', 'realizada', 'cancelada')),
  motivo_cancelamento text,
  convocada_em timestamptz,
  observacoes text,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now(),
  check (status <> 'cancelada' or motivo_cancelamento is not null)
);
create index on public.sessoes (loja_id, data desc);
create index on public.sessoes (criado_por);

create table public.presencas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sessao_id uuid not null references public.sessoes(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  situacao text not null check (situacao in ('presente', 'ausente', 'justificada')),
  justificativa text,
  registrado_por uuid default auth.uid() references auth.users(id),
  registrado_em timestamptz not null default now(),
  unique (sessao_id, irmao_id),
  check (situacao <> 'justificada' or justificativa is not null)
);
create index on public.presencas (irmao_id);
create index on public.presencas (loja_id);
create index on public.presencas (registrado_por);

create table public.visitantes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sessao_id uuid not null references public.sessoes(id) on delete cascade,
  nome text not null,
  grau smallint check (grau between 1 and 3),
  mestre_instalado boolean not null default false,
  loja_origem text,
  numero_loja text,
  oriente text,
  potencia text,
  cim text,
  telefone text,
  observacoes text,
  registrado_por uuid default auth.uid() references auth.users(id),
  registrado_em timestamptz not null default now()
);
create index on public.visitantes (sessao_id);
create index on public.visitantes (loja_id);
create index on public.visitantes (registrado_por);

-- Presença só em sessão do grau do irmão (ou abaixo), da mesma loja, e não cancelada.
create function public.validar_presenca() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
begin
  select * into s from public.sessoes where id = new.sessao_id;
  if s.loja_id <> new.loja_id or not exists (select 1 from public.irmaos where id = new.irmao_id and loja_id = new.loja_id) then
    raise exception 'Sessão ou irmão de outra loja';
  end if;
  if s.status = 'cancelada' then
    raise exception 'Sessão cancelada';
  end if;
  if new.situacao <> 'justificada' and (select grau from public.irmaos where id = new.irmao_id) < s.grau then
    raise exception 'O grau do irmão é menor que o grau da sessão';
  end if;
  new.registrado_por := auth.uid();
  new.registrado_em := now();
  return new;
end $$;
create trigger validar before insert or update on public.presencas for each row execute function public.validar_presenca();

-- Frequência no ano: sessões realizadas no grau do irmão (ou abaixo); sem registro conta como falta.
-- % = presenças ÷ (sessões − justificadas). Respeita o RLS (cada um vê a sua; Chancelaria vê todas).
create function public.frequencia(p_loja uuid, p_ano int)
returns table (irmao_id uuid, sessoes int, presentes int, justificadas int, percentual numeric)
language sql stable set search_path = '' as $$
  select i.id, c.sessoes, c.presentes, c.justificadas,
         round(100.0 * c.presentes / nullif(c.sessoes - c.justificadas, 0), 1)
  from public.irmaos i
  cross join lateral (
    select count(*)::int as sessoes,
           count(*) filter (where p.situacao = 'presente')::int as presentes,
           count(*) filter (where p.situacao = 'justificada')::int as justificadas
    from public.sessoes s
    left join public.presencas p on p.sessao_id = s.id and p.irmao_id = i.id
    where s.loja_id = p_loja and s.status = 'realizada' and extract(year from s.data) = p_ano and s.grau <= i.grau
  ) c
  where i.loja_id = p_loja and i.situacao = 'ativo'
$$;

-- Aniversários do mês: nascimento e datas maçônicas dos irmãos ativos (todos da loja veem);
-- familiares só para quem lê cadastro ou chancelaria.
create function public.aniversariantes(p_loja uuid, p_mes int)
returns table (tipo text, irmao_id uuid, nome text, parentesco text, data date)
language sql stable security definer set search_path = '' as $$
  with ok as (select p_loja in (select public.minhas_lojas()) as membro,
                     (public.tem_permissao(p_loja, 'cadastro.ler') or public.tem_permissao(p_loja, 'chancelaria.ler')) as amplo)
  select x.tipo, x.irmao_id, x.nome, x.parentesco, x.data
  from ok, (
    select 'nascimento' as tipo, i.id as irmao_id, i.nome, null::text as parentesco, i.data_nascimento as data, false as familiar
      from public.irmaos i where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
    union all select 'iniciacao', i.id, i.nome, null, i.data_iniciacao, false from public.irmaos i where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
    union all select 'elevacao', i.id, i.nome, null, i.data_elevacao, false from public.irmaos i where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
    union all select 'exaltacao', i.id, i.nome, null, i.data_exaltacao, false from public.irmaos i where i.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
    union all select 'familiar', f.irmao_id, f.nome, f.parentesco, f.data_nascimento, true
      from public.familiares f join public.irmaos i on i.id = f.irmao_id
      where f.loja_id = p_loja and i.situacao in ('ativo', 'licenciado')
  ) x
  where ok.membro and x.data is not null and extract(month from x.data) = p_mes and (not x.familiar or ok.amplo)
  order by extract(day from x.data), x.nome
$$;

-- =========================================================
-- Secretaria
-- =========================================================

create table public.atas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sessao_id uuid not null unique references public.sessoes(id),
  numero int not null,
  grau smallint not null check (grau between 1 and 3),
  texto text not null default '',
  status text not null default 'rascunho' check (status in ('rascunho', 'aprovada')),
  aprovada_em_sessao_id uuid references public.sessoes(id),
  aprovada_em date,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (loja_id, numero),
  check (status <> 'aprovada' or aprovada_em is not null)
);
create index on public.atas (aprovada_em_sessao_id);
create index on public.atas (criado_por);

-- Número sequencial e grau vêm da sessão; ata aprovada não muda mais.
create function public.validar_ata() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
begin
  if tg_op = 'DELETE' then
    if old.status = 'aprovada' then raise exception 'Ata aprovada não pode ser apagada'; end if;
    return old;
  end if;
  select * into s from public.sessoes where id = new.sessao_id;
  if s.loja_id <> new.loja_id then raise exception 'Sessão de outra loja'; end if;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('ata' || new.loja_id::text));
    new.numero := coalesce((select max(numero) from public.atas where loja_id = new.loja_id), 0) + 1;
    new.criado_por := auth.uid();
    new.criado_em := now();
    new.status := 'rascunho';
  else
    if old.status = 'aprovada' then raise exception 'Ata aprovada não pode ser alterada'; end if;
    if new.numero is distinct from old.numero or new.sessao_id is distinct from old.sessao_id then
      raise exception 'Número e sessão da ata não mudam';
    end if;
    if new.status = 'aprovada' and new.aprovada_em_sessao_id is not null
       and not exists (select 1 from public.sessoes where id = new.aprovada_em_sessao_id and loja_id = new.loja_id) then
      raise exception 'Sessão de aprovação inválida';
    end if;
  end if;
  new.grau := s.grau;
  new.atualizado_em := now();
  return new;
end $$;
create trigger validar before insert or update or delete on public.atas for each row execute function public.validar_ata();

create table public.expediente (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sentido text not null check (sentido in ('recebida', 'expedida')),
  numero text,                  -- expedida: NNN/AAAA automático; recebida: número do remetente
  data date not null default current_date,
  correspondente text not null, -- remetente (recebida) ou destinatário (expedida)
  assunto text not null,
  resumo text,
  lida_em_sessao_id uuid references public.sessoes(id),
  arquivo_caminho text,         -- bucket 'secretaria' (<loja_id>/…)
  arquivo_nome text,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.expediente (loja_id, data desc);
create index on public.expediente (lida_em_sessao_id);
create index on public.expediente (criado_por);

create function public.numerar_expediente() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  if new.sentido = 'expedida' and tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('exp' || new.loja_id::text || extract(year from new.data)::text));
    select count(*) + 1 into n from public.expediente
    where loja_id = new.loja_id and sentido = 'expedida' and extract(year from data) = extract(year from new.data);
    new.numero := lpad(n::text, 3, '0') || '/' || extract(year from new.data)::text;
  end if;
  if tg_op = 'UPDATE' and new.sentido = 'expedida' and new.numero is distinct from old.numero then
    raise exception 'O número da prancha expedida não muda';
  end if;
  if new.arquivo_caminho is not null and public.loja_do_caminho(new.arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  return new;
end $$;
create trigger numerar before insert or update on public.expediente for each row execute function public.numerar_expediente();

create table public.documentos_emitidos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tipo text not null,                       -- ex.: declaração de regularidade
  irmao_id uuid references public.irmaos(id),
  numero text not null,
  conteudo jsonb not null default '{}',     -- dados usados na emissão (para reimprimir igual)
  emitido_por uuid default auth.uid() references auth.users(id),
  emitido_em timestamptz not null default now()
);
create index on public.documentos_emitidos (loja_id, emitido_em desc);
create index on public.documentos_emitidos (irmao_id);
create index on public.documentos_emitidos (emitido_por);

create function public.numerar_documento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  perform pg_advisory_xact_lock(hashtext('doc' || new.loja_id::text));
  select count(*) + 1 into n from public.documentos_emitidos
  where loja_id = new.loja_id and extract(year from emitido_em) = extract(year from now());
  new.numero := 'D' || lpad(n::text, 3, '0') || '/' || extract(year from now())::text;
  new.emitido_por := auth.uid();
  new.emitido_em := now();
  return new;
end $$;
create trigger numerar before insert on public.documentos_emitidos for each row execute function public.numerar_documento();

-- Arquivos da Secretaria (pranchas digitalizadas): privado, por loja.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('secretaria', 'secretaria', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;
create policy secretaria_le on storage.objects for select to authenticated
  using (bucket_id = 'secretaria' and public.tem_permissao(public.loja_do_caminho(name), 'secretaria.ler'));
create policy secretaria_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'secretaria' and public.tem_permissao(public.loja_do_caminho(name), 'secretaria.editar'));

-- =========================================================
-- Envios aos irmãos (convocações e avisos). Hoje: envio manual pelo WhatsApp de quem envia;
-- depois a camada de WhatsApp (UazAPI) consome os destinatários 'pendente' do canal 'whatsapp'.
-- =========================================================

create table public.envios (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tipo text not null check (tipo in ('convocacao', 'aviso')),
  sessao_id uuid references public.sessoes(id),
  canal text not null default 'manual' check (canal in ('manual', 'whatsapp', 'email')),
  mensagem text not null,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.envios (loja_id, criado_em desc);
create index on public.envios (sessao_id);
create index on public.envios (criado_por);

create table public.envio_destinatarios (
  id uuid primary key default gen_random_uuid(),
  envio_id uuid not null references public.envios(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  telefone text,
  status text not null default 'pendente' check (status in ('pendente', 'enviado', 'falhou', 'sem_telefone')),
  enviado_em timestamptz,
  erro text,
  unique (envio_id, irmao_id)
);
create index on public.envio_destinatarios (irmao_id);
create index on public.envio_destinatarios (loja_id, status);

-- Cria o envio com os destinatários. Convocação: Venerável/Chanceler, irmãos ativos com grau ≥ o da sessão.
create function public.criar_envio(p_loja uuid, p_tipo text, p_mensagem text, p_sessao uuid default null, p_irmaos uuid[] default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_grau smallint := 1;
begin
  if p_tipo = 'convocacao' then
    if not public.tem_permissao(p_loja, 'sessoes.convocar') then raise exception 'Só o Venerável ou o Chanceler convocam'; end if;
    select grau into v_grau from public.sessoes where id = p_sessao and loja_id = p_loja and status = 'agendada';
    if v_grau is null then raise exception 'Sessão não encontrada ou já realizada/cancelada'; end if;
  elsif not public.tem_permissao(p_loja, 'comunicacao.enviar') then
    raise exception 'Sem permissão para enviar avisos';
  end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;

  insert into public.envios (loja_id, tipo, sessao_id, mensagem) values (p_loja, p_tipo, p_sessao, trim(p_mensagem))
  returning id into v_id;
  insert into public.envio_destinatarios (envio_id, loja_id, irmao_id, telefone, status)
  select v_id, p_loja, i.id, nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when coalesce(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') = '' then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo' and i.grau >= v_grau
    and (p_irmaos is null or i.id = any (p_irmaos));

  if p_tipo = 'convocacao' then
    update public.sessoes set convocada_em = now() where id = p_sessao;
  end if;
  return v_id;
end $$;

create function public.marcar_enviado(p_destinatario uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d public.envio_destinatarios;
  e public.envios;
begin
  select * into d from public.envio_destinatarios where id = p_destinatario;
  select * into e from public.envios where id = d.envio_id;
  if e.id is null or not (public.tem_permissao(e.loja_id, case when e.tipo = 'convocacao' then 'sessoes.convocar' else 'comunicacao.enviar' end)) then
    raise exception 'Sem permissão';
  end if;
  update public.envio_destinatarios set status = 'enviado', enviado_em = now(), erro = null where id = p_destinatario;
end $$;

-- =========================================================
-- RLS
-- =========================================================

alter table public.sessoes enable row level security;
alter table public.presencas enable row level security;
alter table public.visitantes enable row level security;
alter table public.atas enable row level security;
alter table public.expediente enable row level security;
alter table public.documentos_emitidos enable row level security;
alter table public.envios enable row level security;
alter table public.envio_destinatarios enable row level security;

-- Sessões: o irmão vê as do seu grau (ou abaixo); Chancelaria/Secretaria/convocantes veem todas.
create policy le on public.sessoes for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau))
         or (select public.tem_permissao(loja_id, 'chancelaria.ler'))
         or (select public.tem_permissao(loja_id, 'secretaria.ler'))
         or (select public.tem_permissao(loja_id, 'sessoes.convocar')));
create policy agenda on public.sessoes for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'sessoes.convocar')));
create policy edita on public.sessoes for update to authenticated
  using ((select public.tem_permissao(loja_id, 'sessoes.convocar')) or (select public.tem_permissao(loja_id, 'chancelaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'sessoes.convocar')) or (select public.tem_permissao(loja_id, 'chancelaria.editar')));

create policy le on public.presencas for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.tem_permissao(loja_id, 'chancelaria.ler')));
create policy chanceler on public.presencas for all to authenticated
  using ((select public.tem_permissao(loja_id, 'chancelaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'chancelaria.editar')));

create policy le on public.visitantes for select to authenticated
  using ((select public.tem_permissao(loja_id, 'chancelaria.ler')));
create policy chanceler on public.visitantes for all to authenticated
  using ((select public.tem_permissao(loja_id, 'chancelaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'chancelaria.editar')));

create policy le on public.atas for select to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.ler')) and (select public.pode_ver_grau(loja_id, grau)));
create policy secretario on public.atas for all to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'secretaria.editar')));

create policy le on public.expediente for select to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.ler')));
create policy secretario_cria on public.expediente for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'secretaria.editar')));
create policy secretario_edita on public.expediente for update to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'secretaria.editar')));

create policy le on public.documentos_emitidos for select to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.ler')));
create policy secretario on public.documentos_emitidos for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'secretaria.editar')));

create policy le on public.envios for select to authenticated
  using ((select public.tem_permissao(loja_id, 'comunicacao.enviar')) or (select public.tem_permissao(loja_id, 'sessoes.convocar')));
create policy le on public.envio_destinatarios for select to authenticated
  using ((select public.tem_permissao(loja_id, 'comunicacao.enviar')) or (select public.tem_permissao(loja_id, 'sessoes.convocar')));

-- auditoria
create trigger auditoria after insert or update or delete on public.sessoes for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.presencas for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.visitantes for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.atas for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.expediente for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.documentos_emitidos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.envios for each row execute function public.registrar_auditoria();

revoke execute on function public.criar_envio, public.marcar_enviado, public.frequencia, public.aniversariantes from public, anon;
grant execute on function public.criar_envio, public.marcar_enviado, public.frequencia, public.aniversariantes to authenticated;
revoke execute on function public.validar_presenca, public.validar_ata, public.numerar_expediente, public.numerar_documento
  from public, anon, authenticated;
