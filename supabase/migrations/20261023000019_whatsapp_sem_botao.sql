-- Sistema Malhete — WhatsApp sem depender dos botões (nem todo aparelho mostra):
-- convocação aceita "1"/"sim" e "2"/"não" em texto; no pedido de justificativa, qualquer texto
-- respondido já é a justificativa. Mensagens repetidas do webhook são ignoradas.

create table public.whatsapp_mensagens (
  id text primary key,            -- messageid do WhatsApp
  loja_id uuid not null references public.lojas(id) on delete cascade,
  recebida_em timestamptz not null default now()
);
create index on public.whatsapp_mensagens (loja_id, recebida_em);
alter table public.whatsapp_mensagens enable row level security; -- só funções do sistema

-- Registra a mensagem; devolve false se já tinha chegado.
create function public.whatsapp_nova_mensagem(p_loja uuid, p_id text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.whatsapp_mensagens (id, loja_id) values (p_id, p_loja);
  delete from public.whatsapp_mensagens where recebida_em < now() - interval '30 days';
  return true;
exception when unique_violation then
  return false;
end $$;

-- Ao disparar o pedido de justificativa, abre a conversa de cada irmão: o próximo texto dele é a justificativa.
create function public.whatsapp_abrir_justificativas(p_envio uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.whatsapp_conversas (loja_id, telefone, estado, destinatario_id, expira_em)
  select d.loja_id, public.tel_chave(d.telefone), 'justificativa', d.id, now() + interval '7 days'
  from public.envio_destinatarios d join public.envios e on e.id = d.envio_id
  where d.envio_id = p_envio and e.tipo = 'justificativa' and d.telefone is not null
  on conflict (loja_id, telefone) do update
    set estado = excluded.estado, destinatario_id = excluded.destinatario_id, expira_em = excluded.expira_em
$$;

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

  -- "1"/"2" (e sim/não) respondem à convocação mais recente ainda aberta, mesmo com outra conversa pendente
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
    update public.confirmacoes set motivo = left(trim(p_texto), 1000) where sessao_id = e.sessao_id and irmao_id = d.irmao_id;
    return 'Obrigado, irmão. Registrado.';
  end if;

  perform private.registrar_justificativa(e.loja_id, e.sessao_id, d.irmao_id, p_texto, 'whatsapp');
  return 'Obrigado, irmão. Sua justificativa foi registrada para conhecimento do Venerável Mestre.';
end $$;

revoke all on public.whatsapp_mensagens from anon, authenticated;
revoke execute on function public.whatsapp_nova_mensagem, public.whatsapp_abrir_justificativas, public.whatsapp_texto from public, anon, authenticated;
grant execute on function public.whatsapp_nova_mensagem, public.whatsapp_abrir_justificativas, public.whatsapp_texto to service_role;
