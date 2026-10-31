-- Assinatura eletrônica SIMPLES dentro do sistema (31/10; o Grande Oriente aceita, segundo o Venerável da Orvalho).
-- Lei 14.063/2020, art. 4º, I. O irmão lê, marca "Li e concordo" e confirma com um código de 6 dígitos enviado pelo
-- WhatsApp da Loja (sem custo; SMS teria custo) ou, sem WhatsApp, com a senha do sistema. O sistema registra nome, CPF,
-- data/hora, IP, aparelho, meio de confirmação e o hash SHA-256 do PDF. Ao final, o PDF ganha a página "Registro de
-- assinaturas eletrônicas" com um código de verificação público (/verificar/<código>).
-- Modo por TIPO de documento (padrão definido pelo Venerável) e por documento (troca enquanto ninguém assinou).
alter table public.tipos_documento add column modo_assinatura text not null default 'govbr' check (modo_assinatura in ('govbr', 'simples'));
alter table public.documentos_emitidos
  add column modo_assinatura text not null default 'govbr' check (modo_assinatura in ('govbr', 'simples')),
  add column codigo_verificacao text unique,
  add column hash_final text;
alter table public.documento_assinaturas
  add column codigo_hash text,
  add column codigo_expira timestamptz,
  add column codigo_tentativas int not null default 0,
  add column ip text,
  add column dispositivo text,
  add column hash_documento text,
  add column confirmado_via text check (confirmado_via in ('whatsapp', 'senha', 'govbr'));

-- o modo do tipo vira o modo do documento na aprovação do pedido
create function private.modo_do_tipo() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.tipo_documento_id is not null then
    new.modo_assinatura := coalesce((select modo_assinatura from public.tipos_documento where id = new.tipo_documento_id), new.modo_assinatura);
  end if;
  if new.codigo_verificacao is null then
    new.codigo_verificacao := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  end if;
  return new;
end $$;
create trigger modo_assinatura before insert on public.documentos_emitidos for each row execute function private.modo_do_tipo();
update public.documentos_emitidos set codigo_verificacao = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)) where codigo_verificacao is null;

