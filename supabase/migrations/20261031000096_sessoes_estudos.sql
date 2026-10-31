-- Sessões de estudo (31/10, ideia do 1º Vigilante): tipo 'estudos', presencial ou ONLINE (com link). Quem tem a
-- permissão nova 'sessoes.estudos' (os dois Vigilantes, em todos os ritos; o Venerável pode dar a outro cargo) cria,
-- edita, convoca e marca a presença dessas sessões. Ordinárias e magnas continuam com Venerável e Chanceler.
-- Contam na frequência como qualquer sessão realizada (decisão do Lucas).
CREATE OR REPLACE FUNCTION private.permissoes_ajustaveis()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select array['cadastro.ler', 'cadastro.editar', 'tesouraria.ler', 'tronco.ler', 'secretaria.ler', 'chancelaria.ler',
               'auditoria.ler', 'sessoes.convocar', 'mural.publicar', 'biblioteca.editar', 'hospitalaria.editar',
               'comunicacao.enviar', 'cargos.editar', 'sessoes.estudos']
$function$
;

alter table public.sessoes drop constraint sessoes_tipo_check;
alter table public.sessoes add constraint sessoes_tipo_check check (tipo in ('ordinaria', 'magna', 'estudos'));
alter table public.sessoes
  add column modalidade text not null default 'presencial' check (modalidade in ('presencial', 'online')),
  add column link_online text;

create function private.pode_gerir_sessao(p_loja uuid, p_tipo text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.tem_permissao(p_loja, 'sessoes.convocar') or (p_tipo = 'estudos' and public.tem_permissao(p_loja, 'sessoes.estudos'))
$$;
create function public.pode_gerir_sessao(p_sessao uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select private.pode_gerir_sessao(loja_id, tipo) from public.sessoes where id = p_sessao), false)
$$;
revoke execute on function private.pode_gerir_sessao(uuid, text) from public, anon, authenticated;
revoke execute on function public.pode_gerir_sessao(uuid) from public, anon;
grant execute on function public.pode_gerir_sessao(uuid) to authenticated;

-- sessões: agenda/edita também quem tem sessoes.estudos, só nas de estudo
create function public.pode_gerir_sessao_tipo(p_loja uuid, p_tipo text) returns boolean
language sql stable security definer set search_path = '' as $$ select private.pode_gerir_sessao(p_loja, p_tipo) $$;
revoke execute on function public.pode_gerir_sessao_tipo from public, anon;
grant execute on function public.pode_gerir_sessao_tipo to authenticated;
drop policy agenda on public.sessoes;
create policy agenda on public.sessoes for insert to authenticated
  with check ((select public.pode_gerir_sessao_tipo(loja_id, tipo)));
drop policy edita on public.sessoes;
create policy edita on public.sessoes for update to authenticated
  using ((select public.pode_gerir_sessao_tipo(loja_id, tipo)) or (select public.tem_permissao(loja_id, 'chancelaria.editar')))
  with check ((select public.pode_gerir_sessao_tipo(loja_id, tipo)) or (select public.tem_permissao(loja_id, 'chancelaria.editar')));
drop policy le on public.sessoes;
create policy le on public.sessoes for select to authenticated
  using ((select public.pode_ver_grau(loja_id, grau)) or (select public.tem_permissao(loja_id, 'chancelaria.ler'))
         or (select public.tem_permissao(loja_id, 'secretaria.ler')) or (select public.tem_permissao(loja_id, 'sessoes.convocar'))
         or (select public.tem_permissao(loja_id, 'sessoes.estudos')));

-- presença e visitantes das sessões de estudo: também quem as organiza
create policy estudos on public.presencas for all to authenticated
  using ((select public.pode_gerir_sessao(sessao_id)) and exists (select 1 from public.sessoes s where s.id = sessao_id and s.tipo = 'estudos'))
  with check ((select public.pode_gerir_sessao(sessao_id)) and exists (select 1 from public.sessoes s where s.id = sessao_id and s.tipo = 'estudos'));
create policy estudos on public.visitantes for all to authenticated
  using ((select public.pode_gerir_sessao(sessao_id)) and exists (select 1 from public.sessoes s where s.id = sessao_id and s.tipo = 'estudos'))
  with check ((select public.pode_gerir_sessao(sessao_id)) and exists (select 1 from public.sessoes s where s.id = sessao_id and s.tipo = 'estudos'));

CREATE OR REPLACE FUNCTION public.criar_envio(p_loja uuid, p_tipo text, p_mensagem text, p_sessao uuid DEFAULT NULL::uuid, p_irmaos uuid[] DEFAULT NULL::uuid[], p_canal text DEFAULT 'manual'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id uuid;
  v_grau smallint := 1;
begin
  if p_canal not in ('manual', 'whatsapp') then raise exception 'Canal inválido'; end if;
  if p_tipo = 'convocacao' then
    if not public.pode_gerir_sessao(p_sessao) then raise exception 'Só o Venerável ou o Chanceler convocam (sessão de estudos: também os Vigilantes)'; end if;
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
end $function$
;

-- os Vigilantes ganham a permissão em todos os ritos e nas Lojas já criadas
update public.rito_cargos set permissoes = permissoes || array['sessoes.estudos']
where codigo in ('primeiro_vigilante', 'segundo_vigilante') and not 'sessoes.estudos' = any (permissoes);
update public.loja_cargos set permissoes = permissoes || array['sessoes.estudos']
where codigo in ('primeiro_vigilante', 'segundo_vigilante') and not 'sessoes.estudos' = any (permissoes);
