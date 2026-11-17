-- Biblioteca: trabalho de tema só depois de fazer o seu (0126).
-- Fabricio (Companheiro) faz o tema e é aprovado; William (Companheiro) ainda não: vê na lista trancado, sem texto e
-- sem arquivo (nem pelo storage). Autor, Vigilante do grau, Venerável e Mestre sem cargo leem. William envia: segue
-- trancado; aprovado, libera. Trabalho sem tema continua livre no grau.
do $$
declare
  v uuid := gen_random_uuid(); v1 uuid := gen_random_uuid(); fa uuid := gen_random_uuid(); wi uuid := gen_random_uuid();
  me uuid := gen_random_uuid();
  l uuid; i_v uuid; i_v1 uuid; i_fa uuid; i_wi uuid; g uuid; tema uuid; t_fa uuid; t_wi uuid; t_livre uuid;
  lib boolean; tx text; arq text; n int; r text := '';
begin
  insert into auth.users (id, email, aud, role) values
    (v, 'tv@t.com', 'authenticated', 'authenticated'), (v1, 'tv1@t.com', 'authenticated', 'authenticated'),
    (fa, 'tfa@t.com', 'authenticated', 'authenticated'), (wi, 'twi@t.com', 'authenticated', 'authenticated'),
    (me, 'tme@t.com', 'authenticated', 'authenticated');
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'V');
  select id into i_v from public.irmaos where loja_id = l and user_id = v;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, v1, 'Primeiro Vigilante', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017671', 'tv1@teste.com') returning id into i_v1;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, fa, 'Fabricio Teste', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017752', 'tfa@teste.com') returning id into i_fa;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, wi, 'William Teste', 2, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017833', 'twi@teste.com') returning id into i_wi;
  insert into public.irmaos (loja_id, user_id, nome, grau, cim, data_iniciacao, cpf, email) values (l, me, 'Mestre Sem Cargo', 3, 'T'||left(gen_random_uuid()::text,8), current_date - 400, '00000017914', 'tme@teste.com');
  insert into public.gestoes (loja_id, nome, inicio, fim) values (l, 'G', current_date - 1, current_date + 300) returning id into g;
  insert into public.mandatos (loja_id, gestao_id, irmao_id, cargo_id, inicio, fim)
    select l, g, x.i, c.id, current_date - 1, current_date + 300
    from (values (i_v, 'veneravel'), (i_v1, 'primeiro_vigilante')) x(i, cargo)
    join public.loja_cargos c on c.loja_id = l and c.codigo = x.cargo;
  reset role;
  update public.irmaos set admin_loja = false where id = i_v;

  -- 1º Vigilante propõe o tema; Fabricio faz (com arquivo) e é aprovado; um trabalho sem tema também aprovado
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.temas_trabalho (loja_id, grau, titulo) values (l, 2, 'A Letra G') returning id into tema;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', fa, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id, arquivo_caminho, arquivo_nome)
    values (l, i_fa, 2, 'A Letra G', 'texto do Fabricio', tema, l::text || '/fa/letra-g.pdf', 'letra-g.pdf') returning id into t_fa;
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto)
    values (l, i_fa, 2, 'Livre', 'sem tema') returning id into t_livre;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'aprovado' where id in (t_fa, t_livre);
  reset role;
  insert into storage.objects (bucket_id, name) values ('trabalhos', l::text || '/fa/letra-g.pdf');

  -- William (mesmo grau, não fez): trancado, sem texto, sem arquivo, storage fechado; o sem tema, livre
  perform set_config('request.jwt.claims', json_build_object('sub', wi, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select x.liberado, x.texto, x.arquivo_caminho into lib, tx, arq from public.trabalhos_aprovados(l) x where x.id = t_fa;
  if lib or tx is not null or arq is not null then raise exception 'FALHOU: William leu o trabalho (% % %)', lib, tx, arq; end if;
  if not (select x.liberado from public.trabalhos_aprovados(l) x where x.id = t_livre) then raise exception 'FALHOU: trabalho sem tema trancado'; end if;
  select count(*) into n from storage.objects where bucket_id = 'trabalhos' and name = l::text || '/fa/letra-g.pdf';
  if n <> 0 then raise exception 'FALHOU: William baixou o arquivo pelo storage'; end if;
  r := r || 'William trancado | ';
  -- William envia o dele: ainda trancado
  insert into public.trabalhos (loja_id, irmao_id, grau, titulo, texto, tema_id)
    values (l, i_wi, 2, 'Minha Letra G', 'texto do William', tema) returning id into t_wi;
  if (select x.liberado from public.trabalhos_aprovados(l) x where x.id = t_fa) then raise exception 'FALHOU: liberou só por enviar'; end if;
  reset role;

  -- quem lê sempre: autor, Vigilante do grau, Venerável, Mestre sem cargo
  perform set_config('request.jwt.claims', json_build_object('sub', fa, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if (select x.texto from public.trabalhos_aprovados(l) x where x.id = t_fa) is distinct from 'texto do Fabricio' then raise exception 'FALHOU: autor'; end if;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if not (select x.liberado from public.trabalhos_aprovados(l) x where x.id = t_fa) then raise exception 'FALHOU: 1º Vigilante'; end if;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if not (select x.liberado from public.trabalhos_aprovados(l) x where x.id = t_fa) then raise exception 'FALHOU: Venerável'; end if;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated')::text, true);
  set local role authenticated;
  if not (select x.liberado from public.trabalhos_aprovados(l) x where x.id = t_fa) then raise exception 'FALHOU: Mestre sem cargo'; end if;
  select count(*) into n from storage.objects where bucket_id = 'trabalhos' and name = l::text || '/fa/letra-g.pdf';
  if n <> 1 then raise exception 'FALHOU: Mestre não abre o arquivo'; end if;
  reset role;
  r := r || 'autor, Vigilante, Venerável e Mestre leem | ';

  -- o de William é aprovado: libera para ele (lista e arquivo)
  perform set_config('request.jwt.claims', json_build_object('sub', v1, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.trabalhos set status = 'aprovado' where id = t_wi;
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', wi, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select x.liberado, x.texto into lib, tx from public.trabalhos_aprovados(l) x where x.id = t_fa;
  if not lib or tx is distinct from 'texto do Fabricio' then raise exception 'FALHOU: não liberou depois de aprovado'; end if;
  select count(*) into n from storage.objects where bucket_id = 'trabalhos' and name = l::text || '/fa/letra-g.pdf';
  if n <> 1 then raise exception 'FALHOU: arquivo não liberou'; end if;
  reset role;
  r := r || 'aprovado o seu, libera';

  raise exception 'OK: %', r;
end $$;
