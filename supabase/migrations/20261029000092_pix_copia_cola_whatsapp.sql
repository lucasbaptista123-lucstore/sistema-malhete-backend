-- PIX copia e cola no WhatsApp (29/10): a cobrança da mensalidade guarda o código PIX do Asaas
-- (titulos.pix_copia_cola, lido de /payments/{id}/pixQrCode ao criar a cobrança) e todo aviso ao irmão é seguido
-- de uma SEGUNDA mensagem só com o código (o irmão segura e copia, sem precisar entrar no sistema).
alter table public.titulos add column pix_copia_cola text;

-- manda os códigos PIX (até 3) das contas em aberto, cada um numa mensagem, logo depois do aviso
create function private.notificar_pix(p_loja uuid, p_irmao uuid, p_tipo text, p_titulos uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare t record; v_tel text; i int := 0;
begin
  if current_setting('malhete.sem_avisos', true) = 'on' then return; end if;
  -- mesmo liga/desliga dos avisos da Loja (cobrança / débitos)
  if exists (select 1 from public.avisos_config c where c.loja_id = p_loja
             and not (case p_tipo when 'cobranca' then c.cobranca else c.debitos end)) then return; end if;
  select nullif(regexp_replace(coalesce(telefone, ''), '\D', '', 'g'), '') into v_tel from public.irmaos where id = p_irmao and situacao in ('ativo', 'licenciado');
  for t in select id, pix_copia_cola from public.titulos
           where id = any (p_titulos) and pix_copia_cola is not null and not cancelado and valor_pago < valor
           order by vencimento limit 3 loop
    i := i + 1;
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status, criado_em)
    values (p_loja, p_irmao, p_tipo, t.id, t.pix_copia_cola, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end,
            now() + make_interval(secs => i));
  end loop;
end $$;
revoke execute on function private.notificar_pix from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.asaas_vincular(p_loja uuid, p_titulo uuid, p_irmao uuid, p_cliente_id text, p_pg jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform set_config('malhete.sistema', 'on', true);
  if p_irmao is not null and p_cliente_id is not null then
    update public.irmaos set asaas_cliente_id = p_cliente_id where id = p_irmao and loja_id = p_loja;
  end if;
  if p_titulo is not null and p_pg is not null then
    update public.titulos
    set asaas_id = p_pg->>'id', asaas_link = p_pg->>'invoiceUrl', asaas_forma = p_pg->>'billingType', asaas_status = p_pg->>'status', pix_copia_cola = coalesce(p_pg->>'pix_copia_cola', pix_copia_cola)
    where id = p_titulo and loja_id = p_loja and asaas_id is null;
  end if;
  perform set_config('malhete.sistema', 'off', true);
end $function$
;

CREATE OR REPLACE FUNCTION private.regua_texto(p_modelo text, p_loja uuid, p_irmao uuid, p_titulos uuid[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  select string_agg(format('• %s: %s (venc. %s)', t.descricao,
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
    '{link}', case when exists (select 1 from public.titulos where id = any (p_titulos) and pix_copia_cola is not null)
      then 'O PIX copia e cola vem na próxima mensagem: toque e segure para copiar e cole no app do banco. Ou pague pelo sistema: ' || private.link_mensalidades()
      else 'Pague com PIX pelo sistema: ' || private.link_mensalidades() end);
end $function$
;

CREATE OR REPLACE FUNCTION public.rodar_regua()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      perform private.notificar_pix(r.loja_id, r.irmao_id, 'debito', r.titulos);
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
end $function$
;

CREATE OR REPLACE FUNCTION private.aviso_cobranca()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.asaas_link is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Pague com PIX: o copia e cola vem na próxima mensagem, ou pelo sistema:%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), E'\n', private.link_mensalidades()));
  perform private.notificar_pix(new.loja_id, new.irmao_id, 'cobranca', array[new.id]);
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.avisar_cobranca(p_titulo uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
         format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Pague com PIX: o copia e cola vem na próxima mensagem, ou pelo sistema:%s%s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago), to_char(t.vencimento, 'DD/MM/YYYY'), E'\n', private.link_mensalidades()),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
  perform private.notificar_pix(t.loja_id, t.irmao_id, 'cobranca', array[t.id]);
end $function$
;

CREATE OR REPLACE FUNCTION public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r record;
  n int := 0;
  v_txt text;
  v_tel text;
begin
  if not public.tem_permissao(p_loja, 'tesouraria.editar') then raise exception 'Só o Tesoureiro envia avisos de mensalidade'; end if;
  if coalesce(trim(p_mensagem), '') = '' then raise exception 'Escreva a mensagem'; end if;
  for r in
    select i.id, i.nome, i.telefone,
           coalesce(sum(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento))
                    filter (where t.valor_pago < t.valor), 0) as aberto,
           count(*) filter (where t.valor_pago < t.valor and t.vencimento < current_date and t.origem = 'mensalidade') as atrasados,
           string_agg(format('• %s: %s%s%s', t.descricao,
                             private.moeda(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
                             case when t.vencimento < current_date then ' (vencida em ' || to_char(t.vencimento, 'DD/MM')
                                    || case when private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento) > 0
                                            then ', com multa e juros' else '' end || ')'
                                  else ' (vence ' || to_char(t.vencimento, 'DD/MM') || ')' end,
                             ''),
                      E'\n' order by t.vencimento) filter (where t.valor_pago < t.valor) as itens
    from public.irmaos i
    left join public.titulos t on t.irmao_id = i.id and t.loja_id = p_loja and t.natureza = 'receber' and not t.cancelado
    where i.loja_id = p_loja and i.id = any (p_irmaos)
    group by i.id, i.nome, i.telefone
  loop
    v_txt := replace(replace(replace(trim(p_mensagem),
               '{nome}', private.primeiro_nome(r.nome)),
               '{valor}', private.moeda(r.aberto)),
               '{meses}', r.atrasados::text);
    if r.itens is not null then
      v_txt := v_txt || E'\n\nPendências:\n' || r.itens || case when exists (
                 select 1 from public.titulos x where x.irmao_id = r.id and x.loja_id = p_loja and x.pix_copia_cola is not null
                   and not x.cancelado and x.valor_pago < x.valor)
               then E'\n\nO PIX copia e cola vem na próxima mensagem (toque e segure para copiar), ou pague pelo sistema: '
               else E'\n\nPague com PIX pelo sistema: ' end || private.link_mensalidades();
    end if;
    v_tel := nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '');
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (p_loja, r.id, 'debito', null, v_txt, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
    perform private.notificar_pix(p_loja, r.id, 'debito',
      array(select x.id from public.titulos x where x.irmao_id = r.id and x.loja_id = p_loja and x.natureza = 'receber'));
    n := n + 1;
  end loop;
  return n;
end $function$
;
