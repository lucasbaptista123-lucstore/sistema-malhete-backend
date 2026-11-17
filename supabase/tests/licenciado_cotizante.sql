-- Licenciado cotizante (0127): recebe a mensalidade (gerar, sem lista e com lista) e pode adiantar; NÃO entra na
-- convocação da sessão (nem pela lista escolhida) e mantém o acesso. Quite placet continua fora da mensalidade.
do $$
declare
  v uuid := gen_random_uuid(); u_li uuid := gen_random_uuid();
  l uuid; i_at uuid; i_li uuid; i_qp uuid; s uuid; e uuid; n int; r text := '';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (v, 'lc@t.com', 'authenticated', 'authenticated', now()), (u_li, 'lcli@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values
    (l, 'Ativo Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'lca@teste.com', '11999990001') returning id into i_at;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values
    (l, 'Licenciado Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017752', 'lcli@teste.com', '11999990002') returning id into i_li;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values
    (l, 'Quite Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017833', 'lcq@teste.com', '11999990003') returning id into i_qp;
  perform public.alterar_situacao(i_li, 'licenciado', 'licenca', current_date, 'não pode ir às sessões');
  perform public.alterar_situacao(i_qp, 'quite_placet', 'quite_placet', current_date, 'saiu');

  -- mensalidade: sem lista (todos) e com lista (o diálogo manda os marcados)
  n := public.gerar_mensalidades(l, date_trunc('month', current_date)::date, 150, current_date + 10);
  if not exists (select 1 from public.titulos where irmao_id = i_li and origem = 'mensalidade') then raise exception 'FALHOU: licenciado sem mensalidade (sem lista)'; end if;
  if exists (select 1 from public.titulos where irmao_id = i_qp and origem = 'mensalidade') then raise exception 'FALHOU: quite placet com mensalidade'; end if;
  n := public.gerar_mensalidades(l, (date_trunc('month', current_date) + interval '1 month')::date, 150, current_date + 40, array[i_at, i_li]);
  if n <> 2 then raise exception 'FALHOU: com lista gerou % (esperado 2)', n; end if;
  r := r || 'licenciado recebe mensalidade | ';

  -- convocação: só ativos, mesmo se o licenciado vier na lista
  insert into public.sessoes (loja_id, tipo, grau, data) values (l, 'ordinaria', 1, current_date + 5) returning id into s;
  e := public.criar_envio(l, 'convocacao', 'Convocação', s);
  if exists (select 1 from public.envio_destinatarios where envio_id = e and irmao_id = i_li) then raise exception 'FALHOU: licenciado convocado'; end if;
  if not exists (select 1 from public.envio_destinatarios where envio_id = e and irmao_id = i_at) then raise exception 'FALHOU: ativo não convocado'; end if;
  e := public.criar_envio(l, 'convocacao', 'Convocação', s, array[i_at, i_li]);
  if exists (select 1 from public.envio_destinatarios where envio_id = e and irmao_id = i_li) then raise exception 'FALHOU: licenciado convocado pela lista'; end if;
  r := r || 'licenciado fora da convocação | ';
  reset role;

  -- o licenciado continua entrando e adianta as dele
  update public.irmaos set user_id = u_li where id = i_li;
  insert into public.tesouraria_config (loja_id, valor_mensalidade) values (l, 150)
    on conflict (loja_id) do update set valor_mensalidade = 150;
  perform set_config('request.jwt.claims', json_build_object('sub', u_li, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if not (l in (select public.minhas_lojas())) then raise exception 'FALHOU: licenciado perdeu o acesso'; end if;
  n := public.adiantar_mensalidades(l, 2);
  if n <> 2 then raise exception 'FALHOU: licenciado adiantou % (esperado 2)', n; end if;
  reset role;
  r := r || 'acesso e adiantamento ok';

  raise exception 'OK: %', r;
end $$;
