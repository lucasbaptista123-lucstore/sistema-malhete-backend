-- Entrada pelo e-mail só com e-mail confirmado de verdade (0128) e auditoria sem gravação vazia (0129).
-- Conta criada com o e-mail de um irmão sem acesso, sem confirmação (como no oficial hoje): NÃO é ligada ao irmão.
-- Conta "confirmada" antes de qualquer envio também não. Conta que recebeu a confirmação e clicou depois: é ligada.
-- Auditoria: gravar o irmão só com nova hora não cria registro; mudar um campo cria.
do $$
declare
  v uuid := gen_random_uuid(); intruso uuid := gen_random_uuid(); reenvio uuid := gen_random_uuid(); dono uuid := gen_random_uuid();
  l uuid; i_alvo uuid; i_outro uuid; n int; a0 int; a1 int; r text := '';
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at, confirmation_sent_at) values
    (v, 'ev@t.com', 'authenticated', 'authenticated', now(), null),
    -- intruso: cria a conta com o e-mail do irmão; sem confirmação ligada, já nasce confirmado e nada foi enviado
    (intruso, 'alvo@teste.com', 'authenticated', 'authenticated', now(), null),
    -- confirmado antes do envio (pediu um reenvio depois de já estar confirmado): também não vale
    (reenvio, 'outro@teste.com', 'authenticated', 'authenticated', now() - interval '1 hour', now()),
    -- dono do e-mail: o Supabase mandou a confirmação e ele clicou depois
    (dono, 'outro2@teste.com', 'authenticated', 'authenticated', now(), now() - interval '10 minutes');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Irmao Alvo', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'alvo@teste.com') returning id into i_alvo;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Irmao Outro', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017752', 'outro@teste.com') returning id into i_outro;
  reset role;

  perform set_config('request.jwt.claims', json_build_object('sub', intruso, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := public.vincular_por_email();
  reset role;
  if n <> 0 or (select user_id from public.irmaos where id = i_alvo) is not null then raise exception 'FALHOU: conta sem confirmação ligada ao irmão'; end if;
  r := r || 'sem confirmação não liga | ';

  perform set_config('request.jwt.claims', json_build_object('sub', reenvio, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := public.vincular_por_email();
  reset role;
  if n <> 0 or (select user_id from public.irmaos where id = i_outro) is not null then raise exception 'FALHOU: confirmado antes do envio ligou'; end if;
  r := r || 'confirmado antes do envio não liga | ';

  update auth.users set email = 'outro-antigo@teste.com' where id = reenvio;
  update auth.users set email = 'outro@teste.com' where id = dono;
  perform set_config('request.jwt.claims', json_build_object('sub', dono, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := public.vincular_por_email();
  reset role;
  if n <> 1 or (select user_id from public.irmaos where id = i_outro) is distinct from dono then raise exception 'FALHOU: e-mail confirmado de verdade não ligou (%)', n; end if;
  r := r || 'confirmado pelo e-mail liga | ';

  -- auditoria: só a hora não grava; mudança de verdade grava
  select count(*) into a0 from public.audit_log where tabela = 'irmaos' and registro_id = i_alvo;
  update public.irmaos set atualizado_em = now() + interval '1 minute' where id = i_alvo;
  update public.irmaos set nome = nome where id = i_alvo;
  select count(*) into a1 from public.audit_log where tabela = 'irmaos' and registro_id = i_alvo;
  if a1 <> a0 then raise exception 'FALHOU: auditoria gravou atualização vazia (% -> %)', a0, a1; end if;
  update public.irmaos set profissao = 'Engenheiro' where id = i_alvo;
  select count(*) into a1 from public.audit_log where tabela = 'irmaos' and registro_id = i_alvo;
  if a1 <> a0 + 1 then raise exception 'FALHOU: auditoria não gravou mudança real (% -> %)', a0, a1; end if;
  if (select depois->>'profissao' from public.audit_log where tabela = 'irmaos' and registro_id = i_alvo order by em desc, id desc limit 1) is distinct from 'Engenheiro' then
    raise exception 'FALHOU: auditoria sem o valor novo';
  end if;
  r := r || 'auditoria ignora só a hora e grava mudança';

  raise exception 'OK: %', r;
end $$;
