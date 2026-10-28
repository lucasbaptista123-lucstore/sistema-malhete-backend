-- pg_net fora do schema public (advisor extension_in_public). As funções continuam em net.*,
-- então a rotina do pg_cron (net.http_post) não muda.
drop extension if exists pg_net;
create extension pg_net with schema extensions;
