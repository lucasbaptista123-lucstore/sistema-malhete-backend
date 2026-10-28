-- Planos: teste liberado; teste vencido há mais de 5 dias trava (e o Tesoureiro ainda lê a assinatura);
-- assinante com fatura vencida há 5 dias ainda entra, há 6 trava; pagar destrava; vitalícia nunca trava;
-- trava manual do dono; RLS das tabelas segue a trava.
do $$
declare vm uuid := gen_random_uuid(); te uuid := gen_random_uuid(); l uuid; i_te uuid; g uuid; r text := ''; j jsonb; n int;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (vm, 'pl_vm@t.com', 'authenticated', 'authenticated', now()), (te, 'pl_te@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Plano', '9', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, te, 'Tesoureiro Plano', 3, 'PL1', '2015-01-01', '11144477735', 'plte@teste.com') returning id into i_te;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_te, c.id, current_date - 1, current_date + 300 from public.loja_cargos c where c.loja_id = l and c.codigo = 'tesoureiro';
  n := (select count(*) from public.irmaos where loja_id = l);
  reset role;
  r := r || format('teste novo: liberada=%s ve_irmaos=%s | ', private.loja_liberada(l), n);

  update public.assinaturas set teste_ate = private.hoje_br() - 5 where loja_id = l;
  r := r || format('teste vencido há 5 dias: %s | ', private.loja_liberada(l));
  update public.assinaturas set teste_ate = private.hoje_br() - 6 where loja_id = l;
  r := r || format('há 6 dias: %s | ', private.loja_liberada(l));

  perform set_config('request.jwt.claims', json_build_object('sub', te, 'role', 'authenticated')::text, true);
  set local role authenticated;
  j := public.minha_assinatura(l);
  r := r || format('travada: tesoureiro ve irmaos=%s, tesouraria=%s, minha_assinatura liberada=%s pode_pagar=%s, le assinatura=%s | ',
    (select count(*) from public.irmaos where loja_id = l), public.tem_permissao(l, 'tesouraria.editar'), j->>'liberada', j->>'pode_pagar',
    (select count(*) from public.assinaturas where loja_id = l));
  reset role;

  -- assina: fatura vencida há 5 dias ainda libera; 6 trava; paga destrava
  update public.assinaturas set asaas_assinatura_id = 'sub_teste', ciclo = 'mensal', valor = 199 where loja_id = l;
  perform public.plataforma_espelhar_fatura('sub_teste', 'pay_1', 199, private.hoje_br() - 5, 'OVERDUE', 'PIX', null, null);
  r := r || format('fatura vencida há 5 dias: %s (%s) | ', private.loja_liberada(l), (select status from public.assinaturas where loja_id = l));
  update public.faturas_plataforma set vencimento = private.hoje_br() - 6 where asaas_id = 'pay_1';
  r := r || format('há 6: %s | ', private.loja_liberada(l));
  perform public.plataforma_espelhar_fatura('sub_teste', 'pay_1', 199, private.hoje_br() - 6, 'RECEIVED', 'PIX', null, private.hoje_br());
  r := r || format('pagou: %s (%s, próximo %s) | ', private.loja_liberada(l), (select status from public.assinaturas where loja_id = l),
    (select proximo_vencimento - private.hoje_br() from public.assinaturas where loja_id = l));

  update public.assinaturas set bloqueio_manual = true where loja_id = l;
  r := r || format('trava manual: %s | ', private.loja_liberada(l));
  update public.assinaturas set bloqueio_manual = false, status = 'vitalicia' where loja_id = l;
  update public.faturas_plataforma set status = 'vencida', vencimento = private.hoje_br() - 30 where asaas_id = 'pay_1';
  r := r || format('vitalícia com fatura vencida: %s', private.loja_liberada(l));
  raise exception 'RESULTADO: %', r;
end $$;
