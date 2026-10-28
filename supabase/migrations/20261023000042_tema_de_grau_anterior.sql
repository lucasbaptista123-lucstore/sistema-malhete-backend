-- Sistema Malhete — trabalho sobre tema de grau anterior (pendência de quem recebeu aumento de salário):
-- o trabalho assume o grau do TEMA, então vai para o Vigilante daquele grau e, aprovado, entra na
-- Biblioteca daquele grau. Sem tema, continua com o grau atual do autor.

create or replace function public.validar_tema_trabalho() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_tema_grau smallint;
  v_autor_grau smallint := (select grau from public.irmaos where id = new.irmao_id);
begin
  if new.tema_id is null then return new; end if;
  select grau into v_tema_grau from public.temas_trabalho where id = new.tema_id and loja_id = new.loja_id;
  if v_tema_grau is null or v_tema_grau > v_autor_grau then
    raise exception 'Tema inválido para este trabalho';
  end if;
  if tg_op = 'INSERT' then
    new.grau := v_tema_grau;
  elsif v_tema_grau <> old.grau then
    raise exception 'Este tema é de outro grau; envie um novo trabalho para ele';
  end if;
  return new;
end $$;
