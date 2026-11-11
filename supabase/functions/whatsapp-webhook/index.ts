// Sistema Malhete — recebe os eventos do WhatsApp (UazAPI) de cada loja.
// URL configurada ao conectar: …/functions/v1/whatsapp-webhook?loja=<id>&t=<token da loja>
// Responde 200 na hora (recomendação da UazAPI) e processa em seguida: botões e textos dos irmãos
// viram confirmação de presença, motivo ou justificativa, e o irmão recebe a resposta.
import { admin, asaas, credencial, iguais, resposta } from "../_shared/asaas.ts";
import { credencialWhats, responder } from "../_shared/uazapi.ts";
import { pixCopiaECola } from "../_shared/pix.ts";

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

  // botões da cobrança: "Pagar com PIX" responde só com o código copia e cola; "Pagar pelo Malhete", com o link
  if (m.buttonOrListid?.startsWith("pag:")) {
    const [, opcao, tok] = m.buttonOrListid.split(":");
    const { data: p } = await admin.rpc("whatsapp_pagamento", { p_loja: loja, p_telefone: telefone, p_token: tok ?? "" });
    if (!p) return;
    const destino = m.chatid || telefone;
    const titulos = (p.titulos ?? []) as {
      id: string; asaas_id: string | null; pix: string | null; descricao: string; valor: number; atualizado: number;
    }[];
    if (!titulos.length) return await responder(c, destino, "Esta cobrança já está paga. Obrigado, irmão!");
    // irmão que ainda não acessa o sistema (sem login): em vez do link, já manda o PIX
    if (opcao === "app" && p.tem_acesso !== false) {
      return await responder(c, destino, `Pague pelo Malhete, em Minhas mensalidades (QR Code e PIX copia e cola):\n${p.link}`);
    }
    const codigos: string[] = [];
    // sem cobrança no Asaas (irmão sem CPF): um copia e cola só, na chave da Loja, com o total atualizado;
    // a baixa vem quando o PIX cai e o sistema reconhece quem pagou
    const semAsaas = titulos.filter((t) => !t.asaas_id && !t.pix);
    const totalSemAsaas = Math.round(semAsaas.reduce((s, t) => s + Number(t.atualizado ?? t.valor), 0) * 100) / 100;
    for (const t of titulos.filter((x) => x.asaas_id || x.pix).slice(0, 3)) {
      let pix = t.pix;
      if (!pix && t.asaas_id) {
        try {
          const qr = await asaas(await credencial(loja), `/payments/${t.asaas_id}/pixQrCode`);
          pix = qr?.payload ?? null;
          if (pix) await admin.from("titulos").update({ pix_copia_cola: pix }).eq("id", t.id);
        } catch (e) {
          console.error("pix copia e cola", t.id, e);
        }
      }
      if (pix) codigos.push(pix);
    }
    if (semAsaas.length && p.chave && totalSemAsaas > 0) {
      codigos.push(pixCopiaECola({
        chave: p.chave, nome: p.titular ?? "", cidade: p.cidade ?? "", valor: totalSemAsaas, txid: "***",
      }));
    }
    if (!codigos.length) return await responder(c, destino, `Não consegui gerar o PIX agora. Pague pelo Malhete:\n${p.link}`);
    await responder(c, destino, codigos.length === 1
      ? "Segue o PIX copia e cola na próxima mensagem. Toque e segure, copie e cole no app do banco. A baixa é automática."
      : `São ${codigos.length} cobranças: cada PIX copia e cola vem numa mensagem. Toque e segure para copiar. A baixa é automática.`);
    for (const cod of codigos) await responder(c, destino, cod);
    return;
  }

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
