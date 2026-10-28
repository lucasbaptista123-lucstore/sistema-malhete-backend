-- Kit placet e placets de elevação/exaltação (27/10).
-- O pedido de placet à Potência vira um documento da Loja assinado pelo gov.br (mesma fila de assinaturas dos
-- pedidos dos irmãos). Iniciação/filiação: gerado a partir do processo de admissão (etapa placet). Elevação e
-- exaltação: `placets_grau` reúne os irmãos, gera o pedido, registra o placet recebido e, na cerimônia, muda o grau.

-- documento da Loja ligado a um processo ou a um placet de grau
alter table public.documentos_emitidos
  add column ref_tipo text check (ref_tipo in ('processo', 'placet_grau')),
  add column ref_id uuid;
create index on public.documentos_emitidos (ref_id);
alter table public.processos add column escrutinio_data date;

-- dados da Loja usados no cabeçalho dos ofícios
create function private.dados_oficio(p_loja uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('loja', trim(l.nome) || coalesce(' nº ' || l.numero, ''), 'loja_nome', trim(l.nome), 'loja_numero', l.numero,
                            'cidade', l.cidade, 'oriente', o.nome, 'potencia', pt.nome)
  from public.lojas l
  left join public.orientes o on o.id = l.oriente_id
  left join public.potencias pt on pt.id = o.potencia_id
  where l.id = p_loja
$$;

-- cria o documento da Loja e monta a fila de assinaturas (o PDF base vem do app, por definir_pdf_base)
create function private.emitir_documento(p_loja uuid, p_titulo text, p_codigo text, p_conteudo jsonb, p_assinantes jsonb,
                                         p_ref_tipo text, p_ref_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_doc uuid;
begin
  if jsonb_array_length(coalesce(p_assinantes, '[]')) = 0 then raise exception 'Escolha quem assina o documento'; end if;
  insert into public.documentos_emitidos (loja_id, tipo, irmao_id, conteudo, situacao, ref_tipo, ref_id)
  values (p_loja, p_titulo, null, private.dados_oficio(p_loja) || p_conteudo || jsonb_build_object('tipo_codigo', p_codigo),
          'assinando', p_ref_tipo, p_ref_id)
  returning id into v_doc;
  perform private.gravar_assinantes(v_doc, p_assinantes, 1);
  update public.documento_assinaturas set status = 'vez'
  where id = (select id from public.documento_assinaturas where documento_id = v_doc order by ordem limit 1);
  perform private.evento_documento(v_doc, 'Documento da Loja gerado; fila de assinaturas montada');
  return v_doc;
end $$;

-- ======================= iniciação / filiação =======================
create function public.pedir_placet_processo(p_processo uuid, p_escrutinio date, p_assinantes jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.processos; v_doc uuid; v_prop public.irmaos; v_total int; v_fav int;
begin
  select * into p from public.processos where id = p_processo for update;
  if p.id is null or not (public.tem_permissao(p.loja_id, 'loja.config') or public.tem_permissao(p.loja_id, 'secretaria.editar')) then
    raise exception 'Sem permissão';
  end if;
  if p.etapa <> 'placet' then raise exception 'O pedido de placet é gerado depois de encerrada a sindicância'; end if;
  if exists (select 1 from public.documentos_emitidos where ref_tipo = 'processo' and ref_id = p.id) then
    raise exception 'O pedido de placet deste processo já foi gerado. Para trocar quem assina, use Documentos em assinatura';
  end if;
  if p.tipo = 'iniciacao' and p_escrutinio is null then raise exception 'Informe a data do escrutínio em Loja'; end if;
  select * into v_prop from public.irmaos where id = p.proponente_id;
  select count(*), count(*) filter (where parecer = 'favoravel') into v_total, v_fav from public.sindicancias where processo_id = p.id;
  update public.processos set escrutinio_data = p_escrutinio where id = p.id;
  v_doc := private.emitir_documento(p.loja_id,
    case p.tipo when 'iniciacao' then 'Pedido de placet de iniciação' else 'Pedido de placet de filiação' end,
    'placet_processo',
    jsonb_build_object('processo_tipo', p.tipo, 'nome', p.nome, 'escrutinio', p_escrutinio,
      'proponente', v_prop.nome, 'proponente_cim', v_prop.cim, 'sindicantes', v_total, 'favoraveis', v_fav,
      'finalidade', '', 'grau', coalesce(nullif(p.dados->>'grau', '')::int, 1), 'mestre_instalado', false, 'situacao', 'ativo',
      'cim', nullif(p.dados->>'cim', ''), 'data_iniciacao', nullif(p.dados->>'data_iniciacao', ''),
      'candidato', p.dados - 'motivo' - 'referencias' - 'filhos'),
    p_assinantes, 'processo', p.id);
  perform private.evento_processo(p, 'Pedido de placet gerado e enviado para assinatura pelo gov.br');
  return v_doc;
end $$;

-- ======================= elevação / exaltação =======================
create table public.placets_grau (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  tipo text not null check (tipo in ('elevacao', 'exaltacao')),
  irmaos uuid[] not null check (cardinality(irmaos) > 0),
  status text not null default 'pedido' check (status in ('pedido', 'placet', 'concluido', 'cancelado')),
  documento_id uuid references public.documentos_emitidos(id),
  placet_numero text,
  placet_data date,
  placet_arquivo text,
  data_cerimonia date,
  concluidos uuid[],
  motivo_cancelamento text,
  criado_por uuid default auth.uid() references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.placets_grau (loja_id, status);
create index on public.placets_grau (documento_id);
create index on public.placets_grau (criado_por);
alter table public.placets_grau enable row level security;
create policy le on public.placets_grau for select to authenticated
  using ((select public.tem_permissao(loja_id, 'secretaria.ler')) or (select public.tem_permissao(loja_id, 'loja.config'))
         or (select public.tem_permissao(loja_id, 'graus.editar')));
create trigger auditoria after insert or update or delete on public.placets_grau for each row execute function public.registrar_auditoria();

create function private.pode_placet_grau(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.tem_permissao(p_loja, 'graus.editar') or public.tem_permissao(p_loja, 'loja.config')
$$;

-- candidatos: irmãos ativos do grau, com interstício, frequência de 12 meses, trabalhos aprovados no grau e pendências
create function public.candidatos_placet_grau(p_loja uuid, p_tipo text)
returns table (irmao_id uuid, nome text, cim text, desde date, meses int, frequencia numeric, trabalhos int,
               pendencias int, em_aberto uuid)
language sql stable security definer set search_path = '' as $$
  select i.id, i.nome, i.cim,
         case when p_tipo = 'elevacao' then i.data_iniciacao else i.data_elevacao end,
         (extract(year from age(current_date, case when p_tipo = 'elevacao' then i.data_iniciacao else i.data_elevacao end)) * 12
          + extract(month from age(current_date, case when p_tipo = 'elevacao' then i.data_iniciacao else i.data_elevacao end)))::int,
         (private.frequencia_12m(i.id)->>'percentual')::numeric,
         (select count(*)::int from public.trabalhos t where t.irmao_id = i.id and t.status = 'aprovado' and t.grau = i.grau),
         (private.pendencias_irmao(i.id)).qtd,
         (select g.id from public.placets_grau g where g.loja_id = p_loja and i.id = any(g.irmaos) and g.status in ('pedido', 'placet') limit 1)
  from public.irmaos i
  where private.pode_placet_grau(p_loja) and i.loja_id = p_loja and i.situacao = 'ativo'
    and i.grau = case when p_tipo = 'elevacao' then 1 else 2 end
  order by 4 nulls last, i.nome
$$;

create function public.abrir_placet_grau(p_loja uuid, p_tipo text, p_irmaos uuid[], p_assinantes jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_doc uuid; v_lista jsonb; v_grau int := case p_tipo when 'elevacao' then 1 when 'exaltacao' then 2 end;
begin
  if not private.pode_placet_grau(p_loja) then raise exception 'Só o Venerável e o Secretário pedem placet de elevação ou exaltação'; end if;
  if v_grau is null then raise exception 'Tipo inválido'; end if;
  if coalesce(cardinality(p_irmaos), 0) = 0 then raise exception 'Escolha ao menos um irmão'; end if;
  if exists (select 1 from unnest(p_irmaos) x(id) left join public.irmaos i on i.id = x.id
             where i.id is null or i.loja_id <> p_loja or i.situacao <> 'ativo' or i.grau <> v_grau) then
    raise exception 'Todos os irmãos precisam estar ativos e no grau de %', case v_grau when 1 then 'Aprendiz' else 'Companheiro' end;
  end if;
  if exists (select 1 from public.placets_grau g where g.loja_id = p_loja and g.status in ('pedido', 'placet') and g.irmaos && p_irmaos) then
    raise exception 'Algum dos irmãos já está em outro pedido de placet em andamento';
  end if;
  insert into public.placets_grau (loja_id, tipo, irmaos) values (p_loja, p_tipo, p_irmaos) returning id into v_id;
  select jsonb_agg(jsonb_build_object('nome', i.nome, 'cim', i.cim, 'data_iniciacao', i.data_iniciacao, 'data_elevacao', i.data_elevacao)
                   order by i.nome)
  into v_lista from public.irmaos i where i.id = any(p_irmaos);
  v_doc := private.emitir_documento(p_loja,
    case p_tipo when 'elevacao' then 'Pedido de placet de elevação' else 'Pedido de placet de exaltação' end,
    'placet_' || p_tipo,
    jsonb_build_object('irmaos', v_lista, 'nome', '', 'finalidade', '', 'grau', v_grau, 'mestre_instalado', false, 'situacao', 'ativo'),
    p_assinantes, 'placet_grau', v_id);
  update public.placets_grau set documento_id = v_doc where id = v_id;
  return v_id;
end $$;

create function public.registrar_placet_grau(p_id uuid, p_numero text, p_data date, p_arquivo text, p_cerimonia date) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.placets_grau;
begin
  select * into g from public.placets_grau where id = p_id for update;
  if g.id is null or not private.pode_placet_grau(g.loja_id) then raise exception 'Sem permissão'; end if;
  if g.status not in ('pedido', 'placet') then raise exception 'Este pedido já foi encerrado'; end if;
  if nullif(trim(coalesce(p_numero, '')), '') is null or p_data is null then raise exception 'Informe número e data do placet'; end if;
  if p_arquivo is not null and (public.loja_do_caminho(p_arquivo) is distinct from g.loja_id or split_part(p_arquivo, '/', 2) <> 'placets') then
    raise exception 'Arquivo inválido';
  end if;
  update public.placets_grau set status = 'placet', placet_numero = trim(p_numero), placet_data = p_data,
         placet_arquivo = coalesce(p_arquivo, placet_arquivo), data_cerimonia = coalesce(p_cerimonia, data_cerimonia)
  where id = g.id;
end $$;

-- cerimônia realizada: sobe o grau de quem participou (os outros continuam no grau e podem entrar num próximo pedido)
create function public.concluir_placet_grau(p_id uuid, p_data date, p_irmaos uuid[]) returns int
language plpgsql security definer set search_path = '' as $$
declare g public.placets_grau; v_ok uuid[]; n int;
begin
  select * into g from public.placets_grau where id = p_id for update;
  if g.id is null or not public.tem_permissao(g.loja_id, 'graus.editar') then raise exception 'Só o Venerável e o Secretário alteram o grau'; end if;
  if g.status <> 'placet' then raise exception 'Registre o placet recebido antes da cerimônia'; end if;
  if p_data is null then raise exception 'Informe a data da cerimônia'; end if;
  v_ok := array(select x from unnest(p_irmaos) x where x = any(g.irmaos));
  if cardinality(v_ok) = 0 then raise exception 'Marque quem participou da cerimônia'; end if;
  perform set_config('malhete.sistema', 'on', true);
  if g.tipo = 'elevacao' then
    update public.irmaos set grau = 2, data_elevacao = p_data where id = any(v_ok) and grau = 1;
  else
    update public.irmaos set grau = 3, data_exaltacao = p_data where id = any(v_ok) and grau = 2;
  end if;
  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  update public.placets_grau set status = 'concluido', data_cerimonia = p_data, concluidos = v_ok where id = g.id;
  return n;
end $$;

create function public.cancelar_placet_grau(p_id uuid, p_motivo text) returns void
language plpgsql security definer set search_path = '' as $$
declare g public.placets_grau;
begin
  select * into g from public.placets_grau where id = p_id for update;
  if g.id is null or not private.pode_placet_grau(g.loja_id) then raise exception 'Sem permissão'; end if;
  if g.status not in ('pedido', 'placet') then raise exception 'Este pedido já foi encerrado'; end if;
  if nullif(trim(coalesce(p_motivo, '')), '') is null then raise exception 'Informe o motivo'; end if;
  update public.placets_grau set status = 'cancelado', motivo_cancelamento = trim(p_motivo) where id = g.id;
end $$;

-- o arquivo do placet recebido fica em <loja>/placets/<id>/… no bucket secretaria (o Venerável também envia e lê)
create policy placets_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'secretaria' and split_part(name, '/', 2) = 'placets' and private.pode_placet_grau(public.loja_do_caminho(name)));
create policy placets_le on storage.objects for select to authenticated
  using (bucket_id = 'secretaria' and split_part(name, '/', 2) = 'placets' and private.pode_placet_grau(public.loja_do_caminho(name)));

revoke execute on function private.dados_oficio, private.emitir_documento, private.pode_placet_grau from public, anon, authenticated;
grant execute on function private.pode_placet_grau to authenticated;
revoke execute on function public.pedir_placet_processo, public.candidatos_placet_grau, public.abrir_placet_grau,
  public.registrar_placet_grau, public.concluir_placet_grau, public.cancelar_placet_grau from public, anon;
grant execute on function public.pedir_placet_processo, public.candidatos_placet_grau, public.abrir_placet_grau,
  public.registrar_placet_grau, public.concluir_placet_grau, public.cancelar_placet_grau to authenticated;
grant select on public.placets_grau to authenticated;
