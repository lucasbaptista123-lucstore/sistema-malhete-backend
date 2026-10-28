-- Sistema Malhete: DOCUMENTOS COM ASSINATURA PELO gov.br.
-- O irmão pede um documento (tipos da Loja ou "outro"); se o tipo exige quitação e há conta vencida, o pedido fica
-- em "pendencia" (o irmão vê o que falta e paga ali; com a baixa, o pedido segue sozinho). O Venerável aprova e
-- escolhe quem assina e em que ordem (padrão do tipo, alterável). Cada assinante é avisado na sua vez, assina o PDF
-- no gov.br e devolve; a função `assinaturas` confere a assinatura e o CPF e passa ao próximo. No fim, o irmão é avisado.

-- ======================= tipos de documento (padrão da Loja) =======================
create table public.tipos_documento (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  codigo text not null,
  nome text not null check (length(trim(nome)) > 0),
  assinantes text[] not null default '{}',          -- códigos de cargo, na ordem
  exige_quitacao boolean not null default false,
  irmao_pode_pedir boolean not null default true,
  ativo boolean not null default true,
  ordem int not null default 0,
  unique (loja_id, codigo)
);
create index on public.tipos_documento (loja_id);
alter table public.tipos_documento enable row level security;
create policy le on public.tipos_documento for select to authenticated using (loja_id in (select public.minhas_lojas()));
create policy veneravel on public.tipos_documento for all to authenticated
  using ((select public.tem_permissao(loja_id, 'loja.config'))) with check ((select public.tem_permissao(loja_id, 'loja.config')));
create trigger auditoria after insert or update or delete on public.tipos_documento for each row execute function public.registrar_auditoria();

create function private.tipos_documento_padrao(p_loja uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.tipos_documento (loja_id, codigo, nome, assinantes, exige_quitacao, ordem) values
    (p_loja, 'regularidade', 'Declaração de regularidade', array['secretario', 'tesoureiro', 'veneravel'], true, 1),
    (p_loja, 'quite_placet', 'Quite placet', array['secretario', 'tesoureiro', 'veneravel'], true, 2),
    (p_loja, 'atestado_frequencia', 'Atestado de frequência', array['chanceler', 'veneravel'], false, 3),
    (p_loja, 'carta_visita', 'Carta de apresentação (visita)', array['secretario', 'veneravel'], false, 4),
    (p_loja, 'outro', 'Outro documento', array['secretario', 'veneravel'], false, 9)
  on conflict do nothing
$$;
select private.tipos_documento_padrao(id) from public.lojas;
create function private.tipos_documento_nova_loja() returns trigger
language plpgsql security definer set search_path = '' as $$
begin perform private.tipos_documento_padrao(new.id); return new; end $$;
create trigger zz_tipos_documento after insert on public.lojas for each row execute function private.tipos_documento_nova_loja();
revoke execute on function private.tipos_documento_padrao, private.tipos_documento_nova_loja from public, anon, authenticated;

-- ======================= pedidos e documentos =======================
alter table public.pedidos drop constraint pedidos_tipo_check;
alter table public.pedidos add constraint pedidos_tipo_check check (tipo in ('licenca', 'regularidade', 'documento'));
alter table public.pedidos drop constraint pedidos_status_check;
alter table public.pedidos add constraint pedidos_status_check
  check (status in ('pendencia', 'pendente', 'assinando', 'aprovado', 'recusado'));
alter table public.pedidos add column tipo_documento_id uuid references public.tipos_documento(id);
create index on public.pedidos (tipo_documento_id);

alter table public.documentos_emitidos
  add column pedido_id uuid references public.pedidos(id),
  add column tipo_documento_id uuid references public.tipos_documento(id),
  add column situacao text not null default 'emitido' check (situacao in ('emitido', 'assinando', 'concluido')),
  add column arquivo_base text,
  add column arquivo_atual text,
  add column concluido_em timestamptz;
create index on public.documentos_emitidos (pedido_id);
create index on public.documentos_emitidos (tipo_documento_id);

create table public.documento_assinaturas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  documento_id uuid not null references public.documentos_emitidos(id) on delete cascade,
  ordem smallint not null,
  cargo_codigo text,
  cargo_nome text not null,
  irmao_id uuid not null references public.irmaos(id),
  em_substituicao boolean not null default false,
  status text not null default 'aguardando' check (status in ('aguardando', 'vez', 'assinado')),
  avisado_em timestamptz,
  assinado_em timestamptz,
  cpf_assinatura text,
  nome_assinatura text,
  arquivo_caminho text,
  unique (documento_id, ordem)
);
create index on public.documento_assinaturas (irmao_id, status);
create index on public.documento_assinaturas (loja_id);

