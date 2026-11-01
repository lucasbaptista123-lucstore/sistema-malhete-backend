-- Mensalidades geradas em lote (ano todo) com o Asaas ligado: sem isso, cada irmão receberia uma mensagem por
-- cobrança criada (até 12 de uma vez). Agora o aviso de "cobrança criada" só sai para o que vence em até 20 dias;
-- as demais são lembradas pela régua de cobrança perto do vencimento (1/11).
CREATE OR REPLACE FUNCTION private.aviso_cobranca()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.asaas_link is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then return new; end if;
  -- gerou o ano todo de uma vez: só avisa na criação o que vence nos próximos 20 dias; o resto a régua lembra perto do vencimento
  if new.vencimento > current_date + 20 then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), '', ''));
  perform private.notificar_pix(new.loja_id, new.irmao_id, 'cobranca', array[new.id]);
  return new;
end $function$

;
