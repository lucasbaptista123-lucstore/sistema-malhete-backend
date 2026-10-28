-- Um cargo por irmão; convite de primeiro acesso.
do $$
declare
  se uuid := gen_random_uuid(); novo uuid := gen_random_uuid(); outro uuid := gen_random_uuid();
  l uuid; i_se uuid; i_x uuid; i_y uuid; g uuid; v_link text; v_tok text; r text := ''; n int; t text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (se, 'se@t.com', 'authenticated', 'authenticated', now()), (novo, 'joao@t.com', 'authenticated', 'authenticated', now()),
    (outro, 'outro@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Sec');
  select id into i_se from public.irmaos where loja_id = l and user_id = se;
  insert into public.irmaos (loja_id, nome, grau, telefone, email, cim, data_iniciacao, cpf) values (l, 'João Novo', 3, '12999990009', 'joao@t.com', 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000010316') returning id into i_x;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Irmão Y', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000010405', 'i104x9962@teste.com') returning id into i_y;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_se, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'secretario';

  -- um cargo por irmão
  begin
    insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
      select l, g, i_se, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
    r := r || 'segundo cargo=PERMITIU (ERRO) | ';
  exception when others then r := r || format('segundo cargo=bloqueado (%s) | ', left(sqlerrm, 60));
  end;
  begin
    insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
      select l, g, i_y, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'secretario';
    r := r || 'dois no mesmo cargo=PERMITIU (ERRO) | ';
  exception when others then r := r || 'dois no mesmo cargo=bloqueado | ';
  end;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_y, id, current_date - 1, current_date + 300 from public.loja_cargos where loja_id = l and codigo = 'tesoureiro';
  r := r || 'outro irmão no outro cargo=ok | ';

  -- convite
  reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  set local role service_role;
  perform public.whatsapp_salvar(l, 'x', 'tok');
  perform public.whatsapp_atualizar(l, 'conectado', null, null, null);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', se, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_link := public.convidar_irmao(i_x);
  v_tok := split_part(v_link, '/convite/', 2);
  r := r || format('link gerado=%s | ', v_link like '%/convite/%');
  select count(*) into n from public.notificacoes where irmao_id = i_x and tipo = 'convite' and status = 'pendente';
  r := r || format('convite na fila do WhatsApp=%s (esperado 1) | ', n);
  reset role;

  set local role anon;
  select valido || ' / ' || primeiro_nome || ' / ' || email into t from public.convite_info(v_tok);
  r := r || format('página pública do convite=%s | ', t);
  reset role;

  -- outra pessoa sem convite não entra; o convidado aceita
  perform set_config('request.jwt.claims', json_build_object('sub', novo, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.aceitar_convite(v_tok);
  select count(*) into n from public.minhas_lojas() x where x = l;
  r := r || format('convidado entra na loja=%s (esperado 1) | ', n);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', outro, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.aceitar_convite(v_tok);
    r := r || 'reusar convite=PERMITIU (ERRO)';
  exception when others then r := r || 'reusar convite=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
