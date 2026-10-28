-- Painel do dono completo (28/10): acessos (logins), números e séries para gráficos, cobranças de todas as Lojas,
-- detalhe da Loja, régua de cobrança (avisos do Asaas da plataforma) e configurações de preço/teste/tolerância.
-- Por sigilo, o painel mostra uso e cobrança; dados internos das Lojas só os contatos de cobrança (Venerável e Tesoureiro).

-- ======================= acessos =======================
create table public.acessos (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  loja_id uuid references public.lojas(id) on delete cascade,
  em timestamptz not null default now(),
  ip text,
  dispositivo text
);
create index on public.acessos (em desc);
create index on public.acessos (loja_id, em desc);
create index on public.acessos (user_id, em desc);
alter table public.acessos enable row level security;

-- o app chama ao abrir; no máximo um registro a cada 30 min por pessoa e Loja
create function public.registrar_acesso(p_loja uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare h json := nullif(current_setting('request.headers', true), '')::json;
begin
  if auth.uid() is null or p_loja is null or p_loja not in (select public.minhas_lojas()) then return; end if;
  if exists (select 1 from public.acessos where user_id = auth.uid() and loja_id = p_loja and em > now() - interval '30 minutes') then return; end if;
  insert into public.acessos (user_id, loja_id, ip, dispositivo)
  values (auth.uid(), p_loja, nullif(trim(split_part(coalesce(h->>'x-forwarded-for', h->>'x-real-ip', ''), ',', 1)), ''),
          left(h->>'user-agent', 300));
end $$;

-- ======================= configurações =======================
create function private.fim_teste_padrao() returns date
language sql stable security definer set search_path = '' as $$
  select private.hoje_br() + private.cfg_num('dias_teste', 30)::int
$$;
alter table public.assinaturas alter column teste_ate set default private.fim_teste_padrao();

create function public.plataforma_config() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return (select jsonb_object_agg(chave, valor) from public.config_plataforma)
    || jsonb_build_object('asaas', (select jsonb_build_object('ambiente', ambiente, 'final', chave_final, 'webhook', webhook_id is not null, 'em', conectado_em)
                                    from public.plataforma_asaas where id = 1));
end $$;

create function public.plataforma_config_salvar(p_chave text, p_valor text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  if p_chave not in ('preco_mensal', 'preco_anual', 'dias_teste', 'dias_tolerancia', 'formas_pagamento') then raise exception 'Configuração inválida'; end if;
  if p_chave in ('preco_mensal', 'preco_anual') and (p_valor !~ '^\d+(\.\d{1,2})?$' or p_valor::numeric <= 0) then raise exception 'Valor inválido'; end if;
  if p_chave in ('dias_teste', 'dias_tolerancia') and (p_valor !~ '^\d+$' or p_valor::int > 365) then raise exception 'Número de dias inválido'; end if;
  if p_chave = 'formas_pagamento' and (p_valor = '' or exists (select 1 from unnest(string_to_array(p_valor, ',')) f where f not in ('PIX', 'BOLETO', 'CREDIT_CARD'))) then
    raise exception 'Formas de pagamento inválidas';
  end if;
  insert into public.config_plataforma (chave, valor) values (p_chave, p_valor) on conflict (chave) do update set valor = excluded.valor;
  insert into public.audit_log (tabela, acao, depois) values ('config_plataforma', 'plataforma', jsonb_build_object(p_chave, p_valor));
end $$;

-- ======================= régua de cobrança (avisos do Asaas da plataforma) =======================
create table public.plataforma_regua (
  etapa text primary key check (etapa in ('criada', 'antes', 'no_dia', 'vencida', 'lembrete', 'paga')),
  ordem int not null,
  ativo boolean not null default true,
  email boolean not null default true,
  sms boolean not null default false,
  whatsapp boolean not null default false,
  dias int
);
alter table public.plataforma_regua enable row level security;
insert into public.plataforma_regua (etapa, ordem, ativo, email, sms, whatsapp, dias) values
  ('criada', 1, true, true, false, false, null),
  ('antes', 2, true, true, false, false, 5),
  ('no_dia', 3, true, true, true, false, null),
  ('vencida', 4, true, true, true, false, null),
  ('lembrete', 5, true, true, false, false, 7),
  ('paga', 6, true, true, false, false, null);

create function public.plataforma_regua_ler() returns setof public.plataforma_regua
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Acesso restrito';
  end if;
  return query select * from public.plataforma_regua order by ordem;
end $$;

create function public.plataforma_regua_salvar(p_itens jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare x jsonb;
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  for x in select * from jsonb_array_elements(p_itens) loop
    if x->>'etapa' = 'antes' and (x->>'dias')::int not in (5, 10, 15, 30) then raise exception 'Aviso antes do vencimento: 5, 10, 15 ou 30 dias'; end if;
    if x->>'etapa' = 'lembrete' and (x->>'dias')::int not in (1, 7, 15, 30) then raise exception 'Lembrete depois do vencimento: a cada 1, 7, 15 ou 30 dias'; end if;
    update public.plataforma_regua set ativo = coalesce((x->>'ativo')::boolean, ativo), email = coalesce((x->>'email')::boolean, email),
      sms = coalesce((x->>'sms')::boolean, sms), whatsapp = coalesce((x->>'whatsapp')::boolean, whatsapp),
      dias = case when etapa in ('antes', 'lembrete') then coalesce((x->>'dias')::int, dias) else null end
    where etapa = x->>'etapa';
  end loop;
end $$;

-- ======================= números e séries =======================
create function public.plataforma_painel(p_de date, p_ate date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare n int := greatest(p_ate - p_de + 1, 1); v_pde date := p_de - (p_ate - p_de + 1); v_pate date := p_de - 1; hoje date := private.hoje_br();
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return jsonb_build_object(
    'kpi', jsonb_build_object(
      'recebido', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'paga' and pago_em between p_de and p_ate),
      'recebido_ant', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'paga' and pago_em between v_pde and v_pate),
      'novas', (select count(*) from public.lojas where (criado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate),
      'novas_ant', (select count(*) from public.lojas where (criado_em at time zone 'America/Sao_Paulo')::date between v_pde and v_pate),
      'cancelamentos', (select count(*) from public.assinaturas where (cancelada_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate),
      'cancelamentos_ant', (select count(*) from public.assinaturas where (cancelada_em at time zone 'America/Sao_Paulo')::date between v_pde and v_pate),
      'acessos', (select count(*) from public.acessos where (em at time zone 'America/Sao_Paulo')::date between p_de and p_ate),
      'acessos_ant', (select count(*) from public.acessos where (em at time zone 'America/Sao_Paulo')::date between v_pde and v_pate),
      'usuarios', (select count(distinct user_id) from public.acessos where (em at time zone 'America/Sao_Paulo')::date between p_de and p_ate),
      'usuarios_ant', (select count(distinct user_id) from public.acessos where (em at time zone 'America/Sao_Paulo')::date between v_pde and v_pate),
      'mrr', (select coalesce(sum(case ciclo when 'anual' then valor / 12 else valor end), 0) from public.assinaturas where status in ('ativa', 'atrasada') and asaas_assinatura_id is not null),
      'em_aberto', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'pendente'),
      'vencido', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'vencida'),
      'irmaos', (select count(*) from public.irmaos i join public.assinaturas a on a.loja_id = i.loja_id where i.situacao = 'ativo'),
      'testes_terminados', (select count(*) from public.assinaturas where teste_ate < hoje and status <> 'vitalicia'),
      'convertidas', (select count(*) from public.assinaturas a where a.teste_ate < hoje and a.status <> 'vitalicia'
                        and exists (select 1 from public.faturas_plataforma f where f.loja_id = a.loja_id and f.status = 'paga'))),
    'status', (select jsonb_build_object(
      'teste', count(*) filter (where status = 'teste'), 'ativa', count(*) filter (where status = 'ativa'),
      'atrasada', count(*) filter (where status = 'atrasada'), 'cancelada', count(*) filter (where status = 'cancelada'),
      'vitalicia', count(*) filter (where status = 'vitalicia'), 'travadas', count(*) filter (where not private.loja_liberada(loja_id)))
      from public.assinaturas),
    'receita_mensal', (select jsonb_agg(jsonb_build_object('mes', to_char(m, 'YYYY-MM'),
        'pago', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'paga' and date_trunc('month', pago_em) = m),
        'aberto', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status in ('pendente', 'vencida') and date_trunc('month', vencimento) = m)) order by m)
      from generate_series(date_trunc('month', hoje) - interval '11 months', date_trunc('month', hoje), interval '1 month') m),
    'lojas_mensal', (select jsonb_agg(jsonb_build_object('mes', to_char(m, 'YYYY-MM'),
        'novas', (select count(*) from public.lojas where date_trunc('month', criado_em at time zone 'America/Sao_Paulo') = m),
        'canceladas', (select count(*) from public.assinaturas where date_trunc('month', cancelada_em at time zone 'America/Sao_Paulo') = m)) order by m)
      from generate_series(date_trunc('month', hoje) - interval '11 months', date_trunc('month', hoje), interval '1 month') m),
    'acessos_dia', (select jsonb_agg(jsonb_build_object('dia', d::date,
        'acessos', (select count(*) from public.acessos where (em at time zone 'America/Sao_Paulo')::date = d::date),
        'usuarios', (select count(distinct user_id) from public.acessos where (em at time zone 'America/Sao_Paulo')::date = d::date)) order by d)
      from generate_series(p_de, p_ate, interval '1 day') d),
    'ranking_lojas', (select coalesce(jsonb_agg(x order by x.acessos desc), '[]') from (
        select trim(l.nome) || coalesce(' nº ' || l.numero, '') as loja, l.id as loja_id, count(*) as acessos, count(distinct a.user_id) as usuarios
        from public.acessos a join public.lojas l on l.id = a.loja_id
        where (a.em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
        group by l.id order by count(*) desc limit 8) x),
    'dias', n);
end $$;

-- todas as cobranças, com a Loja
create function public.plataforma_faturas(p_de date, p_ate date)
returns table (id uuid, asaas_id text, loja_id uuid, loja text, valor numeric, vencimento date, status text, forma text, link text, pago_em date)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select f.id, f.asaas_id, f.loja_id, (trim(l.nome) || coalesce(' nº ' || l.numero, ''))::text, f.valor::numeric, f.vencimento, f.status, f.forma, f.link, f.pago_em
  from public.faturas_plataforma f join public.lojas l on l.id = f.loja_id
  where f.vencimento between p_de and p_ate or (f.status in ('pendente', 'vencida'))
  order by f.vencimento desc;
end $$;

-- logins
create function public.plataforma_acessos(p_loja uuid, p_de date, p_ate date, p_limite int default 500)
returns table (em timestamptz, loja_id uuid, loja text, email text, ip text, dispositivo text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select a.em, a.loja_id, (trim(l.nome) || coalesce(' nº ' || l.numero, ''))::text, u.email::text, a.ip, a.dispositivo
  from public.acessos a join auth.users u on u.id = a.user_id left join public.lojas l on l.id = a.loja_id
  where (p_loja is null or a.loja_id = p_loja) and (a.em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
  order by a.em desc limit least(coalesce(p_limite, 500), 2000);
end $$;

-- detalhe da Loja
create function public.plataforma_loja(p_loja uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare hoje date := private.hoje_br();
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return (select jsonb_build_object(
    'loja', jsonb_build_object('id', l.id, 'nome', trim(l.nome), 'numero', l.numero, 'cidade', l.cidade, 'uf', l.uf, 'cnpj', l.cnpj,
                               'criada_em', l.criado_em, 'rito', (select nome from public.ritos where id = l.rito_id),
                               'oriente', (select nome from public.orientes where id = l.oriente_id)),
    'assinatura', to_jsonb(a) - 'asaas_cliente_id' || jsonb_build_object('liberada', private.loja_liberada(l.id), 'cliente_asaas', a.asaas_cliente_id),
    'uso', jsonb_build_object(
      'irmaos', (select count(*) from public.irmaos where loja_id = l.id and situacao = 'ativo'),
      'com_acesso', (select count(*) from public.irmaos where loja_id = l.id and user_id is not null),
      'sessoes_90d', (select count(*) from public.sessoes where loja_id = l.id and status = 'realizada' and data > hoje - 90),
      'acessos_30d', (select count(*) from public.acessos where loja_id = l.id and em > now() - interval '30 days'),
      'usuarios_30d', (select count(distinct user_id) from public.acessos where loja_id = l.id and em > now() - interval '30 days'),
      'whatsapp', coalesce((select status from public.integracoes_whatsapp where loja_id = l.id), 'sem'),
      'asaas', exists (select 1 from public.integracoes_asaas where loja_id = l.id and ativo)),
    'contatos', (select coalesce(jsonb_agg(jsonb_build_object('cargo', c.nome, 'nome', i.nome, 'email', i.email, 'telefone', i.telefone) order by c.ordem), '[]')
                 from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id join public.irmaos i on i.id = m.irmao_id
                 where m.loja_id = l.id and c.codigo in ('veneravel', 'tesoureiro') and current_date between m.inicio and m.fim),
    'usuarios', (select coalesce(jsonb_agg(x order by x.ultimo desc nulls last), '[]') from (
                 select u.email, max(ac.em) as ultimo, count(ac.id) filter (where ac.em > now() - interval '30 days') as acessos_30d
                 from public.irmaos i join auth.users u on u.id = i.user_id left join public.acessos ac on ac.user_id = u.id and ac.loja_id = l.id
                 where i.loja_id = l.id group by u.email) x),
    'acessos_dia', (select jsonb_agg(jsonb_build_object('dia', d::date,
                      'acessos', (select count(*) from public.acessos where loja_id = l.id and (em at time zone 'America/Sao_Paulo')::date = d::date)) order by d)
                    from generate_series(hoje - 29, hoje, interval '1 day') d),
    'faturas', (select coalesce(jsonb_agg(to_jsonb(f) order by f.vencimento desc), '[]') from public.faturas_plataforma f where f.loja_id = l.id),
    'historico', (select coalesce(jsonb_agg(jsonb_build_object('em', g.em, 'acao', g.depois) order by g.em desc), '[]')
                  from public.audit_log g where g.loja_id = l.id and g.tabela = 'assinaturas'))
  from public.lojas l left join public.assinaturas a on a.loja_id = l.id where l.id = p_loja);
end $$;

-- para a edge function aplicar a régua em todos os clientes
create function public.plataforma_clientes_asaas() returns table (loja_id uuid, cliente text)
language sql stable security definer set search_path = '' as $$
  select loja_id, asaas_cliente_id from public.assinaturas where asaas_cliente_id is not null
    and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
$$;

revoke execute on function public.registrar_acesso, public.plataforma_config, public.plataforma_config_salvar, public.plataforma_regua_ler,
  public.plataforma_regua_salvar, public.plataforma_painel, public.plataforma_faturas, public.plataforma_acessos, public.plataforma_loja,
  public.plataforma_clientes_asaas from public, anon;
grant execute on function public.registrar_acesso, public.plataforma_config, public.plataforma_config_salvar, public.plataforma_regua_ler,
  public.plataforma_regua_salvar, public.plataforma_painel, public.plataforma_faturas, public.plataforma_acessos, public.plataforma_loja to authenticated;
revoke execute on function public.plataforma_clientes_asaas from authenticated;
grant execute on function public.plataforma_clientes_asaas, public.plataforma_regua_ler to service_role;
