-- Sistema Malhete: conferência do Asaas a cada 10 minutos (era 30), pedido do Lucas em 04/11/2026.
-- O webhook continua dando a baixa na hora; a rotina pega o que escapar.
select cron.alter_job((select jobid from cron.job where jobname = 'malhete-asaas-sincronizar'), schedule := '*/10 * * * *');
