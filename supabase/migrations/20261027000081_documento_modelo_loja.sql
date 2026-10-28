-- Sistema Malhete: documentos no modelo da Loja (cabeçalho e rodapé próprios) e regularidade assinada por
-- Tesoureiro (metais), Chanceler (frequência) e Venerável, como no modelo da Orvalho de Hermon.
alter table public.lojas add column doc_cabecalho text, add column doc_rodape text;

update public.lojas set
  doc_cabecalho = E'ARLS ORVALHO DE HERMON 2966\nFILIADA AO GRANDE ORIENTE DO BRASIL DE SÃO PAULO\nFEDERADA AO GRANDE ORIENTE DO BRASIL\nFUNDADA EM 12/08/1995 · RITO ESCOCÊS ANTIGO E ACEITO\nCNPJ 67.124.342/0001-94',
  doc_rodape = E'PALÁCIO MAÇÔNICO DUQUE DE CAXIAS\nAvenida Dr. Mário Galvão, 430 · CEP 12209-004 · Jd. Bela Vista · São José dos Campos\nSessões na 2ª e na 4ª sexta-feira do mês, às 20 horas'
where numero::text = '2966' and nome ilike '%orvalho%' and doc_cabecalho is null;

update public.tipos_documento set assinantes = array['tesoureiro', 'chanceler', 'veneravel']
where codigo = 'regularidade' and assinantes = array['secretario', 'tesoureiro', 'veneravel'];

CREATE OR REPLACE FUNCTION private.tipos_documento_padrao(p_loja uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.tipos_documento (loja_id, codigo, nome, assinantes, exige_quitacao, ordem) values
    (p_loja, 'regularidade', 'Declaração de regularidade', array['tesoureiro', 'chanceler', 'veneravel'], true, 1),
    (p_loja, 'quite_placet', 'Quite placet', array['secretario', 'tesoureiro', 'veneravel'], true, 2),
    (p_loja, 'atestado_frequencia', 'Atestado de frequência', array['chanceler', 'veneravel'], false, 3),
    (p_loja, 'carta_visita', 'Carta de apresentação (visita)', array['secretario', 'veneravel'], false, 4),
    (p_loja, 'outro', 'Outro documento', array['secretario', 'veneravel'], false, 9)
  on conflict do nothing
$function$;

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
                             'loja_numero', (select numero from public.lojas where id = p.loja_id)),
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
