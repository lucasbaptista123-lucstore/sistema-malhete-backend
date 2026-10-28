-- Sistema Malhete — Hospitalaria. O Hospitaleiro (e o Venerável) acompanha quem precisa de ajuda (irmãos doentes,
-- viúvas, famílias), registra visitas/ligações, pede auxílio do Tronco — que o Tesoureiro paga pela Tesouraria
-- (lançamento de saída do Tronco, categoria Beneficência) ou recusa — e avisa os irmãos pelo mural.
-- Dado sensível (saúde, situação financeira): só Hospitalaria e Venerável veem; o Tesoureiro vê só os pedidos.

update public.rito_cargos set permissoes = permissoes || array['hospitalaria.editar', 'mural.publicar']
where codigo = 'hospitaleiro' and not 'hospitalaria.editar' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['hospitalaria.editar', 'mural.publicar']
where codigo = 'hospitaleiro' and not 'hospitalaria.editar' = any (permissoes);

create table public.assistidos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid references public.irmaos(id),           -- quando é um irmão da loja
  nome text not null,                                    -- irmão, viúva, familiar…
  vinculo text not null default 'irmao' check (vinculo in ('irmao', 'viuva', 'familiar', 'outro')),
  situacao text not null check (situacao in ('doente', 'internado', 'dificuldade', 'luto', 'idoso', 'outro')),
  descricao text,
  telefone text,
  ativo boolean not null default true,                   -- encerrado = não precisa mais de acompanhamento
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.assistidos (loja_id, ativo);
create index on public.assistidos (irmao_id);
create index on public.assistidos (criado_por);

create table public.assistidos_registros (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  assistido_id uuid not null references public.assistidos(id) on delete cascade,
  data date not null default current_date,
  tipo text not null check (tipo in ('visita', 'ligacao', 'mensagem', 'auxilio', 'outro')),
  anotacao text not null,
  por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.assistidos_registros (assistido_id, data desc);
create index on public.assistidos_registros (loja_id);
create index on public.assistidos_registros (por);

create table public.auxilios (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  assistido_id uuid references public.assistidos(id),
  beneficiario text not null,                            -- nome que aparece para o Tesoureiro
  valor numeric(12,2) not null check (valor > 0),
  motivo text not null,
  status text not null default 'solicitado' check (status in ('solicitado', 'pago', 'recusado')),
  solicitado_por uuid default auth.uid() references auth.users(id),
  solicitado_em timestamptz not null default now(),
  decidido_por uuid references auth.users(id),
  decidido_em timestamptz,
  observacao text,
  lancamento_id uuid references public.lancamentos(id)
);
create index on public.auxilios (loja_id, status);
create index on public.auxilios (assistido_id);
create index on public.auxilios (solicitado_por);
create index on public.auxilios (decidido_por);
create index on public.auxilios (lancamento_id);

alter table public.assistidos enable row level security;
alter table public.assistidos_registros enable row level security;
alter table public.auxilios enable row level security;

create policy hospitalaria on public.assistidos for all to authenticated
  using ((select public.tem_permissao(loja_id, 'hospitalaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'hospitalaria.editar')));
create policy hospitalaria on public.assistidos_registros for all to authenticated
  using ((select public.tem_permissao(loja_id, 'hospitalaria.editar')))
  with check ((select public.tem_permissao(loja_id, 'hospitalaria.editar')));
-- auxílios: Hospitalaria pede e acompanha; quem movimenta o Tronco vê para pagar ou recusar
create policy le on public.auxilios for select to authenticated
  using ((select public.tem_permissao(loja_id, 'hospitalaria.editar')) or (select public.tem_permissao(loja_id, 'tronco.editar')));
create policy pede on public.auxilios for insert to authenticated
  with check ((select public.tem_permissao(loja_id, 'hospitalaria.editar')) and status = 'solicitado'
              and lancamento_id is null and decidido_por is null);

create trigger auditoria after insert or update or delete on public.assistidos for each row execute function public.registrar_auditoria();
create trigger auditoria after insert or update or delete on public.auxilios for each row execute function public.registrar_auditoria();

-- Tesoureiro paga (saída do Tronco, categoria Beneficência) ou recusa; a Hospitalaria vê a decisão
create function public.decidir_auxilio(p_auxilio uuid, p_pagar boolean, p_conta uuid default null,
                                       p_data date default current_date, p_observacao text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.auxilios;
  v_conta uuid;
  v_cat uuid;
  v_lanc uuid;
begin
  select * into a from public.auxilios where id = p_auxilio for update;
  if a.id is null or not public.tem_permissao(a.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro paga auxílios do Tronco'; end if;
  if a.status <> 'solicitado' then raise exception 'Este pedido já foi decidido'; end if;
  if p_pagar then
    v_conta := coalesce(p_conta, (select id from public.contas_financeiras where loja_id = a.loja_id and tipo = 'tronco' and ativa limit 1));
    if v_conta is null or not public.pode_lancar(v_conta) then raise exception 'Conta inválida para o pagamento'; end if;
    select id into v_cat from public.categorias_financeiras where loja_id = a.loja_id and codigo = 'beneficencia';
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao)
    values (a.loja_id, v_conta, v_cat, 'despesa', a.valor, coalesce(p_data, current_date),
            'Auxílio (Hospitalaria): ' || a.beneficiario)
    returning id into v_lanc;
  end if;
  update public.auxilios
  set status = case when p_pagar then 'pago' else 'recusado' end, decidido_por = auth.uid(), decidido_em = now(),
      observacao = nullif(trim(p_observacao), ''), lancamento_id = v_lanc
  where id = a.id;
  if a.assistido_id is not null and p_pagar then
    insert into public.assistidos_registros (loja_id, assistido_id, data, tipo, anotacao)
    values (a.loja_id, a.assistido_id, coalesce(p_data, current_date), 'auxilio',
            format('Auxílio de %s pago pelo Tronco: %s', private.moeda(a.valor), a.motivo));
  end if;
end $$;
revoke execute on function public.decidir_auxilio from public, anon;
grant execute on function public.decidir_auxilio to authenticated;
