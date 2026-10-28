-- Planos e cobrança das Lojas assinantes (28/10, decisões do Lucas):
--   mensal R$ 199, anual R$ 1.790, 30 dias de teste; PIX e boleto (cartão desligado por enquanto);
--   a Loja TRAVA 5 dias depois do vencimento sem pagamento e VOLTA sozinha quando o pagamento cai;
--   o Tesoureiro (tesouraria.editar) paga; o Venerável (loja.config) vê e pode cancelar.
-- Cobrança pela conta Asaas DA PLATAFORMA (CNPJ 34.359.645/0001-37), separada das contas das Lojas.
-- A chave é colada pelo dono no painel Plataforma e fica no Vault (nunca passa pelo app).

-- ======================= configuração =======================
insert into public.config_plataforma (chave, valor) values
  ('preco_mensal', '199'), ('preco_anual', '1790'), ('dias_teste', '30'), ('dias_tolerancia', '5'),
  ('formas_pagamento', 'PIX,BOLETO')
on conflict (chave) do nothing;

create function private.cfg_num(p text, p_padrao numeric) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select nullif(valor, '')::numeric from public.config_plataforma where chave = p), p_padrao)
$$;
create function private.hoje_br() returns date
language sql stable set search_path = '' as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

-- chave do Asaas da plataforma (uma linha só; sem acesso pelo app)
create table public.plataforma_asaas (
  id int primary key default 1 check (id = 1),
  ambiente text not null check (ambiente in ('producao', 'sandbox')),
  segredo_id uuid not null,
  chave_final text,
  webhook_id text,
  webhook_token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  conectado_em timestamptz not null default now()
);
alter table public.plataforma_asaas enable row level security;

create function public.plataforma_asaas_conectar(p_chave text, p_ambiente text) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.plataforma_asaas;
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  if coalesce(length(trim(p_chave)), 0) < 20 then raise exception 'Chave do Asaas inválida'; end if;
  if p_ambiente not in ('producao', 'sandbox') then raise exception 'Ambiente inválido'; end if;
  select * into v from public.plataforma_asaas where id = 1;
  if v.id is null then
    insert into public.plataforma_asaas (ambiente, segredo_id, chave_final)
    values (p_ambiente, vault.create_secret(trim(p_chave), 'asaas_plataforma', 'Chave da API Asaas da plataforma'), right(trim(p_chave), 4));
  else
    perform vault.update_secret(v.segredo_id, trim(p_chave));
    update public.plataforma_asaas set ambiente = p_ambiente, chave_final = right(trim(p_chave), 4), conectado_em = now() where id = 1;
  end if;
end $$;

create function public.plataforma_asaas_credencial() returns table (chave text, ambiente text, webhook_id text, webhook_token text)
language sql security definer set search_path = '' as $$
  select s.decrypted_secret, p.ambiente, p.webhook_id, p.webhook_token
  from public.plataforma_asaas p join vault.decrypted_secrets s on s.id = p.segredo_id
  where p.id = 1 and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role'
$$;

-- ======================= assinatura e faturas =======================
alter table public.assinaturas
  add column ciclo text check (ciclo in ('mensal', 'anual')),
  add column valor numeric(10, 2),
  add column forma text,
  add column asaas_cliente_id text,
  add column asaas_assinatura_id text unique,
  add column proximo_vencimento date,
  add column acesso_ate date,
  add column bloqueio_manual boolean not null default false,
  add column liberada_ate date,
  add column cancelada_em timestamptz,
  add column motivo_cancelamento text,
  add column atualizado_em timestamptz not null default now();
alter table public.assinaturas alter column teste_ate set default ((now() at time zone 'America/Sao_Paulo')::date + 30);

create table public.faturas_plataforma (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  asaas_id text not null unique,
  valor numeric(10, 2) not null,
  vencimento date not null,
  status text not null check (status in ('pendente', 'vencida', 'paga', 'cancelada', 'estornada')),
  forma text,
  link text,
  pago_em date,
  atualizado_em timestamptz not null default now()
);
create index on public.faturas_plataforma (loja_id, vencimento desc);
alter table public.faturas_plataforma enable row level security;

