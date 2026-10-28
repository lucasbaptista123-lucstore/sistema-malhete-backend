-- Sistema Malhete — RÉGUA DE COBRANÇA configurável por loja.
-- Cada etapa: dias em relação ao vencimento (negativo = antes), quem recebe (o irmão ou a Tesouraria), o que
-- cobra (só mensalidade ou todas as pendências) e o texto. Um envio por irmão por etapa por dia, juntando os
-- títulos que caem naquela etapa; cada título passa uma vez só por etapa (`regua_enviados`). Pagou → sai da régua.
-- Substitui o aviso de débito fixo: gerar_avisos_debito() (job malhete-avisos-debito) passa a rodar a régua.
-- Liga/desliga geral continua em avisos_config.debitos.

create table public.regua_etapas (
  id uuid primary key default gen_random_uuid(),
  loja_id uuid not null references public.lojas(id) on delete cascade,
  dias int not null check (dias between -30 and 365),
  destino text not null default 'irmao' check (destino in ('irmao', 'tesouraria')),
  alcance text not null default 'todas' check (alcance in ('mensalidade', 'todas')),
  mensagem text not null check (length(trim(mensagem)) between 10 and 1500),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  unique (loja_id, dias, destino, alcance)
);
create index on public.regua_etapas (loja_id);
alter table public.regua_etapas enable row level security;
create policy le on public.regua_etapas for select to authenticated using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));
create policy edita on public.regua_etapas for all to authenticated
  using ((select public.tem_permissao(loja_id, 'tesouraria.editar')))
  with check ((select public.tem_permissao(loja_id, 'tesouraria.editar')));
create trigger auditoria after insert or update or delete on public.regua_etapas for each row execute function public.registrar_auditoria();

create table public.regua_enviados (
  etapa_id uuid not null references public.regua_etapas(id) on delete cascade,
  titulo_id uuid not null references public.titulos(id) on delete cascade,
  loja_id uuid not null references public.lojas(id) on delete cascade,
  enviado_em timestamptz not null default now(),
  primary key (etapa_id, titulo_id)
);
create index on public.regua_enviados (titulo_id);
create index on public.regua_enviados (loja_id);
alter table public.regua_enviados enable row level security;
create policy le on public.regua_enviados for select to authenticated using ((select public.tem_permissao(loja_id, 'tesouraria.ler')));

