-- Sistema Malhete — Vigilância (trabalhos dos irmãos) e Biblioteca por grau.
-- Acesso sempre pelo grau do CADASTRO (pode_ver_grau); nada é liberado por tempo e o sistema não
-- indica "apto" — elevação/exaltação é decisão do Venerável/Secretário (graus.editar).
-- Trabalhos: o irmão envia; avalia o Vigilante que acompanha o grau do trabalho (grau_acompanhado
-- do cargo) ou o Venerável. Biblioteca: publicam Venerável (*), Vigilantes e Orador (biblioteca.editar).

update public.rito_cargos set permissoes = permissoes || array['biblioteca.editar']
where codigo in ('primeiro_vigilante', 'segundo_vigilante', 'orador') and not 'biblioteca.editar' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['biblioteca.editar']
where codigo in ('primeiro_vigilante', 'segundo_vigilante', 'orador') and not 'biblioteca.editar' = any (permissoes);

-- =========================================================
-- Trabalhos (pranchas de instrução)
-- =========================================================

create table public.trabalhos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  grau smallint not null check (grau between 1 and 3),  -- grau do autor ao enviar
  titulo text not null,
  texto text,
  arquivo_caminho text,       -- bucket 'trabalhos' (<loja_id>/…)
  arquivo_nome text,
  status text not null default 'enviado' check (status in ('enviado', 'ajustes', 'aprovado')),
  parecer text,
  avaliado_por uuid references auth.users(id),
  avaliado_em timestamptz,
  lido_em_sessao_id uuid references public.sessoes(id),
  enviado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (texto is not null or arquivo_caminho is not null)
);
create index on public.trabalhos (loja_id, status, enviado_em desc);
create index on public.trabalhos (irmao_id);
create index on public.trabalhos (avaliado_por);
create index on public.trabalhos (lido_em_sessao_id);

-- Quem avalia trabalhos do grau: Venerável ('*'/admin) ou cargo vigente com trabalhos.avaliar que acompanha o grau.
create function public.pode_avaliar(p_loja uuid, p_grau smallint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.irmaos i
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo'
      and (i.admin_loja or exists (
        select 1 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
        where m.irmao_id = i.id and current_date between m.inicio and m.fim
          and ('*' = any (c.permissoes)
               or ('trabalhos.avaliar' = any (c.permissoes) and c.grau_acompanhado = p_grau)))))
$$;

-- Autor envia/ajusta enquanto não aprovado; avaliação só por quem pode; campos de avaliação protegidos.
create function public.validar_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_eu uuid;
begin
  if tg_op = 'DELETE' then
    if old.status = 'aprovado' then raise exception 'Trabalho aprovado não pode ser apagado'; end if;
    return old;
  end if;
  if new.arquivo_caminho is not null and public.loja_do_caminho(new.arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  if tg_op = 'INSERT' then
    v_eu := public.meu_irmao_id(new.loja_id);
    if v_eu is null then raise exception 'Você não é irmão desta loja'; end if;
    new.irmao_id := v_eu;
    new.grau := (select grau from public.irmaos where id = v_eu);
    new.status := 'enviado'; new.parecer := null; new.avaliado_por := null; new.avaliado_em := null; new.lido_em_sessao_id := null;
    new.enviado_em := now(); new.atualizado_em := now();
    return new;
  end if;
  new.atualizado_em := now();
  if new.irmao_id is distinct from old.irmao_id or new.grau is distinct from old.grau or new.loja_id is distinct from old.loja_id then
    raise exception 'Autor e grau do trabalho não mudam';
  end if;
  if public.pode_avaliar(old.loja_id, old.grau) then
    if new.status is distinct from old.status then
      new.avaliado_por := auth.uid();
      new.avaliado_em := now();
    end if;
    return new;
  end if;
  -- autor: só reenvia conteúdo (volta para "enviado"), enquanto não aprovado
  if old.irmao_id <> public.meu_irmao_id(old.loja_id) or old.status = 'aprovado' then
    raise exception 'Sem permissão para alterar este trabalho';
  end if;
  if new.parecer is distinct from old.parecer or new.avaliado_por is distinct from old.avaliado_por
     or new.lido_em_sessao_id is distinct from old.lido_em_sessao_id or new.status not in ('enviado', old.status) then
    raise exception 'Só o Vigilante avalia o trabalho';
  end if;
  new.status := 'enviado';
  new.enviado_em := now();
  return new;
end $$;
create trigger validar before insert or update or delete on public.trabalhos for each row execute function public.validar_trabalho();

alter table public.trabalhos enable row level security;
create policy le on public.trabalhos for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.pode_avaliar(loja_id, grau)));
create policy autor_envia on public.trabalhos for insert to authenticated
  with check (loja_id in (select public.minhas_lojas()));
