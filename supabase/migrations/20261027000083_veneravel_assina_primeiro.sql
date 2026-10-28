-- O Venerável assina PRIMEIRO: é ele quem abre o processo e autoriza o documento (decisão do Lucas, 27/10).
-- Vale para os padrões das Lojas novas e para os tipos já existentes; em cada pedido ele ainda pode reordenar.
CREATE OR REPLACE FUNCTION private.tipos_documento_padrao(p_loja uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.tipos_documento (loja_id, codigo, nome, assinantes, exige_quitacao, ordem) values
    (p_loja, 'regularidade', 'Declaração de regularidade', array['veneravel', 'tesoureiro', 'chanceler'], true, 1),
    (p_loja, 'quite_placet', 'Quite placet', array['veneravel', 'secretario', 'tesoureiro'], true, 2),
    (p_loja, 'atestado_frequencia', 'Atestado de frequência', array['veneravel', 'chanceler'], false, 3),
    (p_loja, 'carta_visita', 'Carta de apresentação (visita)', array['veneravel', 'secretario'], false, 4),
    (p_loja, 'outro', 'Outro documento', array['veneravel', 'secretario'], false, 9)
  on conflict do nothing
$function$;

update public.tipos_documento
set assinantes = array['veneravel'] || array_remove(assinantes, 'veneravel')
where 'veneravel' = any(assinantes) and assinantes[1] <> 'veneravel';
