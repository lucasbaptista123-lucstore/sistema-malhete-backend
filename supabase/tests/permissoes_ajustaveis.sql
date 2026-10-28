-- Permissões ajustáveis: Venerável dá "ver Tesouraria" ao 1º Vigilante; não consegue dar "movimentar"; cria cargo extra;
-- restaurar volta ao padrão; irmão comum não mexe.
do $$ declare t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; c1 uuid; r text := ''; s text; n int; begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values (t, 'pa@t.com', 'authenticated', 'authenticated', now()),
    (x, 'pax@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 3, 'PX', '2015-01-01', '00000016276', 'i162x6324@teste.com');
  select id into c1 from public.loja_cargos where loja_id = l and codigo = 'primeiro_vigilante';
  update public.loja_cargos set permissoes = permissoes || array['tesouraria.ler', 'mural.publicar'] where id = c1;
  select array_to_string(permissoes, ',') into s from public.loja_cargos where id = c1;
  r := r || format('1º Vig agora=%s | ', s);
  begin update public.loja_cargos set permissoes = permissoes || array['tesouraria.editar'] where id = c1; r := r || 'dar movimentar=PERMITIU (ERRO) | ';
  exception when others then r := r || 'dar movimentar=bloqueado | '; end;
  begin update public.loja_cargos set permissoes = array_remove(permissoes, 'tesouraria.editar') where loja_id = l and codigo = 'tesoureiro'; r := r || 'tirar do Tesoureiro=PERMITIU (ERRO) | ';
  exception when others then r := r || 'tirar do Tesoureiro=bloqueado | '; end;
  begin update public.loja_cargos set permissoes = permissoes || array['inventada.x'] where id = c1; r := r || 'inventada=PERMITIU (ERRO) | ';
  exception when others then r := r || 'inventada=bloqueado | '; end;
  insert into public.loja_cargos (loja_id, codigo, nome, ordem, permissoes) values (l, 'comissao_eventos', 'Comissão de Eventos', 40, array['mural.publicar']);
  r := r || 'cargo extra=criado | ';
  begin insert into public.loja_cargos (loja_id, codigo, nome, ordem, permissoes) values (l, 'tes2', 'Tesoureiro 2', 41, array['tesouraria.editar']); r := r || 'extra com movimentar=PERMITIU (ERRO) | ';
  exception when others then r := r || 'extra com movimentar=bloqueado | '; end;
  n := public.restaurar_permissoes(l);
  select array_to_string(permissoes, ',') into s from public.loja_cargos where id = c1;
  r := r || format('restaurou %s cargo(s), 1º Vig=%s | ', n, s);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.loja_cargos set permissoes = permissoes || array['tesouraria.ler'] where id = c1;
  get diagnostics n = row_count;
  r := r || format('irmão comum alterou=%s linha(s)', n);
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
