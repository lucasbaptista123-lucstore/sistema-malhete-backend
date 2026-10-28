-- Sistema Malhete — o irmão contribui com o Tronco de Beneficência por PIX (QR Code gerado com a chave da loja,
-- identificador TRONCO…). Ele informa "já paguei"; o Tesoureiro confere no extrato e confirma, e o lançamento
-- entra na conta Tronco, categoria Tronco de beneficência. Só o Tesoureiro vê quem contribuiu (discrição).

create table public.tronco_contribuicoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  valor numeric(12,2) not null check (valor > 0),
  txid text not null,                                   -- vai no QR (aparece no extrato de muitos bancos)
  status text not null default 'informada' check (status in ('informada', 'confirmada', 'nao_localizada')),
  informado_em timestamptz not null default now(),
  decidido_por uuid references auth.users(id),
  decidido_em timestamptz,
  lancamento_id uuid references public.lancamentos(id)
);
create index on public.tronco_contribuicoes (loja_id, status);
create index on public.tronco_contribuicoes (irmao_id);
create index on public.tronco_contribuicoes (decidido_por);
create index on public.tronco_contribuicoes (lancamento_id);
alter table public.tronco_contribuicoes enable row level security;
create policy le on public.tronco_contribuicoes for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)) or (select public.tem_permissao(loja_id, 'tronco.editar')));
create policy informa on public.tronco_contribuicoes for insert to authenticated
  with check (irmao_id = (select public.meu_irmao_id(loja_id)) and status = 'informada'
              and decidido_por is null and lancamento_id is null);
create trigger auditoria after insert or update or delete on public.tronco_contribuicoes for each row execute function public.registrar_auditoria();

-- Tesoureiro confirma (lança no Tronco) ou marca como não localizada no extrato
create function public.decidir_tronco(p_id uuid, p_confirmar boolean, p_data date default current_date)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  c public.tronco_contribuicoes;
  v_conta uuid;
  v_lanc uuid;
begin
  select * into c from public.tronco_contribuicoes where id = p_id for update;
  if c.id is null or not public.tem_permissao(c.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro confirma o Tronco'; end if;
  if c.status = 'confirmada' then raise exception 'Já confirmada'; end if;
  if p_confirmar then
    select id into v_conta from public.contas_financeiras where loja_id = c.loja_id and tipo = 'tronco' and ativa limit 1;
    if v_conta is null then raise exception 'A loja não tem conta Tronco ativa'; end if;
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao, documento)
    values (c.loja_id, v_conta,
            (select id from public.categorias_financeiras where loja_id = c.loja_id and codigo = 'tronco'),
            'receita', c.valor, coalesce(p_data, current_date), 'Tronco de Beneficência (PIX)', c.txid)
    returning id into v_lanc;
  end if;
  update public.tronco_contribuicoes
  set status = case when p_confirmar then 'confirmada' else 'nao_localizada' end,
      decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_lanc
  where id = c.id;
end $$;
revoke execute on function public.decidir_tronco from public, anon;
grant execute on function public.decidir_tronco to authenticated;
