-- Teste de permissões da Fase 1. Roda tudo numa transação e desfaz no final
-- (o resultado volta na mensagem de erro proposital "RESULTADO").
do $$
declare
  a uuid := gen_random_uuid(); -- cria Loja 1 (tesoureira)
  b uuid := gen_random_uuid(); -- aprendiz da Loja 1
  c uuid := gen_random_uuid(); -- cria Loja 2
  l1 uuid; l2 uuid; v_irmao_b uuid; v_irmao_a uuid; v_gestao uuid;
  rito uuid := (select id from public.ritos where sigla = 'REAA');
  ori uuid := (select id from public.orientes where uf = 'SP');
  r text := '';
  n int;
begin
  insert into auth.users (id, email, aud, role) values
    (a, 'a@teste.local', 'authenticated', 'authenticated'),
    (b, 'b@teste.local', 'authenticated', 'authenticated'),
    (c, 'c@teste.local', 'authenticated', 'authenticated');

  -- ---- A cria a Loja 1
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l1 := public.criar_loja('Loja Teste 1', '1234', ori, rito, 'São Paulo', 'SP', 'Irmã A');
  select count(*) into n from public.loja_cargos where loja_id = l1;
  r := r || format('cargos copiados=%s (esperado 22) | ', n);

  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l1, b, 'Irmão B', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000014060', 'i140x4186@teste.com') returning id into v_irmao_b;
  r := r || 'admin cadastra irmão=ok | ';

  -- ---- C cria a Loja 2
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l2 := public.criar_loja('Loja Teste 2', '99', ori, rito, 'Campinas', 'SP', 'Irmão C');
  select count(*) into n from public.irmaos;
  r := r || format('C vê irmãos=%s (esperado 1) | ', n);
  select count(*) into n from public.lojas;
  r := r || format('C vê lojas=%s (esperado 1) | ', n);

  -- ---- B (aprendiz da Loja 1)
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.irmaos;
  r := r || format('B vê irmãos=%s (esperado 1) | ', n);
  select count(*) into n from public.diretorio(l1);
  r := r || format('B diretório L1=%s (esperado 2) | ', n);
  select count(*) into n from public.diretorio(l2);
  r := r || format('B diretório L2=%s (esperado 0) | ', n);
  select count(*) into n from public.lojas;
  r := r || format('B vê lojas=%s (esperado 1) | ', n);
  select public.meu_grau(l1) into n;
  r := r || format('B grau=%s | ', n);

  update public.irmaos set telefone = '11999999999' where id = v_irmao_b;
  get diagnostics n = row_count;
  r := r || format('B edita telefone=%s (esperado 1) | ', n);

  begin
    update public.irmaos set grau = 3 where id = v_irmao_b;
    r := r || 'B muda próprio grau=PERMITIU (ERRO) | ';
  exception when others then
    r := r || 'B muda próprio grau=bloqueado | ';
  end;

  begin
    insert into public.gestoes (loja_id, nome, inicio, fim) values (l1, 'x', current_date, current_date + 1);
    r := r || 'B cria gestão=PERMITIU (ERRO) | ';
  exception when others then
    r := r || 'B cria gestão=bloqueado | ';
  end;

  select count(*) into n from public.audit_log;
  r := r || format('B vê auditoria=%s (esperado 0) | ', n);

  -- ---- A vira Tesoureira sem admin_loja
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into v_irmao_a from public.irmaos where loja_id = l1 and user_id = a;
  insert into public.gestoes (loja_id, nome, inicio, fim)
    values (l1, 'Gestão 2026/2027', current_date - 30, current_date + 300) returning id into v_gestao;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l1, v_gestao, v_irmao_a, id, current_date - 30, current_date + 300
    from public.loja_cargos where loja_id = l1 and codigo = 'tesoureiro';

  reset role;
  update public.irmaos set admin_loja = false where id = v_irmao_a;
  set local role authenticated;

  r := r || format('tesoureira: tesouraria.editar=%s tesouraria.ler=%s cadastro.ler=%s cadastro.editar=%s loja.config=%s | ',
    public.tem_permissao(l1, 'tesouraria.editar'), public.tem_permissao(l1, 'tesouraria.ler'),
    public.tem_permissao(l1, 'cadastro.ler'), public.tem_permissao(l1, 'cadastro.editar'),
    public.tem_permissao(l1, 'loja.config'));
  r := r || format('tesoureira na L2: tesouraria.ler=%s | ', public.tem_permissao(l2, 'tesouraria.ler'));
  select count(*) into n from public.irmaos;
  r := r || format('tesoureira vê irmãos=%s (esperado 2) | ', n);

  begin
    update public.irmaos set grau = 2 where id = v_irmao_b;
    get diagnostics n = row_count;
    r := r || format('tesoureira muda grau de B=%s linhas (esperado bloqueio/0) | ', n);
  exception when others then
    r := r || 'tesoureira muda grau de B=bloqueado | ';
  end;

  -- ---- anônimo
  reset role;
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  begin
    select count(*) into n from public.lojas;
    r := r || format('anon vê lojas=%s (esperado 0) | ', n);
  exception when others then
    r := r || 'anon vê lojas=bloqueado | ';
  end;

  reset role;
  select count(*) into n from public.audit_log where loja_id in (l1, l2);
  r := r || format('linhas de auditoria=%s', n);

  raise exception 'RESULTADO: %', r;
end $$;
