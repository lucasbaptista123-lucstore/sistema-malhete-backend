-- Sistema Malhete — pedidos do irmão: LICENÇA (período + motivo) e DECLARAÇÃO DE REGULARIDADE (finalidade).
-- O irmão pede; a Secretaria (ou o Venerável) aprova ou recusa. Licença aprovada → situação "licenciado" (com
-- histórico); declaração aprovada → documento numerado emitido, que o próprio irmão abre e imprime.

create table public.pedidos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  tipo text not null check (tipo in ('licenca', 'regularidade')),
  motivo text not null check (length(trim(motivo)) > 0),   -- licença: motivo; declaração: finalidade
  inicio date,
  fim date,
  status text not null default 'pendente' check (status in ('pendente', 'aprovado', 'recusado')),
  observacao text,
  decidido_por uuid references auth.users(id),
  decidido_em timestamptz,
  documento_id uuid references public.documentos_emitidos(id),
  criado_em timestamptz not null default now(),
  check (tipo <> 'licenca' or inicio is not null),
  check (fim is null or inicio is null or fim >= inicio)
);
create index on public.pedidos (loja_id, status);
create index on public.pedidos (irmao_id);
create index on public.pedidos (decidido_por);
create index on public.pedidos (documento_id);
alter table public.pedidos enable row level security;
create policy le on public.pedidos for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id))
         or (select public.tem_permissao(loja_id, 'secretaria.ler')) or (select public.tem_permissao(loja_id, 'loja.config')));
create policy pede on public.pedidos for insert to authenticated
  with check (irmao_id = (select public.meu_irmao_id(loja_id)) and status = 'pendente' and decidido_por is null and documento_id is null);
create trigger auditoria after insert or update or delete on public.pedidos for each row execute function public.registrar_auditoria();

-- o irmão vê os documentos emitidos em nome dele
create policy le_proprio on public.documentos_emitidos for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id)));

create function public.decidir_pedido(p_pedido uuid, p_aprovar boolean, p_observacao text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  p public.pedidos;
  i public.irmaos;
  v_doc uuid;
  v_loja text;
begin
  select * into p from public.pedidos where id = p_pedido for update;
  if p.id is null or not (public.tem_permissao(p.loja_id, 'secretaria.editar') or public.tem_permissao(p.loja_id, 'loja.config')) then
    raise exception 'Só a Secretaria ou o Venerável decidem pedidos';
  end if;
  if p.status <> 'pendente' then raise exception 'Este pedido já foi decidido'; end if;
  select * into i from public.irmaos where id = p.irmao_id;

  if p_aprovar and p.tipo = 'licenca' and i.situacao <> 'licenciado' then
    perform public.alterar_situacao(p.irmao_id, 'licenciado', 'licenca', p.inicio,
      format('Pedido do irmão: %s%s', p.motivo, coalesce(' (até ' || to_char(p.fim, 'DD/MM/YYYY') || ')', '')));
  elsif p_aprovar and p.tipo = 'regularidade' then
    select trim(nome) || coalesce(' nº ' || numero, '') into v_loja from public.lojas where id = p.loja_id;
    insert into public.documentos_emitidos (loja_id, tipo, irmao_id, conteudo)
    values (p.loja_id, 'Declaração de regularidade', p.irmao_id,
            jsonb_build_object('nome', i.nome, 'cim', i.cim, 'grau', i.grau, 'mestre_instalado', i.mestre_instalado,
                               'situacao', i.situacao, 'data_iniciacao', i.data_iniciacao, 'finalidade', p.motivo, 'loja', v_loja))
    returning id into v_doc;
  end if;
  update public.pedidos
  set status = case when p_aprovar then 'aprovado' else 'recusado' end, observacao = nullif(trim(p_observacao), ''),
      decidido_por = auth.uid(), decidido_em = now(), documento_id = v_doc
  where id = p.id;
end $$;
revoke execute on function public.decidir_pedido from public, anon;
grant execute on function public.decidir_pedido to authenticated;
