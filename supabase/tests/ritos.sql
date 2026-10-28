-- Ritos: Loja nova de cada rito recebe os cargos do rito, o Venerável assume, os documentos padrão acham os cargos
-- (veneravel, secretario, tesoureiro, chanceler) e a Hospitalaria tem dono.
do $$
declare u uuid; l uuid; r text := ''; s text; n int; rito text;
begin
  foreach rito in array array['YORK', 'SCHRODER', 'ADONHIRAMITA', 'MODERNO', 'BRASILEIRO'] loop
    u := gen_random_uuid();
    insert into auth.users (id, email, aud, role, email_confirmed_at) values (u, lower(rito) || '@t.com', 'authenticated', 'authenticated', now());
    perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
    set local role authenticated;
    l := public.criar_loja('Loja ' || rito, '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = rito), 'X', 'SP', 'Venerável');
    select count(*) into n from public.loja_cargos where loja_id = l;
    select string_agg(nome, '/' order by codigo) into s from public.loja_cargos where loja_id = l and codigo in ('veneravel', 'secretario', 'tesoureiro', 'chanceler', 'hospitaleiro', 'orador');
    r := r || format('%s: %s cargos, %s, docs sem cargo=%s, tem_config=%s | ', rito, n, s,
      (select count(*) from public.tipos_documento t, unnest(t.assinantes) a where t.loja_id = l and not exists (select 1 from public.loja_cargos c where c.loja_id = l and c.codigo = a)),
      public.tem_permissao(l, 'loja.config'));
    reset role;
  end loop;
  raise exception 'RESULTADO: %', r;
end $$;
