-- Sistema Malhete — lembrete automático no dia da sessão: às 9h (Brasília) o sistema identifica os convocados
-- pelo WhatsApp que não responderam e manda de novo, com os botões, pedindo uma posição. Uma vez por sessão.
-- Liga/desliga por loja em Avisos automáticos (avisos_config.lembrete_sessao).

alter table public.avisos_config add column lembrete_sessao boolean not null default true;
alter table public.envios add column automatico boolean not null default false;

create function public.criar_lembretes_sessao() returns uuid[]
language plpgsql security definer set search_path = '' as $$
declare
  s record;
  v_id uuid;
  v_ids uuid[] := '{}';
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_msg text;
begin
  for s in
    select se.id, se.loja_id, se.grau
    from public.sessoes se
    join public.integracoes_whatsapp w on w.loja_id = se.loja_id and w.status = 'conectado'
    left join public.avisos_config ac on ac.loja_id = se.loja_id
    where se.data = v_hoje and se.status = 'agendada' and coalesce(ac.lembrete_sessao, true)
      and exists (select 1 from public.envios e where e.sessao_id = se.id and e.tipo = 'convocacao' and e.canal = 'whatsapp')
      and not exists (select 1 from public.envios e where e.sessao_id = se.id and e.tipo = 'convocacao' and e.automatico)
  loop
    select mensagem into v_msg from public.envios
    where sessao_id = s.id and tipo = 'convocacao' and not automatico order by criado_em desc limit 1;

    insert into public.envios (loja_id, tipo, sessao_id, canal, automatico, criado_por, mensagem)
    values (s.loja_id, 'convocacao', s.id, 'whatsapp', true, null,
            '*Lembrete: a sessão é HOJE* e ainda não recebemos sua resposta. Por favor, confirme se poderá comparecer.'
            || E'\n\n' || coalesce(v_msg, ''))
    returning id into v_id;

    -- convocados (receberam pelo WhatsApp) que seguem ativos, no grau e sem resposta
    insert into public.envio_destinatarios (envio_id, loja_id, irmao_id, telefone, status)
    select distinct on (i.id) v_id, s.loja_id, i.id, nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''), 'pendente'
    from public.envio_destinatarios d
    join public.envios e on e.id = d.envio_id and e.sessao_id = s.id and e.tipo = 'convocacao' and e.canal = 'whatsapp'
    join public.irmaos i on i.id = d.irmao_id
    where d.status = 'enviado' and i.situacao = 'ativo' and i.grau >= s.grau
      and nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is not null
      and not exists (select 1 from public.confirmacoes c where c.sessao_id = s.id and c.irmao_id = i.id);

    if found then
      v_ids := v_ids || v_id;
    else
      delete from public.envios where id = v_id;  -- todos responderam: nada a lembrar
    end if;
  end loop;
  return v_ids;
end $$;
revoke execute on function public.criar_lembretes_sessao from public, anon, authenticated;
grant execute on function public.criar_lembretes_sessao to service_role;

select cron.schedule('malhete-lembrete-sessao', '0 12 * * *', $cron$
  select net.http_post(
    url := 'https://heblivnebprikxcjsuan.supabase.co/functions/v1/whatsapp',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_Ge7-D-NsdDZgZCHirtTpeA_lfAs0um8',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'malhete_cron_secret')),
    body := '{"acao":"lembretes_sessao"}'::jsonb,
    timeout_milliseconds := 110000)
  where exists (select 1 from public.sessoes where data = (now() at time zone 'America/Sao_Paulo')::date and status = 'agendada')
$cron$);
