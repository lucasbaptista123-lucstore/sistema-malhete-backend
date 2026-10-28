-- Sistema Malhete — resposta única à convocação: vale a primeira (WhatsApp ou sistema). Depois dela o outro
-- canal só informa o que já foi respondido; mudar de ideia é com o Chanceler (que marca a presença).
-- Exceção: quem disse "não vou" sem motivo ainda pode mandar o motivo, por qualquer canal.

create or replace function private.registrar_confirmacao(p_loja uuid, p_sessao uuid, p_irmao uuid, p_resposta text, p_motivo text, p_canal text)
returns void
language sql security definer set search_path = '' as $$
  insert into public.confirmacoes (loja_id, sessao_id, irmao_id, resposta, motivo, canal)
  values (p_loja, p_sessao, p_irmao, p_resposta, nullif(left(trim(coalesce(p_motivo, '')), 1000), ''), p_canal)
  on conflict (sessao_id, irmao_id) do nothing
$$;

-- texto do que já foi respondido, para o outro canal avisar
create function private.resposta_existente(p_sessao uuid, p_irmao uuid) returns text
language sql stable security definer set search_path = '' as $$
  select format('Você já respondeu %s em %s: %s.',
                case c.canal when 'whatsapp' then 'pelo WhatsApp' else 'pelo sistema' end,
                to_char(c.respondido_em at time zone 'America/Sao_Paulo', 'DD/MM "às" HH24:MI'),
                case c.resposta when 'vou' then 'presença confirmada' else 'não poderá comparecer' end)
  from public.confirmacoes c where c.sessao_id = p_sessao and c.irmao_id = p_irmao
$$;

create or replace function public.responder_convocacao(p_sessao uuid, p_resposta text, p_motivo text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  v_irmao uuid;
  c public.confirmacoes;
begin
  select * into s from public.sessoes where id = p_sessao;
  v_irmao := public.meu_irmao_id(s.loja_id);
  if s.id is null or v_irmao is null or not public.pode_ver_grau(s.loja_id, s.grau) then raise exception 'Sessão não encontrada'; end if;
  if s.status <> 'agendada' then raise exception 'A sessão já foi realizada ou cancelada'; end if;
  if p_resposta not in ('vou', 'nao_vou') then raise exception 'Resposta inválida'; end if;
  select * into c from public.confirmacoes where sessao_id = p_sessao and irmao_id = v_irmao;
  if c.id is not null then
    if c.resposta = 'nao_vou' and p_resposta = 'nao_vou' and c.motivo is null and nullif(trim(coalesce(p_motivo, '')), '') is not null then
      update public.confirmacoes set motivo = left(trim(p_motivo), 1000) where id = c.id;
      return;
    end if;
    raise exception '% Para mudar, fale com o Chanceler.', private.resposta_existente(p_sessao, v_irmao);
  end if;
  perform private.registrar_confirmacao(s.loja_id, s.id, v_irmao, p_resposta, p_motivo, 'sistema');
end $$;

create or replace function public.whatsapp_botao(p_loja uuid, p_telefone text, p_botao text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_acao text := split_part(p_botao, ':', 1) || ':' || split_part(p_botao, ':', 2);
  v_tok text := split_part(p_botao, ':', 3);
  d public.envio_destinatarios;
  e public.envios;
  s public.sessoes;
  c public.confirmacoes;
begin
  select * into d from public.envio_destinatarios where token = v_tok and loja_id = p_loja;
  if d.id is null then return null; end if;
  select * into e from public.envios where id = d.envio_id;
  select * into s from public.sessoes where id = e.sessao_id;

  if v_acao in ('rsvp:sim', 'rsvp:nao') and e.tipo = 'convocacao' then
    if s.status <> 'agendada' then
      return 'Esta sessão já foi ' || case s.status when 'cancelada' then 'cancelada' else 'realizada' end || '.';
    end if;
    select * into c from public.confirmacoes where sessao_id = s.id and irmao_id = d.irmao_id;
    if c.id is not null then
      -- disse "não vou" sem motivo: ainda pode mandar o motivo
      if c.resposta = 'nao_vou' and c.motivo is null and v_acao = 'rsvp:nao' then
        insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
        values (p_loja, public.tel_chave(p_telefone), 'motivo_rsvp', d.id)
        on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
        return private.resposta_existente(s.id, d.irmao_id) || ' Se quiser, responda com o motivo.';
      end if;
      return private.resposta_existente(s.id, d.irmao_id) || ' Para mudar, fale com o Chanceler.';
    end if;
  end if;

  if v_acao = 'rsvp:sim' and e.tipo = 'convocacao' then
    perform private.registrar_confirmacao(d.loja_id, e.sessao_id, d.irmao_id, 'vou', null, 'whatsapp');
    delete from public.whatsapp_conversas where loja_id = p_loja and telefone = public.tel_chave(p_telefone);
    return 'Obrigado, irmão. Sua presença está confirmada para ' || to_char(s.data, 'DD/MM') || '.';
  elsif v_acao = 'rsvp:nao' and e.tipo = 'convocacao' then
    perform private.registrar_confirmacao(d.loja_id, e.sessao_id, d.irmao_id, 'nao_vou', null, 'whatsapp');
    insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
    values (p_loja, public.tel_chave(p_telefone), 'motivo_rsvp', d.id)
    on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
    return 'Entendido, irmão. Se quiser, responda esta mensagem com o motivo, para conhecimento do Venerável Mestre.';
  elsif v_acao = 'just:ok' and e.tipo = 'justificativa' then
    insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
    values (p_loja, public.tel_chave(p_telefone), 'justificativa', d.id)
    on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
    return 'Por favor, escreva aqui o motivo da sua ausência.';
  end if;
  return null;
end $$;

-- o motivo mandado depois pelo WhatsApp só preenche se ainda estiver vazio (não troca um motivo já dado)
create or replace function public.whatsapp_texto(p_loja uuid, p_telefone text, p_texto text) returns text
language plpgsql security definer set search_path = '' as $$
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

  select * into c from public.whatsapp_conversas where loja_id = p_loja and telefone = public.tel_chave(p_telefone) and expira_em > now();
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
end $$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.whatsapp_texto, public.whatsapp_botao from public, anon, authenticated;
grant execute on function public.whatsapp_texto, public.whatsapp_botao to service_role;
