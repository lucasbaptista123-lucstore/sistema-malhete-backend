-- Sistema Malhete — respostas da convocação em tempo real na tela da sessão (Supabase Realtime respeita o RLS).
alter publication supabase_realtime add table public.confirmacoes, public.envio_destinatarios;
