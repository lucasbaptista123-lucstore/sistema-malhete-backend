-- Sistema Malhete: TRONCO PELO WHATSAPP, 2ª versão (14/11, depois da sessão de 13/11: os irmãos geravam o PIX e o
-- banco dava erro; o Lucas pediu "Outro valor" em conversa, como a justificativa de ausência).
--  1) "Outro valor" não manda mais link: pergunta o valor; o irmão responde "30" e recebe o PIX desse valor
--     (whatsapp_conversas.estado 'tronco_valor', ligada ao convite; whatsapp_tronco_texto lê a resposta).
--  2) O PIX vai num botão "Copiar código PIX" (o webhook usa o botão de copiar da UazAPI): o texto solto tinha o
--     e-mail da chave (o WhatsApp oferecia "copiar e-mail" e copiava só um pedaço) e "***" (negrito do WhatsApp).
--  3) Mensagem do convite reescrita ("Ir∴ Fulano, obrigado pela presença na sessão de hoje…").

alter table public.whatsapp_conversas alter column destinatario_id drop not null;
alter table public.whatsapp_conversas add column tronco_convite_id uuid references public.tronco_convites(id) on delete cascade;
create index on public.whatsapp_conversas (tronco_convite_id);
alter table public.whatsapp_conversas drop constraint whatsapp_conversas_estado_check;
alter table public.whatsapp_conversas add constraint whatsapp_conversas_estado_check
  check (estado = any (array['motivo_rsvp', 'justificativa', 'tronco_valor']));

