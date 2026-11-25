-- Sistema Malhete: BOTÕES NO WHATSAPP (25/11, pedidos do Lucas).
-- 1) Convite de acesso: chegava "um card feio, com o link exposto". O texto agora termina no link e a fila
--    (functions/_shared/uazapi.ts linkEmBotao) troca essa última linha pelo botão "Acessar o sistema"; a prévia do
--    link foi desligada em todos os envios. O link do convite passa a respeitar o ambiente de teste (private.link_app).
-- 2) Justificativa: o Venerável recebe os botões "Aceitar" e "Não aceitar" na própria mensagem e decide sem abrir o
--    sistema. O toque só vale do telefone do Venerável avisado, enquanto ele estiver no cargo, e uma vez só
--    (decidida pelo sistema ou pelo WhatsApp, a outra via responde que já foi decidida). A decisão faz o mesmo que
--    "Aceitar ou não aceitar" na Chancelaria (private.aplicar_justificativa) e avisa o irmão.

-- ---------- 1) convite ----------
create or replace function public.convidar_irmao(p_irmao uuid, p_enviar_whatsapp boolean default true)
returns text language plpgsql security definer set search_path = '' as $$
declare
  i public.irmaos;
  v_token text;
  v_link text;
  v_loja text;
  v_tel text;
begin
  select * into i from public.irmaos where id = p_irmao;
  if i.id is null or not public.tem_permissao(i.loja_id, 'cadastro.editar') then raise exception 'Sem permissão'; end if;
  if i.user_id is not null then raise exception 'Este irmão já tem acesso ao sistema'; end if;
  if i.situacao not in ('ativo', 'licenciado') then raise exception 'Só irmãos ativos ou licenciados recebem convite'; end if;

  update public.convites set expira_em = now() where irmao_id = p_irmao and usado_em is null and expira_em > now();
  insert into public.convites (loja_id, irmao_id) values (i.loja_id, p_irmao) returning token into v_token;
  v_link := private.link_app('/convite/' || v_token);

  v_tel := nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '');
  if p_enviar_whatsapp and v_tel is not null then
    select trim(nome) into v_loja from public.lojas where id = i.loja_id;
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (i.loja_id, p_irmao, 'convite', null,
            format('Olá, %s! Você foi convidado a usar o sistema da %s. Toque no botão abaixo para criar o seu acesso. O convite vale por 14 dias.%s%s',
                   private.primeiro_nome(i.nome), v_loja, E'\n', v_link),
            v_tel, 'pendente');
  end if;
  return v_link;
end $$;

-- ---------- 2) justificativa decidida pelo WhatsApp ----------
-- cada aviso ao Venerável ganha um código; o botão leva o código, nunca o id da justificativa
create table public.justificativa_botoes (
  token text primary key default replace(gen_random_uuid()::text, '-', ''),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  origem text not null check (origem in ('confirmacao', 'presenca')),
  ref_id uuid not null,
  veneravel_id uuid not null references public.irmaos(id) on delete cascade,
  criado_em timestamptz not null default now()
);
alter table public.justificativa_botoes enable row level security; -- só funções do sistema
revoke all on public.justificativa_botoes from anon, authenticated;

