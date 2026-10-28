-- Atestado de frequência com os números reais: frequência dos últimos 12 meses (sessões realizadas do grau do
-- irmão; % = presenças / (sessões - justificadas), a mesma regra do relatório). Vai no conteúdo do documento.
create or replace function private.frequencia_12m(p_irmao uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with h as (select (now() at time zone 'America/Sao_Paulo')::date as d)
  select jsonb_build_object('de', (h.d - interval '12 months')::date, 'ate', h.d,
           'sessoes', c.sessoes, 'presentes', c.presentes, 'justificadas', c.justificadas,
           'percentual', round(100.0 * c.presentes / nullif(c.sessoes - c.justificadas, 0), 1))
  from h, public.irmaos i
  cross join lateral (
    select count(*)::int as sessoes,
           count(*) filter (where p.situacao = 'presente')::int as presentes,
           count(*) filter (where p.situacao = 'justificada')::int as justificadas
    from public.sessoes s
    left join public.presencas p on p.sessao_id = s.id and p.irmao_id = i.id
    where s.loja_id = i.loja_id and s.status = 'realizada' and s.grau <= i.grau
      and s.data > h.d - interval '12 months' and s.data <= h.d
  ) c
  where i.id = p_irmao
$$;
revoke execute on function private.frequencia_12m from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.decidir_pedido_documento(p_pedido uuid, p_aprovar boolean, p_observacao text DEFAULT NULL::text, p_assinantes jsonb DEFAULT '[]'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                             'cidade', v_cidade, 'tipo_codigo', t.codigo,
                             'loja_nome', (select trim(nome) from public.lojas where id = p.loja_id),
                             'loja_numero', (select numero from public.lojas where id = p.loja_id),
                             'data_elevacao', i.data_elevacao, 'data_exaltacao', i.data_exaltacao,
                             'frequencia', private.frequencia_12m(i.id)),
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
end $function$;
