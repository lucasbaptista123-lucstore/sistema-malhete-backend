-- Sistema Malhete (05/11/2026): o irmão Bruno pagou o boleto do Asaas e recebeu do sistema "sua cobrança… toque para
-- pagar". Boleto pago fica CONFIRMED até compensar (1 a 2 dias úteis); o espelho criou a conta sem baixa e o aviso saiu.
-- Agora: cobrança criada direto no Asaas não gera aviso do sistema (o Asaas já avisa), e conta paga no Asaas aguardando
-- compensação não entra no aviso de cobrança, na régua nem no aviso de mensalidades.
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
  -- cobrança criada direto no Asaas (o próprio Asaas já avisa) ou já paga lá, aguardando compensação: não avisa
  if new.origem = 'asaas' or coalesce(new.asaas_status, '') in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH') then return new; end if;
  -- gerou o ano todo de uma vez: só avisa na criação o que vence nos próximos 20 dias; o resto a régua lembra perto do vencimento
  if new.vencimento > current_date + 20 then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), '', ''));
  perform private.notificar_pix(new.loja_id, new.irmao_id, 'cobranca', array[new.id]);
  return new;
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
      and coalesce(t.asaas_status, '') not in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH')
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
      and coalesce(t.asaas_status, '') not in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH')
    where i.loja_id = p_loja and i.id = any (p_irmaos)
    group by i.id, i.nome, i.telefone
  loop
    v_txt := replace(replace(replace(trim(p_mensagem),
               '{nome}', private.primeiro_nome(r.nome)),
               '{valor}', private.moeda(r.aberto)),
               '{meses}', r.atrasados::text);
    if r.itens is not null then
      v_txt := v_txt || E'\n\nPendências:\n' || r.itens || case when exists (
                 select 1 from public.titulos x where x.irmao_id = r.id and x.loja_id = p_loja and x.asaas_id is not null
                   and not x.cancelado and x.valor_pago < x.valor)
               then E'\n\nToque em um dos botões abaixo para pagar. Pelo sistema: '
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
