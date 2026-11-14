// Sistema Malhete — PIX do Tronco pedido ao Asaas (QR estático) para a tela do irmão e para a página do convite.
//   POST { contrib_id, token? }  -> { copia_cola }   (copia_cola nulo = a Loja não usa o Asaas no Tronco)
// Sem verificação de JWT no gateway: a página do convite não tem login. Quem pede é conferido no banco:
// o irmão dono da contribuição (JWT) ou quem tem o token do convite.
import { admin, CORS, Falha, resposta, usuarioDe } from "../_shared/asaas.ts";
import { qrTronco } from "../_shared/tronco.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return resposta({ erro: "Método não permitido" }, 405);
  try {
    const corpo = await req.json();
    const contrib = String(corpo.contrib_id ?? "");
    if (!/^[0-9a-f-]{36}$/.test(contrib)) throw new Falha("Contribuição inválida.");
    const token = typeof corpo.token === "string" && corpo.token ? corpo.token : null;
    let loja: string | null = null;
    if (token) {
      const { data } = await admin.rpc("tronco_qr_permitido", { p_contrib: contrib, p_token: token });
      loja = (data as string | null) ?? null;
    } else {
      const auth = req.headers.get("Authorization");
      if (!auth) throw new Falha("Faça login.", 401);
      const { data } = await usuarioDe(auth).rpc("tronco_qr_permitido", { p_contrib: contrib });
      loja = (data as string | null) ?? null;
    }
    if (!loja) throw new Falha("Esta contribuição não é sua.", 403);
    return resposta({ ok: true, copia_cola: await qrTronco(contrib) });
  } catch (e) {
    console.error("tronco-qr", e);
    const f = e instanceof Falha ? e : new Falha("Não foi possível gerar o PIX agora. Tente de novo em alguns minutos.", 500);
    return resposta({ erro: f.message }, f.status);
  }
});
