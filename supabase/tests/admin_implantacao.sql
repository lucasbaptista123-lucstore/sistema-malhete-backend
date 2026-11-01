-- Administrador da implantação perde o acesso quando o Venerável entra; cargo exercido só por substituição.
do $$
declare
  tu uuid := gen_random_uuid(); vu uuid := gen_random_uuid();
  l uuid; i_t uuid; i_v uuid; i_s uuid; i_s2 uuid; g uuid; g2 uuid; m_s uuid; m_f uuid; r text := ''; n int; j jsonb;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (tu, 'tes@t.com', 'authenticated', 'authenticated', now()), (vu, 'vm@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', tu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Tes Fundador');
  select id into i_t from public.irmaos where loja_id = l and user_id = tu;
  insert into public.irmaos (loja_id, nome, grau, email, cim, data_iniciacao, cpf) values (l, 'Vene Ravel', 3, 'vm@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 900, '00000010316') returning id into i_v;
  insert into public.irmaos (loja_id, nome, grau, email, cim, data_iniciacao, cpf) values (l, 'Secre Tario', 3, 's1@teste.com', 'T'||left(gen_random_uuid()::text,8), current_date - 900, '00000010405') returning id into i_s;
  insert into public.irmaos (loja_id, nome, grau, email, cim, data_iniciacao, cpf) values (l, 'Outro Secre', 3, 's2@teste.com', 'T'||left(gen_random_uuid()::text,8), current_date - 900, '00000014656') returning id into i_s2;

  -- fundador monta a gestão em vigor
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, '2026-2028', current_date - 30, current_date + 700) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 30, current_date + 700
    from (values (i_t, 'tesoureiro'), (i_v, 'veneravel'), (i_s, 'secretario')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  r := r || format('Venerável ainda fora: fundador loja.config=%s cargos.editar=%s | ',
    public.tem_permissao(l, 'loja.config'), public.tem_permissao(l, 'cargos.editar'));
  begin
    update public.irmaos set admin_loja = false where id = i_t;
    update public.irmaos set admin_loja = true where id = i_t;
    r := r || 'fundador se torna admin permanente=PERMITIU (ERRO) | ';
  exception when others then r := r || 'fundador se torna admin permanente=bloqueado | ';
  end;
  reset role;

  -- o Venerável aceita o convite
  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos set user_id = vu where id = i_v;
  perform set_config('malhete.sistema', 'off', true);

  perform set_config('request.jwt.claims', json_build_object('sub', tu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  j := public.minha_administracao(l);
  r := r || format('Venerável entrou: fundador loja.config=%s cargos.editar=%s tesouraria.editar=%s ativo=%s (esperado f f t f) | ',
    public.tem_permissao(l, 'loja.config'), public.tem_permissao(l, 'cargos.editar'),
    public.tem_permissao(l, 'tesouraria.editar'), j->>'ativo');
  select count(*) into n from unnest(public.minhas_permissoes(l)) p where p = '*';
  r := r || format('menu do fundador com *=%s (esperado 0) | ', n);
  reset role;

  -- o Venerável dá e tira o acesso de administrador
  perform set_config('request.jwt.claims', json_build_object('sub', vu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.irmaos set admin_loja = false where id = i_t;
  update public.irmaos set admin_loja = true where id = i_t;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', tu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := r || format('dado pelo Venerável: loja.config=%s implantação=%s (esperado t f) | ',
    public.tem_permissao(l, 'loja.config'), (select admin_implantacao from public.irmaos where id = i_t));
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', vu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.irmaos set admin_loja = false where id = i_t;

  -- correção livre nos primeiros 15 dias
  update public.mandatos set irmao_id = i_s2 where irmao_id = i_s and loja_id = l;
  update public.mandatos set irmao_id = i_s where irmao_id = i_s2 and loja_id = l returning id into m_s;
  r := r || 'corrigir nos 15 dias=ok | ';
  reset role;
  perform set_config('malhete.sistema', 'on', true);
  update public.mandatos set criado_em = now() - interval '20 days' where loja_id = l;
  perform set_config('malhete.sistema', 'off', true);

  perform set_config('request.jwt.claims', json_build_object('sub', vu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    update public.mandatos set irmao_id = i_s2 where id = m_s;
    r := r || 'trocar cargo exercido=PERMITIU (ERRO) | ';
  exception when others then r := r || 'trocar cargo exercido=bloqueado | ';
  end;
  begin
    delete from public.mandatos where id = m_s;
    r := r || 'apagar cargo exercido=PERMITIU (ERRO) | ';
  exception when others then r := r || 'apagar cargo exercido=bloqueado | ';
  end;
  begin
    perform public.substituir_cargo(m_s, i_s2, current_date, '');
    r := r || 'substituir sem motivo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'substituir sem motivo=bloqueado | ';
  end;
  perform public.substituir_cargo(m_s, i_s2, current_date, 'Mudou de Oriente');
  select count(*) into n from public.mandatos m join public.loja_cargos c on c.id = m.cargo_id and c.codigo = 'secretario'
    where m.loja_id = l and current_date between m.inicio and m.fim and m.irmao_id = i_s2;
  r := r || format('substituído: novo Secretário em vigor=%s (esperado 1) | ', n);
  reset role;
  select count(*) into n from public.audit_log where loja_id = l and acao = 'substituicao' and depois->>'motivo' = 'Mudou de Oriente';
  r := r || format('motivo na auditoria=%s (esperado 1) | ', n);

  -- gestão futura muda livremente
  perform set_config('request.jwt.claims', json_build_object('sub', vu, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'Futura', current_date + 701, current_date + 1400) returning id into g2;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g2, i_s, id, current_date + 701, current_date + 1400 from public.loja_cargos where loja_id = l and codigo = 'veneravel'
    returning id into m_f;
  update public.mandatos set criado_em = now() - interval '60 days', irmao_id = i_t where id = m_f;
  delete from public.mandatos where id = m_f;
  r := r || 'gestão futura: trocar e apagar=ok';
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
