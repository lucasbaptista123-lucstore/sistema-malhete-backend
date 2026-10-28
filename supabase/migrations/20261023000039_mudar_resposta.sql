-- Sistema Malhete — o irmão pode MUDAR a resposta (sistema ou WhatsApp) enquanto a sessão estiver agendada.
-- Resposta igual continua bloqueada ("você já respondeu"); só a mudança passa, e fica registrada.
-- Quem disse "não vou" e foi marcado Presente pelo Chanceler sai da fila de justificativas do Venerável.

alter table public.confirmacoes add column resposta_anterior text, add column mudou_em timestamptz;

-- troca a resposta; "não vou" → "vou" limpa motivo e decisão do Venerável
create function private.mudar_confirmacao(p_id uuid, p_resposta text, p_motivo text, p_canal text) returns void
language sql security definer set search_path = '' as $$
  update public.confirmacoes
  set resposta_anterior = resposta, resposta = p_resposta, mudou_em = now(), respondido_em = now(), canal = p_canal,
      motivo = case when p_resposta = 'nao_vou' then nullif(left(trim(coalesce(p_motivo, '')), 1000), '') end,
      ciente_em = null, ciente_por = null, aceita = null, parecer = null
  where id = p_id
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
  if c.id is null then
    perform private.registrar_confirmacao(s.loja_id, s.id, v_irmao, p_resposta, p_motivo, 'sistema');
  elsif c.resposta <> p_resposta then
    perform private.mudar_confirmacao(c.id, p_resposta, p_motivo, 'sistema');
  elsif c.resposta = 'nao_vou' and c.motivo is null and nullif(trim(coalesce(p_motivo, '')), '') is not null then
    update public.confirmacoes set motivo = left(trim(p_motivo), 1000) where id = c.id;
  else
    raise exception '%', private.resposta_existente(p_sessao, v_irmao);
  end if;
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
  v_resp text;
begin
  select * into d from public.envio_destinatarios where token = v_tok and loja_id = p_loja;
  if d.id is null then return null; end if;
  select * into e from public.envios where id = d.envio_id;
  select * into s from public.sessoes where id = e.sessao_id;

  if v_acao in ('rsvp:sim', 'rsvp:nao') and e.tipo = 'convocacao' then
    if s.status <> 'agendada' then
      return 'Esta sessão já foi ' || case s.status when 'cancelada' then 'cancelada' else 'realizada' end || '.';
    end if;
    v_resp := case v_acao when 'rsvp:sim' then 'vou' else 'nao_vou' end;
    select * into c from public.confirmacoes where sessao_id = s.id and irmao_id = d.irmao_id;
    if c.id is not null and c.resposta = v_resp then
      if c.resposta = 'nao_vou' and c.motivo is null then
        insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
        values (p_loja, public.tel_chave(p_telefone), 'motivo_rsvp', d.id)
        on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
        return private.resposta_existente(s.id, d.irmao_id) || ' Se quiser, responda com o motivo.';
      end if;
      return private.resposta_existente(s.id, d.irmao_id);
    end if;
    if c.id is not null then
      perform private.mudar_confirmacao(c.id, v_resp, null, 'whatsapp');
    else
      perform private.registrar_confirmacao(d.loja_id, e.sessao_id, d.irmao_id, v_resp, null, 'whatsapp');
    end if;
    if v_resp = 'vou' then
      delete from public.whatsapp_conversas where loja_id = p_loja and telefone = public.tel_chave(p_telefone);
      return case when c.id is not null then 'Resposta alterada. ' else '' end
             || 'Obrigado, irmão. Sua presença está confirmada para ' || to_char(s.data, 'DD/MM') || '.';
    end if;
    insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
    values (p_loja, public.tel_chave(p_telefone), 'motivo_rsvp', d.id)
    on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
    return case when c.id is not null then 'Resposta alterada. ' else '' end
           || 'Entendido, irmão. Se quiser, responda esta mensagem com o motivo, para conhecimento do Venerável Mestre.';
  elsif v_acao = 'just:ok' and e.tipo = 'justificativa' then
    insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id)
    values (p_loja, public.tel_chave(p_telefone), 'justificativa', d.id)
    on conflict (loja_id, telefone) do update set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = now() + interval '3 days';
    return 'Por favor, escreva aqui o motivo da sua ausência.';
  end if;
  return null;
end $$;

-- fila do Venerável: some quem mudou para "vou" (já coberto: resposta deixa de ser nao_vou) e quem foi marcado Presente
create or replace function public.justificativas(p_loja uuid, p_todas boolean default false)
returns table (origem text, id uuid, sessao_id uuid, sessao_data date, irmao_id uuid, irmao text, texto text,
               via text, enviada_em timestamptz, ciente_em timestamptz, aceita boolean, parecer text)
language sql stable security definer set search_path = '' as $$
  select * from (
    select 'confirmacao'::text as origem, c.id, c.sessao_id, s.data as sessao_data, c.irmao_id, i.nome as irmao,
           c.motivo as texto, c.canal as via, c.respondido_em as enviada_em, c.ciente_em, c.aceita, c.parecer
    from public.confirmacoes c join public.sessoes s on s.id = c.sessao_id join public.irmaos i on i.id = c.irmao_id
    where c.loja_id = p_loja and c.resposta = 'nao_vou' and c.motivo is not null
      and not exists (select 1 from public.presencas p where p.sessao_id = c.sessao_id and p.irmao_id = c.irmao_id and p.situacao = 'presente')
    union all
    select 'presenca', p.id, p.sessao_id, s.data, p.irmao_id, i.nome, p.justificativa,
           case when p.justificada_pelo_irmao then p.justificada_via else 'chanceler' end, p.registrado_em,
           p.ciente_em, p.aceita, p.parecer
    from public.presencas p join public.sessoes s on s.id = p.sessao_id join public.irmaos i on i.id = p.irmao_id
    where p.loja_id = p_loja and p.justificativa is not null
      and (p.situacao = 'justificada' or p.aceita = false)
      and not exists (select 1 from public.confirmacoes c where c.sessao_id = p.sessao_id and c.irmao_id = p.irmao_id
                      and c.resposta = 'nao_vou' and c.motivo is not null)
  ) x
  where (public.tem_permissao(p_loja, 'loja.config') or public.tem_permissao(p_loja, 'chancelaria.ler'))
    and (p_todas or x.ciente_em is null)
  order by x.enviada_em desc
  limit 300
$$;

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.whatsapp_botao from public, anon, authenticated;
grant execute on function public.whatsapp_botao to service_role;
