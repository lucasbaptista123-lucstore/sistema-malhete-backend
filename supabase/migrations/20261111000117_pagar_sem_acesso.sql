-- Irmão que ainda não acessa o sistema (11/11, caso Tauan: tocou em "Pagar pelo Malhete" no lembrete, o
-- sistema pediu login e ele não tinha conta; só pagou depois de aceitar o convite).
-- Sem acesso: o aviso vai só com o botão "Pagar com PIX" e o texto não manda entrar no sistema.
-- O botão "Pagar pelo Malhete" de mensagens antigas responde com o PIX (whatsapp-webhook usa tem_acesso).

create or replace function private.irmao_tem_acesso(p_irmao uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.irmaos where id = p_irmao and user_id is not null)
$$;
revoke execute on function private.irmao_tem_acesso from public, anon, authenticated;

-- frase final do aviso, conforme o irmão tem botão de PIX e acesso ao sistema
create or replace function private.texto_pagar(p_loja uuid, p_irmao uuid, p_titulos uuid[]) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from public.titulos where id = any (p_titulos) and not cancelado and valor_pago < valor
                 and (asaas_id is not null or private.tem_pix_chave(p_loja))) then
      case when private.irmao_tem_acesso(p_irmao)
           then 'Toque em um dos botões abaixo para pagar: PIX copia e cola ou pelo Malhete.'
           else 'Toque no botão abaixo para receber o PIX copia e cola.' end
    else 'Pague com PIX pelo sistema: ' || private.link_mensalidades()
  end
$$;
revoke execute on function private.texto_pagar from public, anon, authenticated;

create or replace function private.notificar_pix(p_loja uuid, p_irmao uuid, p_tipo text, p_titulos uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_tok text; v_ids uuid[]; v_chave boolean := private.tem_pix_chave(p_loja);
begin
  select array_agg(id order by vencimento) into v_ids from public.titulos
  where id = any (p_titulos) and not cancelado and valor_pago < valor and natureza = 'receber'
    and (asaas_id is not null or v_chave);
  if v_ids is null then return; end if;
  select id, token into v_id, v_tok from public.notificacoes
  where loja_id = p_loja and irmao_id = p_irmao and tipo = p_tipo and criado_em = now() and botoes is null
  order by id limit 1;
  if v_id is null then return; end if;
  update public.notificacoes
  set botoes = case when private.irmao_tem_acesso(p_irmao)
                    then array['Pagar com PIX|pag:pix:' || v_tok, 'Pagar pelo Malhete|pag:app:' || v_tok]
                    else array['Pagar com PIX|pag:pix:' || v_tok] end,
      titulos = v_ids
  where id = v_id;
end $$;
revoke execute on function private.notificar_pix from public, anon, authenticated;

create or replace function private.regua_texto(p_modelo text, p_loja uuid, p_irmao uuid, p_titulos uuid[])
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_nome text;
  v_loja text;
  v_itens text;
  v_total numeric;
  v_venc text;
begin
  select nome into v_nome from public.irmaos where id = p_irmao;
  select trim(nome) || coalesce(' nº ' || numero, '') into v_loja from public.lojas where id = p_loja;
  select string_agg(format('• %s: %s (venc. %s)', t.descricao,
                           private.moeda(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
                           to_char(t.vencimento, 'DD/MM')), E'\n' order by t.vencimento),
         sum(t.valor - t.valor_pago + private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento)),
         string_agg(distinct to_char(t.vencimento, 'DD/MM'), ', ')
    into v_itens, v_total, v_venc
  from public.titulos t where t.id = any (p_titulos);
  return replace(replace(replace(replace(replace(replace(replace(p_modelo,
    '{nome}', coalesce(private.primeiro_nome(v_nome), 'irmão')),
    '{irmao}', coalesce(v_nome, '')),
    '{loja}', coalesce(v_loja, '')),
    '{itens}', coalesce(v_itens, '')),
    '{valor}', private.moeda(coalesce(v_total, 0))),
    '{vencimento}', coalesce(v_venc, '')),
    '{link}', private.texto_pagar(p_loja, p_irmao, p_titulos));
end $$;

create or replace function private.aviso_cobranca() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_nome text;
begin
  if new.natureza <> 'receber' or new.irmao_id is null or new.cancelado or new.valor_pago >= new.valor then
    return new;
  end if;
  if new.asaas_link is null then
    if tg_op <> 'INSERT' or new.origem = 'asaas' or private.vira_cobranca_asaas(new.loja_id, new.irmao_id)
       or not private.tem_pix_chave(new.loja_id) then
      return new;
    end if;
  elsif tg_op = 'UPDATE' and old.asaas_link is not distinct from new.asaas_link then
    return new;
  end if;
  if new.origem = 'asaas' or coalesce(new.asaas_status, '') in ('CONFIRMED', 'RECEIVED', 'RECEIVED_IN_CASH') then return new; end if;
  if new.vencimento > current_date + 20 then return new; end if;
  if exists (select 1 from public.notificacoes where referencia = new.id and tipo = 'cobranca') then return new; end if;
  select nome into v_nome from public.irmaos where id = new.irmao_id;
  perform private.notificar(new.loja_id, new.irmao_id, 'cobranca', new.id,
    format('Olá, %s! Sua cobrança de %s (%s) vence em %s. %s',
           private.primeiro_nome(v_nome), new.descricao, private.moeda(new.valor - new.valor_pago),
           to_char(new.vencimento, 'DD/MM/YYYY'), private.texto_pagar(new.loja_id, new.irmao_id, array[new.id])));
  perform private.notificar_pix(new.loja_id, new.irmao_id, 'cobranca', array[new.id]);
  return new;
end $$;

create or replace function public.avisar_cobranca(p_titulo uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t public.titulos;
  v_nome text;
begin
  select * into t from public.titulos where id = p_titulo;
  if t.id is null or not public.tem_permissao(t.loja_id, 'tesouraria.editar') then raise exception 'Sem permissão'; end if;
  if t.irmao_id is null then raise exception 'Esta conta não é de um irmão'; end if;
  if t.asaas_link is null and not private.tem_pix_chave(t.loja_id) then
    raise exception 'Esta conta não tem link de pagamento. Preencha a chave PIX da Loja em Tesouraria, Configurações';
  end if;
  select nome into v_nome from public.irmaos where id = t.irmao_id;
  insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
  select t.loja_id, t.irmao_id, 'cobranca', t.id,
         format('Olá, %s! Sua cobrança de %s (%s) vence em %s. %s', private.primeiro_nome(v_nome), t.descricao,
                private.moeda(t.valor - t.valor_pago + case when t.vencimento < current_date
                              then private.encargos(t.loja_id, t.valor - t.valor_pago, t.vencimento) else 0 end),
                to_char(t.vencimento, 'DD/MM/YYYY'), private.texto_pagar(t.loja_id, t.irmao_id, array[t.id])),
         nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), ''),
         case when nullif(regexp_replace(coalesce(i.telefone, ''), '\D', '', 'g'), '') is null then 'sem_telefone' else 'pendente' end
  from public.irmaos i where i.id = t.irmao_id;
  perform private.notificar_pix(t.loja_id, t.irmao_id, 'cobranca', array[t.id]);
