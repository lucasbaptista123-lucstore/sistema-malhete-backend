-- Sistema Malhete — avisos automáticos ao irmão pelo WhatsApp da loja.
-- Fila única (notificacoes) alimentada por gatilhos: cobrança com link (Asaas), débitos em aberto
-- (rotina diária), baixa de pagamento e trabalho recebido/avaliado. A edge function `whatsapp`
-- (rotina a cada 2 min) envia aos poucos. Cada tipo pode ser desligado pela loja. Textos discretos.

-- =========================================================
-- Configuração da plataforma e da loja
-- =========================================================

create table public.config_plataforma (chave text primary key, valor text not null);
alter table public.config_plataforma enable row level security;
create policy leitura on public.config_plataforma for select to authenticated using (true);
insert into public.config_plataforma values ('app_url', 'https://pixel-perfect-replica-6084.lovable.app');

create table public.avisos_config (
  loja_id uuid primary key references public.lojas(id) on delete cascade,
  cobranca boolean not null default true,
  debitos boolean not null default true,
  debitos_intervalo_dias int not null default 15 check (debitos_intervalo_dias between 3 and 90),
  baixa boolean not null default true,
  trabalhos boolean not null default true,
  atualizado_em timestamptz not null default now()
);
alter table public.avisos_config enable row level security;
create policy le on public.avisos_config for select to authenticated using (loja_id in (select public.minhas_lojas()));
create policy configura on public.avisos_config for all to authenticated
  using ((select public.whatsapp_pode_configurar(loja_id)) or (select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check ((select public.whatsapp_pode_configurar(loja_id)) or (select public.tem_permissao(loja_id, 'tesouraria.editar')));
create trigger auditoria after insert or update or delete on public.avisos_config for each row execute function public.registrar_auditoria();

-- =========================================================
-- Fila
-- =========================================================

create table public.notificacoes (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  irmao_id uuid not null references public.irmaos(id),
  tipo text not null check (tipo in ('cobranca', 'debito', 'baixa', 'trabalho_recebido', 'trabalho_avaliado')),
  referencia uuid,                 -- título, lançamento ou trabalho
  mensagem text not null,
  telefone text,
  status text not null default 'pendente' check (status in ('pendente', 'enviado', 'sem_telefone', 'falhou', 'descartado')),
  erro text,
  criado_em timestamptz not null default now(),
  enviado_em timestamptz
);
create index on public.notificacoes (status, criado_em) where status = 'pendente';
create index on public.notificacoes (loja_id, criado_em desc);
create index on public.notificacoes (irmao_id, tipo, criado_em desc);
alter table public.notificacoes enable row level security;
-- quem configura os avisos acompanha o que saiu; o irmão vê os seus
create policy le on public.notificacoes for select to authenticated
  using (irmao_id = (select public.meu_irmao_id(loja_id))
         or (select public.whatsapp_pode_configurar(loja_id))
         or (select public.tem_permissao(loja_id, 'tesouraria.ler')));

create function private.primeiro_nome(p_nome text) returns text
language sql immutable set search_path = '' as $$ select split_part(trim(coalesce(p_nome, '')), ' ', 1) $$;

create function private.moeda(p numeric) returns text
language sql immutable set search_path = '' as $$
  select 'R$ ' || replace(replace(replace(to_char(p, 'FM999G999G990D00'), ',', '#'), '.', ','), '#', '.')
$$;

-- Enfileira se o tipo estiver ligado na loja (sem configuração = tudo ligado).
create function private.notificar(p_loja uuid, p_irmao uuid, p_tipo text, p_ref uuid, p_msg text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  c public.avisos_config;
  v_tel text;
begin
  select * into c from public.avisos_config where loja_id = p_loja;
  if c.loja_id is not null and not (case p_tipo
      when 'cobranca' then c.cobranca when 'debito' then c.debitos when 'baixa' then c.baixa else c.trabalhos end) then
    return;
  end if;
  select nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_tel from public.irmaos where id = p_irmao and situacao in ('ativo', 'licenciado');
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  values (p_loja, p_irmao, p_tipo, p_ref, p_msg, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
end $$;

-- =========================================================
-- Gatilhos
-- =========================================================

-- Cobrança do irmão ganhou link de pagamento (criada no Asaas por aqui ou espelhada de lá).
create function private.aviso_cobranca() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.asaas_link is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Segue o link para pagamento de %s — %s, vencimento %s:%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), E'\n', new.asaas_link));
  return new;
end $$;
create trigger aviso_cobranca after insert or update of asaas_link on public.titulos
for each row execute function private.aviso_cobranca();

-- Baixa de conta a receber do irmão (manual ou automática pelo Asaas).
create function private.aviso_baixa() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  t public.titulos;
  v_nome text;
begin
  if new.titulo_id is null or new.estorno_de is not null or new.tipo <> 'receita' then return new; end if;
  select * into t from public.titulos where id = new.titulo_id;
  if t.irmao_id is null then return new; end if;
  select nome into v_nome from public.irmaos where id = t.irmao_id;
  perform private.notificar(new.loja_id, t.irmao_id, 'baixa', new.id,
    format('Olá, %s! Recebemos seu pagamento de %s referente a %s. Obrigado!',
           private.primeiro_nome(v_nome), private.moeda(new.valor), t.descricao));
  return new;
end $$;
create trigger aviso_baixa after insert on public.lancamentos
for each row execute function private.aviso_baixa();

-- Trabalho recebido e avaliado.
create function private.aviso_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_nome text;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  if tg_op = 'INSERT' or (old.status <> 'enviado' and new.status = 'enviado') then
    perform private.notificar(new.loja_id, new.irmao_id, 'trabalho_recebido', new.id,
      format('Olá, %s! Seu trabalho “%s” foi recebido e está em avaliação.', private.primeiro_nome(v_nome), new.titulo));
  elsif new.status is distinct from old.status and new.status in ('aprovado', 'ajustes') then
    perform private.notificar(new.loja_id, new.irmao_id, 'trabalho_avaliado', new.id,
      case when new.status = 'aprovado'
        then format('Olá, %s! Seu trabalho “%s” foi avaliado e aprovado.%s', private.primeiro_nome(v_nome), new.titulo,
                    case when new.parecer is not null then E'\n' || 'Parecer: ' || new.parecer else '' end)
        else format('Olá, %s! Seu trabalho “%s” foi avaliado e há ajustes pedidos:%s%s%sPara reenviar: %s/app/trabalhos',
                    private.primeiro_nome(v_nome), new.titulo, E'\n', coalesce(new.parecer, ''), E'\n\n', v_url)
      end);
  end if;
  return new;
end $$;
create trigger aviso_trabalho after insert or update of status on public.trabalhos
for each row execute function private.aviso_trabalho();

-- =========================================================
-- Rotina diária: aviso de débitos (vencido há mais de 3 dias, no máximo 1 a cada N dias por irmão)
-- =========================================================

create function public.gerar_avisos_debito() returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  for r in
    select t.loja_id, t.irmao_id, i.nome, count(*) as qtd, sum(t.valor - t.valor_pago) as total,
           (array_agg(t.asaas_link order by t.vencimento desc) filter (where t.asaas_link is not null))[1] as link,
           coalesce(c.debitos_intervalo_dias, 15) as intervalo
    from public.titulos t
    join public.irmaos i on i.id = t.irmao_id and i.situacao in ('ativo', 'licenciado')
    join public.integracoes_whatsapp w on w.loja_id = t.loja_id and w.status = 'conectado'
    left join public.avisos_config c on c.loja_id = t.loja_id
    where t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor
      and t.vencimento < current_date - 3 and coalesce(c.debitos, true)
    group by t.loja_id, t.irmao_id, i.nome, c.debitos_intervalo_dias
  loop
    if exists (select 1 from public.notificacoes x where x.irmao_id = r.irmao_id and x.tipo = 'debito'
               and x.criado_em > now() - make_interval(days => r.intervalo)) then
      continue;
    end if;
    perform private.notificar(r.loja_id, r.irmao_id, 'debito', null,
      format('Olá, %s. Consta%s %s em aberto, no total de %s.%s%sSe já acertou, por favor desconsidere. Para ver os detalhes: %s/app/mensalidades',
             private.primeiro_nome(r.nome), case when r.qtd > 1 then 'm' else '' end,
             case when r.qtd > 1 then r.qtd || ' pendências' else '1 pendência' end, private.moeda(r.total),
             case when r.link is not null then E'\n' || 'Link para pagamento: ' || r.link else '' end, E'\n\n', v_url));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Para a edge function: próximos a enviar (só lojas com WhatsApp conectado); descarta o que ficou velho.
create function public.notificacoes_proximas(p_por_loja int default 4)
returns table (id uuid, loja_id uuid, telefone text, mensagem text)
language plpgsql security definer set search_path = '' as $$
begin
  update public.notificacoes set status = 'descartado', erro = 'WhatsApp desconectado por mais de 3 dias'
  where status = 'pendente' and criado_em < now() - interval '3 days';
  return query
  select x.id, x.loja_id, x.telefone, x.mensagem from (
    select n.*, row_number() over (partition by n.loja_id order by n.criado_em) as k
    from public.notificacoes n
    join public.integracoes_whatsapp w on w.loja_id = n.loja_id and w.status = 'conectado'
    where n.status = 'pendente'
  ) x where x.k <= p_por_loja;
end $$;

-- Envio manual (Tesouraria): cobrança de um título agora / aviso de débito de um irmão agora.
create function public.avisar_cobranca(p_titulo uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t public.titulos;
  v_nome text;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or not public.tem_permissao(t.loja_id, 'tesouraria.editar') then raise exception 'Sem permissão'; end if;
  if t.irmao_id is null or t.asaas_link is null then raise exception 'Esta conta não tem irmão ou link de pagamento'; end if;
  select nome into v_nome from public.irmaos where id = t.irmao_id;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select t.loja_id, t.irmao_id, 'cobranca', t.id,
         format('Olá, %s! Segue o link para pagamento de %s — %s, vencimento %s:%s%s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago), to_char(t.vencimento, 'DD/MM/YYYY'), E'\n', t.asaas_link),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
end $$;

-- =========================================================
-- Rotinas: aviso de débitos às 10h (13h UTC) e envio da fila a cada 2 minutos
-- =========================================================

select cron.schedule('malhete-avisos-debito', '0 13 * * *', $c$ select public.gerar_avisos_debito() $c$);
select cron.schedule('malhete-whatsapp-fila', '*/2 * * * *', $cron$
  select net.http_post(
    url := 'https://heblivnebprikxcjsuan.supabase.co/functions/v1/whatsapp',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer sb_publishable_Ge7-D-NsdDZgZCHirtTpeA_lfAs0um8',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'malhete_cron_secret')),
    body := '{"acao":"processar_fila"}'::jsonb,
    timeout_milliseconds := 110000)
  where exists (select 1 from public.notificacoes where status = 'pendente')
$cron$);

revoke all on all functions in schema private from public, anon, authenticated;
revoke execute on function public.gerar_avisos_debito, public.notificacoes_proximas from public, anon, authenticated;
grant execute on function public.gerar_avisos_debito, public.notificacoes_proximas to service_role;
revoke execute on function public.avisar_cobranca from public, anon;
grant execute on function public.avisar_cobranca to authenticated;
