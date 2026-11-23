-- Sistema Malhete: CONTA SÓ É LIGADA AO IRMÃO PELO E-MAIL QUANDO O E-MAIL FOI CONFIRMADO DE VERDADE (23/11, varredura
-- antes de rodar de vez).
-- O oficial está com a confirmação de e-mail desligada (o envio embutido do Supabase só entrega para a equipe do
-- projeto, 2 por hora), então toda conta nova já nasce "confirmada". `vincular_por_email` ligava a conta ao irmão
-- cadastrado com o mesmo e-mail e ainda sem acesso: qualquer pessoa que soubesse o e-mail de um irmão podia criar a
-- conta com ele e entrar como esse irmão, com o cargo dele.
-- Agora só liga quando o Supabase MANDOU a confirmação e a pessoa clicou depois (confirmation_sent_at preenchido e
-- email_confirmed_at depois dele). Com a confirmação desligada ninguém entra por esse caminho: o acesso é pelo
-- convite (link único pelo WhatsApp da Loja, `aceitar_convite`). Quando o domínio próprio e o envio de e-mail
-- estiverem ligados e a confirmação voltar, este caminho volta a funcionar sozinho, sem mudar nada aqui.

create or replace function public.vincular_por_email() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_email text;
  n int;
begin
  select lower(email) into v_email
  from auth.users
  where id = auth.uid()
    and email_confirmed_at is not null
    and confirmation_sent_at is not null
    and email_confirmed_at >= confirmation_sent_at;

  if v_email is null then
    return 0;
  end if;

  perform set_config('malhete.sistema', 'on', true);
  update public.irmaos i
  set user_id = auth.uid()
  where i.user_id is null
    and lower(i.email) = v_email
    and i.situacao in ('ativo', 'licenciado', 'irregular')
    and not exists (select 1 from public.irmaos o where o.loja_id = i.loja_id and o.user_id = auth.uid());

  get diagnostics n = row_count;
  perform set_config('malhete.sistema', 'off', true);
  return n;
end $$;
