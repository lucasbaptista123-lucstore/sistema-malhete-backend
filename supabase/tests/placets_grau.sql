-- Placets de elevação/exaltação: só Venerável/Secretário abrem; grau errado e irmão em dois pedidos bloqueados;
-- documento da Loja vai para a fila gov.br; registra placet; cerimônia sobe o grau só de quem participou.
do $$
declare
  vm uuid := gen_random_uuid(); se uuid := gen_random_uuid(); te uuid := gen_random_uuid();
  l uuid; i_vm uuid; i_se uuid; i_te uuid; a1 uuid; a2 uuid; c1 uuid; g uuid; pg uuid; doc uuid; r text := ''; n int; s text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'pvm@t.com', 'authenticated', 'authenticated', now()), (se, 'pse@t.com', 'authenticated', 'authenticated', now()),
    (te, 'pte@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Placet', '8', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  select id into i_vm from public.irmaos where loja_id = l and user_id = vm;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, se, 'Secretário Silva', 3, 'P1', '2015-01-01', '52998224725', 'pse@teste.com') returning id into i_se;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, te, 'Tesoureiro Souza', 3, 'P2', '2015-01-01', '11144477735', 'pte@teste.com') returning id into i_te;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Aprendiz Um', 1, 'P3', '2025-09-01', '39053344705', 'a1@teste.com') returning id into a1;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Aprendiz Dois', 1, 'P4', '2025-10-01', '86288366757', 'a2@teste.com') returning id into a2;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, data_elevacao, cpf, email) values (l, 'Companheiro Um', 2, 'P5', '2024-01-01', '2025-01-01', '74682489070', 'c1@teste.com') returning id into c1;
  update public.irmaos set cpf = '15350946056' where id = i_vm;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_vm, 'veneravel'), (i_se, 'secretario'), (i_te, 'tesoureiro')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_vm;

  -- Tesoureiro não abre
  perform set_config('request.jwt.claims', json_build_object('sub', te, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.abrir_placet_grau(l, 'elevacao', array[a1], '[]'); r := r || 'tesoureiro abre=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tesoureiro abre=bloqueado | '; end;
  select count(*) into n from public.placets_grau where loja_id = l;
  r := r || format('tesoureiro vê %s | ', n);
  reset role;

  -- Venerável: candidatos, grau errado, abre, duplicado
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.candidatos_placet_grau(l, 'elevacao');
  r := r || format('candidatos elevação=%s | ', n);
  begin perform public.abrir_placet_grau(l, 'elevacao', array[c1], jsonb_build_array(jsonb_build_object('cargo_codigo', 'veneravel', 'irmao_id', i_vm)));
    r := r || 'companheiro na elevação=PERMITIU (ERRO) | ';
  exception when others then r := r || 'companheiro na elevação=bloqueado | '; end;
  pg := public.abrir_placet_grau(l, 'elevacao', array[a1, a2], jsonb_build_array(
          jsonb_build_object('cargo_codigo', 'veneravel', 'irmao_id', i_vm), jsonb_build_object('cargo_codigo', 'secretario', 'irmao_id', i_se)));
  select documento_id into doc from public.placets_grau where id = pg;
  select string_agg(cargo_nome || ':' || status, ',' order by ordem) into s from public.documento_assinaturas where documento_id = doc;
  r := r || format('fila=%s | texto tem 2 irmãos=%s | ', s, (select jsonb_array_length(conteudo->'irmaos') from public.documentos_emitidos where id = doc));
  begin perform public.abrir_placet_grau(l, 'elevacao', array[a1], jsonb_build_array(jsonb_build_object('cargo_codigo', 'veneravel', 'irmao_id', i_vm)));
    r := r || 'mesmo irmão em 2 pedidos=PERMITIU (ERRO) | ';
  exception when others then r := r || 'mesmo irmão em 2 pedidos=bloqueado | '; end;
  begin perform public.concluir_placet_grau(pg, current_date, array[a1]); r := r || 'conclui sem placet=PERMITIU (ERRO) | ';
  exception when others then r := r || 'conclui sem placet=bloqueado | '; end;
  perform public.registrar_placet_grau(pg, '123/2026', current_date, null, current_date + 10);
  n := public.concluir_placet_grau(pg, current_date, array[a1]);
  r := r || format('elevados=%s; a1 grau=%s (%s); a2 grau=%s | ', n,
    (select grau from public.irmaos where id = a1), (select data_elevacao = current_date from public.irmaos where id = a1),
    (select grau from public.irmaos where id = a2));
  select count(*) into n from public.candidatos_placet_grau(l, 'exaltacao');
  r := r || format('candidatos exaltação agora=%s', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
