-- Sistema Malhete — o tronco é recebido e movimentado pela Tesouraria e fica à disposição da
-- Hospitalaria: o Hospitaleiro acompanha (tronco.ler), quem lança é o Tesoureiro (tronco.editar).
update public.rito_cargos
set permissoes = array_replace(permissoes, 'tronco.editar', 'tronco.ler')
where codigo = 'hospitaleiro';

update public.loja_cargos
set permissoes = array_replace(permissoes, 'tronco.editar', 'tronco.ler')
where codigo = 'hospitaleiro';
