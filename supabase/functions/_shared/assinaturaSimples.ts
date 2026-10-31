// Assinatura eletrônica SIMPLES no sistema (Lei 14.063/2020, art. 4º, I): código de 6 dígitos pelo WhatsApp da Loja
// (sem custo) ou a senha do sistema; ao final, o PDF ganha a página "Registro de assinaturas eletrônicas".
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";
import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import { admin, CHAVE_PUBLICA, Falha, SUPABASE_URL } from "./asaas.ts";
import { credencialWhats, numeroWhats, uazapi } from "./uazapi.ts";

const BUCKET = "secretaria";
const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, "0")).join("");
const sha256 = async (dados: Uint8Array | string) =>
  hex(await crypto.subtle.digest("SHA-256", typeof dados === "string" ? new TextEncoder().encode(dados) : dados.slice().buffer));
const mascaraTel = (t: string) => t.replace(/\D/g, "").replace(/^(\d+)(\d{4})$/, (_, a, b) => "*".repeat(Math.max(0, a.length - 2)) + a.slice(-2) + b);

type Ctx = { usuario: SupabaseClient; ip: string | null; dispositivo: string | null };

async function minhaVez(usuario: SupabaseClient, idAss: string) {
  if (!/^[0-9a-f-]{36}$/.test(idAss)) throw new Falha("Assinatura inválida.");
  const { data: a } = await admin.from("documento_assinaturas")
    .select("id, loja_id, documento_id, irmao_id, status, cargo_nome, codigo_hash, codigo_expira, codigo_tentativas").eq("id", idAss).maybeSingle();
  if (!a) throw new Falha("Assinatura não encontrada.", 404);
  const { data: eu } = await usuario.rpc("meu_irmao_id", { p_loja: a.loja_id });
  if (!eu || eu !== a.irmao_id) throw new Falha("Esta assinatura não é sua.", 403);
  if (a.status !== "vez") throw new Falha("Não é a sua vez de assinar este documento.");
  const { data: d } = await admin.from("documentos_emitidos").select("id, tipo, numero, modo_assinatura, arquivo_atual, codigo_verificacao, loja_id").eq("id", a.documento_id).single();
  if (d?.modo_assinatura !== "simples") throw new Falha("Este documento é assinado pelo gov.br.");
  if (!d.arquivo_atual) throw new Falha("O PDF do documento ainda está sendo preparado.");
  return { a, d };
}

/** Gera e manda o código pelo WhatsApp da Loja. Sem WhatsApp conectado ou sem celular: a confirmação é pela senha. */
export async function enviarCodigo(ctx: Ctx, idAss: string) {
  const { a, d } = await minhaVez(ctx.usuario, idAss);
  const { data: ir } = await admin.from("irmaos").select("telefone, nome").eq("id", a.irmao_id).single();
  const c = await credencialWhats(a.loja_id);
  const tel = String(ir?.telefone ?? "").replace(/\D/g, "");
  if (!c || c.status !== "conectado" || tel.length < 10) return { canal: "senha" as const };
  const codigo = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, "0");
  await admin.from("documento_assinaturas").update({
    codigo_hash: await sha256(`${a.id}:${codigo}`), codigo_expira: new Date(Date.now() + 10 * 60_000).toISOString(), codigo_tentativas: 0,
  }).eq("id", a.id);
  await uazapi("/send/text", { method: "POST", token: c.token, body: {
    number: numeroWhats(tel),
    text: `Sistema Malhete: seu código para assinar ${d.tipo} nº ${d.numero} como ${a.cargo_nome} é *${codigo}*. Vale por 10 minutos. Não compartilhe.`,
  } });
  return { canal: "whatsapp" as const, telefone: mascaraTel(tel) };
}

/** Confere o código (ou a senha), registra a assinatura e, se for a última, fecha o PDF com o registro. */
export async function assinarSimples(ctx: Ctx, idAss: string, codigo: string | null, senha: string | null, aceite: boolean) {
  if (!aceite) throw new Falha("Marque que leu e concorda com o documento.");
  const { a, d } = await minhaVez(ctx.usuario, idAss);
  let via: "whatsapp" | "senha";
  if (codigo) {
    if (!a.codigo_hash || !a.codigo_expira) throw new Falha("Peça um código novo.");
    if (new Date(a.codigo_expira) < new Date()) throw new Falha("O código venceu. Peça um novo.");
    if (a.codigo_tentativas >= 5) throw new Falha("Muitas tentativas. Peça um código novo.");
    if ((await sha256(`${a.id}:${codigo.replace(/\D/g, "")}`)) !== a.codigo_hash) {
      await admin.from("documento_assinaturas").update({ codigo_tentativas: a.codigo_tentativas + 1 }).eq("id", a.id);
      throw new Falha("Código incorreto.");
    }
    via = "whatsapp";
  } else if (senha) {
    const { data: u } = await ctx.usuario.auth.getUser();
    const email = u.user?.email;
    if (!email) throw new Falha("Faça login de novo.", 401);
    const conf = createClient(SUPABASE_URL, CHAVE_PUBLICA, { auth: { persistSession: false } });
    const { error } = await conf.auth.signInWithPassword({ email, password: senha });
    if (error) throw new Falha("Senha incorreta.");
    via = "senha";
  } else throw new Falha("Informe o código ou a senha.");

  const pdf = await admin.storage.from(BUCKET).download(d.arquivo_atual!);
  if (pdf.error || !pdf.data) throw new Falha("Arquivo do documento não encontrado.");
  const bytes = new Uint8Array(await pdf.data.arrayBuffer());
  const hash = await sha256(bytes);
  const { data: res, error } = await admin.rpc("registrar_assinatura_simples", {
    p_assinatura: a.id, p_via: via, p_ip: ctx.ip, p_dispositivo: ctx.dispositivo, p_hash: hash,
  });
  if (error) throw new Falha(error.message);
  if (res === "último") await fecharDocumento(d, bytes, hash);
  return { resultado: res === "último" ? "concluído" : "próximo avisado" };
}

