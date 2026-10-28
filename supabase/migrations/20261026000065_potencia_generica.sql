-- Sistema Malhete — o sistema é para Lojas de qualquer Potência (GOB, Grandes Lojas, COMAB…): nome neutro da
-- categoria de taxas (o código taxas_gob continua o mesmo).
update public.categorias_financeiras set nome = 'Taxas da Potência (cobradas dos irmãos)'
where codigo = 'taxas_gob' and nome = 'Taxas do GOB (cobradas dos irmãos)';
create or replace function private.categorias_irmaos_nome_neutro() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.categorias_financeiras set nome = 'Taxas da Potência (cobradas dos irmãos)'
  where loja_id = new.id and codigo = 'taxas_gob' and nome = 'Taxas do GOB (cobradas dos irmãos)';
  return new;
end $$;
create trigger zzz_categoria_potencia after insert on public.lojas
for each row execute function private.categorias_irmaos_nome_neutro();
revoke execute on function private.categorias_irmaos_nome_neutro from public, anon, authenticated;
