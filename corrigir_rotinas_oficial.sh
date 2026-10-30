#!/bin/bash
# Troca, nas rotinas do projeto OFICIAL, a chave herdada do projeto de teste pela chave publishable do oficial.
# Acerta também o site_url do login. As rotinas continuam DESLIGADAS.
# Uso: bash ~/sistema-malhete/corrigir_rotinas_oficial.sh
set -e
cd "$(dirname "$0")"
set -a; . ./.env.local; set +a
API="https://api.supabase.com/v1/projects/$MALHETE_OFICIAL_REF"
H=(-H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json")
NOVA=$(curl -s "$API/api-keys" "${H[@]}" | python3 -I -c 'import json,sys;print([k["api_key"] for k in json.load(sys.stdin) if k["name"]=="default"][0])')
NOVA="$NOVA" python3 -I -c 'import json,os
n=os.environ["NOVA"]
print(json.dumps({"query":"select cron.alter_job(jobid, command := regexp_replace(command, $r$Bearer [^ \x27]+$r$, $k$Bearer %s$k$)) from cron.job where command like $k$%%Bearer %%$k$; select jobname, active, command like $k$%%Bearer %s%%$k$ as chave_certa from cron.job where command like $k$%%Bearer %%$k$ order by 1"%(n,n)}))' \
 | curl -s -X POST "$API/database/query" "${H[@]}" -d @- -w "\nRotinas: HTTP %{http_code}\n"
curl -s -X PATCH "$API/config/auth" "${H[@]}" -d '{"site_url":"https://pixel-perfect-replay-6084.lovable.app"}' -o /dev/null -w "Endereço do login: HTTP %{http_code}\n"
echo "Pronto. Pode avisar o Claude."