create table public.documento_eventos (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  documento_id uuid not null references public.documentos_emitidos(id) on delete cascade,
  descricao text not null,
  por uuid default auth.uid() references auth.users(id),
  em timestamptz not null default now()
);
create index on public.documento_eventos (documento_id);
create index on public.documento_eventos (loja_id);
create index on public.documento_eventos (por);

-- quem enxerga o documento: Secretaria, Venerável, o irmão do documento e quem está na fila de assinatura
create function public.pode_ver_documento(p_doc uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.documentos_emitidos d where d.id = p_doc and (
    public.tem_permissao(d.loja_id, 'secretaria.ler') or public.tem_permissao(d.loja_id, 'loja.config')
    or d.irmao_id = public.meu_irmao_id(d.loja_id)
    or exists (select 1 from public.documento_assinaturas a where a.documento_id = d.id and a.irmao_id = public.meu_irmao_id(d.loja_id))))
$$;
create policy assinante_le on public.documentos_emitidos for select to authenticated using ((select public.pode_ver_documento(id)));
alter table public.documento_assinaturas enable row level security;
alter table public.documento_eventos enable row level security;
create policy le on public.documento_assinaturas for select to authenticated using ((select public.pode_ver_documento(documento_id)));
create policy le on public.documento_eventos for select to authenticated using ((select public.pode_ver_documento(documento_id)));
create trigger auditoria after insert or update or delete on public.documento_assinaturas for each row execute function public.registrar_auditoria();

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check
  check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema',
                  'justificativa', 'evento', 'documento'));

-- ======================= auxiliares =======================
-- contas vencidas e em aberto do irmão
create function private.pendencias_irmao(p_irmao uuid, out qtd int, out total numeric) returns record
language sql stable security definer set search_path = '' as $$
  select count(*)::int, coalesce(sum(t.valor - t.valor_pago + private.encargos(t.loja_id, t.valor - t.valor_pago, t.vencimento)), 0)
  from public.titulos t
  where t.irmao_id = p_irmao and t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor and t.vencimento < current_date
$$;
create function public.minhas_pendencias(p_loja uuid, out qtd int, out total numeric) returns record
language sql stable security definer set search_path = '' as $$
  select p.qtd, p.total from private.pendencias_irmao(public.meu_irmao_id(p_loja)) p
$$;
create function public.pendencias_do_irmao(p_irmao uuid, out qtd int, out total numeric) returns record
language plpgsql stable security definer set search_path = '' as $$
declare v_loja uuid := (select loja_id from public.irmaos where id = p_irmao);
begin
  -- quem decide ou assina documentos pode ver o resumo (não o detalhe) da situação do irmão
  if not (public.tem_permissao(v_loja, 'loja.config') or public.tem_permissao(v_loja, 'secretaria.ler')
          or public.tem_permissao(v_loja, 'tesouraria.ler')
          or exists (select 1 from public.documento_assinaturas a join public.documentos_emitidos d on d.id = a.documento_id
                     where d.irmao_id = p_irmao and a.irmao_id = public.meu_irmao_id(v_loja) and a.status <> 'assinado')) then
    raise exception 'Sem permissão';
  end if;
  select p.qtd, p.total into qtd, total from private.pendencias_irmao(p_irmao) p;
end $$;

create function private.ocupante_cargo(p_loja uuid, p_codigo text) returns uuid
language sql stable security definer set search_path = '' as $$
  select m.irmao_id from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
  where m.loja_id = p_loja and c.codigo = p_codigo and current_date between m.inicio and m.fim
  order by m.inicio desc limit 1
$$;

-- assinantes sugeridos para um tipo (cargo -> quem ocupa hoje)
create function public.assinantes_sugeridos(p_tipo uuid)
returns table (ordem int, cargo_codigo text, cargo_nome text, irmao_id uuid, irmao_nome text)
language sql stable security definer set search_path = '' as $$
  select x.ord::int, x.cod, coalesce(c.nome, x.cod), o.id, o.nome
  from public.tipos_documento t
  cross join lateral unnest(t.assinantes) with ordinality as x(cod, ord)
  left join public.loja_cargos c on c.loja_id = t.loja_id and c.codigo = x.cod
  left join public.irmaos o on o.id = private.ocupante_cargo(t.loja_id, x.cod)
  where t.id = p_tipo and t.loja_id in (select public.minhas_lojas())
  order by x.ord