CREATE OR REPLACE FUNCTION public.whatsapp_texto(p_loja uuid, p_telefone text, p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.whatsapp_conversas;
  d public.envio_destinatarios;
  e public.envios;
  v_txt text := lower(trim(coalesce(p_texto, '')));
  v_resp text;
begin
  if v_txt = '' then return null; end if;

  v_resp := case
    when v_txt in ('1', 'sim', 'vou', 'confirmo', 'presente') then 'rsvp:sim'
    when v_txt in ('2', 'não', 'nao', 'não vou', 'nao vou', 'não posso', 'nao posso') then 'rsvp:nao'
  end;
  if v_resp is not null then
    select d2.* into d from public.envio_destinatarios d2
    join public.envios e2 on e2.id = d2.envio_id and e2.tipo = 'convocacao'
    join public.sessoes s on s.id = e2.sessao_id and s.status = 'agendada' and s.data >= current_date
    where d2.loja_id = p_loja and public.tel_chave(d2.telefone) = public.tel_chave(p_telefone)
    order by e2.criado_em desc limit 1;
    if d.id is not null then
      return public.whatsapp_botao(p_loja, p_telefone, v_resp || ':' || d.token);
    end if;
  end if;

  -- a conversa do Tronco (valor) é respondida por whatsapp_tronco_texto
  select * into c from public.whatsapp_conversas where loja_id = p_loja and telefone = public.tel_chave(p_telefone) and expira_em > now()
    and estado <> 'tronco_valor';
  if c.loja_id is null then return null; end if;

  select * into d from public.envio_destinatarios where id = c.destinatario_id;
  select * into e from public.envios where id = d.envio_id;
  delete from public.whatsapp_conversas where loja_id = c.loja_id and telefone = c.telefone;

  if c.estado = 'motivo_rsvp' then
    update public.confirmacoes set motivo = left(trim(p_texto), 1000)
    where sessao_id = e.sessao_id and irmao_id = d.irmao_id and resposta = 'nao_vou' and motivo is null;
    return 'Obrigado, irmão. Registrado.';
  end if;

  perform private.registrar_justificativa(e.loja_id, e.sessao_id, d.irmao_id, p_texto, 'whatsapp');
  return 'Obrigado, irmão. Sua justificativa foi registrada para conhecimento do Venerável Mestre.';
end $function$
;

/** Valor escrito pelo irmão: "30", "R$ 30,00", "50 reais", "1.000", "25,5". Nulo se não der para ler. */
create function private.ler_valor_texto(p text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare m text;
begin
  m := (regexp_match(coalesce(p, ''), '\d[\d.,]*'))[1];
  if m is null then return null; end if;
  m := regexp_replace(m, '[.,]+$', '');
  if m ~ ',' then m := replace(replace(m, '.', ''), ',', '.');
  elsif m ~ '^\d{1,3}(\.\d{3})+$' then m := replace(m, '.', '');
  end if;
  if m !~ '^\d+(\.\d{1,2})?$' then return null; end if;
  return round(m::numeric, 2);
end $$;

CREATE OR REPLACE FUNCTION public.tronco_enviar(p_sessao uuid, p_irmaos uuid[], p_quando timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  ts public.tronco_sessoes;
  pix jsonb;
  vals numeric[];
  v_quando timestamptz := case when p_quando is null or p_quando <= now() + interval '1 minute' then null else p_quando end;
  i record;
  cv public.tronco_convites;
  v_tel text;
  v_bot text[];
  v_not uuid;
  n_fila int := 0;
  n_sem int := 0;
  n_ja int := 0;
begin
  select * into s from public.sessoes where id = p_sessao;
  if s.id is null or not public.tem_permissao(s.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro envia o Tronco'; end if;
  if v_quando is not null and v_quando > now() + interval '7 days' then raise exception 'Agende para no máximo 7 dias'; end if;
  pix := private.tronco_pix_dados(s.loja_id);
  if pix->>'chave' is null then raise exception 'Cadastre a chave PIX em Tesouraria → Recebimento e PIX'; end if;
  vals := array(select jsonb_array_elements_text(pix->'valores')::numeric);

  insert into public.tronco_sessoes (loja_id, sessao_id, criado_por) values (s.loja_id, s.id, auth.uid())
  on conflict (sessao_id) do nothing;
  select * into ts from public.tronco_sessoes where sessao_id = s.id;
  if v_quando is not null then update public.tronco_sessoes set agendado_para = v_quando where id = ts.id; end if;

  for i in select ir.id, ir.nome, ir.telefone from public.irmaos ir
           where ir.loja_id = s.loja_id and ir.id = any (p_irmaos) and ir.situacao in ('ativo', 'licenciado') loop
    if exists (select 1 from public.tronco_convites where tronco_sessao_id = ts.id and irmao_id = i.id) then
      n_ja := n_ja + 1;
      continue;
    end if;
    insert into public.tronco_convites (loja_id, tronco_sessao_id, irmao_id) values (s.loja_id, ts.id, i.id) returning * into cv;
    v_tel := nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '');
    v_bot := array(select private.valor_curto(x) || '|tronco:' || x::text || ':' || cv.token from unnest(vals[1:2]) x)
             || ('Outro valor|tronco:outro:' || cv.token);
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status, botoes, enviar_apos)
    values (s.loja_id, i.id, 'tronco', cv.id,
      format(E'Ir∴ %s, obrigado pela presença na sessão %s.\n\nPara contribuir com o Tronco de Beneficência pelo '
             'PIX, escolha um valor abaixo ou toque em Outro valor. Sua contribuição é anônima: ninguém na Loja vê '
             'quanto cada irmão deu.', private.primeiro_nome(i.nome),
             case when s.data = (now() at time zone 'America/Sao_Paulo')::date then 'de hoje'
                  else 'de ' || to_char(s.data, 'DD/MM') end),
      v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end, v_bot, v_quando)
    returning id into v_not;
    update public.tronco_convites set notificacao_id = v_not where id = cv.id;
    if v_tel is null then n_sem := n_sem + 1; else n_fila := n_fila + 1; end if;
  end loop;
  return jsonb_build_object('na_fila', n_fila, 'sem_telefone', n_sem, 'ja_recebiam', n_ja, 'quando', v_quando);
end $$;

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
  return pix - 'valores' || jsonb_build_object('valor', c.valor, 'token', cv.token);
end $$;

/** Resposta em texto com o valor do Tronco (depois de "Outro valor"): devolve os dados do PIX ou o que dizer. */
create function public.whatsapp_tronco_texto(p_loja uuid, p_telefone text, p_texto text) returns jsonb
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
  return private.tronco_pix_dados(p_loja) - 'valores' || jsonb_build_object('valor', ct.valor, 'token', cv.token);
end $$;
revoke execute on function public.whatsapp_tronco_texto from public, anon, authenticated;
grant execute on function public.whatsapp_tronco_texto to service_role;

-- 4) "Confirmar no Tronco" com Asaas (e sem chave própria do Tronco) só confirma se o PIX entrou: todo PIX na chave
-- aparece no Asaas, então não achar = não pagou (ou ainda não chegou). Antes lançava na conta Tronco mesmo assim
-- (sessão de 13/11: R$ 50 confirmados sem PIX). Sem Asaas, lança na conta Tronco como sempre.
CREATE OR REPLACE FUNCTION public.decidir_tronco(p_id uuid, p_confirmar boolean, p_data date DEFAULT CURRENT_DATE)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.tronco_contribuicoes;
  v_conta uuid;
  v_lanc uuid;
  v_pix uuid;
begin
  select * into c from public.tronco_contribuicoes where id = p_id for update;
  if c.id is null or not public.tem_permissao(c.loja_id, 'tronco.editar') then raise exception 'Só o Tesoureiro confirma o Tronco'; end if;
  if c.status = 'confirmada' then raise exception 'Já confirmada'; end if;
  if p_confirmar then
    -- o PIX já entrou pelo Asaas sem ser reconhecido: o mais antigo com o mesmo valor, de um dia antes a 5 dias depois
    select l.id into v_pix from public.lancamentos l
    where l.loja_id = c.loja_id and l.tipo = 'receita' and l.valor = c.valor
      and l.data between c.informado_em::date - 1 and c.informado_em::date + 5
      and private.pix_sem_dono(l.id)
    order by l.data, l.criado_em limit 1;
    if v_pix is not null then
      perform private.tronco_do_lancamento(v_pix, c.id);
      return;
    end if;
    if (private.tronco_pix_dados(c.loja_id)->>'automatico')::boolean then
      raise exception 'Não achei um PIX de % no Asaas. Se o irmão pagou agora, espere aparecer em Movimentações; se deu em dinheiro, lance em Dinheiro do saco.', private.moeda(c.valor);
    end if;
    select id into v_conta from public.contas_financeiras where loja_id = c.loja_id and tipo = 'tronco' and ativa limit 1;
    if v_conta is null then raise exception 'A loja não tem conta Tronco ativa'; end if;
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, data, descricao, documento)
    values (c.loja_id, v_conta,
            (select id from public.categorias_financeiras where loja_id = c.loja_id and codigo = 'tronco'),
            'receita', c.valor, coalesce(p_data, current_date), 'Tronco de Beneficência (PIX)', c.txid)
    returning id into v_lanc;
  end if;
  update public.tronco_contribuicoes
  set status = case when p_confirmar then 'confirmada' else 'nao_localizada' end,
      decidido_por = auth.uid(), decidido_em = now(), lancamento_id = v_lanc
  where id = c.id;
end $function$;
