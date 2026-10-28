// Sistema Malhete: avisos do Asaas DA PLATAFORMA sobre as cobranças das assinaturas das Lojas.
// Autenticação: cabeçalho asaas-access-token = webhook_token da plataforma. Pagou: a Loja destrava na hora.
import { admin, iguais, resposta } from "../_shared/asaas.ts";
import { espelharFatura } from "../_shared/plataforma.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta({ erro: "Método não permitido" }, 405);
  const { data: p } = await admin.from("plataforma_asaas").select("webhook_token").eq("id", 1).maybeSingle();
  if (!p || !iguais(req.headers.get("asaas-access-token") ?? "", p.webhook_token)) return resposta({ erro: "Não autorizado" }, 401);
  let corpo: { event?: string; payment?: Record<string, unknown> };
  try { corpo = await req.json(); } catch { return resposta({ erro: "JSON inválido" }, 400); }
  const evento = String(corpo.event ?? "");
  if (!evento.startsWith("PAYMENT_") || !corpo.payment?.subscription) return resposta({ ok: true, ignorado: true });
  try {
    const r = await espelharFatura(corpo.payment, evento);
    return resposta({ ok: true, resultado: r });
  } catch (e) {
    // responde 200 para o Asaas não pausar a fila; a tela "Minha assinatura" relê as cobranças
    console.error("plataforma-webhook", evento, e);
    return resposta({ ok: false });
  }
});
