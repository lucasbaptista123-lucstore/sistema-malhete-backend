// Sistema Malhete — recebe os avisos (webhooks) do Asaas de cada loja.
// URL cadastrada automaticamente ao conectar: …/functions/v1/asaas-webhook?loja=<id>
// Autenticação: cabeçalho asaas-access-token = token gerado para a loja (comparado em tempo constante).
// Responde 200 mesmo quando o processamento falha (o erro fica em asaas_eventos e a varredura
// refaz o espelho) para o Asaas não pausar a fila de avisos da loja.
// Cobranças (PAYMENT_*): espelha na hora. Saídas (TRANSFER_*, BILL_*: PIX/TED enviado, conta paga pelo
// Tesoureiro no Asaas): lê o extrato da loja na hora (em segundo plano, para responder rápido ao Asaas).
import { admin, credencial, espelhar, EVENTOS_SAIDA, iguais, registrarErro, resposta, sincronizarLoja } from "../_shared/asaas.ts";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };

Deno.serve(async (req) => {
  if (req.method !== "POST") return resposta({ erro: "Método não permitido" }, 405);
  const loja = new URL(req.url).searchParams.get("loja") ?? "";
  if (!/^[0-9a-f-]{36}$/.test(loja)) return resposta({ erro: "Loja inválida" }, 400);

  const { data: integ } = await admin.from("integracoes_asaas").select("webhook_token").eq("loja_id", loja).eq("ativo", true).maybeSingle();
  if (!integ || !iguais(req.headers.get("asaas-access-token") ?? "", integ.webhook_token)) {
    return resposta({ erro: "Não autorizado" }, 401);
  }

  let corpo: { id?: string; event?: string; payment?: Record<string, unknown> };
  try { corpo = await req.json(); } catch { return resposta({ erro: "JSON inválido" }, 400); }
  const evento = String(corpo.event ?? "");
  const idEvento = String(corpo.id ?? `${evento}:${corpo.payment?.id ?? crypto.randomUUID()}`);

  // idempotência: o mesmo aviso pode chegar mais de uma vez
  const { error: dup } = await admin.from("asaas_eventos").insert({ id: idEvento, loja_id: loja, evento, payment_id: corpo.payment?.id ?? null });
  if (dup) {
    const { data: ant } = await admin.from("asaas_eventos").select("resultado").eq("id", idEvento).maybeSingle();
    if (ant?.resultado) return resposta({ ok: true, duplicado: true });
  }

  if (EVENTOS_SAIDA.includes(evento)) {
    // espera uns segundos: a movimentação precisa aparecer no extrato do Asaas
    const tarefa = new Promise((r) => setTimeout(r, 8000))
      .then(() => sincronizarLoja(loja, undefined, undefined, true))
      .then(() => admin.from("asaas_eventos").update({ resultado: "extrato lido", erro: null }).eq("id", idEvento))
      .catch(async (e) => {
        const msg = e instanceof Error ? e.message : "erro";
        await admin.from("asaas_eventos").update({ erro: msg }).eq("id", idEvento);
        await registrarErro(loja, msg);
      });
    EdgeRuntime.waitUntil(tarefa);
    return resposta({ ok: true });
  }

  if (!evento.startsWith("PAYMENT_") || !corpo.payment?.id) {
    await admin.from("asaas_eventos").update({ resultado: "ignorado" }).eq("id", idEvento);
    return resposta({ ok: true });
  }

  try {
    const c = await credencial(loja);
    const resultado = await espelhar(loja, c, evento, corpo.payment);
    await admin.from("asaas_eventos").update({ resultado, erro: null }).eq("id", idEvento);
  } catch (e) {
    console.error("webhook", loja, evento, e);
    await admin.from("asaas_eventos").update({ erro: e instanceof Error ? e.message : "erro" }).eq("id", idEvento);
  }
  return resposta({ ok: true });
});
