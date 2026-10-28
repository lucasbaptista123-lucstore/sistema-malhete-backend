-- Painel da plataforma: só o dono vê; vê contagens, não dados internos.
do $$
declare a uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; r text := ''; n int; t text;
begin
  insert into auth.users (id, email, aud, role) values (a, 'a@t.com', 'authenticated', 'authenticated'), (x, 'x@t.com', 'authenticated', 'authenticated');
  insert into public.plataforma_admins (user_id) values (a);
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja X', '9', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'X');
  begin
    perform * from public.plataforma_lojas();
    r := r || 'irmão comum vê painel=PERMITIU (ERRO) | ';
  exception when others then r := r || 'irmão comum vê painel=bloqueado | ';
  end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select irmaos_ativos || '/' || com_acesso || '/' || status into t from public.plataforma_lojas() where loja_id = l;
  r := r || format('dono vê loja=%s (esperado 1/1/teste) | ', t);
  perform public.plataforma_assinatura(l, 'ativa', 'mensal', null);
  select status into t from public.plataforma_lojas() where loja_id = l;
  r := r || format('ativa a loja=%s | ', t);
  select count(*) into n from public.irmaos where loja_id = l;
  r := r || format('dono lê irmãos da loja=%s (esperado 0)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
