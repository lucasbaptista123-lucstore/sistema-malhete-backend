// Sistema Malhete: confere o PDF assinado no gov.br que o assinante devolveu e passa a vez ao próximo.
//   conferir { assinatura_id, caminho }  caminho = <loja>/documentos/<doc>/envio-<assinatura>-<ts>.pdf (já no bucket secretaria)
import { admin, CORS, Falha, resposta, usuarioDe } from "../_shared/asaas.ts";
import { conferirPdf, type Selo } from "../_shared/pdfassinatura.ts";

const BUCKET = "secretaria";
// distância do centro do selo até o bloco de um assinante (0 = dentro)
function distancia(s: Selo, a: Selo) {
  const cx = (s.x1 + s.x2) / 2, cy = (s.y1 + s.y2) / 2;
  const dx = Math.max(a.x1 - cx, 0, cx - a.x2), dy = Math.max(a.y1 - cy, 0, cy - a.y2);
  return Math.hypot(dx, dy);
}
const mascara = (c: string) => `***.${c.slice(3, 6)}.${c.slice(6, 9)}-**`;

async function baixar(caminho: string) {
  const { data, error } = await admin.storage.from(BUCKET).download(caminho);
  if (error || !data) throw new Falha("Arquivo não encontrado.");
  return new Uint8Array(await data.arrayBuffer());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const corpo = await req.json().catch(() => ({}));
    if (corpo.acao !== "conferir") throw new Falha("Ação desconhecida.");
    const usuario = usuarioDe(req.headers.get("Authorization") ?? "");
    const idAss = String(corpo.assinatura_id ?? "");
    const caminho = String(corpo.caminho ?? "");
    if (!/^[0-9a-f-]{36}$/.test(idAss)) throw new Falha("Assinatura inválida.");

    const { data: a } = await admin.from("documento_assinaturas")
      .select("id, loja_id, documento_id, irmao_id, status, cargo_nome").eq("id", idAss).maybeSingle();
    if (!a) throw new Falha("Assinatura não encontrada.", 404);
    const { data: eu } = await usuario.rpc("meu_irmao_id", { p_loja: a.loja_id });
    if (!eu || eu !== a.irmao_id) throw new Falha("Esta assinatura não é sua.", 403);
    if (a.status !== "vez") throw new Falha("Não é a sua vez de assinar este documento.");
    if (!caminho.startsWith(`${a.loja_id}/documentos/${a.documento_id}/envio-${a.id}-`) || !caminho.endsWith(".pdf")) {
      throw new Falha("Arquivo inválido.");
    }
    const { data: d } = await admin.from("documentos_emitidos").select("arquivo_atual").eq("id", a.documento_id).single();
    if (!d?.arquivo_atual) throw new Falha("O PDF do documento ainda não foi gerado.");

    const recusar = async (motivo: string, detalhe?: string) => {
      await admin.storage.from(BUCKET).remove([caminho]);
      console.log("assinatura recusada", a.id, motivo, detalhe ?? "");
      return resposta({ ok: false, motivo, detalhe });
    };
    const r = await conferirPdf(await baixar(d.arquivo_atual as string), await baixar(caminho));
    if (!r.ok) return await recusar(r.motivo, r.detalhe);
    if (!r.govbrOuIcp) return await recusar("A assinatura não é do gov.br nem de certificado ICP-Brasil. Assine pelo assinador do gov.br.", r.detalhe);
    // o selo tem de ficar no bloco deste assinante, não no de outro cargo
    if (r.selo) {
      const { data: fila } = await admin.from("documento_assinaturas")
        .select("id, cargo_nome, area").eq("documento_id", a.documento_id).not("area", "is", null);
      const blocos = (fila ?? []) as { id: string; cargo_nome: string; area: Selo }[];
      if (blocos.some((b) => b.id === a.id)) {
        const perto = blocos.reduce((m, b) => (distancia(r.selo!, b.area) < distancia(r.selo!, m.area) ? b : m));
        if (perto.id !== a.id) {
          return await recusar(
            `Você colocou o selo do gov.br no espaço do ${perto.cargo_nome}, mas esta assinatura é como ${a.cargo_nome}. Assine de novo o PDF baixado aqui, pondo o selo sobre a linha do ${a.cargo_nome}.`,
            `${r.detalhe}; selo em [${[r.selo.x1, r.selo.y1, r.selo.x2, r.selo.y2].map(Math.round).join(" ")}]`,
          );
        }
      }
    }
    const { data: ir } = await admin.from("irmaos").select("cpf, nome").eq("id", a.irmao_id).single();
    const esperado = String(ir?.cpf ?? "").replace(/\D/g, "");
    if (!r.cpf) return await recusar("Não foi possível ler o CPF na assinatura. Assine com a sua conta gov.br.", r.detalhe);
    if (r.cpf !== esperado) {
      return await recusar(`O documento foi assinado pelo CPF ${mascara(r.cpf)}, que não é de quem foi escolhido para assinar como ${a.cargo_nome}.`, r.detalhe);
    }
    const { data: res, error } = await admin.rpc("registrar_assinatura", {
      p_assinatura: a.id, p_caminho: caminho, p_cpf: r.cpf, p_nome: r.nome,
    });
    if (error) throw new Falha(error.message);
    return resposta({ ok: true, nome: r.nome, resultado: res });
  } catch (e) {
    const st = e instanceof Falha ? e.status : 500;
    if (!(e instanceof Falha)) console.error("assinaturas", e);
    return resposta({ erro: e instanceof Error ? e.message : "Erro" }, st);
  }
});