-- etapas padrão (a loja ajusta depois)
create function private.regua_padrao(p_loja uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.regua_etapas (loja_id, dias, destino, alcance, mensagem) values
    (p_loja, -3, 'irmao', 'todas',
     'Olá, {nome}! Lembrete da {loja}: vence em {vencimento}:' || E'\n' || '{itens}' || E'\n' || 'Total: {valor}.' || E'\n' || '{link}'),
    (p_loja, 0, 'irmao', 'todas',
     'Olá, {nome}! Vence hoje:' || E'\n' || '{itens}' || E'\n' || 'Total: {valor}.' || E'\n' || '{link}'),
    (p_loja, 5, 'irmao', 'todas',
     'Olá, {nome}. Consta em aberto na {loja}:' || E'\n' || '{itens}' || E'\n' || 'Total atualizado: {valor}. Se já acertou, por favor desconsidere.' || E'\n' || '{link}'),
    (p_loja, 30, 'irmao', 'todas',
     '{nome}, sua pendência com a {loja} completou 30 dias:' || E'\n' || '{itens}' || E'\n' || 'Total atualizado com encargos: {valor}. Precisando conversar, procure o Tesoureiro.' || E'\n' || '{link}'),
    (p_loja, 60, 'tesouraria', 'todas',
     'Tesouraria: o irmão {irmao} está com pendência há 60 dias:' || E'\n' || '{itens}' || E'\n' || 'Total atualizado: {valor}.')
  on conflict do nothing
$$;
select private.regua_padrao(id) from public.lojas;
create function private.regua_nova_loja() returns trigger
language plpgsql security definer set search_path = '' as $$
begin perform private.regua_padrao(new.id); return new; end $$;
create trigger zz_regua_padrao after insert on public.lojas for each row execute function private.regua_nova_loja();
revoke execute on function private.regua_padrao, private.regua_nova_loja from public, anon, authenticated;

-- monta o texto de uma etapa para um irmão (também usado na prévia da tela)
create function private.regua_texto(p_modelo text, p_loja uuid, p_irmao uuid, p_titulos uuid[]) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_nome text;
  v_loja text;
  v_itens text;
  v_total numeric;
  v_venc text;
  v_link text;
  v_url text := (select valor from public.config_plataforma where chave = 'app_url');
begin
  select nome into v_nome from public.irmaos where id = p_irmao;
  select trim(nome) || coalesce(' nº ' || numero, '') into v_loja from public.lojas where id = p_loja;
  select string_agg(format('• %s — %s (venc. %s)', t.descricao,
                           private.moeda(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
                           to_char(t.vencimento, 'DD/MM')), E'\n' order by t.vencimento),
         sum(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
         string_agg(distinct to_char(t.vencimento, 'DD/MM'), ', '),
         (array_agg(t.asaas_link order by t.vencimento) filter (where t.asaas_link is not null))[1]
    into v_itens, v_total, v_venc, v_link
  from public.titulos t where t.id = any (p_titulos);
  return replace(replace(replace(replace(replace(replace(replace(p_modelo,
    '{nome}', coalesce(private.primeiro_nome(v_nome), 'irmão')),
    '{irmao}', coalesce(v_nome, '')),
    '{loja}', coalesce(v_loja, '')),
    '{itens}', coalesce(v_itens, '')),
    '{valor}', private.moeda(coalesce(v_total, 0))),
    '{vencimento}', coalesce(v_venc, '')),
    '{link}', coalesce('Pagar: ' || v_link, 'Ver e pagar: ' || v_url || '/app/mensalidades'));
end $$;
revoke execute on function private.regua_texto from public, anon, authenticated;

-- roda a régua de todas as lojas (cron diário). Janela de 3 dias para não perder etapa se o cron falhar um dia.
create function public.rodar_regua() returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_msg text;
begin
  for r in
    select e.id as etapa, e.loja_id, e.destino, e.mensagem, t.irmao_id, array_agg(t.id order by t.vencimento) as titulos
    from public.regua_etapas e
    join public.titulos t on t.loja_id = e.loja_id
    join public.irmaos i on i.id = t.irmao_id and i.situacao in ('ativo', 'licenciado')
    join public.integracoes_whatsapp w on w.loja_id = e.loja_id and w.status = 'conectado'
    left join public.avisos_config c on c.loja_id = e.loja_id
    where e.ativo and coalesce(c.debitos, true)
      and t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor
      and (e.alcance = 'todas' or t.origem = 'mensalidade')
      and t.vencimento + e.dias between current_date - 2 and current_date
      and not exists (select 1 from public.regua_enviados x where x.etapa_id = e.id and x.titulo_id = t.id)
    group by e.id, e.loja_id, e.destino, e.mensagem, t.irmao_id
  loop
    v_msg := private.regua_texto(r.mensagem, r.loja_id, r.irmao_id, r.titulos);
    if r.destino = 'irmao' then
      perform private.notificar(r.loja_id, r.irmao_id, 'debito', r.titulos[1], v_msg);
    else
      -- Tesoureiro(s) com cargo vigente; sem Tesoureiro, quem administra a loja
      perform private.notificar(r.loja_id, v.id, 'debito', r.titulos[1], v_msg)
      from public.irmaos v
      where v.loja_id = r.loja_id and v.situacao = 'ativo'
        and (exists (select 1 from public.mandatos m join public.loja_cargos lc on lc.id = m.cargo_id
                     where m.irmao_id = v.id and lc.codigo = 'tesoureiro' and current_date between m.inicio and m.fim)
             or (v.admin_loja and not exists (
                   select 1 from public.mandatos m join public.loja_cargos lc on lc.id = m.cargo_id
                   where m.loja_id = r.loja_id and lc.codigo = 'tesoureiro' and current_date between m.inicio and m.fim)));
    end if;
    insert into public.regua_enviados (etapa_id, titulo_id, loja_id)
    select r.etapa, x, r.loja_id from unnest(r.titulos) x on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.rodar_regua from public, anon, authenticated;
grant execute on function public.rodar_regua to service_role;

-- o job diário de débitos (malhete-avisos-debito) passa a rodar a régua; continua pausado até o OK do Lucas
create or replace function public.gerar_avisos_debito() returns int
language sql security definer set search_path = '' as $$ select public.rodar_regua() $$;
revoke execute on function public.gerar_avisos_debito from public, anon, authenticated;
grant execute on function public.gerar_avisos_debito to service_role;

-- prévia da mensagem na tela (com um irmão de exemplo e os títulos abertos dele)
create function public.regua_previa(p_loja uuid, p_mensagem text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_irmao uuid;
  v_tit uuid[];
begin
  if not public.tem_permissao(p_loja, 'tesouraria.ler') then raise exception 'Sem permissão'; end if;
  select t.irmao_id, array_agg(t.id) into v_irmao, v_tit
  from public.titulos t
  where t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado and t.valor_pago < t.valor and t.irmao_id is not null
  group by t.irmao_id order by count(*) desc limit 1;
  if v_irmao is null then
    return replace(replace(replace(replace(replace(replace(replace(p_mensagem, '{nome}', 'Carlos'), '{irmao}', 'Carlos André'),
      '{loja}', (select trim(nome) from public.lojas where id = p_loja)), '{itens}', '• Mensalidade 11/2026 — R$ 100,00 (venc. 10/11)'),
      '{valor}', 'R$ 100,00'), '{vencimento}', '10/11'), '{link}', 'Ver e pagar: (link)');
  end if;
  return private.regua_texto(p_mensagem, p_loja, v_irmao, v_tit);
end $$;
revoke execute on function public.regua_previa from public, anon;
grant execute on function public.regua_previa to authenticated;

-- os envios automáticos estão ligados? (mostra na tela; hoje pausados a pedido do Lucas)
create function public.envios_automaticos_ligados() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select active from cron.job where jobname = 'malhete-whatsapp-fila'), false)
     and coalesce((select active from cron.job where jobname = 'malhete-avisos-debito'), false)
$$;
revoke execute on function public.envios_automaticos_ligados from public, anon;
grant execute on function public.envios_automaticos_ligados to authenticated;
