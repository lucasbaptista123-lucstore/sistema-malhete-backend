-- Só o Tesoureiro movimenta a Tesouraria; Venerável e admin (com Tesoureiro definido) só leem.
do $$
declare
  a uuid := gen_random_uuid(); -- admin da loja (quem cadastrou), depois Venerável
  t uuid := gen_random_uuid(); -- Tesoureiro
  l uuid; v_a uuid; v_t uuid; g uuid; v_caixa uuid; v_cat uuid;
  r text := '';
begin
  insert into auth.users (id, email, aud, role) values (a, 'a@t.com', 'authenticated', 'authenticated'), (t, 't@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'A');
  select id into v_a from public.irmaos where loja_id = l and user_id = a;
  select id into v_caixa from public.contas_financeiras where loja_id = l and tipo = 'caixa';
  select id into v_cat from public.categorias_financeiras where loja_id = l and codigo = 'doacoes';

  r := r || format('admin sem gestão edita=%s (esperado t) | ', public.tem_permissao(l, 'tesouraria.editar'));
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, t, 'Irmão T', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000011207', 'i112x8660@teste.com') returning id into v_t;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, v_a, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'veneravel';
  r := r || format('admin+Venerável sem Tesoureiro edita=%s (esperado t) | ', public.tem_permissao(l, 'tesouraria.editar'));
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, v_t, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
  r := r || format('Venerável/admin com Tesoureiro: edita=%s lê=%s tronco.editar=%s cargos.editar=%s (esperado f t f t) | ',
    public.tem_permissao(l, 'tesouraria.editar'), public.tem_permissao(l, 'tesouraria.ler'),
    public.tem_permissao(l, 'tronco.editar'), public.tem_permissao(l, 'cargos.editar'));
  r := r || format('menu do Venerável=%s (sem tesouraria.editar) | ', public.minhas_permissoes(l)::text);
  begin
    insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao) values (l, v_caixa, v_cat, 'receita', 10, 'x');
    r := r || 'Venerável lança=PERMITIU (ERRO) | ';
  exception when others then r := r || 'Venerável lança=bloqueado | ';
  end;

  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := r || format('Tesoureiro edita=%s | menu=%s | ', public.tem_permissao(l, 'tesouraria.editar'), public.minhas_permissoes(l)::text);
  insert into public.lancamentos (loja_id, conta_id, categoria_id, tipo, valor, descricao) values (l, v_caixa, v_cat, 'receita', 10, 'x');
  r := r || 'Tesoureiro lança=ok';

  raise exception 'RESULTADO: %', r;
end $$;