create policy edita on public.trabalhos for update to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.pode_avaliar(loja_id, grau)))
  with check (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.pode_avaliar(loja_id, grau)));
create policy autor_apaga on public.trabalhos for delete to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)));
create trigger auditoria after insert or update or delete on public.trabalhos for each row execute function public.registrar_auditoria();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trabalhos', 'trabalhos', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/msword'])
on conflict (id) do nothing;
-- arquivo do trabalho: quem pode ver a linha do trabalho; envio por qualquer irmão da loja
create policy trabalhos_le on storage.objects for select to authenticated
  using (bucket_id = 'trabalhos' and exists (
    select 1 from public.trabalhos t where t.arquivo_caminho = name
      and (t.irmao_id = public.meu_irmao_id(t.loja_id) or public.pode_avaliar(t.loja_id, t.grau))));
create policy trabalhos_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'trabalhos' and public.loja_do_caminho(name) in (select public.minhas_lojas()));

-- =========================================================
-- Biblioteca por grau
-- =========================================================

create table public.biblioteca (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  titulo text not null,
  descricao text,
  grau_minimo smallint not null default 1 check (grau_minimo between 1 and 3),
  categoria text,
  link text,
  arquivo_caminho text,      -- bucket 'biblioteca'
  arquivo_nome text,
  publicado_por uuid default auth.uid() references auth.users(id),
  publicado_em timestamptz not null default now(),
  check (link is not null or arquivo_caminho is not null or descricao is not null)
);
create index on public.biblioteca (loja_id, grau_minimo);
create index on public.biblioteca (publicado_por);

create function public.validar_biblioteca() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.arquivo_caminho is not null and public.loja_do_caminho(new.arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  return new;
end $$;
create trigger validar before insert or update on public.biblioteca for each row execute function public.validar_biblioteca();

alter table public.biblioteca enable row level security;
create policy le on public.biblioteca for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau_minimo)));
create policy publica on public.biblioteca for all to authenticated
  using ((select public.tem_permissao(loja_id, 'biblioteca.editar')))
  with check ((select public.tem_permissao(loja_id, 'biblioteca.editar')));
create trigger auditoria after insert or update or delete on public.biblioteca for each row execute function public.registrar_auditoria();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('biblioteca', 'biblioteca', false, 52428800, array['application/pdf', 'image/jpeg', 'image/png', 'audio/mpeg', 'video/mp4', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;
-- arquivo da biblioteca: só quem tem grau para o item
create policy biblioteca_le on storage.objects for select to authenticated
  using (bucket_id = 'biblioteca' and exists (
    select 1 from public.biblioteca b where b.arquivo_caminho = name and public.pode_ver_grau(b.loja_id, b.grau_minimo)));
create policy biblioteca_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'biblioteca' and public.tem_permissao(public.loja_do_caminho(name), 'biblioteca.editar'));

revoke execute on function public.pode_avaliar from public, anon;
grant execute on function public.pode_avaliar to authenticated;
revoke execute on function public.validar_trabalho, public.validar_biblioteca from public, anon, authenticated;
