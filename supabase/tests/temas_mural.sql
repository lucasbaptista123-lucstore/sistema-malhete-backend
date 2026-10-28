-- Temas de trabalho por grau e mural de avisos do Venerável.
do $$
declare
  v uuid := gen_random_uuid(); v1 uuid := gen_random_uuid(); v2 uuid := gen_random_uuid();
  ap uuid := gen_random_uuid(); co uuid := gen_random_uuid();
  l uuid; i_v uuid; i_v1 uuid; i_v2 uuid; i_ap uuid; i_co uuid; g uuid; t_ap uuid; t_co uuid;
  r text := ''; n int; t text; tm_ap uuid; tm_m uuid; av uuid; av3 uuid;
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'v@t.com', 'authenticated', 'authenticated'), (v1, 'v1@t.com', 'authenticated', 'authenticated'), (v2, 'v2@t.com', 'authenticated', 'authenticated'),
    (ap, 'ap@t.com', 'authenticated', 'authenticated'), (co, 'co@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, '1º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000016942', 'i169x2779@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v2, '2º Vig', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017086', 'i170x2779@teste.com') returning id into i_v2;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Aprendiz', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017167', 'i171x2779@teste.com') returning id into i_ap;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, co, 'Irmão Companheiro', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017248', 'i172x2779@teste.com') returning id into i_co;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v1, 'primeiro_vigilante'), (i_v2, 'segundo_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;


  -- 2º Vigilante (acompanha Aprendizes) propõe tema de Aprendiz; não de Companheiro
  perform set_config('request.jwt.claims', json_build_object('sub', v2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.temas_trabalho (loja_id, grau, titulo) values (l, 1, 'O Painel do 1º grau') returning id into tm_ap;
  r := r || '2º Vig propõe tema de Aprendiz=ok | ';
  begin
    insert into public.temas_trabalho (loja_id, grau, titulo) values (l, 2, 'X');
    r := r || '2º Vig propõe tema de Companheiro=PERMITIU (ERRO) | ';
  exception when others then r := r || '2º Vig propõe tema de Companheiro=bloqueado | ';
  end;
  reset role;
  -- Venerável: tema dos Mestres e mural
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.temas_trabalho (loja_id, grau, titulo) values (l, 3, 'Lenda do 3º grau') returning id into tm_m;
  insert into public.mural (loja_id, titulo, texto) values (l, 'Ágape com as famílias', 'Hoje tragam as famílias') returning id into av;
  insert into public.mural (loja_id, titulo, grau_minimo) values (l, 'Só mestres', 3) returning id into av3;
  r := r || 'Venerável propõe tema de Mestre e publica no mural=ok | ';
  r := r || format('aviso na fila do WhatsApp=%s (esperado 5) | ', public.mural_whatsapp(av)); select left(mensagem, 40) into t from public.notificacoes where referencia = av limit 1; r := r || format('texto=%s | ', t);
  reset role;
  -- Aprendiz: vê o tema dele, não o de Mestre; vê o aviso geral, não o de Mestres; não publica
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.temas_trabalho where loja_id = l;
  r := r || format('Aprendiz vê temas=%s (esperado 1) | ', n);
  select count(*) into n from public.mural where loja_id = l;
  r := r || format('Aprendiz vê avisos=%s (esperado 1) | ', n);
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id) values (l, i_ap, 1, 'Meu painel', 'texto', tm_ap);
  r := r || 'Aprendiz envia trabalho com tema=ok | ';
  begin
    insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id) values (l, i_ap, 1, 'X', 'texto', tm_m);
    r := r || 'Aprendiz usa tema de Mestre=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Aprendiz usa tema de Mestre=bloqueado | ';
  end;
  begin
    insert into public.mural (loja_id, titulo) values (l, 'X');
    r := r || 'Aprendiz publica no mural=PERMITIU (ERRO)';
  exception when others then r := r || 'Aprendiz publica no mural=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
