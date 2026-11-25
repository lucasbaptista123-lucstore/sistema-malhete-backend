-- Botões no WhatsApp (0131): convite termina no link (a fila o troca pelo botão "Acessar o sistema") e o Venerável
-- decide a justificativa pelos botões "Aceitar" / "Não aceitar". Só vale do telefone dele, uma vez, e avisa o irmão.
do $$
declare
  v uuid := gen_random_uuid(); ir uuid := gen_random_uuid();
  l uuid; i_v uuid; i_ir uuid; i_novo uuid; g uuid; s uuid; cf uuid; n public.notificacoes; tok text; r text; ok text := '';
begin
  insert into auth.users (id, email, aud, role) values (v, 'jbv@t.com', 'authenticated', 'authenticated'), (ir, 'jbi@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  update public.irmaos set telefone = '(11) 98888-7777' where id = i_v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, ir, 'Joao Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'jbi@teste.com', '11977776666') returning id into i_ir;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email, telefone) values (l, 'Novo Irmao', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 30, '00000017752', 'novo@teste.com', '11966665555') returning id into i_novo;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, i_v, c.id, current_date - 1, current_date + 300 from public.loja_cargos c where c.loja_id = l and c.codigo = 'veneravel';
  insert into public.sessoes (loja_id, data, hora, tipo, grau) values (l, current_date + 3, '20:00', 'ordinaria', 1) returning id into s;

  -- convite: o texto termina no link do convite
  perform public.convidar_irmao(i_novo, true);
  select * into n from public.notificacoes where irmao_id = i_novo and tipo = 'convite' order by criado_em desc limit 1;
  if n.mensagem !~ 'Toque no botão abaixo' or n.mensagem !~ '/convite/[0-9a-f]+$' then raise exception 'FALHOU: convite sem o link no fim: %', n.mensagem; end if;
  ok := ok || 'convite termina no link | ';
  reset role;

  -- o irmão avisa que não vai, com motivo: o Venerável recebe os botões
  perform set_config('request.jwt.claims', json_build_object('sub', ir, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.responder_convocacao(s, 'nao_vou', 'Plantão no hospital');
  select id into cf from public.confirmacoes where sessao_id = s and irmao_id = i_ir;
  reset role;
  select * into n from public.notificacoes where irmao_id = i_v and tipo = 'justificativa' order by criado_em desc limit 1;
  if n.botoes is null or n.botoes[1] !~ '^Aceitar\|jv:sim:' or n.botoes[2] !~ '^Não aceitar\|jv:nao:' then raise exception 'FALHOU: aviso sem botões: %', n.botoes; end if;
  tok := split_part(n.botoes[1], ':', 3);
  ok := ok || 'Venerável recebe Aceitar e Não aceitar | ';

  -- outro telefone não decide
  r := public.whatsapp_botao(l, '5511900001111', 'jv:sim:' || tok);
  if r is not null or (select ciente_em from public.confirmacoes where id = cf) is not null then raise exception 'FALHOU: outro telefone decidiu'; end if;
  ok := ok || 'outro telefone ignorado | ';

  -- o Venerável toca em Aceitar (o WhatsApp manda o número com 55)
  r := public.whatsapp_botao(l, '5511988887777@s.whatsapp.net', 'jv:sim:' || tok);
  if r !~ 'foi aceita' or not (select aceita from public.confirmacoes where id = cf) then raise exception 'FALHOU: não aceitou (%)', r; end if;
  if not exists (select 1 from public.notificacoes where irmao_id = i_ir and tipo = 'justificativa' and mensagem ~ 'aceitou sua justificativa') then
    raise exception 'FALHOU: irmão não foi avisado';
  end if;
  ok := ok || 'Aceitar decide e avisa o irmão | ';

  -- segundo toque (ou Não aceitar depois): já decidida
  r := public.whatsapp_botao(l, '11988887777', 'jv:nao:' || tok);
  if r !~ 'já foi decidida: aceita' or not (select aceita from public.confirmacoes where id = cf) then raise exception 'FALHOU: decidiu duas vezes (%)', r; end if;
  ok := ok || 'segundo toque não muda';

  raise exception 'OK: %', ok;
end $$;
