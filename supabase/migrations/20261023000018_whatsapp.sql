-- Sistema Malhete — WhatsApp da loja (UazAPI): conexão por QR dentro do app, convocação com botões
-- (Vou / Não poderei ir), motivo respondido no próprio WhatsApp, pedido de justificativa para quem
-- faltou e ciência do Venerável. A instância é criada pela plataforma (admintoken só na edge function);
-- o token de cada instância fica no Vault e só o service_role lê.

-- =========================================================
-- Integração por loja
-- =========================================================

create table public.integracoes_whatsapp (
  loja_id uuid primary key references public.lojas(id) on delete cascade,
  instancia text not null,
  segredo_id uuid not null,                 -- vault: token da instância
  status text not null default 'desconectado' check (status in ('desconectado', 'conectando', 'conectado')),
  numero text,
  perfil text,
  conectado_em timestamptz,
  ultimo_erro text,
  webhook_token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  criado_por uuid references auth.users(id),
  criado_em timestamptz not null default now()
);
create index on public.integracoes_whatsapp (criado_por);
alter table public.integracoes_whatsapp enable row level security;
create policy le on public.integracoes_whatsapp for select to authenticated
  using (loja_id in (select public.minhas_lojas()));
revoke select on public.integracoes_whatsapp from anon, authenticated;
grant select (loja_id, instancia, status, numero, perfil, conectado_em, ultimo_erro) on public.integracoes_whatsapp to authenticated;
create trigger auditoria after insert or update or delete on public.integracoes_whatsapp for each row execute function public.registrar_auditoria();

-- Quem conecta o WhatsApp da loja: Venerável/admin (loja.config) ou Secretário.
create function public.whatsapp_pode_configurar(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.tem_permissao(p_loja, 'loja.config') or public.tem_permissao(p_loja, 'secretaria.editar')
$$;

-- ---- só service_role (edge functions)
create function public.whatsapp_salvar(p_loja uuid, p_instancia text, p_token text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v public.integracoes_whatsapp;
begin
  select * into v from public.integracoes_whatsapp where loja_id = p_loja;
  if v.loja_id is null then
    insert into public.integracoes_whatsapp (loja_id, instancia, segredo_id, status)
    values (p_loja, p_instancia, vault.create_secret(p_token, 'whatsapp_' || p_loja, 'Token da instância UazAPI da loja'), 'conectando')
    returning * into v;
  else
    perform vault.update_secret(v.segredo_id, p_token);
    update public.integracoes_whatsapp set instancia = p_instancia, status = 'conectando', ultimo_erro = null where loja_id = p_loja returning * into v;
  end if;
  return v.webhook_token;
end $$;

create function public.whatsapp_credenciais(p_loja uuid)
returns table (token text, instancia text, webhook_token text, status text)
language sql security definer set search_path = '' as $$
  select s.decrypted_secret, w.instancia, w.webhook_token, w.status
  from public.integracoes_whatsapp w join vault.decrypted_secrets s on s.id = w.segredo_id
  where w.loja_id = p_loja
$$;

create function public.whatsapp_atualizar(p_loja uuid, p_status text, p_numero text, p_perfil text, p_erro text) returns void
language sql security definer set search_path = '' as $$
  update public.integracoes_whatsapp
  set status = coalesce(p_status, status), numero = coalesce(p_numero, numero), perfil = coalesce(p_perfil, perfil),
      conectado_em = case when p_status = 'conectado' and status <> 'conectado' then now() else conectado_em end,
      ultimo_erro = p_erro
  where loja_id = p_loja
$$;

create function public.whatsapp_remover(p_loja uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_segredo uuid;
begin
  delete from public.integracoes_whatsapp where loja_id = p_loja returning segredo_id into v_segredo;
  if v_segredo is not null then delete from vault.secrets where id = v_segredo; end if;
end $$;

-- =========================================================
-- Envios por WhatsApp: token por destinatário (vai no id do botão), resposta e motivo
-- =========================================================

alter table public.envios drop constraint envios_tipo_check;
alter table public.envios add constraint envios_tipo_check check (tipo in ('convocacao', 'aviso', 'justificativa'));
alter table public.envios add column lote_externo text; -- folder_id da campanha na UazAPI

alter table public.envio_destinatarios
  add column token text not null default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16);
create unique index envio_destinatarios_token on public.envio_destinatarios (token);

-- Confirmação de presença (antes da sessão), pelo WhatsApp ou pelo sistema.
create table public.confirmacoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  sessao_id uuid not null references public.sessoes(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  resposta text not null check (resposta in ('vou', 'nao_vou')),
  motivo text,
  canal text not null check (canal in ('whatsapp', 'sistema')),
  respondido_em timestamptz not null default now(),
  unique (sessao_id, irmao_id)
);
create index on public.confirmacoes (irmao_id);
create index on public.confirmacoes (loja_id);
alter table public.confirmacoes enable row level security;
create policy le on public.confirmacoes for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id))
         or (select public.tem_permissao(loja_id, 'chancelaria.ler'))
         or (select public.tem_permissao(loja_id, 'sessoes.convocar')));
