-- Sistema Malhete — AGENDA DE EVENTOS (jantares, festas, palestras, ações beneficentes, visitas).
-- Organiza: quem publica no Mural, a Secretaria, a Chancelaria ou o Venerável. Irmão vê pelo grau, confirma
-- presença e quantos acompanhantes leva. Anúncio opcional pelo WhatsApp (fila de notificações).

create table public.eventos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  titulo text not null check (length(trim(titulo)) > 0),
  descricao text,
  tipo text not null default 'social' check (tipo in ('social', 'palestra', 'beneficente', 'visita', 'outro')),
  data date not null,
  hora time,
  local text,
  grau_minimo smallint not null default 1 check (grau_minimo between 1 and 3),
  familia boolean not null default false,          -- aberto a familiares (pede nº de acompanhantes)
  valor_por_pessoa numeric(10,2) check (valor_por_pessoa is null or valor_por_pessoa >= 0),
  confirmar_ate date,
  cancelado boolean not null default false,
  pelo_whatsapp boolean not null default false,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.eventos (loja_id, data);
create index on public.eventos (criado_por);

create table public.evento_respostas (
  evento_id uuid not null references public.eventos(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  vai boolean not null,
  acompanhantes smallint not null default 0 check (acompanhantes between 0 and 20),
  respondido_em timestamptz not null default now(),
  primary key (evento_id, irmao_id)
);
create index on public.evento_respostas (irmao_id);
create index on public.evento_respostas (loja_id);

create function public.organiza_eventos(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.tem_permissao(p_loja, 'mural.publicar') or public.tem_permissao(p_loja, 'secretaria.editar')
      or public.tem_permissao(p_loja, 'chancelaria.editar') or public.tem_permissao(p_loja, 'loja.config')
$$;

alter table public.eventos enable row level security;
alter table public.evento_respostas enable row level security;
create policy le on public.eventos for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau_minimo)) or (select public.organiza_eventos(loja_id)));
create policy organiza on public.eventos for all to authenticated
  using ((select public.organiza_eventos(loja_id))) with check ((select public.organiza_eventos(loja_id)));
-- respostas: o próprio irmão e quem organiza
create policy le on public.evento_respostas for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.organiza_eventos(loja_id)));
create trigger auditoria after insert or update or delete on public.eventos for each row execute function public.registrar_auditoria();

create function public.responder_evento(p_evento uuid, p_vai boolean, p_acompanhantes int default 0) returns void
language plpgsql security definer set search_path = '' as $$
declare
  e public.eventos;
  v_eu uuid;
begin
  select * into e from public.eventos where id = p_evento;
  v_eu := public.meu_irmao_id(e.loja_id);
  if e.id is null or v_eu is null or not public.pode_ver_grau(e.loja_id, e.grau_minimo) then raise exception 'Evento não encontrado'; end if;
  if e.cancelado then raise exception 'Este evento foi cancelado'; end if;
  if e.data < current_date then raise exception 'O evento já aconteceu'; end if;
  if e.confirmar_ate is not null and current_date > e.confirmar_ate then raise exception 'O prazo para confirmar terminou'; end if;
  insert into public.evento_respostas (evento_id, irmao_id, loja_id, vai, acompanhantes)
  values (e.id, v_eu, e.loja_id, p_vai, case when p_vai and e.familia then greatest(0, least(coalesce(p_acompanhantes, 0), 20)) else 0 end)
  on conflict (evento_id, irmao_id) do update
    set vai = excluded.vai, acompanhantes = excluded.acompanhantes, respondido_em = now();
end $$;

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check
  check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema', 'justificativa', 'evento'));

create function public.evento_whatsapp(p_evento uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  e public.eventos;
  n int;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select * into e from public.eventos where id = p_evento;
  if e.id is null or not public.organiza_eventos(e.loja_id) then raise exception 'Sem permissão'; end if;
  if e.pelo_whatsapp then raise exception 'Este evento já foi anunciado pelo WhatsApp'; end if;
  if e.cancelado or e.data < current_date then raise exception 'Evento cancelado ou já realizado'; end if;
  if current_setting('malhete.sem_avisos', true) = 'on' then return 0; end if;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select e.loja_id, i.id, 'evento', e.id,
         format(E'Olá, %s!\n*%s*\n%s%s%s%s%s\n\nConfirme sua presença: %s/app/agenda',
                private.primeiro_nome(i.nome), e.titulo,
                to_char(e.data, 'DD/MM/YYYY'), coalesce(' às ' || to_char(e.hora, 'HH24:MI'), ''),
                coalesce(E'\n' || nullif(trim(e.local), ''), ''),
                coalesce(E'\n\n' || nullif(trim(e.descricao), ''), ''),
                case when e.familia then E'\nFamiliares são bem-vindos.' else '' end, v_url),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = e.loja_id and i.situacao in ('ativo', 'licenciado') and i.grau >= e.grau_minimo;
  get diagnostics n = row_count;
  update public.eventos set pelo_whatsapp = true where id = e.id;
  return n;
end $$;

-- lista de quem respondeu (para quem organiza), com nome
create function public.evento_lista(p_evento uuid)
returns table (irmao_id uuid, nome text, vai boolean, acompanhantes smallint, respondido_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.irmao_id, i.nome, r.vai, r.acompanhantes, r.respondido_em
  from public.evento_respostas r join public.irmaos i on i.id = r.irmao_id join public.eventos e on e.id = r.evento_id
  where r.evento_id = p_evento and public.organiza_eventos(e.loja_id)
  order by r.vai desc, i.nome
$$;

revoke execute on function public.organiza_eventos, public.responder_evento, public.evento_whatsapp, public.evento_lista from public, anon;
grant execute on function public.organiza_eventos, public.responder_evento, public.evento_whatsapp, public.evento_lista to authenticated;
