-- Trocar rito: Loja REAA com irmão num cargo só do REAA e outro no Secretário; troca para York e volta.
do $$
declare u uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); l uuid; g uuid; i2 uuid; i3 uuid; c_so uuid; c_sec uuid;
  r text := ''; j jsonb; york uuid; reaa uuid; s text;
begin
  select id into york from public.ritos where sigla = 'YORK';
  select id into reaa from public.ritos where sigla = 'REAA';
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (u, 'vm_rito@t.com', 'authenticated', 'authenticated', now()),
    (u2, 'ir_rito@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Rito', '1', (select id from public.orientes where uf = 'SP'), reaa, 'X', 'SP', 'Venerável');
  reset role;
  -- cargo que o York não tem, com mandato
  select c.id into c_so from public.loja_cargos c where c.loja_id = l
    and not exists (select 1 from public.rito_cargos y where y.rito_id = york and y.codigo = c.codigo) order by c.ordem limit 1;
  select id into c_sec from public.loja_cargos where loja_id = l and codigo = 'secretario';
  select id into g from public.gestoes where loja_id = l limit 1;
  if g is null then insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 365) returning id into g; end if;
  perform set_config('malhete.sistema', 'on', true);
  insert into public.irmaos (loja_id, nome, grau, situacao, user_id) values (l, 'Irmão Teste', 3, 'ativo', u2) returning id into i2;
  insert into public.irmaos (loja_id, nome, grau, situacao) values (l, 'Irmão Dois', 3, 'ativo') returning id into i3;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim) values
    (l, g, i2, c_so, current_date, current_date + 365), (l, g, i3, c_sec, current_date, current_date + 365);

  -- irmão sem loja.config não troca
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin perform public.trocar_rito(l, york); r := r || 'ERRO: irmão trocou | ';
  exception when others then r := r || 'irmão barrado | '; end;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  j := public.trocar_rito(l, york);
  reset role;
  r := r || 'york ' || j::text || ' | ';
  r := r || format('rito=%s, cargo só REAA ficou extra=%s, secretario mesmo id=%s nome=%s, faltando do York=%s, Venerável ainda config=%s | ',
    (select sigla from public.ritos x join public.lojas y on y.rito_id = x.id where y.id = l),
    (select rito_cargo_id is null from public.loja_cargos where id = c_so),
    exists (select 1 from public.loja_cargos where id = c_sec and rito_cargo_id in (select id from public.rito_cargos where rito_id = york)),
    (select nome from public.loja_cargos where id = c_sec),
    (select count(*) from public.rito_cargos y where y.rito_id = york and not exists (select 1 from public.loja_cargos c where c.loja_id = l and c.rito_cargo_id = y.id)),
    public.tem_permissao(l, 'loja.config'));

  set local role authenticated;
  j := public.trocar_rito(l, reaa);
  reset role;
  r := r || 'volta ' || j::text || ' | ';
  r := r || format('cargo antigo voltou ao rito=%s, cargos = modelo REAA? %s, auditoria=%s',
    (select rito_cargo_id is not null from public.loja_cargos where id = c_so),
    (select count(*) from public.loja_cargos where loja_id = l and rito_cargo_id is not null) = (select count(*) from public.rito_cargos where rito_id = reaa),
    (select count(*) from public.audit_log where loja_id = l and acao = 'trocar_rito'));
  raise exception 'RESULTADO: %', r;
end $$;
