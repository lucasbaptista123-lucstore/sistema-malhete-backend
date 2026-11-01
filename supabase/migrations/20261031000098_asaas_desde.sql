-- Ao conectar o Asaas, a Loja escolhe: trazer o histórico (últimos 90 dias) ou começar a partir de hoje (31/10).
-- "A partir de hoje": a sincronização nunca lê nada antes desta data; o saldo inicial vira o saldo atual do Asaas.
alter table public.integracoes_asaas add column sincronizar_desde date;
