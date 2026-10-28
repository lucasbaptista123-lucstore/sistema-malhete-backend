-- Estandarte: só loja.config envia; caminho tem de ser da própria loja.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; l2 uuid; r text := ''; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'es@t.com', 'authenticated', 'authenticated', now()),
    (x, 'esx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  l2 := public.criar_loja('L2', '2', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão Comum', 3, 'EX', '2015-01-01', '52998224725', 'ex@teste.com');
  r := r || format('Venerável pode enviar=%s | ', public.pode_mudar_estandarte(l || '/loja/estandarte-1.png'));
  update public.lojas set estandarte_caminho = l || '/loja/estandarte-1.png' where id = l;
  begin update public.lojas set estandarte_caminho = l2 || '/loja/x.png' where id = l; r := r || 'caminho de outra loja=PERMITIU (ERRO) | ';
  exception when others then r := r || 'caminho de outra loja=bloqueado | '; end;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := r || format('irmão comum pode enviar=%s', public.pode_mudar_estandarte(l || '/loja/estandarte-2.png'));
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
