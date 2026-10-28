-- Sistema Malhete — plano de contas: a loja cria os próprios grupos (além dos padrão).
-- Grupos padrão (loja_id nulo) valem para todas e não mudam; os da loja são criados, renomeados
-- e desativados pelo Tesoureiro. Na DRE entram na seção do tipo (receitas ou despesas operacionais).

alter table public.grupos_dre
  add column loja_id uuid references public.lojas(id) on delete cascade,
  add column ativo boolean not null default true;
create index on public.grupos_dre (loja_id);
create unique index grupos_dre_nome_unq on public.grupos_dre
  (coalesce(loja_id, '00000000-0000-0000-0000-000000000000'::uuid), tipo, lower(nome));

drop policy leitura on public.grupos_dre;
create policy le on public.grupos_dre for select to authenticated
  using (loja_id is null
         or (select public.tem_permissao(loja_id, 'tesouraria.ler'))
         or (select public.tem_permissao(loja_id, 'tronco.ler')));
create policy tesouraria_cria on public.grupos_dre for insert to authenticated
  with check (loja_id is not null and (select public.tem_permissao(loja_id, 'tesouraria.editar')));
create policy tesouraria_edita on public.grupos_dre for update to authenticated
  using (loja_id is not null and (select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check (loja_id is not null and (select public.tem_permissao(loja_id, 'tesouraria.editar')));

-- Grupo novo ganha código e posição do sistema; depois só nome e ativo mudam.
create function public.proteger_grupo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.codigo := 'g_' || replace(gen_random_uuid()::text, '-', '');
    new.ordem := 115; -- depois de "Outras", antes do resultado financeiro
    new.nome := trim(new.nome);
    if new.nome = '' then
      raise exception 'Informe o nome do grupo';
    end if;
    return new;
  end if;
  if new.codigo is distinct from old.codigo or new.tipo is distinct from old.tipo
     or new.loja_id is distinct from old.loja_id or new.ordem is distinct from old.ordem then
    raise exception 'Só o nome do grupo pode ser alterado';
  end if;
  if not new.ativo and exists (select 1 from public.categorias_financeiras where grupo = old.codigo and ativa) then
    raise exception 'Desative ou mova as contas deste grupo antes de desativá-lo';
  end if;
  new.nome := trim(new.nome);
  return new;
end $$;

create trigger proteger before insert or update on public.grupos_dre
for each row execute function public.proteger_grupo();
create trigger auditoria after insert or update or delete on public.grupos_dre
for each row execute function public.registrar_auditoria();

-- Categoria só pode usar grupo padrão ou da própria loja, do mesmo tipo e ativo.
create or replace function public.proteger_categoria() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.grupo is null then
    new.grupo := case new.tipo when 'receita' then 'outras_receitas' else 'outras_despesas' end;
  end if;
  if tg_op = 'INSERT' or new.grupo is distinct from old.grupo then
    if not exists (select 1 from public.grupos_dre
                   where codigo = new.grupo and tipo = new.tipo and ativo
                     and (loja_id is null or loja_id = new.loja_id)) then
      raise exception 'O grupo precisa ser da loja (ou padrão), ativo e do mesmo tipo da conta';
    end if;
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

revoke execute on function public.proteger_grupo from public, anon, authenticated;