$$;

create function private.evento_documento(p_doc uuid, p_txt text) returns void
language sql security definer set search_path = '' as $$
  insert into public.documento_eventos (loja_id, documento_id, descricao)
  select loja_id, id, p_txt from public.documentos_emitidos where id = p_doc
$$;

create function private.avisar_veneravel_pedido(p_pedido uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.pedidos; v_nome text; v_tipo text; v_vm uuid; v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select * into p from public.pedidos where id = p_pedido;
  select nome into v_nome from public.irmaos where id = p.irmao_id;
  select nome into v_tipo from public.tipos_documento where id = p.tipo_documento_id;
  v_vm := private.ocupante_cargo(p.loja_id, 'veneravel');
  if v_vm is null or v_vm = p.irmao_id then return; end if;
  perform private.notificar(p.loja_id, v_vm, 'documento', p.id,
    format('Venerável, o Ir. %s pediu: %s (%s). Decida e escolha quem assina: %s/app/secretaria/pedidos',
           v_nome, coalesce(v_tipo, 'documento'), left(p.motivo, 120), v_url));
end $$;

create function private.avisar_assinante(p_assinatura uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare a public.documento_assinaturas; d public.documentos_emitidos; v_nome text; v_de text; v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select * into a from public.documento_assinaturas where id = p_assinatura;
  select * into d from public.documentos_emitidos where id = a.documento_id;
  select nome into v_nome from public.irmaos where id = a.irmao_id;
  select nome into v_de from public.irmaos where id = d.irmao_id;
  perform private.notificar(a.loja_id, a.irmao_id, 'documento', d.id,
    format('Olá, %s! %s%s aguarda sua assinatura como %s. Assinar: %s/app/assinaturas',
           private.primeiro_nome(v_nome), d.tipo, coalesce(' do Ir. ' || v_de, ''), a.cargo_nome, v_url));
  update public.documento_assinaturas set avisado_em = now() where id = a.id;
end $$;

-- ======================= o irmão pede =======================
create function public.pedir_documento(p_loja uuid, p_tipo uuid, p_finalidade text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_eu uuid := public.meu_irmao_id(p_loja);
  t public.tipos_documento;
  pend record;
  v_status text;
  v_id uuid;
begin
  if v_eu is null then raise exception 'Você não é irmão desta Loja'; end if;
  select * into t from public.tipos_documento where id = p_tipo and loja_id = p_loja and ativo and irmao_pode_pedir;
  if t.id is null then raise exception 'Tipo de documento não disponível'; end if;
  if length(trim(coalesce(p_finalidade, ''))) < 3 then raise exception 'Diga para que é o documento'; end if;
  select * into pend from private.pendencias_irmao(v_eu);
  v_status := case when t.exige_quitacao and pend.qtd > 0 then 'pendencia' else 'pendente' end;
  insert into public.pedidos (loja_id, irmao_id, tipo, tipo_documento_id, motivo, status)
  values (p_loja, v_eu, 'documento', t.id, trim(p_finalidade), v_status)
  returning id into v_id;
  if v_status = 'pendente' then perform private.avisar_veneravel_pedido(v_id); end if;
  return jsonb_build_object('pedido', v_id, 'status', v_status, 'qtd', pend.qtd, 'total', pend.total);
end $$;

-- pagamento caiu: pedidos travados por pendência seguem sozinhos ao Venerável
create function private.reavaliar_pedidos() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v_nome text;
begin
  if new.irmao_id is null or new.valor_pago <= old.valor_pago then return null; end if;
  if (select qtd from private.pendencias_irmao(new.irmao_id)) > 0 then return null; end if;
  for r in select id, loja_id from public.pedidos where irmao_id = new.irmao_id and status = 'pendencia' loop
    update public.pedidos set status = 'pendente' where id = r.id;
    select nome into v_nome from public.irmaos where id = new.irmao_id;
    perform private.notificar(r.loja_id, new.irmao_id, 'documento', r.id,
      format('Olá, %s! Pagamento recebido. Seu pedido de documento seguiu para o Venerável.', private.primeiro_nome(v_nome)));
    perform private.avisar_veneravel_pedido(r.id);
  end loop;
  return null;
end $$;
create trigger reavaliar_pedidos after update of valor_pago on public.titulos
for each row execute function private.reavaliar_pedidos();

-- ======================= o Venerável decide e escolhe quem assina =======================
create function private.gravar_assinantes(p_doc uuid, p_assinantes jsonb, p_a_partir int) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d public.documentos_emitidos;
  x jsonb;
  k int := p_a_partir;
  v_cargo text; v_nome_cargo text; v_irmao uuid;
begin
  select * into d from public.documentos_emitidos where id = p_doc;
  for x in select value from jsonb_array_elements(p_assinantes) loop
    v_irmao := nullif(x->>'irmao_id', '')::uuid;
    v_cargo := nullif(x->>'cargo_codigo', '');
    if v_irmao is null or not exists (select 1 from public.irmaos where id = v_irmao and loja_id = d.loja_id and situacao = 'ativo') then
      raise exception 'Escolha um irmão ativo para cada assinatura';
    end if;
    if (select cpf from public.irmaos where id = v_irmao) is null then
      raise exception 'O irmão escolhido para assinar precisa ter CPF no cadastro (a assinatura gov.br é conferida pelo CPF)';
    end if;
    v_nome_cargo := coalesce(nullif(trim(x->>'cargo_nome'), ''),
                             (select nome from public.loja_cargos where loja_id = d.loja_id and codigo = v_cargo), 'Irmão');
    insert into public.documento_assinaturas (loja_id, documento_id, ordem, cargo_codigo, cargo_nome, irmao_id, em_substituicao)
    values (d.loja_id, d.id, k, v_cargo, v_nome_cargo, v_irmao,
            v_cargo is not null and private.ocupante_cargo(d.loja_id, v_cargo) is distinct from v_irmao);
    k := k + 1;
  end loop;
end $$;

create function public.decidir_pedido_documento(p_pedido uuid, p_aprovar boolean, p_observacao text default null,
                                                p_assinantes jsonb default '[]') returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  p public.pedidos;
  t public.tipos_documento;
  i public.irmaos;
  v_loja text; v_cidade text;
  v_doc uuid;
  v_primeira uuid;
begin
  select * into p from public.pedidos where id = p_pedido for update;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Só o Venerável decide pedidos de documento'; end if;
  if p.tipo <> 'documento' then raise exception 'Use a decisão de licença para este pedido'; end if;
  if p.status = 'pendencia' then raise exception 'O irmão ainda tem pendência com a Tesouraria'; end if;
  if p.status <> 'pendente' then raise exception 'Este pedido já foi decidido'; end if;
  if not p_aprovar then
    update public.pedidos set status = 'recusado', observacao = nullif(trim(p_observacao), ''), decidido_por = auth.uid(), decidido_em = now()
    where id = p.id;
    perform private.notificar(p.loja_id, p.irmao_id, 'documento', p.id,
      'Seu pedido de documento não foi aprovado' || coalesce(': ' || nullif(trim(p_observacao), ''), '.'));
    return null;
  end if;
  if jsonb_array_length(coalesce(p_assinantes, '[]')) = 0 then raise exception 'Escolha quem assina o documento'; end if;
  select * into t from public.tipos_documento where id = p.tipo_documento_id;
  select * into i from public.irmaos where id = p.irmao_id;
  select trim(nome) || coalesce(' nº ' || numero, ''), cidade into v_loja, v_cidade from public.lojas where id = p.loja_id;
  insert into public.documentos_emitidos (loja_id, tipo, irmao_id, conteudo, pedido_id, tipo_documento_id, situacao)
  values (p.loja_id, t.nome, p.irmao_id,
          jsonb_build_object('nome', i.nome, 'cim', i.cim, 'cpf', i.cpf, 'grau', i.grau, 'mestre_instalado', i.mestre_instalado,
                             'situacao', i.situacao, 'data_iniciacao', i.data_iniciacao, 'finalidade', p.motivo, 'loja', v_loja,
                             'cidade', v_cidade, 'tipo_codigo', t.codigo),
          p.id, t.id, 'assinando')
  returning id into v_doc;
  perform private.gravar_assinantes(v_doc, p_assinantes, 1);
  select id into v_primeira from public.documento_assinaturas where documento_id = v_doc order by ordem limit 1;
  update public.documento_assinaturas set status = 'vez' where id = v_primeira;
  update public.pedidos set status = 'assinando', observacao = nullif(trim(p_observacao), ''), decidido_por = auth.uid(),
         decidido_em = now(), documento_id = v_doc
  where id = p.id;
  perform private.evento_documento(v_doc, 'Pedido aprovado pelo Venerável; fila de assinaturas montada');
  perform private.notificar(p.loja_id, p.irmao_id, 'documento', p.id, 'Seu pedido foi aprovado e está em assinatura. Você será avisado quando ficar pronto.');
  -- o primeiro assinante só é avisado quando o PDF base estiver salvo (definir_pdf_base)
  return v_doc;
end $$;

-- o PDF base é gerado no app (logo após aprovar) e guardado; só então o primeiro assinante é avisado
create function public.definir_pdf_base(p_doc uuid, p_caminho text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos; v_vez uuid;
begin
  select * into d from public.documentos_emitidos where id = p_doc for update;
  if d.id is null or not (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.editar')) then
    raise exception 'Sem permissão';
  end if;
  if d.arquivo_base is not null then raise exception 'O PDF deste documento já foi gerado'; end if;
  if public.loja_do_caminho(p_caminho) is distinct from d.loja_id or split_part(p_caminho, '/', 3) <> d.id::text then
    raise exception 'Caminho inválido';
  end if;
  update public.documentos_emitidos set arquivo_base = p_caminho, arquivo_atual = p_caminho where id = d.id;
  select id into v_vez from public.documento_assinaturas where documento_id = d.id and status = 'vez';
  if v_vez is not null then perform private.avisar_assinante(v_vez); end if;
end $$;

-- assinatura conferida (chamado pela função `assinaturas`, com service_role)
create function public.registrar_assinatura(p_assinatura uuid, p_caminho text, p_cpf text, p_nome text) returns text
language plpgsql security definer set search_path = '' as $$
declare a public.documento_assinaturas; d public.documentos_emitidos; v_prox uuid; v_nome text;
begin
  select * into a from public.documento_assinaturas where id = p_assinatura for update;
  if a.id is null or a.status <> 'vez' then raise exception 'Assinatura fora da vez'; end if;
  update public.documento_assinaturas
  set status = 'assinado', assinado_em = now(), cpf_assinatura = p_cpf, nome_assinatura = p_nome, arquivo_caminho = p_caminho
  where id = a.id;
  update public.documentos_emitidos set arquivo_atual = p_caminho where id = a.documento_id;
  perform private.evento_documento(a.documento_id, format('%s assinou pelo gov.br (CPF confere)', a.cargo_nome));
  select id into v_prox from public.documento_assinaturas where documento_id = a.documento_id and status = 'aguardando' order by ordem limit 1;
  if v_prox is not null then
    update public.documento_assinaturas set status = 'vez' where id = v_prox;
    perform private.avisar_assinante(v_prox);
    return 'próximo avisado';
  end if;
  update public.documentos_emitidos set situacao = 'concluido', concluido_em = now() where id = a.documento_id returning * into d;
  update public.pedidos set status = 'aprovado' where id = d.pedido_id;
  perform private.evento_documento(d.id, 'Todas as assinaturas concluídas');
  if d.irmao_id is not null then
    select nome into v_nome from public.irmaos where id = d.irmao_id;
    perform private.notificar(d.loja_id, d.irmao_id, 'documento', d.id,
      format('Olá, %s! Seu documento "%s" está pronto e assinado. Baixe em Meus pedidos.', private.primeiro_nome(v_nome), d.tipo));
  end if;
  return 'concluído';
end $$;

-- o Venerável (ou a Secretaria) troca quem ainda não assinou
create function public.alterar_assinantes(p_doc uuid, p_assinantes jsonb, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos; n_assinados int; v_vez uuid;
begin
  select * into d from public.documentos_emitidos where id = p_doc for update;
  if d.id is null or not (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.editar')) then
    raise exception 'Só o Venerável ou a Secretaria alteram quem assina';
  end if;
  if d.situacao <> 'assinando' then raise exception 'Documento já concluído'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Informe o motivo da alteração'; end if;
  if jsonb_array_length(coalesce(p_assinantes, '[]')) = 0 and not exists (select 1 from public.documento_assinaturas where documento_id = d.id and status = 'assinado') then
    raise exception 'Escolha quem assina';
  end if;
  select count(*) into n_assinados from public.documento_assinaturas where documento_id = d.id and status = 'assinado';
  delete from public.documento_assinaturas where documento_id = d.id and status <> 'assinado';
  perform private.gravar_assinantes(d.id, p_assinantes, n_assinados + 1);
  perform private.evento_documento(d.id, 'Assinantes alterados: ' || trim(p_motivo));
  select id into v_vez from public.documento_assinaturas where documento_id = d.id and status = 'aguardando' order by ordem limit 1;
  if v_vez is null then
    -- todos os que restavam foram retirados: concluído com quem já assinou
    update public.documentos_emitidos set situacao = 'concluido', concluido_em = now() where id = d.id;
    update public.pedidos set status = 'aprovado' where id = d.pedido_id;
  else
    update public.documento_assinaturas set status = 'vez' where id = v_vez;
    if d.arquivo_base is not null then perform private.avisar_assinante(v_vez); end if;
  end if;
end $$;

create function public.lembrar_assinante(p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos; v_vez uuid;
begin
  select * into d from public.documentos_emitidos where id = p_doc;
  if d.id is null or not (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.ler')) then
    raise exception 'Sem permissão';
  end if;
  select id into v_vez from public.documento_assinaturas where documento_id = d.id and status = 'vez';
  if v_vez is null then raise exception 'Ninguém na vez de assinar'; end if;
  perform private.avisar_assinante(v_vez);
end $$;

-- ======================= arquivos =======================
-- <loja>/documentos/<doc>/base.pdf (gerado no app) e <loja>/documentos/<doc>/envio-<assinatura>-<ts>.pdf (assinado)
create function public.pode_ler_arquivo_documento(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_doc uuid;
begin
  if split_part(p_nome, '/', 2) <> 'documentos' then return false; end if;
  begin v_doc := split_part(p_nome, '/', 3)::uuid; exception when others then return false; end;
  return public.pode_ver_documento(v_doc);
end $$;
create function public.pode_enviar_arquivo_documento(p_nome text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_doc uuid; v_ass uuid; d public.documentos_emitidos;
begin
  if split_part(p_nome, '/', 2) <> 'documentos' then return false; end if;
  begin v_doc := split_part(p_nome, '/', 3)::uuid; exception when others then return false; end;
  select * into d from public.documentos_emitidos where id = v_doc and loja_id = public.loja_do_caminho(p_nome);
  if d.id is null then return false; end if;
  if split_part(p_nome, '/', 4) = 'base.pdf' then
    return d.arquivo_base is null and (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.editar'));
  end if;
  begin v_ass := substring(split_part(p_nome, '/', 4) from '^envio-([0-9a-f-]{36})-')::uuid; exception when others then return false; end;
  return exists (select 1 from public.documento_assinaturas a where a.id = v_ass and a.documento_id = d.id and a.status = 'vez'
                 and a.irmao_id = public.meu_irmao_id(d.loja_id));
end $$;
create policy documentos_le on storage.objects for select to authenticated
  using (bucket_id = 'secretaria' and public.pode_ler_arquivo_documento(name));
create policy documentos_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'secretaria' and public.pode_enviar_arquivo_documento(name));

revoke execute on function private.pendencias_irmao, private.ocupante_cargo, private.evento_documento, private.avisar_veneravel_pedido,
  private.avisar_assinante, private.reavaliar_pedidos, private.gravar_assinantes from public, anon, authenticated;
revoke execute on function public.minhas_pendencias, public.pendencias_do_irmao, public.assinantes_sugeridos, public.pedir_documento,
  public.decidir_pedido_documento, public.definir_pdf_base, public.alterar_assinantes, public.lembrar_assinante,
  public.pode_ver_documento, public.pode_ler_arquivo_documento, public.pode_enviar_arquivo_documento from public, anon;
grant execute on function public.minhas_pendencias, public.pendencias_do_irmao, public.assinantes_sugeridos, public.pedir_documento,
  public.decidir_pedido_documento, public.definir_pdf_base, public.alterar_assinantes, public.lembrar_assinante,
  public.pode_ver_documento, public.pode_ler_arquivo_documento, public.pode_enviar_arquivo_documento to authenticated;
revoke execute on function public.registrar_assinatura from public, anon, authenticated;
grant execute on function public.registrar_assinatura to service_role;