-- Venerável/Secretaria trocam o modo de um documento enquanto ninguém assinou
create function public.definir_modo_assinatura(p_doc uuid, p_modo text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos;
begin
  select * into d from public.documentos_emitidos where id = p_doc for update;
  if d.id is null or not (public.tem_permissao(d.loja_id, 'loja.config') or public.tem_permissao(d.loja_id, 'secretaria.editar')) then
    raise exception 'Sem permissão';
  end if;
  if p_modo not in ('govbr', 'simples') then raise exception 'Modo inválido'; end if;
  if exists (select 1 from public.documento_assinaturas where documento_id = d.id and status = 'assinado') then
    raise exception 'Alguém já assinou: o modo não pode mais mudar';
  end if;
  update public.documentos_emitidos set modo_assinatura = p_modo where id = d.id;
  perform private.evento_documento(d.id, case p_modo when 'simples' then 'Modo de assinatura: simples (no sistema, com código)' else 'Modo de assinatura: gov.br' end);
end $$;

-- a assinatura simples conferida (chamado pela função `assinaturas`, com service_role)
create function public.registrar_assinatura_simples(p_assinatura uuid, p_via text, p_ip text, p_dispositivo text, p_hash text) returns text
language plpgsql security definer set search_path = '' as $$
declare a public.documento_assinaturas; d public.documentos_emitidos; i public.irmaos; v_prox uuid;
begin
  select * into a from public.documento_assinaturas where id = p_assinatura for update;
  if a.id is null or a.status <> 'vez' then raise exception 'Assinatura fora da vez'; end if;
  select * into d from public.documentos_emitidos where id = a.documento_id;
  if d.modo_assinatura <> 'simples' then raise exception 'Este documento é assinado pelo gov.br'; end if;
  select * into i from public.irmaos where id = a.irmao_id;
  update public.documento_assinaturas
  set status = 'assinado', assinado_em = now(), cpf_assinatura = regexp_replace(coalesce(i.cpf, ''), '\D', '', 'g'),
      nome_assinatura = i.nome, confirmado_via = p_via, ip = p_ip, dispositivo = left(p_dispositivo, 300), hash_documento = p_hash,
      codigo_hash = null, codigo_expira = null
  where id = a.id;
  perform private.evento_documento(a.documento_id,
    format('%s assinou no sistema (assinatura eletrônica simples, confirmada por %s)', a.cargo_nome,
           case p_via when 'whatsapp' then 'código no WhatsApp' else 'senha' end));
  select id into v_prox from public.documento_assinaturas where documento_id = a.documento_id and status = 'aguardando' order by ordem limit 1;
  if v_prox is not null then
    update public.documento_assinaturas set status = 'vez' where id = v_prox;
    perform private.avisar_assinante(v_prox);
    return 'próximo avisado';
  end if;
  return 'último';
end $$;

-- fecha o documento simples com o PDF final (com a página de registro) gerado pela função `assinaturas`
create function public.concluir_documento_simples(p_doc uuid, p_caminho text, p_hash text) returns void
language plpgsql security definer set search_path = '' as $$
declare d public.documentos_emitidos; v_nome text;
begin
  select * into d from public.documentos_emitidos where id = p_doc for update;
  if d.id is null or d.situacao = 'concluido' then return; end if;
  if exists (select 1 from public.documento_assinaturas where documento_id = d.id and status <> 'assinado') then
    raise exception 'Ainda há assinaturas pendentes';
  end if;
  update public.documentos_emitidos set situacao = 'concluido', concluido_em = now(), arquivo_atual = p_caminho, hash_final = p_hash
  where id = d.id;
  update public.pedidos set status = 'aprovado' where id = d.pedido_id;
  perform private.evento_documento(d.id, 'Todas as assinaturas concluídas (registro de assinaturas anexado ao PDF)');
  if d.irmao_id is not null then
    select nome into v_nome from public.irmaos where id = d.irmao_id;
    perform private.notificar(d.loja_id, d.irmao_id, 'documento', d.id,
      format('Olá, %s! Seu documento "%s" está pronto e assinado. Baixe em Meus pedidos.', private.primeiro_nome(v_nome), d.tipo));
  end if;
end $$;

-- verificação pública pelo código impresso no PDF (sem login): o que foi assinado, por quem e quando
create function public.verificar_documento(p_codigo text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'tipo', d.tipo, 'numero', d.numero, 'emitido_em', d.emitido_em, 'situacao', d.situacao, 'concluido_em', d.concluido_em,
    'modo', d.modo_assinatura, 'hash_final', d.hash_final,
    'loja', (select trim(nome) || coalesce(' nº ' || numero, '') from public.lojas where id = d.loja_id),
    'assinaturas', (select coalesce(jsonb_agg(jsonb_build_object(
        'cargo', a.cargo_nome, 'nome', a.nome_assinatura, 'em', a.assinado_em, 'via', a.confirmado_via,
        'cpf', case when a.cpf_assinatura is not null then '***.' || substr(a.cpf_assinatura, 4, 3) || '.' || substr(a.cpf_assinatura, 7, 3) || '-**' end)
        order by a.ordem), '[]') from public.documento_assinaturas a where a.documento_id = d.id and a.status = 'assinado'))
  from public.documentos_emitidos d where d.codigo_verificacao = upper(trim(p_codigo)) and d.situacao <> 'emitido'
$$;

revoke execute on function public.registrar_assinatura_simples, public.concluir_documento_simples from public, anon, authenticated;
grant execute on function public.registrar_assinatura_simples, public.concluir_documento_simples to service_role;
revoke execute on function public.definir_modo_assinatura from public, anon;
grant execute on function public.definir_modo_assinatura to authenticated;
revoke execute on function public.verificar_documento from public;
grant execute on function public.verificar_documento to anon, authenticated;
