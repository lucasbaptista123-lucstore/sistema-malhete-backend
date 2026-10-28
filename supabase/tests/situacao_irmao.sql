-- Situação do irmão: motivo + histórico; quem sai perde acesso e cargo.
do $$
declare
  se uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  l uuid; i_se uuid; i_x uuid; g uuid; r text := ''; n int; t text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'se2@t.com', 'authenticated', 'authenticated', now()), (u2, 'x2@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Sec');
  select id into i_se from public.irmaos where loja_id = l and user_id = se;
  insert into public.irmaos (loja_id, nome, grau, email, cim, data_iniciacao, cpf) values (l, 'Irmão X', 3, 'x2@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000010740') returning id into i_x;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 10, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_x, id, current_date - 10, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
  reset role;
  update public.irmaos set user_id = u2 where id = i_x;
  set local role authenticated;
  select count(*)::int into n from public.diretorio(l) d where d.tem_acesso;
  r := r || format('diretório com acesso=%s (esperado 2) | ', n);

  perform public.alterar_situacao(i_x, 'quite_placet', 'quite_placet', current_date, 'pedido do irmão');
  select situacao::text into t from public.irmaos where id = i_x;
  r := r || format('situação=%s | ', t);
  select count(*) into n from public.irmao_situacoes where irmao_id = i_x;
  r := r || format('histórico=%s | ', n);
  select count(*) into n from public.mandatos where irmao_id = i_x and current_date between inicio and fim;
  r := r || format('cargo vigente=%s (esperado 0) | ', n);
  begin
    perform public.alterar_situacao(i_se, 'desligado', 'saida');
    r := r || 'desligar a si mesmo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'desligar a si mesmo=bloqueado | ';
  end;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.minhas_lojas() x where x = l;
  r := r || format('quite placet ainda entra=%s (esperado 0) | ', n);
  begin
    perform public.alterar_situacao(i_x, 'ativo', 'regularizacao');
    r := r || 'irmão reativa a si=PERMITIU (ERRO)';
  exception when others then r := r || 'irmão reativa a si=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
