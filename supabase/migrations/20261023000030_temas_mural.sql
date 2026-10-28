-- Sistema Malhete — (1) temas de trabalho: o Vigilante que acompanha o grau (2º → Aprendizes, 1º → Companheiros)
-- e o Venerável (Mestres, e qualquer grau) propõem temas; o irmão escolhe o tema ao enviar o trabalho.
-- (2) mural de avisos da loja: o Venerável publica ("tragam as famílias para o ágape", "campanha de arrecadação"),
-- todos veem no Início, com opção de mandar também pelo WhatsApp da loja.

-- =========================================================
-- Temas de trabalho
-- =========================================================

create table public.temas_trabalho (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  grau smallint not null check (grau between 1 and 3),
  titulo text not null check (length(trim(titulo)) > 0),
  descricao text,
  prazo date,
  ativo boolean not null default true,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.temas_trabalho (loja_id, grau, ativo);
create index on public.temas_trabalho (criado_por);
alter table public.temas_trabalho enable row level security;
create policy le on public.temas_trabalho for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau)) or (select public.pode_avaliar(loja_id, grau)));
create policy propoe on public.temas_trabalho for insert to authenticated
  with check ((select public.pode_avaliar(loja_id, grau)));
create policy edita on public.temas_trabalho for update to authenticated
  using ((select public.pode_avaliar(loja_id, grau))) with check ((select public.pode_avaliar(loja_id, grau)));
create policy apaga on public.temas_trabalho for delete to authenticated
  using ((select public.pode_avaliar(loja_id, grau)));
create trigger auditoria after insert or update or delete on public.temas_trabalho for each row execute function public.registrar_auditoria();

alter table public.trabalhos add column tema_id uuid references public.temas_trabalho(id) on delete set null;
create index on public.trabalhos (tema_id);

-- o tema tem que ser da loja e de grau que o autor alcança
create function public.validar_tema_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.tema_id is not null and not exists (
    select 1 from public.temas_trabalho t where t.id = new.tema_id and t.loja_id = new.loja_id and t.grau <= new.grau) then
    raise exception 'Tema inválido para este trabalho';
  end if;
  return new;
end $$;
-- roda depois de "validar" (ordem alfabética), quando o grau do autor já foi preenchido
create trigger validar_tema before insert or update of tema_id on public.trabalhos
for each row execute function public.validar_tema_trabalho();
revoke execute on function public.validar_tema_trabalho from public, anon, authenticated;

-- =========================================================
-- Mural de avisos
-- =========================================================

update public.rito_cargos set permissoes = permissoes || array['mural.publicar']
where codigo = 'veneravel' and not 'mural.publicar' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['mural.publicar']
where codigo = 'veneravel' and not 'mural.publicar' = any (permissoes);

create table public.mural (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  titulo text not null check (length(trim(titulo)) > 0),
  texto text,
  grau_minimo smallint not null default 1 check (grau_minimo between 1 and 3),
  fixado boolean not null default false,
  expira_em date,
  pelo_whatsapp boolean not null default false,
  publicado_por uuid default auth.uid() references auth.users(id),
  publicado_em timestamptz not null default now()
);
create index on public.mural (loja_id, publicado_em desc);
create index on public.mural (publicado_por);
alter table public.mural enable row level security;
create policy le on public.mural for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau_minimo)) or (select public.tem_permissao(loja_id, 'mural.publicar')));
create policy publica on public.mural for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'mural.publicar')));
create policy edita on public.mural for update to authenticated
  using ((select public.tem_permissao(loja_id, 'mural.publicar'))) with check ((select public.tem_permissao(loja_id, 'mural.publicar')));
create policy apaga on public.mural for delete to authenticated
  using ((select public.tem_permissao(loja_id, 'mural.publicar')));
create trigger auditoria after insert or update or delete on public.mural for each row execute function public.registrar_auditoria();

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check
  check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema'));

-- põe na fila do WhatsApp um aviso do mural (irmãos ativos/licenciados do grau) ou um tema (irmãos daquele grau).
create function public.mural_whatsapp(p_aviso uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  a public.mural;
  n int;
begin
  select * into a from public.mural where id = p_aviso;
  if a.id is null or not public.tem_permissao(a.loja_id, 'mural.publicar') then raise exception 'Sem permissão'; end if;
  if a.pelo_whatsapp then raise exception 'Este aviso já foi enviado pelo WhatsApp'; end if;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select a.loja_id, i.id, 'mural', a.id,
         format('*%s*%s', a.titulo, coalesce(E'\n\n' || nullif(trim(a.texto), ''), '')),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = a.loja_id and i.situacao in ('ativo', 'licenciado') and i.grau >= a.grau_minimo;
  get diagnostics n = row_count;
  update public.mural set pelo_whatsapp = true where id = a.id;
  return n;
end $$;

create function public.tema_whatsapp(p_tema uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  t public.temas_trabalho;
  n int;
begin
  select * into t from public.temas_trabalho where id = p_tema;
  if t.id is null or not public.pode_avaliar(t.loja_id, t.grau) then raise exception 'Sem permissão'; end if;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select t.loja_id, i.id, 'tema', t.id,
         format('Olá, %s! Novo tema de trabalho proposto: *%s*%s%s. Envie pelo sistema em Meu espaço → Enviar trabalho.',
                private.primeiro_nome(i.nome), t.titulo,
                coalesce(E'\n' || nullif(trim(t.descricao), ''), ''),
                coalesce(E'\nPrazo: ' || to_char(t.prazo, 'DD/MM/YYYY'), '')),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = t.loja_id and i.situacao in ('ativo', 'licenciado') and i.grau = t.grau;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.mural_whatsapp, public.tema_whatsapp from public, anon;
grant execute on function public.mural_whatsapp, public.tema_whatsapp to authenticated;
