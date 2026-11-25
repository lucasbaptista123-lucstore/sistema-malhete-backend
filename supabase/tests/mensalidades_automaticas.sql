-- Mensalidades automáticas (0133): desligada não gera; 'mensal' gera o mês seguinte a partir de 15 dias antes, para
-- quem pagou o mês anterior e para irmão novo, nunca para quem foi desmarcado; 'anual' gera os doze meses em dezembro.
do $$
declare
  v uuid := gen_random_uuid();
  l uuid; i_v uuid; i_paga uuid; i_desm uuid; i_novo uuid; i_lic uuid; n int; ok text := '';
begin
  insert into auth.users (id, email, aud, role) values (v, 'ma@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Paga Sempre', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'p@teste.com') returning id into i_paga;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Foi Desmarcado', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017752', 'd@teste.com') returning id into i_desm;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Licenciado Cotizante', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017833', 'lc@teste.com') returning id into i_lic;
  -- novembro de 2026 gerado pelo diálogo para todos menos o desmarcado
  perform public.gerar_mensalidades(l, '2026-11-01', 180, '2026-11-10', array[i_v, i_paga, i_lic]);
  reset role;
  update public.irmaos set situacao = 'licenciado' where id = i_lic;
  -- irmão novo, que nunca teve mensalidade
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cim_pendente) values (l, 'Aprendiz Novo', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 5, true) returning id into i_novo;
  -- (no teste tudo roda no mesmo instante; na vida real o irmão novo é cadastrado depois da geração)
  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos set criado_em = now() + interval '1 minute' where id = i_novo;
  perform set_config('malhete.sistema', 'off', true);
  insert into public.tesouraria_config (loja_id, valor_mensalidade, dia_vencimento) values (l, 200, 28)
    on conflict (loja_id) do update set valor_mensalidade = 200, dia_vencimento = 28;

  -- desligada: nada
  n := private.gerar_mensalidades_auto('2026-11-20');
  if exists (select 1 from public.titulos where loja_id = l and competencia = '2026-12-01') then raise exception 'FALHOU: gerou desligada'; end if;

  -- mensal, antes dos 15 dias: nada; a 15 dias: dezembro
  update public.tesouraria_config set mensalidade_auto = 'mensal' where loja_id = l;
  perform private.gerar_mensalidades_auto('2026-11-15');
  if exists (select 1 from public.titulos where loja_id = l and competencia = '2026-12-01') then raise exception 'FALHOU: gerou cedo demais'; end if;
  perform private.gerar_mensalidades_auto('2026-11-16');
  select count(*) into n from public.titulos where loja_id = l and competencia = '2026-12-01' and origem = 'mensalidade';
  if n <> 4 then raise exception 'FALHOU: dezembro gerou % (esperado 4: V, paga, licenciado, novo)', n; end if;
  if exists (select 1 from public.titulos where irmao_id = i_desm and competencia = '2026-12-01') then raise exception 'FALHOU: gerou para o desmarcado'; end if;
  if (select valor from public.titulos where irmao_id = i_paga and competencia = '2026-12-01') <> 200
     or (select vencimento from public.titulos where irmao_id = i_paga and competencia = '2026-12-01') <> '2026-12-28' then
    raise exception 'FALHOU: valor ou vencimento da configuração';
  end if;
  ok := ok || 'mensal: 15 dias antes, pagantes + novo, sem o desmarcado | ';

  -- rodar de novo não duplica
  perform private.gerar_mensalidades_auto('2026-11-17');
  if (select count(*) from public.titulos where loja_id = l and competencia = '2026-12-01') <> 4 then raise exception 'FALHOU: duplicou'; end if;
  ok := ok || 'não duplica | ';

  -- anual: em dezembro, o ano seguinte inteiro (dia 28 em todos os meses)
  update public.tesouraria_config set mensalidade_auto = 'anual' where loja_id = l;
  perform private.gerar_mensalidades_auto('2026-12-01');
  select count(*) into n from public.titulos where irmao_id = i_paga and origem = 'mensalidade' and competencia between '2027-01-01' and '2027-12-01';
  if n <> 12 then raise exception 'FALHOU: anual gerou % meses (esperado 12)', n; end if;
  if (select vencimento from public.titulos where irmao_id = i_paga and competencia = '2027-02-01') <> '2027-02-28' then raise exception 'FALHOU: vencimento de fevereiro'; end if;
  if exists (select 1 from public.titulos where irmao_id = i_desm and competencia >= '2027-01-01') then raise exception 'FALHOU: anual gerou para o desmarcado'; end if;
  ok := ok || 'anual: doze meses em dezembro';

  raise exception 'OK: %', ok;
end $$;
