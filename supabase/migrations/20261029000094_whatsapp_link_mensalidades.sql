-- Link do sistema para o envio de reserva (quando o servidor de WhatsApp recusa os botões da cobrança).
create function public.whatsapp_link_mensalidades() returns text
language sql stable security definer set search_path = '' as $$ select private.link_mensalidades() $$;
revoke execute on function public.whatsapp_link_mensalidades from public, anon, authenticated;
grant execute on function public.whatsapp_link_mensalidades to service_role;
