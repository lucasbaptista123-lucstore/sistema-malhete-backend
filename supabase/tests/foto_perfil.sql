-- Foto de perfil: o próprio irmão troca a dele e os dados pessoais; não mexe em dados maçônicos nem na foto de outro.
do $$
declare
  se uuid := gen_random_uuid(); ap uuid := gen_random_uuid(); l uuid; i_se uuid; i_ap uuid; r text := '';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'f1@t.com', 'authenticated', 'authenticated', now()), (ap, 'f2@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Sec');
  select id into i_se from public.irmaos where loja_id = l and user_id = se;
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, ap, 'Irmão Ap', '9', '2020-01-01', '00000018724', 'i187x729@teste.com') returning id into i_ap;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', ap, 'role', 'authenticated')::text, true);
  set local role authenticated;
  r := r || format('pode mudar a própria foto=%s | ', public.pode_mudar_foto(l || '/' || i_ap || '/a.jpg'));
  r := r || format('pode mudar foto de outro=%s (esperado f) | ', public.pode_mudar_foto(l || '/' || i_se || '/a.jpg'));
  update public.irmaos set nome = 'Ap Novo', cpf = '11144477735', profissao = 'Eng', foto_caminho = l || '/' || i_ap || '/a.jpg' where id = i_ap;
  r := r || 'altera nome/cpf/profissão/foto=ok | ';
  begin
    update public.irmaos set foto_caminho = l || '/' || i_se || '/a.jpg' where id = i_ap;
    r := r || 'aponta foto de outro=PERMITIU (ERRO) | ';
  exception when others then r := r || 'aponta foto de outro=bloqueado | ';
  end;
  begin
    update public.irmaos set data_iniciacao = '2010-01-01' where id = i_ap;
    r := r || 'altera iniciação=PERMITIU (ERRO)';
  exception when others then r := r || 'altera iniciação=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
