-- CIM e data de iniciação obrigatórios; CIM não repete na loja.
do $$
declare
  se uuid := gen_random_uuid(); l uuid; i_x uuid; i_old uuid; r text := '';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (se, 'cim@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Sec');
  r := r || 'fundador sem CIM cria a loja=ok | ';
  select id into i_old from public.irmaos where loja_id = l and user_id = se;
  update public.irmaos set telefone = '12999999999' where id = i_old;
  r := r || 'cadastro antigo sem CIM ainda edita telefone=ok | ';
  begin
    insert into public.irmaos (loja_id, nome, cpf, email) values (l, 'Sem CIM', '00000011550', 'i115x6617@teste.com');
    r := r || 'sem CIM=PERMITIU (ERRO) | ';
  exception when others then r := r || format('sem CIM=bloqueado (%s) | ', sqlerrm);
  end;
  begin
    insert into public.irmaos (loja_id, nome, cim, cpf, email) values (l, 'Sem data', '111', '00000011630', 'i116x6617@teste.com');
    r := r || 'sem iniciação=PERMITIU (ERRO) | ';
  exception when others then r := r || format('sem iniciação=bloqueado (%s) | ', sqlerrm);
  end;
  insert into public.irmaos (loja_id, nome, cim, data_iniciacao, cpf, email) values (l, 'Irmão Completo', ' 222 ', '2015-03-10', '00000011711', 'i117x6617@teste.com') returning id into i_x;
  r := r || 'completo=ok | ';
  begin
    insert into public.irmaos (loja_id, nome, cim, data_iniciacao, cpf, email) values (l, 'Irmão Duplicado', '222', '2016-01-01', '00000011800', 'i118x6617@teste.com');
    r := r || 'CIM repetido=PERMITIU (ERRO) | ';
  exception when others then r := r || 'CIM repetido=bloqueado | ';
  end;
  begin
    update public.irmaos set cim = null where id = i_x;
    r := r || 'apagar CIM=PERMITIU (ERRO)';
  exception when others then r := r || 'apagar CIM=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
