-- Ata pronta (0134): o rascunho sai do que a sessão registrou, com o que só o Secretário sabe entre colchetes.
do $$
declare
  v uuid := gen_random_uuid(); sec uuid := gen_random_uuid(); outro uuid := gen_random_uuid();
  l uuid; i_v uuid; i_sec uuid; i_a uuid; i_b uuid; g uuid; s uuid; ata uuid; t uuid; txt text; ok text := '';
begin
  insert into auth.users (id, email, aud, role) values (v, 'apv@t.com', 'authenticated', 'authenticated'), (sec, 'aps@t.com', 'authenticated', 'authenticated'), (outro, 'apo@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Teste', '777', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'Campinas', 'SP', 'Venerável Teste');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, sec, 'Secretario Teste', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'aps@teste.com') returning id into i_sec;
  insert into public.irmaos (loja_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, 'Antonio Presente', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017752', 'ap@teste.com') returning id into i_a;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, outro, 'Bruno Justificado', 1, 'T'||left(gen_random_uuid()::text,8), current_date - 100, '00000017833', 'bj@teste.com') returning id into i_b;
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 30, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 30, current_date + 300
    from (values (i_v, 'veneravel'), (i_sec, 'secretario')) x(i, cargo) join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  insert into public.sessoes (loja_id, data, hora, tipo, grau, local, pauta, status)
    values (l, current_date - 2, '20:00', 'ordinaria', 1, 'Templo da Loja', 'Iniciação do candidato Fulano', 'realizada') returning id into s;
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao) values (l, s, i_v, 'presente'), (l, s, i_a, 'presente'), (l, s, i_sec, 'presente');
  insert into public.presencas (loja_id, sessao_id, irmao_id, situacao, justificativa) values (l, s, i_b, 'justificada', 'Viagem');
  insert into public.visitantes (loja_id, sessao_id, nome, grau, loja_origem, numero_loja, oriente) values (l, s, 'Roberto Nunes', 3, 'Loja Fraternidade', '1234', 'Jundiaí');
  insert into public.tronco_sessoes (loja_id, sessao_id, dinheiro) values (l, s, 85);
  insert into public.atas (loja_id, sessao_id, texto) values (l, s, '') returning id into ata;

  -- o Secretário pede o rascunho
  perform set_config('request.jwt.claims', json_build_object('sub', sec, 'role', 'authenticated')::text, true);
  set local role authenticated;
  txt := public.ata_rascunho(ata);
  reset role;
  if txt !~ 'reuniu-se a Loja Teste nº 777, ao Oriente de Campinas, em Sessão Ordinária no Grau de Aprendiz' then raise exception 'FALHOU: abertura: %', left(txt, 300); end if;
  if txt !~ 'presidência do Venerável Mestre Ir∴ ' then raise exception 'FALHOU: Venerável'; end if;
  if txt !~ 'Estiveram presentes 3 obreiros do quadro: Ir∴ Antonio Presente' then raise exception 'FALHOU: presentes'; end if;
  if txt !~ 'Justificaram a ausência: Ir∴ Bruno Justificado' then raise exception 'FALHOU: justificados'; end if;
  if txt !~ 'Visitantes: Ir∴ Roberto Nunes, Mestre, da Loja Fraternidade nº 1234, Oriente de Jundiaí' then raise exception 'FALHOU: visitante'; end if;
  if txt !~ 'Ordem do dia:\nIniciação do candidato Fulano' then raise exception 'FALHOU: ordem do dia'; end if;
  if txt !~ 'O Tronco de Beneficência rendeu R\$ 85,00' then raise exception 'FALHOU: Tronco: %', txt; end if;
  if txt !~ '\[Uso da palavra' or txt !~ 'eu, Ir∴ Secretario Teste, Secretário' then raise exception 'FALHOU: encerramento'; end if;
  ok := ok || 'abertura, presentes, justificados, visitante, ordem do dia, Tronco e encerramento | ';

  -- irmão sem cargo não pede o rascunho
  perform set_config('request.jwt.claims', json_build_object('sub', outro, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    txt := public.ata_rascunho(ata);
    raise exception 'FALHOU: irmão comum gerou o rascunho';
  exception when others then
    if sqlerrm like 'FALHOU%' then raise; end if;
  end;
  reset role;
  ok := ok || 'irmão comum barrado';

  raise exception 'OK: %', ok;
end $$;
