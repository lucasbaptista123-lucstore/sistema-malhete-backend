-- Login em duas etapas no banco: com fator verificado, sessão aal1 não acessa; aal2 acessa; sem fator, normal.
do $$ declare t uuid := gen_random_uuid(); l uuid; r text := ''; n int; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'mfa@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  r := r || format('sem fator: loja.config=%s | ', public.tem_permissao(l, 'loja.config'));
  reset role;
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
  values (gen_random_uuid(), t, 'teste', 'totp', 'verified', now(), now());
  set local role authenticated;
  select count(*) into n from public.minhas_lojas();
  r := r || format('fator + aal1: loja.config=%s, lojas=%s, irmaos visíveis=%s | ', public.tem_permissao(l, 'loja.config'), n, (select count(*) from public.irmaos));
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  set local role authenticated;
  select count(*) into n from public.minhas_lojas();
  r := r || format('fator + aal2: loja.config=%s, lojas=%s', public.tem_permissao(l, 'loja.config'), n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
