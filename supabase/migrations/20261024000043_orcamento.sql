-- Sistema Malhete — Orçamento anual da Tesouraria: previsão por conta (categoria) e mês; o realizado vem dos
-- lançamentos (regime de caixa, como a DRE). Só quem movimenta a Tesouraria edita; quem lê a Tesouraria vê.
-- Aprovado (em sessão) = travado; o Tesoureiro reabre se precisar (fica na auditoria).

create table public.orcamentos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  ano int not null check (ano between 2000 and 2100),
  status text not null default 'rascunho' check (status in ('rascunho', 'aprovado')),
  aprovado_em date,
  aprovado_sessao_id uuid references public.sessoes(id),
  observacoes text,
  atualizado_em timestamptz not null default now(),
  unique (loja_id, ano)
);
create index on public.orcamentos (aprovado_sessao_id);

create table public.orcamento_itens (
  id uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  categoria_id uuid not null references public.categorias_financeiras(id),
  mes smallint not null check (mes between 1 and 12),
  valor numeric(12,2) not null default 0 check (valor >= 0),
  unique (orcamento_id, categoria_id, mes)
);
create index on public.orcamento_itens (loja_id);
create index on public.orcamento_itens (categoria_id);

alter table public.orcamentos enable row level security;
alter table public.orcamento_itens enable row level security;
create policy le on public.orcamentos for select to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));
create policy edita on public.orcamentos for all to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check ((select public.tem_permissao(loja_id, 'tesouraria.editar')));
create policy le on public.orcamento_itens for select to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));
create policy edita on public.orcamento_itens for all to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check ((select public.tem_permissao(loja_id, 'tesouraria.editar')));
create trigger auditoria after insert or update or delete on public.orcamentos for each row execute function public.registrar_auditoria();

-- orçamento aprovado não muda (o Tesoureiro reabre: status volta a rascunho)
create function public.travar_orcamento() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_status text;
begin
  select status into v_status from public.orcamentos where id = coalesce(new.orcamento_id, old.orcamento_id);
  if v_status = 'aprovado' then raise exception 'Orçamento aprovado: reabra para alterar'; end if;
  if tg_op <> 'DELETE' then
    if (select loja_id from public.orcamentos where id = new.orcamento_id) <> new.loja_id
       or (select loja_id from public.categorias_financeiras where id = new.categoria_id) <> new.loja_id then
      raise exception 'Conta de outra loja';
    end if;
    return new;
  end if;
  return old;
end $$;
create trigger travar before insert or update or delete on public.orcamento_itens
for each row execute function public.travar_orcamento();
revoke execute on function public.travar_orcamento from public, anon, authenticated;

-- salva a previsão de uma conta nos 12 meses de uma vez (cria o orçamento do ano se não existir)
create function public.orcamento_salvar(p_loja uuid, p_ano int, p_categoria uuid, p_meses numeric[])
returns void
language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid;
begin
  if array_length(p_meses, 1) is distinct from 12 then raise exception 'Informe os 12 meses'; end if;
  insert into public.orcamentos (loja_id, ano) values (p_loja, p_ano)
  on conflict (loja_id, ano) do update set atualizado_em = now()
  returning id into v_id;
  insert into public.orcamento_itens (orcamento_id, loja_id, categoria_id, mes, valor)
  select v_id, p_loja, p_categoria, m, round(coalesce(p_meses[m], 0), 2) from generate_series(1, 12) m
  on conflict (orcamento_id, categoria_id, mes) do update set valor = excluded.valor;
end $$;

-- ponto de partida: realizado do ano anterior (regime de caixa) por conta e mês, com reajuste em %
create function public.orcamento_copiar_realizado(p_loja uuid, p_ano int, p_reajuste numeric default 0)
returns int
language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid;
  n int;
begin
  insert into public.orcamentos (loja_id, ano) values (p_loja, p_ano)
  on conflict (loja_id, ano) do update set atualizado_em = now()
  returning id into v_id;
  insert into public.orcamento_itens (orcamento_id, loja_id, categoria_id, mes, valor)
  select v_id, p_loja, d.categoria_id, extract(month from d.mes)::smallint,
         round(greatest(sum(d.valor), 0) * (1 + coalesce(p_reajuste, 0) / 100.0), 2)
  from public.rel_dre(p_loja, make_date(p_ano - 1, 1, 1), make_date(p_ano - 1, 12, 31), 'caixa') d
  where d.categoria_id is not null
  group by d.categoria_id, extract(month from d.mes)
  on conflict (orcamento_id, categoria_id, mes) do update set valor = excluded.valor;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.orcamento_salvar, public.orcamento_copiar_realizado from public, anon;
grant execute on function public.orcamento_salvar, public.orcamento_copiar_realizado to authenticated;
