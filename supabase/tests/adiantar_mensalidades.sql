-- Irmão adianta mensalidades no valor da Tesouraria; não duplica; irmão comum não edita a configuração.
do $$
declare
  t uuid := gen_random_uuid(); x uuid := gen_random_uuid(); l uuid; r text := ''; n int; s text;
begin
  insert into auth.users (id, email, aud, role, email_confirmed_at) values
    (t, 'ad@t.com', 'authenticated', 'authenticated', now()), (x, 'adx@t.com', 'authenticated', 'authenticated', now());
  perform set_config('request.jwt.claims', json_build_object('sub', t, 'role', 'authenticated')::text, true);
  set local role authenticated;
  l := public.criar_loja('L', '1', (select id from public.orientes where uf = 'SP'), (select id from public.ritos where sigla = 'REAA'), 'X', 'SP', 'T');
  insert into public.irmaos (loja_id, user_id, nome, cim, data_iniciacao, cpf, email) values (l, x, 'Irmão X', 'A1', '2020-01-01', '00000011479', 'i114x9197@teste.com');
  insert into public.tesouraria_config (loja_id, pix_chave, pix_titular, valor_mensalidade, dia_vencimento) values (l, '12.345.678/0001-90', 'Loja X', 120, 5);
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select pix_chave into s from public.tesouraria_config where loja_id = l;
  r := r || format('irmão vê PIX=%s | ', s);
  n := public.adiantar_mensalidades(l, 3);
  r := r || format('adiantou=%s (esperado 3) | ', n);
  n := public.adiantar_mensalidades(l, 2);
  select string_agg(to_char(competencia, 'MM') || '/' || valor || '/' || extract(day from vencimento), ',' order by competencia) into s
  from public.titulos where loja_id = l and origem = 'mensalidade';
  r := r || format('de novo=%s; títulos=%s | ', n, s);
  begin
    update public.tesouraria_config set pix_chave = 'golpe' where loja_id = l;
    get diagnostics n = row_count;
    r := r || format('irmão altera PIX=%s linhas (esperado 0)', n);
  exception when others then r := r || 'irmão altera PIX=bloqueado';
  end;
  reset role;
  raise exception 'RESULTADO: %', r;
end $$;
