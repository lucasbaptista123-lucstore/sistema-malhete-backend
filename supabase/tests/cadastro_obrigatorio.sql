-- Cadastro obrigatório: nome completo, CPF válido, e-mail válido, CIM (ou pendente só p/ Aprendiz) e iniciação.
do $$ declare t uuid := gen_random_uuid(); l uuid; i uuid; r text := ''; s text; b boolean;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'co@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  begin insert into public.irmaos (loja_id, nome, cpf, email, cim, data_iniciacao) values (l, 'José', '52998224725', 'j@x.com', 'C1', '2020-01-01');
    r := r || 'só primeiro nome=PERMITIU (ERRO) | '; exception when others then r := r || 'só primeiro nome=bloqueado | '; end;
  begin insert into public.irmaos (loja_id, nome, email, cim, data_iniciacao) values (l, 'José Silva', 'j@x.com', 'C1', '2020-01-01');
    r := r || 'sem CPF=PERMITIU (ERRO) | '; exception when others then r := r || 'sem CPF=bloqueado | '; end;
  begin insert into public.irmaos (loja_id, nome, cpf, email, cim, data_iniciacao) values (l, 'José Silva', '12345678900', 'j@x.com', 'C1', '2020-01-01');
    r := r || 'CPF inválido=PERMITIU (ERRO) | '; exception when others then r := r || 'CPF inválido=bloqueado | '; end;
  begin insert into public.irmaos (loja_id, nome, cpf, email, cim, data_iniciacao) values (l, 'José Silva', '52998224725', 'jose@', 'C1', '2020-01-01');
    r := r || 'e-mail inválido=PERMITIU (ERRO) | '; exception when others then r := r || 'e-mail inválido=bloqueado | '; end;
  begin insert into public.irmaos (loja_id, nome, cpf, email, grau, cim_pendente, data_iniciacao) values (l, 'José Silva', '52998224725', 'j@x.com', 3, true, '2020-01-01');
    r := r || 'Mestre sem CIM=PERMITIU (ERRO) | '; exception when others then r := r || 'Mestre sem CIM=bloqueado | '; end;
  insert into public.irmaos (loja_id, nome, cpf, email, grau, cim_pendente, data_iniciacao)
  values (l, 'Novo Aprendiz', '529.982.247-25', ' Novo@X.com ', 1, true, current_date) returning id into i;
  select cpf || ' ' || email into s from public.irmaos where id = i;
  r := r || format('Aprendiz recém-iniciado sem CIM=ok (%s) | ', s);
  select array_to_string(faltando, ',') into s from public.diretorio(l) where id = i;
  r := r || format('faltando=%s | ', coalesce(nullif(s, ''), 'nada'));
  begin update public.irmaos set email = null where id = i; r := r || 'apagar e-mail=PERMITIU (ERRO) | ';
  exception when others then r := r || 'apagar e-mail=bloqueado | '; end;
  update public.irmaos set cim = 'NOVO1' where id = i;
  select cim_pendente into b from public.irmaos where id = i;
  r := r || format('CIM chegou, pendente=%s', b);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
