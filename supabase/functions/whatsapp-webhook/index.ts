// Sistema Malhete — recebe os eventos do WhatsApp (UazAPI) de cada loja.
// URL configurada ao conectar: …/functions/v1/whatsapp-webhook?loja=<id>&t=<token da loja>
// Responde 200 na hora (recomendação da UazAPI) e processa em seguida: botões e textos dos irmãos
// viram confirmação de presença, motivo ou justificativa, e o irmão recebe a resposta.
import { admin, iguais, resposta } from "../_shared/asaas.ts";
import { credencialWhats, responder } from "../_shared/uazapi.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };

type Mensagem = {
  messageid?: string; id?: string; chatid?: string; sender?: string; sender_pn?: string; fromMe?: boolean; isGroup?: boolean;
  text?: string; buttonOrListid?: string; wasSentByApi?: boolean;
};

async function processar(loja: string, corpo: Record<string, unknown>) {
  const c = await credencialWhats(loja);
  if (!c) return;
  // o payload traz o token da instância: tem que ser o desta loja
  if (typeof corpo.token === "string" && corpo.token && !iguais(corpo.token, c.token)) return;

  if (corpo.EventType === "connection") {
    const inst = (corpo.instance ?? {}) as { status?: string };
    const st = inst.status === "connected" ? "conectado" : inst.status === "connecting" ? "conectando" : inst.status ? "desconectado" : null;
    if (st) await admin.rpc("whatsapp_atualizar", { p_loja: loja, p_status: st, p_numero: null, p_perfil: null, p_erro: null });
    return;
  }
  if (corpo.EventType !== "messages") return;

  const m = (corpo.message ?? {}) as Mensagem;
  if (m.fromMe || m.isGroup || m.wasSentByApi) return;
  const id = m.messageid ?? m.id;
  if (id) {
    const { data: nova } = await admin.rpc("whatsapp_nova_mensagem", { p_loja: loja, p_id: id });
    if (nova === false) return;
  }
  const telefone = m.sender_pn || m.chatid || m.sender || "";
  if (!telefone) return;

  const { data: texto } = m.buttonOrListid
    ? await admin.rpc("whatsapp_botao", { p_loja: loja, p_telefone: telefone, p_botao: m.buttonOrListid })
    : await admin.rpc("whatsapp_texto", { p_loja: loja, p_telefone: telefone, p_texto: m.text ?? "" });
  if (typeof texto === "string" && texto) await responder(c, m.chatid || telefone, texto);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta({ ok: true });
  const url = new URL(req.url);
  const loja = url.searchParams.get("loja") ?? "";
  const t = url.searchParams.get("t") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(loja)) return resposta({ erro: "Loja inválida" }, 400);
  const { data: integ } = await admin.from("integracoes_whatsapp").select("webhook_token").eq("loja_id", loja).maybeSingle();
  if (!integ || !iguais(t, integ.webhook_token)) return resposta({ erro: "Não autorizado" }, 401);

  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return resposta({ ok: true }); }
  EdgeRuntime.waitUntil(processar(loja, corpo).catch((e) => console.error("whatsapp-webhook", loja, e)));
  return resposta({ ok: true });
});
