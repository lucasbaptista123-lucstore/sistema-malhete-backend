-- Cobrança no WhatsApp com BOTÕES (29/10, ideia do Lucas, igual à confirmação de sessão): o aviso vem com
-- "Pagar com PIX" (a resposta traz o PIX copia e cola sozinho numa mensagem) e "Pagar pelo Malhete" (a resposta traz o
-- link do sistema). Substitui o envio automático dos códigos logo após o aviso (0092).
alter table public.notificacoes
  add column botoes text[],
  add column titulos uuid[],
  add column token text not null default replace(gen_random_uuid()::text, '-', '');
create index on public.notificacoes (token);

-- marca o aviso que acabou de ser criado (mesma transação) com os botões de pagamento
create or replace function private.notificar_pix(p_loja uuid, p_irmao uuid, p_tipo text, p_titulos uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tok text;
begin
  if not exists (select 1 from public.titulos where id = any (p_titulos) and asaas_id is not null and not cancelado and valor_pago < valor) then
    return;
  end if;
  select id, token into v_id, v_tok from public.notificacoes
  where loja_id = p_loja and irmao_id = p_irmao and tipo = p_tipo and criado_em = now() and botoes is null
  order by id limit 1;
  if v_id is null then return; end if;
  update public.notificacoes
  set botoes = array['Pagar com PIX|pag:pix:' || v_tok, 'Pagar pelo Malhete|pag:app:' || v_tok],
      titulos = (select array_agg(id order by vencimento) from public.titulos
                 where id = any (p_titulos) and asaas_id is not null and not cancelado and valor_pago < valor)
  where id = v_id;
end $$;

-- o botão tocado pelo irmão: confere que é o telefone de quem recebeu e devolve o que mandar
create function public.whatsapp_pagamento(p_loja uuid, p_telefone text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n public.notificacoes;
begin
  select * into n from public.notificacoes where loja_id = p_loja and token = p_token and botoes is not null;
  if n.id is null or public.tel_chave(p_telefone) is distinct from public.tel_chave(n.telefone) then return null; end if;
  return jsonb_build_object('link', private.link_mensalidades(),
    'titulos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'asaas_id', t.asaas_id, 'pix', t.pix_copia_cola,
                        'descricao', t.descricao, 'valor', t.valor - t.valor_pago) order by t.vencimento), '[]')
                from public.titulos t where t.id = any (n.titulos) and not t.cancelado and t.valor_pago < t.valor));
end $$;
revoke execute on function public.whatsapp_pagamento from public, anon, authenticated;
grant execute on function public.whatsapp_pagamento to service_role;

drop function public.notificacoes_proximas(integer);
create function public.notificacoes_proximas(p_por_loja integer default 4)
returns table (id uuid, loja_id uuid, telefone text, mensagem text, botoes text[])
language plpgsql security definer set search_path = '' as $$
begin
  update public.notificacoes set status = 'descartado', erro = 'WhatsApp desconectado por mais de 3 dias'
  where status = 'pendente' and criado_em < now() - interval '3 days';
  return query
  select x.id, x.loja_id, x.telefone, x.mensagem, x.botoes from (
    select n.*, row_number() over (partition by n.loja_id order by n.criado_em) as k
    from public.notificacoes n
    join public.integracoes_whatsapp w on w.loja_id = n.loja_id and w.status = 'conectado'
    where n.status = 'pendente'
  ) x where x.k <= p_por_loja;
end $$;
revoke execute on function public.notificacoes_proximas from public, anon, authenticated;
grant execute on function public.notificacoes_proximas to service_role;

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
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), '', ''));
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
         format('Olá, %s! Sua cobrança de %s (%s) vence em %s. Toque em um dos botões abaixo para pagar.%s%s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago), to_char(t.vencimento, 'DD/MM/YYYY'), '', ''),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
  perform private.notificar_pix(t.loja_id, t.irmao_id, 'cobranca', array[t.id]);
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
    '{link}', case when exists (select 1 from public.titulos where id = any (p_titulos) and asaas_id is not null and not cancelado and valor_pago < valor)
      then 'Toque em um dos botões abaixo para pagar: PIX copia e cola ou pelo Malhete.'
      else 'Pague com PIX pelo sistema: ' || private.link_mensalidades() end);
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
