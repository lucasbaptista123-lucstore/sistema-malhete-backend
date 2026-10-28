-- Sistema Malhete — categorias: a loja cria, renomeia e desativa à vontade,
-- mas o tipo (receita/despesa) e o código das pré-cadastradas não mudam
-- (os lançamentos antigos e a baixa de mensalidade dependem deles).

create function public.proteger_categoria() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.loja_id is distinct from old.loja_id
     or new.tipo is distinct from old.tipo
     or new.codigo is distinct from old.codigo then
    raise exception 'Tipo e código da categoria não podem ser alterados; crie uma nova categoria';
  end if;
  if old.codigo = 'mensalidades' and not new.ativa then
    raise exception 'A categoria de mensalidades é usada pelo sistema e não pode ser desativada';
  end if;
  return new;
end $$;

create trigger proteger before update on public.categorias_financeiras
for each row execute function public.proteger_categoria();

-- Categoria criada pela loja (pela API) nunca ganha código de sistema;
-- as padrão vêm de criar_tesouraria_padrao(), que roda como dono das tabelas.
create function public.categoria_sem_codigo() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.codigo := null;
  end if;
  return new;
end $$;

create trigger sem_codigo before insert on public.categorias_financeiras
for each row execute function public.categoria_sem_codigo();

revoke execute on function public.proteger_categoria, public.categoria_sem_codigo from public, anon, authenticated;
