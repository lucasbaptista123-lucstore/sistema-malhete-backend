-- Sistema Malhete — histórico do trabalho (cada envio, reenvio e avaliação, com o arquivo daquela versão)
-- e arquivo de ressalvas: quem avalia pode anexar a prancha marcada (PDF/Word com comentários).

alter table public.trabalhos add column parecer_arquivo_caminho text, add column parecer_arquivo_nome text;

create table public.trabalho_historico (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  trabalho_id uuid not null references public.trabalhos(id) on delete cascade,
  evento text not null check (evento in ('enviado', 'reenviado', 'ajustes', 'aprovado')),
  titulo text,
  texto text,
  arquivo_caminho text,
  arquivo_nome text,
  parecer text,
  por uuid default auth.uid() references auth.users(id),
  em timestamptz not null default now()
);
create index on public.trabalho_historico (trabalho_id, em);
create index on public.trabalho_historico (loja_id);
create index on public.trabalho_historico (por);
alter table public.trabalho_historico enable row level security;
create policy le on public.trabalho_historico for select to authenticated
  using (exists (select 1 from public.trabalhos t where t.id = trabalho_id
                 and (t.irmao_id = (select public.meu_irmao_id(t.loja_id)) or (select public.pode_avaliar(t.loja_id, t.grau)))));

-- só quem avalia mexe no arquivo de ressalvas
create function public.proteger_parecer_arquivo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.parecer_arquivo_caminho is distinct from old.parecer_arquivo_caminho
      or new.parecer_arquivo_nome is distinct from old.parecer_arquivo_nome)
     and not public.pode_avaliar(old.loja_id, old.grau) then
    raise exception 'Só quem avalia anexa o arquivo de ressalvas';
  end if;
  if new.parecer_arquivo_caminho is not null and public.loja_do_caminho(new.parecer_arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  return new;
end $$;
create trigger proteger_parecer before update of parecer_arquivo_caminho, parecer_arquivo_nome on public.trabalhos
for each row execute function public.proteger_parecer_arquivo();

create function public.registrar_historico_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.trabalho_historico (loja_id, trabalho_id, evento, titulo, texto, arquivo_caminho, arquivo_nome)
    values (new.loja_id, new.id, 'enviado', new.titulo, new.texto, new.arquivo_caminho, new.arquivo_nome);
  elsif new.enviado_em is distinct from old.enviado_em then
    insert into public.trabalho_historico (loja_id, trabalho_id, evento, titulo, texto, arquivo_caminho, arquivo_nome)
    values (new.loja_id, new.id, 'reenviado', new.titulo, new.texto, new.arquivo_caminho, new.arquivo_nome);
  elsif new.status in ('ajustes', 'aprovado')
        and (new.status is distinct from old.status or new.parecer is distinct from old.parecer
             or new.parecer_arquivo_caminho is distinct from old.parecer_arquivo_caminho) then
    insert into public.trabalho_historico (loja_id, trabalho_id, evento, parecer, arquivo_caminho, arquivo_nome)
    values (new.loja_id, new.id, new.status, new.parecer, new.parecer_arquivo_caminho, new.parecer_arquivo_nome);
  end if;
  return null;
end $$;
create trigger historico after insert or update on public.trabalhos
for each row execute function public.registrar_historico_trabalho();
revoke execute on function public.proteger_parecer_arquivo, public.registrar_historico_trabalho from public, anon, authenticated;

-- trabalhos já existentes ganham o primeiro registro
insert into public.trabalho_historico (loja_id, trabalho_id, evento, titulo, texto, arquivo_caminho, arquivo_nome, por, em)
select loja_id, id, 'enviado', titulo, texto, arquivo_caminho, arquivo_nome, null, enviado_em from public.trabalhos;

-- arquivos: a versão atual, as versões antigas e o arquivo de ressalvas, para o autor e quem avalia
drop policy trabalhos_le on storage.objects;
create policy trabalhos_le on storage.objects for select to authenticated
  using (bucket_id = 'trabalhos' and exists (
    select 1 from public.trabalhos t
    where (t.arquivo_caminho = name or t.parecer_arquivo_caminho = name
           or exists (select 1 from public.trabalho_historico h where h.trabalho_id = t.id and h.arquivo_caminho = name))
      and (t.irmao_id = public.meu_irmao_id(t.loja_id) or public.pode_avaliar(t.loja_id, t.grau))));
