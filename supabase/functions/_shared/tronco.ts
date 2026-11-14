// Tronco de Beneficência: o PIX é pedido ao próprio Asaas (QR Code estático, sem cobrança antes). O Asaas recusa código
// PIX montado fora dele ("O banco de destino não pode processar o Pix agora", sessão de 13/11). O pagamento volta com o
// pixQrCodeId e o banco (asaas_espelhar_pagamento) lança no Tronco sozinho, anônimo.
import { admin, asaas, credencial } from "./asaas.ts";

/** Copia e cola do PIX desta contribuição, feito pelo Asaas. Nulo quando a Loja não usa o Asaas no Tronco. */
export async function qrTronco(contribId: string): Promise<string | null> {
  const { data: d } = await admin.rpc("tronco_qr_dados", { p_contrib: contribId });
  if (!d || !d.automatico || !d.chave) return null;
  if (d.pix_copia_cola) return String(d.pix_copia_cola);
  const c = await credencial(String(d.loja_id));
  const qr = await asaas(c, "/pix/qrCodes/static", { method: "POST", body: {
    addressKey: d.chave, value: Number(d.valor), description: "Tronco de Beneficência", format: "PAYLOAD",
    expirationSeconds: 7 * 86400, allowsMultiplePayments: false, externalReference: `tronco:${contribId}`,
  } });
  if (!qr?.payload || !qr?.id) throw new Error("O Asaas não devolveu o QR Code do PIX.");
  await admin.rpc("tronco_qr_guardar", { p_contrib: contribId, p_qr_id: String(qr.id), p_payload: String(qr.payload) });
  return String(qr.payload);
}

/** Data e hora do fim do dia de hoje no horário de Brasília, no formato do Asaas ("AAAA-MM-DD 23:59:59"). */
function fimDoDia() {
  const brasilia = new Date(Date.now() - 3 * 3600_000);
  return { asaas: `${brasilia.toISOString().slice(0, 10)} 23:59:59`, iso: `${brasilia.toISOString().slice(0, 10)}T23:59:59-03:00` };
}

/**
 * PIX de contas a receber (mensalidade e outras) pedido ao Asaas: QR estático com o valor do dia (multa e juros
 * inclusos), válido até o fim do dia; o pagamento dá baixa nas contas pelo pixQrCodeId (pix_qr_baixar).
 * Nulo quando a Loja não usa o Asaas (o chamador monta o código na chave, como antes).
 */
export async function qrTitulos(loja: string, titulos: string[]): Promise<{ payload: string; valor: number } | null> {
  const { data: d } = await admin.rpc("pix_qr_titulos_dados", { p_loja: loja, p_titulos: titulos });
  if (!d || !d.automatico || !d.chave) return null;
  const valor = Number(d.total);
  if (!(valor > 0)) return null;
  if (d.reaproveitar) return { payload: String(d.reaproveitar), valor };
  const c = await credencial(loja);
  const fim = fimDoDia();
  const qr = await asaas(c, "/pix/qrCodes/static", { method: "POST", body: {
    addressKey: d.chave, value: valor, description: String(d.descricao ?? "Conta da Loja").slice(0, 100), format: "PAYLOAD",
    expirationDate: fim.asaas, allowsMultiplePayments: false,
  } });
  if (!qr?.payload || !qr?.id) throw new Error("O Asaas não devolveu o QR Code do PIX.");
  await admin.rpc("pix_qr_guardar", {
    p_id: String(qr.id), p_loja: loja, p_partes: d.partes, p_valor: valor, p_payload: String(qr.payload), p_expira: fim.iso,
  });
  return { payload: String(qr.payload), valor };
}
