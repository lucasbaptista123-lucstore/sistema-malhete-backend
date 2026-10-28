-- Sistema Malhete — atas: (1) LEITURA pelos irmãos com confirmação ("li a ata"): o Secretário libera a ata
-- (rascunho para ratificação ou aprovada) e os irmãos do grau leem no sistema; o Secretário vê quem leu.
-- (2) IMPORTAÇÃO de atas antigas (PDF/texto) sem sessão no sistema: número original, data e grau; entram aprovadas.

alter table public.atas alter column sessao_id drop not null;
alter table public.atas
  add column data_sessao date,
  add column numero_original text,
  add column arquivo_caminho text,       -- bucket 'secretaria' (<loja_id>/…)
  add column arquivo_nome text,
  add column importada boolean not null default false,
  add column para_leitura boolean not null default false;
alter table public.atas add constraint ata_com_sessao_ou_importada check (sessao_id is not null or importada);

create or replace function public.validar_ata() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
begin
  if tg_op = 'DELETE' then
    if old.status = 'aprovada' and not old.importada then raise exception 'Ata aprovada não pode ser apagada'; end if;
    return old;
  end if;
  if new.arquivo_caminho is not null and public.loja_do_caminho(new.arquivo_caminho) is distinct from new.loja_id then
    raise exception 'Arquivo de outra loja';
  end if;
  if new.sessao_id is not null then
    select * into s from public.sessoes where id = new.sessao_id;
    if s.loja_id <> new.loja_id then raise exception 'Sessão de outra loja'; end if;
  end if;
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtext('ata' || new.loja_id::text));
    new.numero := coalesce((select max(numero) from public.atas where loja_id = new.loja_id), 0) + 1;
    new.criado_por := auth.uid();
    new.criado_em := now();
    if new.sessao_id is null then
      -- ata antiga importada: já vem aprovada (é o registro oficial da época)
      if new.data_sessao is null or new.grau is null then raise exception 'Informe a data e o grau da ata'; end if;
      if coalesce(trim(new.texto), '') = '' and new.arquivo_caminho is null then raise exception 'Anexe o arquivo ou cole o texto da ata'; end if;
      new.importada := true;
      new.status := 'aprovada';
      new.aprovada_em := coalesce(new.aprovada_em, new.data_sessao);
    else
      new.importada := false;
      new.status := 'rascunho';
      new.data_sessao := s.data;
    end if;
  else
    -- liberar/recolher para leitura é permitido mesmo aprovada
    if old.status = 'aprovada' and (to_jsonb(new) - 'para_leitura' - 'atualizado_em') <> (to_jsonb(old) - 'para_leitura' - 'atualizado_em') then
      raise exception 'Ata aprovada não pode ser alterada';
    end if;
    if new.numero is distinct from old.numero or new.sessao_id is distinct from old.sessao_id or new.importada is distinct from old.importada then
      raise exception 'Número e sessão da ata não mudam';
    end if;
    if new.status = 'aprovada' and new.aprovada_em_sessao_id is not null
       and not exists (select 1 from public.sessoes where id = new.aprovada_em_sessao_id and loja_id = new.loja_id) then
      raise exception 'Sessão de aprovação inválida';
    end if;
  end if;
  if new.sessao_id is not null then new.grau := s.grau; end if;
  new.atualizado_em := now();
  return new;
end $$;

-- irmão do grau lê a ata liberada
create policy le_irmaos on public.atas for select to authenticated
  using (para_leitura and loja_id in (select public.minhas_lojas()) and (select public.pode_ver_grau(loja_id, grau)));

create table public.ata_leituras (
  ata_id uuid not null references public.atas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  lida_em timestamptz not null default now(),
  primary key (ata_id, irmao_id)
);
create index on public.ata_leituras (irmao_id);
create index on public.ata_leituras (loja_id);
alter table public.ata_leituras enable row level security;
create policy le on public.ata_leituras for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.tem_permissao(loja_id, 'secretaria.ler')));

create function public.confirmar_leitura_ata(p_ata uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.atas;
  v_irmao uuid;
begin
  select * into a from public.atas where id = p_ata;
  v_irmao := public.meu_irmao_id(a.loja_id);
  if a.id is null or v_irmao is null or not a.para_leitura or not public.pode_ver_grau(a.loja_id, a.grau) then
    raise exception 'Ata não disponível para leitura';
  end if;
  insert into public.ata_leituras (ata_id, irmao_id, loja_id) values (a.id, v_irmao, a.loja_id) on conflict do nothing;
end $$;
revoke execute on function public.confirmar_leitura_ata from public, anon;
grant execute on function public.confirmar_leitura_ata to authenticated;

-- arquivo (PDF) da ata liberada: o irmão do grau também baixa/lê
create policy secretaria_le_ata on storage.objects for select to authenticated
  using (bucket_id = 'secretaria' and exists (
    select 1 from public.atas a
    where a.arquivo_caminho = name and a.para_leitura
      and a.loja_id in (select public.minhas_lojas()) and public.pode_ver_grau(a.loja_id, a.grau)));