end $$;

create or replace function public.avisar_mensalidades(p_loja uuid, p_irmaos uuid[], p_mensagem text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  v_txt text;
  v_tel text;
  v_ids uuid[];
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
    v_ids := array(select x.id from public.titulos x where x.irmao_id = r.id and x.loja_id = p_loja and x.natureza = 'receber');
    if r.itens is not null then
      v_txt := v_txt || E'\n\nPendências:\n' || r.itens || E'\n\n' || private.texto_pagar(p_loja, r.id, v_ids);
    end if;
    v_tel := nullif(regexp_replace(coalesce(r.telefone, ''), '\D', '', 'g'), '');
    insert into public.notificacoes (loja_id, irmao_id, tipo, referencia, mensagem, telefone, status)
    values (p_loja, r.id, 'debito', null, v_txt, v_tel, case when v_tel is null then 'sem_telefone' else 'pendente' end);
    perform private.notificar_pix(p_loja, r.id, 'debito', v_ids);
    n := n + 1;
  end loop;
  return n;
end $$;

-- o webhook precisa saber se o irmão já acessa o sistema
create or replace function public.whatsapp_pagamento(p_loja uuid, p_telefone text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n public.notificacoes;
begin
  select * into n from public.notificacoes where loja_id = p_loja and token = p_token and botoes is not null;
  if n.id is null or public.tel_chave(p_telefone) is distinct from public.tel_chave(n.telefone) then return null; end if;
  return jsonb_build_object('link', private.link_mensalidades(),
    'tem_acesso', private.irmao_tem_acesso(n.irmao_id),
    'chave', (select nullif(trim(pix_chave), '') from public.tesouraria_config where loja_id = p_loja),
    'titular', (select coalesce(nullif(trim(c.pix_titular), ''), l.nome) from public.lojas l
                left join public.tesouraria_config c on c.loja_id = l.id where l.id = p_loja),
    'cidade', (select cidade from public.lojas where id = p_loja),
    'titulos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'asaas_id', t.asaas_id, 'pix', t.pix_copia_cola,
                        'descricao', t.descricao, 'valor', t.valor - t.valor_pago,
                        'atualizado', t.valor - t.valor_pago + case when t.vencimento < current_date
                                        then private.encargos(p_loja, t.valor - t.valor_pago, t.vencimento) else 0 end)
                        order by t.vencimento), '[]')
                from public.titulos t where t.id = any (n.titulos) and not t.cancelado and t.valor_pago < t.valor));
end $$;
