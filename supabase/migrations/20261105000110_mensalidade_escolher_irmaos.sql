-- Sistema Malhete (05/11/2026, pedido do Lucas): gerar mensalidades escolhendo os irmãos. Há irmão que não paga mais
-- (remido/isento) e irmão que já pagou o ano todo. `mensalidade_isentos` guarda quem não paga (vem desmarcado);
-- `gerar_mensalidades` ganha p_irmaos (null = todos os ativos que não estão isentos).
create table public.mensalidade_isentos (
  irmao_id uuid primary key references public.irmaos(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  motivo text,
  criado_por uuid references auth.users(id) default auth.uid(),
  criado_em timestamptz not null default now()
);
create index on public.mensalidade_isentos (loja_id);
create index on public.mensalidade_isentos (criado_por);
alter table public.mensalidade_isentos enable row level security;
create policy le on public.mensalidade_isentos for select to authenticated
  using (public.tem_permissao(loja_id, 'tesouraria.ler'));
create trigger auditoria after insert or update or delete on public.mensalidade_isentos
  for each row execute function public.registrar_auditoria();
grant select on public.mensalidade_isentos to authenticated;

create or replace function public.definir_isento_mensalidade(p_irmao uuid, p_isento boolean, p_motivo text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_loja uuid := (select loja_id from public.irmaos where id = p_irmao);
begin
  if v_loja is null or not public.tem_permissao(v_loja, 'tesouraria.editar') then raise exception 'Sem permissão'; end if;
  if p_isento then
    insert into public.mensalidade_isentos (irmao_id, loja_id, motivo) values (p_irmao, v_loja, nullif(trim(p_motivo), ''))
    on conflict (irmao_id) do update set motivo = excluded.motivo;
  else
    delete from public.mensalidade_isentos where irmao_id = p_irmao;
  end if;
end $$;
revoke execute on function public.definir_isento_mensalidade from public, anon;
grant execute on function public.definir_isento_mensalidade to authenticated;

drop function public.gerar_mensalidades(uuid, date, numeric, date);
create function public.gerar_mensalidades(p_loja uuid, p_competencia date, p_valor numeric, p_vencimento date,
                                          p_irmaos uuid[] default null)
returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_comp date := date_trunc('month', p_competencia)::date;
  n int;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then
    raise exception 'Sem permissão para gerar mensalidades';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'Informe o valor da mensalidade';
  end if;

  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
  select p_loja, 'receber', 'Mensalidade ' || to_char(v_comp, 'MM/YYYY'),
         (select id from public.categorias_financeiras where loja_id = p_loja and codigo = 'mensalidades'),
         i.id, p_valor, p_vencimento, v_comp, 'mensalidade'
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo'
    and (case when p_irmaos is null
              then not exists (select 1 from public.mensalidade_isentos x where x.irmao_id = i.id)
              else i.id = any (p_irmaos) end)
  on conflict (irmao_id, competencia) where origem = 'mensalidade' do nothing;

  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.gerar_mensalidades from public, anon;
grant execute on function public.gerar_mensalidades to authenticated;
