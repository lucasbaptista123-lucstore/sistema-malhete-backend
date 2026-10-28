-- Sistema Malhete — situação do irmão com motivo e histórico (quite placet, inadimplência, saída, falecimento,
-- licença, regularização). Quem sai (quite placet, desligado, falecido) perde o acesso (minhas_lojas já filtra),
-- tem os cargos encerrados e os convites cancelados. Irregular continua vendo Início/mensalidades, sem cargo.
-- Também: profissão no cadastro (preenchida pelo próprio irmão) e o diretório informa quem já tem acesso.

alter table public.irmaos add column profissao text;

create table public.irmao_situacoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id) on delete cascade,
  situacao public.situacao_irmao not null,
  anterior public.situacao_irmao,
  motivo text not null check (motivo in ('quite_placet', 'inadimplencia', 'saida', 'falecimento', 'licenca', 'regularizacao', 'outro')),
  data date not null default current_date,
  observacao text,
  registrado_por uuid default auth.uid() references auth.users(id),
  registrado_em timestamptz not null default now()
);
create index on public.irmao_situacoes (irmao_id, data desc);
create index on public.irmao_situacoes (loja_id);
create index on public.irmao_situacoes (registrado_por);
alter table public.irmao_situacoes enable row level security;
create policy le on public.irmao_situacoes for select to authenticated
  using ((select public.tem_permissao(loja_id, 'cadastro.ler')));
create trigger auditoria after insert or update or delete on public.irmao_situacoes for each row execute function public.registrar_auditoria();

create function public.alterar_situacao(p_irmao uuid, p_situacao public.situacao_irmao, p_motivo text, p_data date default current_date, p_observacao text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  i public.irmaos;
begin
  select * into i from public.irmaos where id = p_irmao for update;
  if i.id is null or not public.tem_permissao(i.loja_id, 'cadastro.editar') then raise exception 'Sem permissão'; end if;
  if i.situacao = p_situacao then raise exception 'O irmão já está nessa situação'; end if;
  if i.user_id = auth.uid() and p_situacao not in ('ativo', 'licenciado') then raise exception 'Você não pode alterar a sua própria situação'; end if;

  insert into public.irmao_situacoes (loja_id, irmao_id, situacao, anterior, motivo, data, observacao)
  values (i.loja_id, p_irmao, p_situacao, i.situacao, p_motivo, coalesce(p_data, current_date), nullif(trim(p_observacao), ''));

  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos set situacao = p_situacao where id = p_irmao;
  -- quem sai ou fica irregular deixa o cargo
  if p_situacao in ('quite_placet', 'desligado', 'falecido', 'irregular') then
    update public.mandatos set fim = greatest(inicio, coalesce(p_data, current_date) - 1)
    where irmao_id = p_irmao and fim >= coalesce(p_data, current_date);
  end if;
  perform set_config('malhete.sistema', 'off', true);
  if p_situacao in ('quite_placet', 'desligado', 'falecido') then
    update public.convites set expira_em = now() where irmao_id = p_irmao and usado_em is null and expira_em > now();
    update public.notificacoes set status = 'descartado' where irmao_id = p_irmao and status = 'pendente';
  end if;
end $$;

-- diretório: mais "tem_acesso" e "convidado_em" (último convite em aberto)
drop function public.diretorio(uuid);
create function public.diretorio(p_loja uuid)
returns table (id uuid, nome text, grau smallint, mestre_instalado boolean, situacao public.situacao_irmao, tem_acesso boolean, convidado_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.grau, i.mestre_instalado, i.situacao, i.user_id is not null,
         (select max(c.criado_em) from public.convites c where c.irmao_id = i.id and c.usado_em is null and c.expira_em > now())
  from public.irmaos i
  where i.loja_id = p_loja
    and p_loja in (select public.minhas_lojas())
  order by i.nome
$$;

revoke execute on function public.alterar_situacao from public, anon;
grant execute on function public.alterar_situacao to authenticated;
revoke execute on function public.diretorio from public, anon;
grant execute on function public.diretorio to authenticated;
