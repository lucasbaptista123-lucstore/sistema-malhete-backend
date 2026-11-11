#!/bin/bash
# 09/11: leva ao OFICIAL 0114 (acesso total por exceção), 0115 (PIX de irmão sem CPF + "É uma conta"
# para a conta automática do PIX) e 0116 (cobrança pela chave PIX para quem está sem CPF) e liga o acesso total SÓ para o Lucas, SÓ na Orvalho de Hermon (registrado no audit_log).
# Exceção da Orvalho: nunca usar em outra Loja. Para desligar: trocar true por false na linha do update e rodar de novo.
set -e
cd "$(dirname "$0")"
source .env.local
./oficial.sh   # banco (0114, 0115, 0116) e funções (whatsapp-webhook com o PIX da chave)
API="https://api.supabase.com/v1/projects/$MALHETE_OFICIAL_REF"
SQL="update public.irmaos set admin_total = true
 where id = '6d19a119-a953-4087-976e-e16ba834ca87' and loja_id = 'a5a5ba5c-85fa-449b-acf8-f405750e8fe8' and admin_loja;
insert into public.audit_log (loja_id, tabela, registro_id, acao, antes, depois)
values ('a5a5ba5c-85fa-449b-acf8-f405750e8fe8', 'irmaos', '6d19a119-a953-4087-976e-e16ba834ca87', 'administrador',
        null, jsonb_build_object('por', 'dono da plataforma', 'acesso_total', true,
        'motivo', 'Acesso total por exceção na implantação (Venerável e Secretário nomeados, ainda sem uso do sistema)'));
select admin_loja, admin_total from public.irmaos where id = '6d19a119-a953-4087-976e-e16ba834ca87';"
python3 -I -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "$SQL" > /tmp/acesso_total.json
curl -sS -X POST "$API/database/query" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' --data @/tmp/acesso_total.json -w '  (HTTP %{http_code})\n'
rm -f /tmp/acesso_total.json
echo "Pronto. Me avise no chat que eu confiro."
