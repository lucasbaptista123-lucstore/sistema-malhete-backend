-- Sistema Malhete: LEMBRETES DIÁRIOS (25/11, pedidos do Lucas).
-- 1) Sessão não encerrada: "nossa outra sessão demorou dias para ser encerrada". Todo dia, às 9h de Brasília, quem
--    encerra a sessão (Chanceler; nas sessões de estudos também os Vigilantes) recebe o aviso de cada sessão que já
--    passou e continua agendada, com o botão "Abrir a sessão". A partir do 3º dia o Venerável Mestre também recebe.
--    Para de avisar quando a sessão é encerrada ou cancelada, ou depois de 30 dias.
-- 2) Prazo do tema: se o Vigilante pôs prazo no tema, sete dias antes e na véspera o irmão do grau que ainda não
--    enviou trabalho sobre ele recebe o lembrete, com o botão "Enviar o trabalho".
-- Cada Loja liga e desliga em Avisos automáticos (avisos_config.sessao_aberta, avisos_config.prazo_tema).
-- Um aviso de cada tipo por pessoa, por sessão ou tema, por dia. A fila respeita o ritmo de sempre.

alter table public.avisos_config
  add column sessao_aberta boolean not null default true,
  add column prazo_tema boolean not null default true;

alter table public.notificacoes drop constraint notificacoes_tipo_check;
alter table public.notificacoes add constraint notificacoes_tipo_check check (tipo = any (array[
  'cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado', 'convite', 'mural', 'tema', 'justificativa',
  'evento', 'documento', 'tronco', 'sessao_aberta', 'prazo_tema']));

create function private.hoje_sp() returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

create function private.avisos_sessao_aberta() returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
begin
  for r in
    with abertas as (
      select s.*, private.hoje_sp() - s.data as dias
      from public.sessoes s
      where s.status = 'agendada' and s.data < private.hoje_sp() and s.data >= private.hoje_sp() - 30
        and coalesce((select a.sessao_aberta from public.avisos_config a where a.loja_id = s.loja_id), true)
    ), quem as (
      -- quem encerra: Chanceler; nas de estudos, também os Vigilantes; do 3º dia em diante, também o Venerável
      select distinct on (ab.id, i.id) ab.id as sessao, ab.loja_id, ab.data, ab.tipo, ab.dias, i.id as irmao, i.nome, i.telefone
      from abertas ab
      join public.mandatos m on m.loja_id = ab.loja_id and private.hoje_sp() between m.inicio and m.fim
      join public.loja_cargos c on c.id = m.cargo_id
      join public.irmaos i on i.id = m.irmao_id and i.situacao = 'ativo'
      where c.codigo = 'chanceler'
         or (ab.tipo = 'estudos' and c.codigo in ('primeiro_vigilante', 'segundo_vigilante'))
         or (ab.dias >= 3 and c.codigo = 'veneravel')
    )
    select q.* from quem q
    where not exists (select 1 from public.notificacoes x
                      where x.tipo = 'sessao_aberta' and x.referencia = q.sessao and x.irmao_id = q.irmao
                        and (x.criado_em at time zone 'America/Sao_Paulo')::date = private.hoje_sp())
  loop
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (r.loja_id, r.irmao, 'sessao_aberta', r.sessao,
            format('Irmão %s, a %s de %s ainda não foi encerrada%s. Confira a chamada e encerre para lançar a frequência.%s%s',
                   private.primeiro_nome(r.nome),
                   case r.tipo when 'ordinaria' then 'Sessão Ordinária' when 'magna' then 'Sessão Magna'
                               when 'estudos' then 'Sessão de Estudos' else 'sessão' end,
                   to_char(r.data, 'DD/MM'),
                   case when r.dias >= 2 then format(' (já são %s dias)', r.dias) else '' end,
                   E'\n', private.link_app('/app/chancelaria/sessoes/' || r.sessao)),
            nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), ''),
            case when nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function private.avisos_sessao_aberta from public, anon, authenticated;

create function private.lembretes_prazo_tema() returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select t.id as tema, t.loja_id, t.titulo, t.prazo, t.prazo - private.hoje_sp() as faltam, i.id as irmao, i.nome, i.telefone
    from public.temas_trabalho t
    join public.irmaos i on i.loja_id = t.loja_id and i.grau = t.grau and i.situacao = 'ativo'
    where t.ativo and t.prazo is not null and t.prazo - private.hoje_sp() in (7, 1)
      and coalesce((select a.prazo_tema from public.avisos_config a where a.loja_id = t.loja_id), true)
      and not exists (select 1 from public.trabalhos w where w.tema_id = t.id and w.irmao_id = i.id)
      and not exists (select 1 from public.notificacoes x
                      where x.tipo = 'prazo_tema' and x.referencia = t.id and x.irmao_id = i.id
                        and (x.criado_em at time zone 'America/Sao_Paulo')::date = private.hoje_sp())
  loop
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (r.loja_id, r.irmao, 'prazo_tema', r.tema,
            format('Irmão %s, o prazo do tema “%s” termina %s, em %s. Envie o seu trabalho pelo sistema.%s%s',
                   private.primeiro_nome(r.nome), r.titulo,
                   case when r.faltam = 1 then 'amanhã' else 'em sete dias' end, to_char(r.prazo, 'DD/MM'),
                   E'\n', private.link_app('/app/trabalhos/novo?tema=' || r.tema)),
            nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), ''),
            case when nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function private.lembretes_prazo_tema from public, anon, authenticated;

create function private.lembretes_diarios() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_build_object('sessao_aberta', private.avisos_sessao_aberta(), 'prazo_tema', private.lembretes_prazo_tema());
end $$;
revoke all on function private.lembretes_diarios from public, anon, authenticated;

-- 9h de Brasília (12h UTC), junto com o lembrete do dia da sessão; só põe na fila, quem envia é a fila de sempre
select cron.schedule('malhete-lembretes-diarios', '0 12 * * *', $c$ select private.lembretes_diarios() $c$);
