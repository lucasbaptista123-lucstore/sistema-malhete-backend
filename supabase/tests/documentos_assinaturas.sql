-- Documentos com assinatura: pendência trava, pagamento destrava, Venerável monta a fila, troca assinante, conclui.
do $$
declare
  vm uuid := gen_random_uuid(); se uuid := gen_random_uuid(); te uuid := gen_random_uuid(); jp uuid := gen_random_uuid(); ou uuid := gen_random_uuid();
  l uuid; i_vm uuid; i_se uuid; i_te uuid; i_jp uuid; i_ou uuid; g uuid; cx uuid; tit uuid; tp uuid; ped uuid; doc uuid; j jsonb; r text := ''; s text; n int; a uuid;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'dvm@t.com', 'authenticated', 'authenticated', now()), (se, 'dse@t.com', 'authenticated', 'authenticated', now()),
    (te, 'dte@t.com', 'authenticated', 'authenticated', now()), (jp, 'djp@t.com', 'authenticated', 'authenticated', now()),
    (ou, 'dou@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Doc', '7', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  select id into i_vm from public.irmaos where loja_id = l and user_id = vm;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, se, 'Secretário Silva', 3, 'D1', '2015-01-01', '52998224725', 'dse@teste.com') returning id into i_se;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, te, 'Tesoureiro Souza', 3, 'D2', '2015-01-01', '11144477735', 'dte@teste.com') returning id into i_te;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, jp, 'João Paulo', 3, 'D3', '2015-01-01', '39053344705', 'djp@teste.com') returning id into i_jp;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ou, 'Orador Lima', 3, 'D4', '2015-01-01', '86288366757', 'dou@teste.com') returning id into i_ou;
  update public.irmaos set cpf = '74682489070' where id = i_vm;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_vm, 'veneravel'), (i_se, 'secretario'), (i_te, 'tesoureiro'), (i_ou, 'orador')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_vm;
  perform set_config('request.jwt.claims', json_build_object('sub', te, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into cx from public.contas_financeiras where loja_id = l and tipo = 'banco';
  insert into public.titulos (loja_id, natureza, descricao, categoria_id, valor, vencimento, competencia, irmao_id)
  values (l, 'receber', 'Mensalidade 09/2026', (select id from public.categorias_financeiras where loja_id = l and codigo = 'mensalidades'), 100, current_date - 40, current_date - 40, i_jp)
  returning id into tit;
  reset role;

  -- 1) João Paulo pede: trava por pendência
  perform set_config('request.jwt.claims', json_build_object('sub', jp, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into tp from public.tipos_documento where loja_id = l and codigo = 'regularidade';
  j := public.pedir_documento(l, tp, 'Ingressar no Supremo Conselho');
  ped := (j->>'pedido')::uuid;
  r := r || format('pedido=%s (%s em aberto) | ', j->>'status', j->>'qtd');
  reset role;
  -- 2) Venerável não consegue aprovar com pendência
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.decidir_pedido_documento(ped, true, null, '[]'); r := r || 'aprova com pendência=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aprova com pendência=bloqueado | '; end;
  reset role;
  -- 3) paga: segue sozinho
  perform set_config('request.jwt.claims', json_build_object('sub', te, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.baixar_titulo(tit, cx, current_date);
  reset role;
  select status into s from public.pedidos where id = ped;
  r := r || format('após pagar=%s | ', s);
  -- 4) Venerável aprova com os sugeridos
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select jsonb_agg(jsonb_build_object('cargo_codigo', cargo_codigo, 'irmao_id', irmao_id) order by ordem) into j from public.assinantes_sugeridos(tp);
  doc := public.decidir_pedido_documento(ped, true, null, j);
  perform public.definir_pdf_base(doc, l || '/documentos/' || doc || '/base.pdf');
  select string_agg(ordem || ':' || cargo_nome || '/' || status, ' ' order by ordem) into s from public.documento_assinaturas where documento_id = doc;
  r := r || format('fila=%s | ', s);
  reset role;
  -- 5) Secretário assina (registro feito pela função de conferência)
  select id into a from public.documento_assinaturas where documento_id = doc and status = 'vez';
  perform public.registrar_assinatura(a, l || '/documentos/' || doc || '/envio-1.pdf', '52998224725', 'SECRETARIO SILVA');
  -- 6) Venerável troca o Tesoureiro pelo Orador (substituto)
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.alterar_assinantes(doc, jsonb_build_array(
    jsonb_build_object('cargo_codigo', 'tesoureiro', 'irmao_id', i_ou),
    jsonb_build_object('cargo_codigo', 'veneravel', 'irmao_id', i_vm)), 'Tesoureiro viajando');
  select string_agg(ordem || ':' || cargo_nome || case when em_substituicao then '(subst)' else '' end || '/' || status, ' ' order by ordem) into s
    from public.documento_assinaturas where documento_id = doc;
  r := r || format('após trocar=%s | ', s);
  reset role;
  -- outro irmão (Tesoureiro saiu da fila) não vê mais? vê pelo cargo tesouraria? checa um irmão comum: o próprio João vê
  perform set_config('request.jwt.claims', json_build_object('sub', jp, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.documentos_emitidos where id = doc;
  r := r || format('João vê o documento=%s | ', n);
  reset role;
  -- 7) restantes assinam
  select id into a from public.documento_assinaturas where documento_id = doc and status = 'vez';
  perform public.registrar_assinatura(a, l || '/documentos/' || doc || '/envio-2.pdf', '86288366757', 'ORADOR LIMA');
  select id into a from public.documento_assinaturas where documento_id = doc and status = 'vez';
  s := public.registrar_assinatura(a, l || '/documentos/' || doc || '/envio-3.pdf', '74682489070', 'VENERAVEL');
  r := r || format('última=%s | ', s);
  select d.situacao || '/' || p.status into s from public.documentos_emitidos d join public.pedidos p on p.id = d.pedido_id where d.id = doc;
  r := r || format('documento/pedido=%s | avisos=%s', s,
    (select count(*) from public.notificacoes where loja_id = l and tipo = 'documento'));
  raise exception 'RESULTADO: %', r;
end $$;