const latin = (s: string) => s.replace(/[“”]/g, '"').replace(/[‘’]/g, "'").replace(/[–—]/g, "-").replace(/…/g, "...")
  .replace(/[^\x20-\xFF]/g, "");

/** Acrescenta ao PDF a página de registro (quem, quando, como, hash, código de verificação) e conclui o documento. */
async function fecharDocumento(d: { id: string; tipo: string; numero: string; loja_id: string; codigo_verificacao: string }, base: Uint8Array, hashBase: string) {
  const [{ data: ass }, { data: loja }, { data: cfg }] = await Promise.all([
    admin.from("documento_assinaturas").select("ordem, cargo_nome, nome_assinatura, cpf_assinatura, assinado_em, confirmado_via, ip, dispositivo").eq("documento_id", d.id).order("ordem"),
    admin.from("lojas").select("nome, numero").eq("id", d.loja_id).single(),
    admin.from("config_plataforma").select("valor").eq("chave", "app_url").maybeSingle(),
  ]);
  const doc = await PDFDocument.load(base);
  const f = await doc.embedFont(StandardFonts.Helvetica);
  const fb = await doc.embedFont(StandardFonts.HelveticaBold);
  const pag = doc.addPage([595.28, 841.89]);
  const tinta = rgb(0.08, 0.1, 0.2), cinza = rgb(0.4, 0.4, 0.45);
  let y = 790;
  const linha = (t: string, tam = 10, fonte = f, cor = tinta) => { pag.drawText(latin(t), { x: 56, y, size: tam, font: fonte, color: cor }); y -= tam + 5; };
  linha("REGISTRO DE ASSINATURAS ELETRÔNICAS", 14, fb);
  y -= 4;
  linha(`${d.tipo} nº ${d.numero} · ${String(loja?.nome ?? "").trim()}${loja?.numero ? ` nº ${loja.numero}` : ""}`, 10, f, cinza);
  linha("Assinatura eletrônica simples (Lei 14.063/2020, art. 4º, I), feita no Sistema Malhete.", 9, f, cinza);
  y -= 10;
  const fmt = (iso: string) => new Date(iso).toLocaleString("pt-BR", { timeZone: "America/Sao_Paulo", dateStyle: "short", timeStyle: "medium" });
  for (const a of (ass ?? []) as Record<string, string | number | null>[]) {
    const cpf = a.cpf_assinatura ? `***.${String(a.cpf_assinatura).slice(3, 6)}.${String(a.cpf_assinatura).slice(6, 9)}-**` : "não informado";
    linha(`${a.ordem}. ${a.cargo_nome}: ${a.nome_assinatura}`, 11, fb);
    linha(`CPF ${cpf} · assinou em ${fmt(String(a.assinado_em))} (horário de Brasília)`);
    linha(`Confirmado por ${a.confirmado_via === "whatsapp" ? "código enviado ao WhatsApp do assinante" : "senha pessoal do sistema"} · IP ${a.ip ?? "não informado"}`);
    linha(`Aparelho: ${String(a.dispositivo ?? "não informado").slice(0, 95)}`, 8, f, cinza);
    y -= 8;
  }
  y -= 6;
  linha("Impressão digital (SHA-256) do documento assinado (páginas anteriores):", 9, fb);
  linha(hashBase, 8, f, cinza);
  y -= 6;
  linha(`Código de verificação: ${d.codigo_verificacao}`, 12, fb);
  linha(`Confira em ${String(cfg?.valor ?? "")}/verificar/${d.codigo_verificacao}`, 10);
  const final = await doc.save();
  const caminho = `${d.loja_id}/documentos/${d.id}/final-${Date.now()}.pdf`;
  const up = await admin.storage.from(BUCKET).upload(caminho, new Blob([final.slice().buffer], { type: "application/pdf" }), { contentType: "application/pdf" });
  if (up.error) throw new Falha("Não foi possível salvar o PDF final.", 500);
  const { error } = await admin.rpc("concluir_documento_simples", { p_doc: d.id, p_caminho: caminho, p_hash: await sha256(final) });
  if (error) throw new Falha(error.message, 500);
}