-- o núcleo da decisão, igual ao de antes; quem decide entra em ciente_por
create function private.aplicar_justificativa(p_origem text, p_id uuid, p_aceita boolean, p_parecer text, p_por uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_loja uuid; v_sessao uuid; v_irmao uuid; v_data date; v_tel text; v_nome text;
begin
  if p_origem = 'confirmacao' then
    select loja_id, sessao_id, irmao_id into v_loja, v_sessao, v_irmao from public.confirmacoes where id = p_id;
  elsif p_origem = 'presenca' then
    select loja_id, sessao_id, irmao_id into v_loja, v_sessao, v_irmao from public.presencas where id = p_id;
  end if;
  if v_loja is null then raise exception 'Justificativa não encontrada'; end if;
  if p_aceita is null then raise exception 'Escolha aceitar ou não aceitar'; end if;

  if p_origem = 'confirmacao' then
    update public.confirmacoes set ciente_em = now(), ciente_por = p_por, aceita = p_aceita, parecer = nullif(trim(p_parecer), '')
    where id = p_id;
  end if;
  -- reflete na presença (se o Chanceler já marcou, ou se a justificativa veio depois da sessão); "presente" não muda
  update public.presencas
  set situacao = case when p_aceita then 'justificada' else 'ausente' end,
      justificativa = coalesce(justificativa, (select motivo from public.confirmacoes where id = p_id)),
      ciente_em = now(), ciente_por = p_por, aceita = p_aceita, parecer = nullif(trim(p_parecer), '')
  where sessao_id = v_sessao and irmao_id = v_irmao and situacao <> 'presente';

  -- devolve a decisão ao irmão
  select data into v_data from public.sessoes where id = v_sessao;
  select nome, nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_nome, v_tel from public.irmaos where id = v_irmao;
  if coalesce((select justificativas from public.avisos_config where loja_id = v_loja), true) then
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (v_loja, v_irmao, 'justificativa', v_sessao,
            format('Irmão %s, o Venerável Mestre %s sua justificativa da sessão de %s.%s',
                   private.primeiro_nome(v_nome), case when p_aceita then 'aceitou' else 'não aceitou' end, to_char(v_data, 'DD/MM'),
                   coalesce(E'\n' || nullif(trim(p_parecer), ''), '')),
            v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
  end if;
end $$;
revoke all on function private.aplicar_justificativa from public, anon, authenticated;

create or replace function public.avaliar_justificativa(p_origem text, p_id uuid, p_aceita boolean, p_parecer text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_loja uuid;
begin
  if p_origem = 'confirmacao' then
    select loja_id into v_loja from public.confirmacoes where id = p_id;
  elsif p_origem = 'presenca' then
    select loja_id into v_loja from public.presencas where id = p_id;
  end if;
  if v_loja is null or not public.tem_permissao(v_loja, 'loja.config') then raise exception 'Só o Venerável Mestre aceita justificativas'; end if;
  perform private.aplicar_justificativa(p_origem, p_id, p_aceita, p_parecer, auth.uid());
end $$;

-- aviso ao Venerável, agora com os botões
create or replace function private.avisar_veneravel(p_loja uuid, p_sessao uuid, p_irmao uuid, p_texto text, p_antes boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_nome text := (select nome from public.irmaos where id = p_irmao);
  v_data date := (select data from public.sessoes where id = p_sessao);
  v_origem text := case when p_antes then 'confirmacao' else 'presenca' end;
  v_ref uuid;
  v record;
  v_tok text;
  v_tel text;
begin
  if not coalesce((select justificativas from public.avisos_config where loja_id = p_loja), true) then return; end if;
  if p_antes then
    select id into v_ref from public.confirmacoes where sessao_id = p_sessao and irmao_id = p_irmao;
  else
    select id into v_ref from public.presencas where sessao_id = p_sessao and irmao_id = p_irmao;
  end if;
  for v in
    select vi.id, vi.nome, vi.telefone from public.irmaos vi
    where vi.loja_id = p_loja and vi.id <> p_irmao and vi.situacao = 'ativo'
      and exists (select 1 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
                  where m.irmao_id = vi.id and c.codigo = 'veneravel' and current_date between m.inicio and m.fim)
  loop
    v_tel := nullif(regexp_replace(coalesce(v.telefone, ''), '\D', '', 'g'), '');
    v_tok := null;
    if v_ref is not null then
      insert into public.justificativa_botoes (loja_id, origem, ref_id, veneravel_id)
      values (p_loja, v_origem, v_ref, v.id) returning token into v_tok;
    end if;
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status, botoes)
    values (p_loja, v.id, 'justificativa', p_sessao,
            format('Irmão %s, o irmão %s %s %s:%s“%s”%sPara aceitar ou não, abra: %s',
                   private.primeiro_nome(v.nome), v_nome,
                   case when p_antes then 'avisou que não poderá comparecer à sessão de' else 'justificou a falta na sessão de' end,
                   to_char(v_data, 'DD/MM'), E'\n', left(p_texto, 500), E'\n\n', private.link_app('/app/chancelaria/justificativas')),
            v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end,
            case when v_tok is not null then array['Aceitar|jv:sim:' || v_tok, 'Não aceitar|jv:nao:' || v_tok] end);
  end loop;
end $$;

-- o toque no botão
create function private.whatsapp_justificativa(p_loja uuid, p_telefone text, p_token text, p_aceita boolean)
returns text language plpgsql security definer set search_path = '' as $$
declare
  b public.justificativa_botoes;
  v public.irmaos;
  v_ciente timestamptz; v_aceita boolean; v_irmao uuid; v_nome text;
begin
  select * into b from public.justificativa_botoes where token = p_token and loja_id = p_loja;
  if b.token is null then return null; end if;
  select * into v from public.irmaos where id = b.veneravel_id;
  -- só vale do telefone de quem recebeu o aviso
  if public.tel_chave(coalesce(v.telefone, '')) <> public.tel_chave(p_telefone) then return null; end if;
  if not exists (select 1 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id
                 where m.irmao_id = v.id and c.codigo = 'veneravel' and current_date between m.inicio and m.fim) then
    return 'Só o Venerável Mestre em exercício decide as justificativas.';
  end if;
  if b.origem = 'confirmacao' then
    select ciente_em, aceita, irmao_id into v_ciente, v_aceita, v_irmao from public.confirmacoes where id = b.ref_id;
  else
    select ciente_em, aceita, irmao_id into v_ciente, v_aceita, v_irmao from public.presencas where id = b.ref_id;
  end if;
  if v_irmao is null then return 'Esta justificativa não existe mais.'; end if;
  v_nome := private.primeiro_nome((select nome from public.irmaos where id = v_irmao));
  if v_ciente is not null then
    return format('A justificativa do Ir∴ %s já foi decidida: %s.', v_nome, case when v_aceita then 'aceita' else 'não aceita' end);
  end if;
  perform private.aplicar_justificativa(b.origem, b.ref_id, p_aceita, null, v.user_id);
  return format('Pronto, irmão. A justificativa do Ir∴ %s foi %s e ele será avisado.', v_nome, case when p_aceita then 'aceita' else 'não aceita' end);
end $$;
revoke all on function private.whatsapp_justificativa from public, anon, authenticated;

-- whatsapp_botao: o mesmo de antes, com os botões da justificativa ("jv:sim:<código>" e "jv:nao:<código>") na frente
create or replace function public.whatsapp_botao(p_loja uuid, p_telefone text, p_botao text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_acao text := split_part(p_botao, ':', 1) || ':' || split_part(p_botao, ':', 2);
  v_tok text := split_part(p_botao, ':', 3);
  d public.envio_destinatarios;
  e public.envios;
  s public.sessoes;
  c public.confirmacoes;
  v_resp text;
begin
  if v_acao in ('jv:sim', 'jv:nao') then
    return private.whatsapp_justificativa(p_loja, p_telefone, v_tok, v_acao = 'jv:sim');
  end if;
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
