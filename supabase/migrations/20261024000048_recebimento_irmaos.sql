-- Sistema Malhete — como o irmão paga: a Tesouraria informa chave PIX, titular, valor da mensalidade e dia de
-- vencimento; o irmão vê as pendências e pode ADIANTAR mensalidades (gera as próximas para ele mesmo pagar).

create table public.tesouraria_config (
  loja_id uuid primary key references public.lojas(id) on delete cascade,
  pix_chave text,
  pix_titular text,
  valor_mensalidade numeric(12,2) check (valor_mensalidade is null or valor_mensalidade > 0),
  dia_vencimento smallint not null default 10 check (dia_vencimento between 1 and 28),
  instrucoes text,
  atualizado_em timestamptz not null default now()
);
alter table public.tesouraria_config enable row level security;
create policy le on public.tesouraria_config for select to authenticated
  using (loja_id in (select public.minhas_lojas()));
create policy edita on public.tesouraria_config for all to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check ((select public.tem_permissao(loja_id, 'tesouraria.editar')));
create trigger auditoria after insert or update or delete on public.tesouraria_config for each row execute function public.registrar_auditoria();

-- o próprio irmão gera as próximas N mensalidades (as que ainda não existem), no valor e dia definidos pela Tesouraria
create function public.adiantar_mensalidades(p_loja uuid, p_meses int)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_irmao uuid := public.meu_irmao_id(p_loja);
  c public.tesouraria_config;
  v_valor numeric;
  v_cat uuid;
  v_inicio date;
  n int;
begin
  if v_irmao is null or not exists (select 1 from public.irmaos where id = v_irmao and situacao = 'ativo') then
    raise exception 'Só irmãos ativos adiantam mensalidades';
  end if;
  if p_meses is null or p_meses < 1 or p_meses > 12 then raise exception 'Escolha de 1 a 12 meses'; end if;
  select * into c from public.tesouraria_config where loja_id = p_loja;
  v_valor := coalesce(c.valor_mensalidade,
    (select valor from public.titulos where loja_id = p_loja and origem = 'mensalidade' order by competencia desc limit 1));
  if v_valor is null then raise exception 'A Tesouraria ainda não definiu o valor da mensalidade'; end if;
  select id into v_cat from public.categorias_financeiras where loja_id = p_loja and codigo = 'mensalidades';
  -- começa no mês seguinte à última mensalidade dele (ou no mês atual, se não tiver nenhuma)
  v_inicio := coalesce(
    (select max(competencia) + interval '1 month' from public.titulos where irmao_id = v_irmao and origem = 'mensalidade' and not cancelado),
    date_trunc('month', current_date))::date;
  v_inicio := greatest(v_inicio, date_trunc('month', current_date)::date);
  perform set_config('malhete.sistema', 'on', true);
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
  select p_loja, 'receber', 'Mensalidade ' || to_char(m, 'MM/YYYY'), v_cat, v_irmao, v_valor,
         greatest(make_date(extract(year from m)::int, extract(month from m)::int, coalesce(c.dia_vencimento, 10)), current_date), m::date, 'mensalidade'
  from generate_series(v_inicio, v_inicio + make_interval(months => p_meses - 1), interval '1 month') m
  on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;
  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $$;
revoke execute on function public.adiantar_mensalidades from public, anon;
grant execute on function public.adiantar_mensalidades to authenticated;
