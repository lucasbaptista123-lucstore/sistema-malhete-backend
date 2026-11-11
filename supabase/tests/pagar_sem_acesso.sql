-- Irmão sem acesso ao sistema (0117, caso Tauan 10/11): aviso só com "Pagar com PIX" e texto sem mandar
-- entrar no sistema; irmão com acesso continua com os dois botões; whatsapp_pagamento informa tem_acesso.
do $$ declare
  t uuid := gen_random_uuid(); u uuid := gen_random_uuid(); l uuid; cx uuid; cat uuid; isem uuid; icom uuid; ts uuid; tc uuid;
  bs text[]; bc text[]; ms text; mc text; p jsonb; rg text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'tsa@t.com', 'authenticated', 'authenticated', now()), (u, 'usa@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'Sao Paulo', 'SP', 'T');
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone) values
    (l, 'Tauan Sem Acesso', 3, '1', '2020-01-01', 'ativo', '11999990001') returning id into isem;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, situacao, telefone, user_id) values
    (l, 'Joao Com Acesso', 3, '2', '2020-01-01', 'ativo', '11999990002', u) returning id into icom;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.tesouraria_config (loja_id, pix_chave, pix_titular) values (l, 'tesouraria@loja.org', 'Loja Teste')
    on conflict (loja_id) do update set pix_chave = excluded.pix_chave, pix_titular = excluded.pix_titular;
  select id into cat from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades';
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
    values (l, 'receber', 'Mensalidade', cat, isem, 250, current_date + 5, current_date, 'mensalidade') returning id into ts;
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, irmao_id, valor, vencimento, competencia, origem)
    values (l, 'receber', 'Mensalidade', cat, icom, 250, current_date + 5, current_date, 'mensalidade') returning id into tc;
  select botoes, mensagem into bs, ms from public.notificacoes where referencia = ts and tipo = 'cobranca';
  select botoes, mensagem into bc, mc from public.notificacoes where referencia = tc and tipo = 'cobranca';
  if array_length(bs, 1) <> 1 or bs[1] not like 'Pagar com PIX|%' or ms like '%Malhete%' then
    raise exception 'FALHOU sem acesso: % | %', bs, ms;
  end if;
  if array_length(bc, 1) <> 2 then raise exception 'FALHOU com acesso: % | %', bc, mc; end if;
  p := public.whatsapp_pagamento(l, '5511999990001', (select token from public.notificacoes where referencia = ts and tipo = 'cobranca'));
  if (p->>'tem_acesso')::boolean is distinct from false then raise exception 'FALHOU tem_acesso: %', p; end if;
  rg := private.regua_texto('{link}', l, isem, array[ts]);
  if rg like '%sistema%' or rg like '%Malhete%' then raise exception 'FALHOU régua: %', rg; end if;
  raise exception 'OK: sem acesso=% "%" | com acesso=% | régua="%"', bs, ms, bc, rg;
end $$;