create trigger auditoria after insert or update or delete on public.confirmacoes for each row execute function public.registrar_auditoria();

alter table public.presencas
  add column justificada_pelo_irmao boolean not null default false,
  add column justificada_via text check (justificada_via in ('whatsapp', 'sistema')),
  add column ciente_em timestamptz,
  add column ciente_por uuid references auth.users(id);
create index on public.presencas (ciente_por);

-- O que o sistema espera do irmão no próximo texto (motivo do "não vou" ou justificativa da falta).
create table public.whatsapp_conversas (
  loja_id uuid not null references public.lojas(id) on delete cascade,
  telefone text not null,                -- chave: DDD + 8 últimos dígitos
  estado text not null check (estado in ('motivo_rsvp', 'justificativa')),
  destinatario_id uuid not null references public.envio_destinatarios(id) on delete cascade,
  expira_em timestamptz not null default now() + interval '3 days',
  primary key (loja_id, telefone)
);
create index on public.whatsapp_conversas (destinatario_id);
alter table public.whatsapp_conversas enable row level security; -- só funções do sistema

-- Telefone brasileiro → chave estável (o WhatsApp às vezes omite o 9): DDD + 8 últimos dígitos.
create function public.tel_chave(p text) returns text
language sql immutable set search_path = '' as $$
  select case when length(d) >= 10 then substr(d, 1, 2) || right(d, 8) else d end
  from (select case when length(x) >= 12 and left(x, 2) = '55' then substr(x, 3) else x end as d
        from (select regexp_replace(coalesce(split_part(p, '@', 1), ''), '\D', '', 'g') as x) a) b
$$;

