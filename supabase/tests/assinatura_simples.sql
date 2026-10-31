-- Assinatura simples: tipo no modo simples gera documento simples com código de verificação; registrar passa a vez;
-- o último fecha com o PDF final; verificação pública mostra os assinantes com CPF mascarado; govbr recusa o simples.
do $$
declare vm uuid := gen_random_uuid(); l uuid; i_vm uuid; g uuid; tp uuid; doc uuid; a uuid; r text := ''; j jsonb; s text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (vm, 'asvm@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', vm, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('Loja Simples', '6', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'Venerável');
  select id into i_vm from public.irmaos where loja_id = l and user_id = vm;
  reset role;
  update public.irmaos set cpf = '39053344705', email = 'asvm@teste.com', nome = 'Venerável Teste' where id = i_vm;
  update public.tipos_documento set modo_assinatura = 'simples' where loja_id = l and codigo = 'atestado_frequencia';
  select id into tp from public.tipos_documento where loja_id = l and codigo = 'atestado_frequencia';
  insert into public.documentos_emitidos (loja_id, tipo, irmao_id, conteudo, tipo_documento_id, situacao)
  values (l, 'Atestado de frequência', i_vm, '{}', tp, 'assinando') returning id into doc;
  insert into public.documento_assinaturas (loja_id, documento_id, ordem, cargo_codigo, cargo_nome, irmao_id, status)
  values (l, doc, 1, 'veneravel', 'Venerável Mestre', i_vm, 'vez') returning id into a;
  select modo_assinatura || ' / código ' || length(codigo_verificacao) into s from public.documentos_emitidos where id = doc;
  r := r || format('documento=%s | ', s);
  s := public.registrar_assinatura_simples(a, 'whatsapp', '200.1.2.3', 'iPhone', 'abc123');
  r := r || format('registrar=%s | ', s);
  begin perform public.concluir_documento_simples(doc, l || '/documentos/' || doc || '/final.pdf', 'h'); r := r || 'concluído=ok | ';
  exception when others then r := r || 'concluir falhou: ' || sqlerrm || ' | '; end;
  j := public.verificar_documento((select codigo_verificacao from public.documentos_emitidos where id = doc));
  r := r || format('verificação=%s %s, assinante %s, cpf %s, via %s | ', j->>'tipo', j->>'situacao', j->'assinaturas'->0->>'nome', j->'assinaturas'->0->>'cpf', j->'assinaturas'->0->>'via');
  r := r || format('código errado=%s | ', coalesce(public.verificar_documento('XXXX')::text, 'nada'));
  -- documento gov.br não aceita assinatura simples
  update public.documentos_emitidos set situacao = 'assinando', modo_assinatura = 'govbr' where id = doc;
  update public.documento_assinaturas set status = 'vez' where id = a;
  begin perform public.registrar_assinatura_simples(a, 'senha', null, null, null); r := r || 'simples em doc gov.br=PERMITIU (ERRO)';
  exception when others then r := r || 'simples em doc gov.br=bloqueado'; end;
  raise exception 'RESULTADO: %', r;
end $$;
