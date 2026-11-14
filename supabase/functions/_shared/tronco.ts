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