-- ======================= trava =======================
-- Loja liberada? Teste até o fim (+ tolerância); assinante sem fatura vencida há mais de 5 dias; cancelada até o fim
-- do período pago; vitalícia sempre. O dono pode liberar até uma data (liberada_ate) ou travar à mão.
create function private.loja_liberada(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when a.liberada_ate is not null and a.liberada_ate >= private.hoje_br() then true
      when a.bloqueio_manual then false
      when a.status = 'vitalicia' then true
      when a.status = 'cancelada' then coalesce(a.acesso_ate, a.teste_ate, private.hoje_br() - 1) >= private.hoje_br()
      when exists (select 1 from public.faturas_plataforma f
                   where f.loja_id = a.loja_id and f.status in ('pendente', 'vencida')
                     and f.vencimento + private.cfg_num('dias_tolerancia', 5)::int < private.hoje_br()) then false
      when a.status = 'teste' and a.asaas_assinatura_id is null
        then a.teste_ate + private.cfg_num('dias_tolerancia', 5)::int >= private.hoje_br()
      else true
    end
    from public.assinaturas a where a.loja_id = p_loja), true)
$$;

-- permissão "crua" (sem olhar a assinatura): usada só para a própria assinatura, que precisa funcionar com a Loja travada
-- (as políticas de RLS apontam para public.tem_permissao pelo OID: a função continua a mesma, só muda o corpo)
create function private.tem_permissao_base(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  with exclusiva as (
    select p_perm = any (public.permissoes_exclusivas()) as sim
  )
  select exists (
    select 1 from public.irmaos i, exclusiva x
    where i.loja_id = p_loja and i.user_id = auth.uid() and i.situacao = 'ativo' and private.mfa_ok()
      and (
        (i.admin_loja and (
           not x.sim
           or not exists (
             select 1 from public.mandatos m2
             join public.loja_cargos c2 on c2.id = m2.cargo_id
             where m2.loja_id = p_loja and current_date between m2.inicio and m2.fim
               and p_perm = any (c2.permissoes))))
        or exists (
          select 1 from public.mandatos m
          join public.loja_cargos c on c.id = m.cargo_id
          where m.irmao_id = i.id
            and current_date between m.inicio and m.fim
            and (
              ('*' = any (c.permissoes) and not x.sim)
              or p_perm = any (c.permissoes)
              or (p_perm like '%.ler' and replace(p_perm, '.ler', '.editar') = any (c.permissoes))
            )
        )
      )
  )
$$;
create or replace function public.tem_permissao(p_loja uuid, p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.tem_permissao_base(p_loja, p_perm) and private.loja_liberada(p_loja)
$$;
revoke execute on function private.tem_permissao_base(uuid, text) from public, anon, authenticated;

create or replace function public.pode_ver_grau(p_loja uuid, p_grau_minimo smallint) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.meu_grau(p_loja) >= p_grau_minimo and private.loja_liberada(p_loja)
$$;

-- leitura da assinatura e das faturas: Venerável e Tesoureiro, mesmo com a Loja travada
create function public.pode_ver_assinatura(p_loja uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.tem_permissao_base(p_loja, 'loja.config') or private.tem_permissao_base(p_loja, 'tesouraria.editar')
$$;
drop policy if exists config_le on public.assinaturas;
create policy le on public.assinaturas for select to authenticated using ((select public.pode_ver_assinatura(loja_id)));
create policy le on public.faturas_plataforma for select to authenticated using ((select public.pode_ver_assinatura(loja_id)));
grant select on public.faturas_plataforma to authenticated;

-- o que cada um vê da assinatura (todo membro sabe se está travada; números só para quem administra)
create function public.minha_assinatura(p_loja uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a public.assinaturas; v_paga boolean; v_ve boolean; v_venc date;
begin
  if p_loja not in (select public.minhas_lojas()) then raise exception 'Sem acesso'; end if;
  select * into a from public.assinaturas where loja_id = p_loja;
  v_paga := private.tem_permissao_base(p_loja, 'tesouraria.editar');
  v_ve := v_paga or private.tem_permissao_base(p_loja, 'loja.config');
  select min(vencimento) into v_venc from public.faturas_plataforma where loja_id = p_loja and status in ('pendente', 'vencida');
  return jsonb_build_object(
    'liberada', private.loja_liberada(p_loja), 'status', a.status, 'pode_pagar', v_paga,
    'pode_cancelar', private.tem_permissao_base(p_loja, 'loja.config'), 've_detalhes', v_ve,
    'teste_ate', a.teste_ate, 'fatura_aberta', v_venc,
    'trava_em', case when v_venc is not null then v_venc + private.cfg_num('dias_tolerancia', 5)::int + 1
                     when a.status = 'teste' and a.asaas_assinatura_id is null then a.teste_ate + private.cfg_num('dias_tolerancia', 5)::int + 1 end,
    'ciclo', case when v_ve then a.ciclo end, 'valor', case when v_ve then a.valor end, 'forma', case when v_ve then a.forma end,
    'assinou', a.asaas_assinatura_id is not null, 'proximo_vencimento', case when v_ve then a.proximo_vencimento end,
    'acesso_ate', a.acesso_ate,
    'preco_mensal', private.cfg_num('preco_mensal', 199), 'preco_anual', private.cfg_num('preco_anual', 1790),
    'formas', (select valor from public.config_plataforma where chave = 'formas_pagamento'));
end $$;

-- ======================= funções da edge function (service_role) =======================
create function public.plataforma_registrar_assinatura(p_loja uuid, p_ciclo text, p_valor numeric, p_forma text,
                                                       p_cliente text, p_assinatura text, p_proximo date) returns void
language sql security definer set search_path = '' as $$
  update public.assinaturas set ciclo = p_ciclo, valor = p_valor, forma = p_forma, asaas_cliente_id = p_cliente,
         asaas_assinatura_id = p_assinatura, proximo_vencimento = p_proximo, cancelada_em = null, motivo_cancelamento = null,
         acesso_ate = null, status = case when status in ('cancelada', 'atrasada') then 'ativa' else status end, atualizado_em = now()
  where loja_id = p_loja and status <> 'vitalicia'
$$;

-- espelha uma cobrança da assinatura (webhook ou leitura): paga -> ativa; vencida -> atrasada
create function public.plataforma_espelhar_fatura(p_assinatura text, p_id text, p_valor numeric, p_vencimento date,
                                                  p_status text, p_forma text, p_link text, p_pago date) returns text
language plpgsql security definer set search_path = '' as $$
declare a public.assinaturas; v_status text;
begin
  select * into a from public.assinaturas where asaas_assinatura_id = p_assinatura;
  if a.id is null then return 'assinatura desconhecida'; end if;
  v_status := case
    when p_status in ('RECEIVED', 'CONFIRMED', 'RECEIVED_IN_CASH') then 'paga'
    when p_status = 'OVERDUE' then 'vencida'
    when p_status in ('REFUNDED', 'REFUND_REQUESTED', 'CHARGEBACK_REQUESTED') then 'estornada'
    when p_status = 'DELETED' then 'cancelada'
    else 'pendente' end;
  insert into public.faturas_plataforma (loja_id, asaas_id, valor, vencimento, status, forma, link, pago_em)
  values (a.loja_id, p_id, p_valor, p_vencimento, v_status, p_forma, p_link, p_pago)
  on conflict (asaas_id) do update set valor = excluded.valor, vencimento = excluded.vencimento, status = excluded.status,
     forma = excluded.forma, link = coalesce(excluded.link, faturas_plataforma.link), pago_em = excluded.pago_em, atualizado_em = now();
  if v_status = 'paga' and a.status not in ('vitalicia', 'cancelada') then
    update public.assinaturas set status = 'ativa',
      proximo_vencimento = greatest(coalesce(proximo_vencimento, p_vencimento),
                                    (p_vencimento + case ciclo when 'anual' then interval '1 year' else interval '1 month' end)::date),
      atualizado_em = now()
    where id = a.id;
  elsif v_status = 'vencida' and a.status in ('ativa', 'teste') then
    update public.assinaturas set status = 'atrasada', atualizado_em = now() where id = a.id;
  end if;
  if v_status = 'paga' and not exists (select 1 from public.faturas_plataforma where loja_id = a.loja_id and status = 'vencida') then
    update public.assinaturas set status = 'ativa' where id = a.id and status = 'atrasada';
  end if;
  return v_status;
end $$;

create function public.plataforma_cancelar(p_loja uuid, p_motivo text, p_acesso_ate date) returns void
language sql security definer set search_path = '' as $$
  update public.assinaturas set status = 'cancelada', cancelada_em = now(), motivo_cancelamento = p_motivo,
         acesso_ate = p_acesso_ate, asaas_assinatura_id = null, atualizado_em = now()
  where loja_id = p_loja and status <> 'vitalicia';
  update public.faturas_plataforma set status = 'cancelada', atualizado_em = now()
  where loja_id = p_loja and status in ('pendente', 'vencida');
$$;

-- ======================= painel do dono =======================
drop function public.plataforma_lojas();
create function public.plataforma_lojas()
returns table (
  loja_id uuid, nome text, numero text, cidade text, uf text, criada_em timestamptz,
  status text, plano text, teste_ate date, ciclo text, valor numeric, forma text, proximo_vencimento date,
  liberada boolean, bloqueio_manual boolean, liberada_ate date, faturas_abertas int, valor_aberto numeric,
  pago_total numeric, irmaos_ativos int, com_acesso int, whatsapp text, asaas boolean, ultima_atividade timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return query
  select l.id, trim(l.nome), l.numero, l.cidade, l.uf, l.criado_em,
         a.status, a.plano, a.teste_ate, a.ciclo, a.valor, a.forma, a.proximo_vencimento,
         private.loja_liberada(l.id), a.bloqueio_manual, a.liberada_ate,
         (select count(*)::int from public.faturas_plataforma f where f.loja_id = l.id and f.status in ('pendente', 'vencida')),
         (select coalesce(sum(f.valor), 0) from public.faturas_plataforma f where f.loja_id = l.id and f.status in ('pendente', 'vencida')),
         (select coalesce(sum(f.valor), 0) from public.faturas_plataforma f where f.loja_id = l.id and f.status = 'paga'),
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.situacao = 'ativo'),
         (select count(*)::int from public.irmaos i where i.loja_id = l.id and i.user_id is not null),
         coalesce((select w.status from public.integracoes_whatsapp w where w.loja_id = l.id), 'sem'),
         exists (select 1 from public.integracoes_asaas x where x.loja_id = l.id and x.ativo),
         (select max(g.criado_em) from public.audit_log g where g.loja_id = l.id)
  from public.lojas l left join public.assinaturas a on a.loja_id = l.id
  order by l.criado_em desc;
end $$;

-- ajustes do dono: estender teste, liberar até uma data, travar/destravar, vitalícia
create function public.plataforma_ajustar(p_loja uuid, p_acao text, p_data date default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  case p_acao
    when 'estender_teste' then update public.assinaturas set teste_ate = p_data, status = case when status = 'teste' then 'teste' else status end where loja_id = p_loja;
    when 'liberar_ate' then update public.assinaturas set liberada_ate = p_data, bloqueio_manual = false where loja_id = p_loja;
    when 'travar' then update public.assinaturas set bloqueio_manual = true, liberada_ate = null where loja_id = p_loja;
    when 'destravar' then update public.assinaturas set bloqueio_manual = false where loja_id = p_loja;
    when 'vitalicia' then update public.assinaturas set status = 'vitalicia', plano = 'vitalicio', bloqueio_manual = false where loja_id = p_loja;
    when 'tirar_vitalicia' then update public.assinaturas set status = 'teste', plano = 'teste', teste_ate = coalesce(p_data, private.hoje_br() + 30) where loja_id = p_loja and status = 'vitalicia';
    else raise exception 'Ação inválida';
  end case;
  update public.assinaturas set atualizado_em = now() where loja_id = p_loja;
  insert into public.audit_log (loja_id, tabela, registro_id, acao, depois)
  values (p_loja, 'assinaturas', null, 'plataforma', jsonb_build_object('acao', p_acao, 'data', p_data));
end $$;

create function public.plataforma_resumo() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin_plataforma() then raise exception 'Acesso restrito'; end if;
  return (select jsonb_build_object(
    'lojas', count(*), 'teste', count(*) filter (where a.status = 'teste'), 'ativas', count(*) filter (where a.status = 'ativa'),
    'atrasadas', count(*) filter (where a.status = 'atrasada'), 'canceladas', count(*) filter (where a.status = 'cancelada'),
    'vitalicias', count(*) filter (where a.status = 'vitalicia'),
    'travadas', count(*) filter (where not private.loja_liberada(a.loja_id)),
    'receita_mensal', coalesce(sum(case when a.status in ('ativa', 'atrasada') then case a.ciclo when 'anual' then a.valor / 12 else a.valor end end), 0),
    'recebido_mes', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status = 'paga' and date_trunc('month', pago_em) = date_trunc('month', private.hoje_br())),
    'em_aberto', (select coalesce(sum(valor), 0) from public.faturas_plataforma where status in ('pendente', 'vencida')),
    'asaas_conectado', exists (select 1 from public.plataforma_asaas))
  from public.assinaturas a);
end $$;

revoke execute on function private.cfg_num, private.loja_liberada, private.hoje_br from public, anon, authenticated;
revoke execute on function public.pode_ver_assinatura from public, anon;
grant execute on function public.pode_ver_assinatura to authenticated;
revoke execute on function public.plataforma_asaas_credencial, public.plataforma_registrar_assinatura,
  public.plataforma_espelhar_fatura, public.plataforma_cancelar from public, anon, authenticated;
grant execute on function public.plataforma_asaas_credencial, public.plataforma_registrar_assinatura,
  public.plataforma_espelhar_fatura, public.plataforma_cancelar to service_role;
revoke execute on function public.plataforma_asaas_conectar, public.minha_assinatura, public.plataforma_lojas,
  public.plataforma_ajustar, public.plataforma_resumo from public, anon;
grant execute on function public.plataforma_asaas_conectar, public.minha_assinatura, public.plataforma_lojas,
  public.plataforma_ajustar, public.plataforma_resumo to authenticated;
