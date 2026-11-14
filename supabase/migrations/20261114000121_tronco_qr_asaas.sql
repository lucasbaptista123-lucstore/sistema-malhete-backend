-- Sistema Malhete: TRONCO PELO QR ESTÁTICO DO ASAAS (14/11). Na sessão de 13/11 os irmãos geravam o PIX do Tronco e o
-- banco respondia "O banco de destino não pode processar o Pix agora": o Asaas recusa código PIX montado fora dele
-- (testado pelo Lucas com R$ 1,00, com e sem "***"); o PIX digitado na chave funciona. Agora, com Asaas, o sistema pede
-- ao Asaas um QR Code estático do valor (POST /pix/qrCodes/static, sem cobrança antes) e guarda o id e o copia e cola
-- na contribuição; o pagamento chega com pixQrCodeId e entra no Tronco sozinho (anônimo), sem depender de CPF.
-- Sem Asaas (ou com chave própria do Tronco), continua o código montado pelo sistema.

alter table public.tronco_contribuicoes add column asaas_qr_id text, add column pix_copia_cola text;
create index on public.tronco_contribuicoes (asaas_qr_id);

CREATE OR REPLACE FUNCTION public.asaas_espelhar_pagamento(p_loja uuid, p_evento text, p_pg jsonb, p_cliente jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_conectado date := (select criado_em::date from public.integracoes_asaas where loja_id = p_loja);
  v_quando date := coalesce(nullif(p_pg->>'paymentDate', '')::date, nullif(p_pg->>'clientPaymentDate', '')::date,
                            nullif(p_pg->>'dateCreated', '')::date, current_date);
  v_res text;
begin
  -- histórico (antes da conexão): espelha em silêncio
  if v_conectado is not null and v_quando < v_conectado then
    perform set_config('malhete.sem_avisos', 'on', true);
  end if;
  -- PIX do Tronco pelo QR estático que o sistema pediu ao Asaas: o pagamento traz o pixQrCodeId do QR
  if coalesce(p_pg->>'externalReference', '') = '' and coalesce(p_pg->>'pixQrCodeId', '') <> '' then
    select 'tronco:' || id into v_res from public.tronco_contribuicoes
    where loja_id = p_loja and asaas_qr_id = p_pg->>'pixQrCodeId' limit 1;
    if v_res is not null then
      p_pg := p_pg || jsonb_build_object('externalReference', v_res);
      v_res := null;
    end if;
  end if;
  -- PIX do Tronco gerado pelo sistema (externalReference tronco:<contribuição>)
  if coalesce(p_pg->>'externalReference', '') like 'tronco:%' then
    v_res := private.tronco_asaas(p_loja, p_evento, p_pg);
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  -- PIX direto na chave da Loja vindo de um irmão (CPF): Tronco ou baixa das contas abertas dele, sem cobrança e sem taxa
  v_res := private.pix_irmao(p_loja, p_evento, p_pg, p_cliente);
  if v_res is not null then
    perform set_config('malhete.sem_avisos', 'off', true);
    return v_res;
  end if;
  v_res := private.asaas_espelhar_base(p_loja, p_evento, p_pg, p_cliente);
  perform set_config('malhete.sem_avisos', 'off', true);
  return v_res;
end $function$
;

CREATE OR REPLACE FUNCTION public.whatsapp_tronco(p_loja uuid, p_telefone text, p_token text, p_opcao text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cv public.tronco_convites;
  c public.tronco_contribuicoes;
  pix jsonb;
  v_tel text;
begin
  cv := private.tronco_convite_valido(p_token);
  if cv.id is null or cv.loja_id <> p_loja then
    return jsonb_build_object('texto', 'Este convite para o Tronco já não vale. Contribua pelo sistema, em Tronco de Beneficência.');
  end if;
  select telefone into v_tel from public.irmaos where id = cv.irmao_id;
  if public.tel_chave(p_telefone) is distinct from public.tel_chave(v_tel) then return null; end if;
  -- "Outro valor": pergunta o valor e espera a resposta (como a justificativa de ausência)
  if p_opcao = 'outro' then
    insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id, tronco_convite_id, expira_em)
    values (p_loja, public.tel_chave(p_telefone), 'tronco_valor', null, cv.id, now() + interval '12 hours')
    on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = null,
      tronco_convite_id = excluded.tronco_convite_id, expira_em = excluded.expira_em;
    return jsonb_build_object('texto', 'Qual valor você quer dar ao Tronco? Responda só com o número, por exemplo: 30');
  end if;
  if p_opcao = 'pago' then
    update public.tronco_contribuicoes set status = 'informada', informado_em = now()
    where id = (select id from public.tronco_contribuicoes where tronco_sessao_id = cv.tronco_sessao_id
                and irmao_id = cv.irmao_id and status = 'aguardando' order by informado_em desc limit 1);
    return jsonb_build_object('texto', 'Obrigado, irmão! A Tesouraria vai conferir no extrato.');
  end if;
  if p_opcao !~ '^[0-9]+(\.[0-9]{1,2})?$' then return null; end if;
  c := private.tronco_contribuir(cv, p_opcao::numeric);
  pix := private.tronco_pix_dados(p_loja);
  return pix - 'valores' || jsonb_build_object('valor', c.valor, 'token', cv.token, 'contrib_id', c.id,
    'pix_copia_cola', c.pix_copia_cola);
end $$;


CREATE OR REPLACE FUNCTION public.whatsapp_tronco_texto(p_loja uuid, p_telefone text, p_texto text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.whatsapp_conversas;
  cv public.tronco_convites;
  ct public.tronco_contribuicoes;
  v numeric;
  t text := lower(trim(coalesce(p_texto, '')));
begin
  select * into c from public.whatsapp_conversas
  where loja_id = p_loja and telefone = public.tel_chave(p_telefone) and estado = 'tronco_valor' and expira_em > now();
  if c.loja_id is null then return null; end if;
  if t in ('cancelar', 'cancela', 'não', 'nao', 'desisto', 'sair', 'deixa', 'esquece') then
    delete from public.whatsapp_conversas where loja_id = c.loja_id and telefone = c.telefone;
    return jsonb_build_object('texto', 'Tudo bem, irmão. Se mudar de ideia, toque de novo em Outro valor.');
  end if;
  v := private.ler_valor_texto(p_texto);
  if v is null or v <= 0 or v > 10000 then
    return jsonb_build_object('texto', 'Não entendi o valor. Responda só com o número, por exemplo: 30');
  end if;
  select * into cv from public.tronco_convites where id = c.tronco_convite_id;
  delete from public.whatsapp_conversas where loja_id = c.loja_id and telefone = c.telefone;
  cv := private.tronco_convite_valido(cv.token);
  if cv.id is null then
    return jsonb_build_object('texto', 'Este convite para o Tronco já não vale. Contribua pelo sistema, em Tronco de Beneficência.');
  end if;
  ct := private.tronco_contribuir(cv, v);
  return private.tronco_pix_dados(p_loja) - 'valores' || jsonb_build_object('valor', ct.valor, 'token', cv.token,
    'contrib_id', ct.id, 'pix_copia_cola', ct.pix_copia_cola);
end $$;

/** Para a função tronco-qr e o WhatsApp (só servidor): o que é preciso para pedir o QR ao Asaas. */
create function public.tronco_qr_dados(p_contrib uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('loja_id', c.loja_id, 'valor', c.valor, 'status', c.status,
    'pix_copia_cola', c.pix_copia_cola, 'asaas_qr_id', c.asaas_qr_id)
    || (private.tronco_pix_dados(c.loja_id) - 'valores')
  from public.tronco_contribuicoes c where c.id = p_contrib
$$;
revoke execute on function public.tronco_qr_dados from public, anon, authenticated;
grant execute on function public.tronco_qr_dados to service_role;

create function public.tronco_qr_guardar(p_contrib uuid, p_qr_id text, p_payload text) returns void
language sql security definer set search_path = '' as $$
  update public.tronco_contribuicoes set asaas_qr_id = p_qr_id, pix_copia_cola = p_payload
  where id = p_contrib and asaas_qr_id is null
$$;
revoke execute on function public.tronco_qr_guardar from public, anon, authenticated;
grant execute on function public.tronco_qr_guardar to service_role;

/** Quem pode pedir o QR de uma contribuição: o próprio irmão (logado) ou quem tem o convite (token). Devolve a Loja. */
create function public.tronco_qr_permitido(p_contrib uuid, p_token text default null) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.tronco_contribuicoes;
  cv public.tronco_convites;
begin
  select * into c from public.tronco_contribuicoes where id = p_contrib and status in ('aguardando', 'informada');
  if c.id is null then return null; end if;
  if p_token is not null then
    cv := private.tronco_convite_valido(p_token);
    if cv.id is not null and cv.irmao_id = c.irmao_id and cv.tronco_sessao_id = c.tronco_sessao_id then return c.loja_id; end if;
    return null;
  end if;
  if c.irmao_id = public.meu_irmao_id(c.loja_id) then return c.loja_id; end if;
  return null;
end $$;
revoke execute on function public.tronco_qr_permitido from public;
grant execute on function public.tronco_qr_permitido to anon, authenticated, service_role;
