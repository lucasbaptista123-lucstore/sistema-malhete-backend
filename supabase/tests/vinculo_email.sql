do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; r text := ''; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (a,'a@t.com','authenticated','authenticated',now()),
    (b,'Irmao.B@t.com','authenticated','authenticated',now()),
    (x,'irmao.x@t.com','authenticated','authenticated',null);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L','1',(select id from public.orientes where uf='SP'),(select id from public.ritos where sigla='REAA'),'X','SP','A');
  insert into public.irmaos (loja_id, nome, email, cim, data_iniciacao, cpf) values (l, 'Irmão B','irmao.b@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000018562'),(l, 'Irmão X','irmao.x@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000018643');
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true); set local role authenticated;
  n := public.vincular_por_email(); r := r || format('X sem confirmar vincula=%s (esperado 0) | ', n);
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true); set local role authenticated;
  n := public.vincular_por_email(); r := r || format('B vincula=%s (esperado 1) | ', n);
  r := r || format('B minhas_lojas=%s (esperado 1) | ', (select count(*) from public.minhas_lojas()));
  r := r || format('B grau=%s | ', public.meu_grau(l));
  n := public.vincular_por_email(); r := r || format('B de novo=%s (esperado 0)', n);
  raise exception 'RESULTADO: %', r;
end $$;