-- Envio pelo WhatsApp: mesma criação do envio manual, com canal 'whatsapp' (substitui a versão sem canal).
drop function public.criar_envio(uuid, text, text, uuid, uuid[]);
create function public.criar_envio(p_loja uuid, p_tipo text, p_mensagem text, p_sessao uuid default null,
                                              p_irmaos uuid[] default null, p_canal text default 'manual')
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_grau smallint := 1;
begin
  if p_canal not in ('manual', 'whatsapp') then raise exception 'Canal inválido'; end if;
  if p_tipo = 'convocacao' then
    if not public.tem_permissao(p_loja, 'sessoes.convocar') then raise exception 'Só o Venerável ou o Chanceler convocam'; end if;
    select grau into v_grau from public.sessoes where id = p_sessao and loja_id = p_loja and status = 'agendada';
    if v_grau is null then raise exception 'Sessão não encontrada ou já realizada/cancelada'; end if;
  elsif p_tipo = 'justificativa' then
    raise exception 'Use pedir_justificativas';
  elsif not public.tem_permissao(p_loja, 'comunicacao.enviar') then
    raise exception 'Sem permissão para enviar avisos';
  end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;
  if p_canal = 'whatsapp' and not exists (select 1 from public.integracoes_whatsapp where loja_id = p_loja and status = 'conectado') then
    raise exception 'O WhatsApp da loja não está conectado';
  end if;

  insert into public.envios (loja_id, tipo, sessao_id, mensagem, canal) values (p_loja, p_tipo, p_sessao, trim(p_mensagem), p_canal)
  returning id into v_id;
  insert into public.envio_destinatarios (envio_id, loja_id, irmao_id, telefone, status)
  select v_id, p_loja, i.id, nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when coalesce(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') = '' then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo' and i.grau >= v_grau
    and (p_irmaos is null or i.id = any (p_irmaos));

  if p_tipo = 'convocacao' then
    update public.sessoes set convocada_em = now() where id = p_sessao;
  end if;
  return v_id;
end $$;

-- Depois da sessão realizada: pede justificativa a quem faltou (sem presença nem justificativa).
create function public.pedir_justificativas(p_loja uuid, p_sessao uuid, p_mensagem text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  v_id uuid;
begin
  if not (public.tem_permissao(p_loja, 'chancelaria.editar') or public.tem_permissao(p_loja, 'sessoes.convocar')) then
    raise exception 'Sem permissão';
  end if;
  select * into s from public.sessoes where id = p_sessao and loja_id = p_loja;
  if s.status <> 'realizada' then raise exception 'Marque a sessão como realizada antes'; end if;
  if not exists (select 1 from public.integracoes_whatsapp where loja_id = p_loja and status = 'conectado') then
    raise exception 'O WhatsApp da loja não está conectado';
  end if;

  insert into public.envios (loja_id, tipo, sessao_id, mensagem, canal) values (p_loja, 'justificativa', p_sessao, trim(p_mensagem), 'whatsapp')
  returning id into v_id;
  insert into public.envio_destinatarios (envio_id, loja_id, irmao_id, telefone, status)
  select v_id, p_loja, i.id, nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when coalesce(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') = '' then 'sem_telefone' else 'pendente' end
  from public.irmaos i
  where i.loja_id = p_loja and i.situacao = 'ativo' and i.grau >= s.grau
    and not exists (select 1 from public.presencas p where p.sessao_id = p_sessao and p.irmao_id = i.id and p.situacao in ('presente', 'justificada'));
  return v_id;
end $$;

-- ---- rotinas comuns aos dois canais
create function private.registrar_confirmacao(p_loja uuid, p_sessao uuid, p_irmao uuid, p_resposta text, p_motivo text, p_canal text)
returns void
language sql security definer set search_path = '' as $$
  insert into public.confirmacoes (loja_id, sessao_id, irmao_id, resposta, motivo, canal)
  values (p_loja, p_sessao, p_irmao, p_resposta, nullif(left(trim(coalesce(p_motivo, '')), 1000), ''), p_canal)
  on conflict (sessao_id, irmao_id) do update
    set resposta = excluded.resposta, motivo = excluded.motivo, canal = excluded.canal, respondido_em = now()
$$;

-- Justificativa da falta: vira presença justificada (não sobrepõe "presente" marcado pelo Chanceler).
create function private.registrar_justificativa(p_loja uuid, p_sessao uuid, p_irmao uuid, p_texto text, p_canal text)
returns void
language sql security definer set search_path = '' as $$
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao, justificativa, justificada_pelo_irmao, justificada_via)
  values (p_loja, p_sessao, p_irmao, 'justificada', left(trim(p_texto), 1000), true, p_canal)
  on conflict (sessao_id, irmao_id) do update
    set situacao = 'justificada', justificativa = excluded.justificativa, justificada_pelo_irmao = true,
        justificada_via = excluded.justificada_via, ciente_em = null, ciente_por = null
    where public.presencas.situacao <> 'presente'
$$;

-- ---- o irmão logado, pelo sistema
create function public.responder_convocacao(p_sessao uuid, p_resposta text, p_motivo text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  v_irmao uuid;
begin
  select * into s from public.sessoes where id = p_sessao;
  v_irmao := public.meu_irmao_id(s.loja_id);
  if s.id is null or v_irmao is null or not public.pode_ver_grau(s.loja_id, s.grau) then raise exception 'Sessão não encontrada'; end if;
  if s.status <> 'agendada' then raise exception 'A sessão já foi realizada ou cancelada'; end if;
  if p_resposta not in ('vou', 'nao_vou') then raise exception 'Resposta inválida'; end if;
  perform private.registrar_confirmacao(s.loja_id, s.id, v_irmao, p_resposta, p_motivo, 'sistema');
end $$;

create function public.justificar_falta(p_sessao uuid, p_texto text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.sessoes;
  v_irmao uuid;
begin
  select * into s from public.sessoes where id = p_sessao;
  v_irmao := public.meu_irmao_id(s.loja_id);
  if s.id is null or v_irmao is null or not public.pode_ver_grau(s.loja_id, s.grau) then raise exception 'Sessão não encontrada'; end if;
  if s.status <> 'realizada' or s.data < current_date - 30 then raise exception 'Só dá para justificar sessões realizadas nos últimos 30 dias'; end if;
  if coalesce(trim(p_texto), '') = '' then raise exception 'Escreva o motivo'; end if;
  if exists (select 1 from public.presencas where sessao_id = p_sessao and irmao_id = v_irmao and situacao = 'presente') then
    raise exception 'Você está com presença registrada nesta sessão';
  end if;
  perform private.registrar_justificativa(s.loja_id, s.id, v_irmao, p_texto, 'sistema');
end $$;

-- ---- respostas do irmão (chamadas pelo webhook como service_role). Devolvem o texto de resposta ao irmão.

create function public.whatsapp_botao(p_loja uuid, p_telefone text, p_botao text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_acao text := split_part(p_botao, ':', 1) || ':' || split_part(p_botao, ':', 2);
  v_tok text := split_part(p_botao, ':', 3);
  d public.envio_destinatarios;
  e public.envios;
  s public.sessoes;
begin
  select * into d from public.envio_destinatarios where token = v_tok and loja_id = p_loja;
  if d.id is null then return null; end if;
  select * into e from public.envios where id = d.envio_id;
  select * into s from public.sessoes where id = e.sessao_id;

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

create function public.whatsapp_texto(p_loja uuid, p_telefone text, p_texto text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  c public.whatsapp_conversas;
  d public.envio_destinatarios;
  e public.envios;
begin
  select * into c from public.whatsapp_conversas where loja_id = p_loja and telefone = public.tel_chave(p_telefone) and expira_em > now();
  if c.loja_id is null or coalesce(trim(p_texto), '') = '' then return null; end if;
  select * into d from public.envio_destinatarios where id = c.destinatario_id;
  select * into e from public.envios where id = d.envio_id;
  delete from public.whatsapp_conversas where loja_id = c.loja_id and telefone = c.telefone;

  if c.estado = 'motivo_rsvp' then
    update public.confirmacoes set motivo = left(trim(p_texto), 1000) where sessao_id = e.sessao_id and irmao_id = d.irmao_id;
    return 'Obrigado, irmão. Registrado.';
  end if;

  perform private.registrar_justificativa(e.loja_id, e.sessao_id, d.irmao_id, p_texto, 'whatsapp');
  return 'Obrigado, irmão. Sua justificativa foi registrada para conhecimento do Venerável Mestre.';
end $$;

-- Venerável (ou quem configura a loja) toma ciência das justificativas enviadas pelos irmãos.
create function public.tomar_ciencia(p_presenca uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p public.presencas;
begin
  select * into p from public.presencas where id = p_presenca;
  if p.id is null or not public.tem_permissao(p.loja_id, 'loja.config') then raise exception 'Sem permissão'; end if;
  update public.presencas set ciente_em = now(), ciente_por = auth.uid() where id = p_presenca;
end $$;

-- Venerável lê as justificativas (presenças) mesmo sem chancelaria.ler explícita: já coberto pelo '*'.

revoke all on public.whatsapp_conversas from anon, authenticated;
revoke execute on function public.whatsapp_salvar, public.whatsapp_credenciais, public.whatsapp_atualizar, public.whatsapp_remover,
  public.whatsapp_botao, public.whatsapp_texto from public, anon, authenticated;
grant execute on function public.whatsapp_salvar, public.whatsapp_credenciais, public.whatsapp_atualizar, public.whatsapp_remover,
  public.whatsapp_botao, public.whatsapp_texto to service_role;
revoke execute on function public.whatsapp_pode_configurar, public.pedir_justificativas, public.tomar_ciencia,
  public.responder_convocacao, public.justificar_falta, public.criar_envio from public, anon;
grant execute on function public.whatsapp_pode_configurar, public.pedir_justificativas, public.tomar_ciencia,
  public.responder_convocacao, public.justificar_falta, public.criar_envio to authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
