// Sistema Malhete: confere a assinatura digital (PAdES) acrescentada a um PDF, sem depender de serviço externo.
//  1) o arquivo novo começa EXATAMENTE com o anterior (atualização incremental: nada antes foi alterado ou removido)
//  2) há uma assinatura nova (/ByteRange) e ela cobre o arquivo inteiro até o fim
//  3) a assinatura CMS confere com o conteúdo (hash + chave pública do certificado)
//  4) a cadeia do certificado chega a uma raiz OFICIAL do ITI (gov.br ou ICP-Brasil), certificado a certificado,
//     dentro da validade, e o certificado do assinante não está na lista de revogados (LCR)
//  5) lê nome e CPF do certificado
import * as asn1js from "npm:asn1js@3.0.5";
import * as pkijs from "npm:pkijs@3.2.4";
import { INTERMEDIARIAS, RAIZES } from "./raizes.ts";

// Verificação feita com o WebCrypto nativo (o "motor" do pkijs quebra no Edge Runtime do Supabase).
// O pkijs fica só para LER a estrutura CMS.
const HASH: Record<string, string> = {
  "1.3.14.3.2.26": "SHA-1",
  "2.16.840.1.101.3.4.2.1": "SHA-256",
  "2.16.840.1.101.3.4.2.2": "SHA-384",
  "2.16.840.1.101.3.4.2.3": "SHA-512",
};
const HASH_DA_ASSINATURA: Record<string, string> = {
  "1.2.840.113549.1.1.5": "SHA-1",
  "1.2.840.113549.1.1.11": "SHA-256",
  "1.2.840.113549.1.1.12": "SHA-384",
  "1.2.840.113549.1.1.13": "SHA-512",
  "1.2.840.10045.4.3.2": "SHA-256",
  "1.2.840.10045.4.3.3": "SHA-384",
  "1.2.840.10045.4.3.4": "SHA-512",
};
const ab = (u: Uint8Array) => u.slice().buffer as ArrayBuffer;
const igual = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((v, i) => v === b[i]);

/** ECDSA no CMS vem em DER (SEQUENCE r, s); o WebCrypto quer r||s de tamanho fixo. */
function ecdsaCru(der: Uint8Array, tam: number) {
  const seq = asn1js.fromBER(der.slice().buffer).result as asn1js.Sequence;
  const parte = (x: asn1js.Integer) => {
    let v = new Uint8Array(x.valueBlock.valueHexView);
    while (v.length > tam && v[0] === 0) v = v.slice(1);
    const out = new Uint8Array(tam);
    out.set(v, tam - v.length);
    return out;
  };
  const r = parte(seq.valueBlock.value[0] as asn1js.Integer);
  const s = parte(seq.valueBlock.value[1] as asn1js.Integer);
  const out = new Uint8Array(tam * 2);
  out.set(r, 0);
  out.set(s, tam);
  return out;
}

async function verificarCms(sd: pkijs.SignedData, cert: pkijs.Certificate, dados: Uint8Array): Promise<string | null> {
  const si = sd.signerInfos[0]!;
  const hash = HASH[si.digestAlgorithm.algorithmId];
  if (!hash) return `algoritmo de resumo desconhecido (${si.digestAlgorithm.algorithmId})`;
  let assinado: Uint8Array;
  if (si.signedAttrs) {
    const md = si.signedAttrs.attributes.find((x) => x.type === "1.2.840.113549.1.9.4");
    if (!md) return "assinatura sem resumo do documento";
    const esperado = new Uint8Array((md.values[0] as asn1js.OctetString).valueBlock.valueHexView);
    const calculado = new Uint8Array(await crypto.subtle.digest(hash, ab(dados)));
    if (!igual(esperado, calculado)) return "o resumo do documento não confere (arquivo alterado)";
    assinado = new Uint8Array(si.signedAttrs.encodedValue);
    assinado[0] = 0x31; // [0] IMPLICIT -> SET, como foi assinado
  } else {
    assinado = dados;
  }
  const valor = new Uint8Array(si.signature.valueBlock.valueHexView);
  return await verificarCom(cert, si.signatureAlgorithm.algorithmId, HASH_DA_ASSINATURA[si.signatureAlgorithm.algorithmId] ?? hash, valor, assinado);
}

/** Confere uma assinatura (valor) sobre "assinado" com a chave pública de "cert". null = confere. */
async function verificarCom(cert: pkijs.Certificate, algId: string, hashAss: string, valor: Uint8Array, assinado: Uint8Array): Promise<string | null> {
  const spki = new Uint8Array(cert.subjectPublicKeyInfo.toSchema().toBER(false));
  const algChave = cert.subjectPublicKeyInfo.algorithm.algorithmId;
  const si = { signatureAlgorithm: { algorithmId: algId } };
  try {
    if (algChave === "1.2.840.113549.1.1.1") {
      if (si.signatureAlgorithm.algorithmId === "1.2.840.113549.1.1.10") return "assinatura RSA-PSS ainda não suportada";
      const k = await crypto.subtle.importKey("spki", ab(spki), { name: "RSASSA-PKCS1-v1_5", hash: hashAss }, false, ["verify"]);
      return (await crypto.subtle.verify("RSASSA-PKCS1-v1_5", k, ab(valor), ab(assinado))) ? null : "assinatura RSA inválida";
    }
    if (algChave === "1.2.840.10045.2.1") {
      const curvaOid = (cert.subjectPublicKeyInfo.algorithm.algorithmParams as asn1js.ObjectIdentifier).valueBlock.toString();
      const curva = { "1.2.840.10045.3.1.7": "P-256", "1.3.132.0.34": "P-384", "1.3.132.0.35": "P-521" }[curvaOid];
      if (!curva) return `curva desconhecida (${curvaOid})`;
      const tam = curva === "P-256" ? 32 : curva === "P-384" ? 48 : 66;
      const k = await crypto.subtle.importKey("spki", ab(spki), { name: "ECDSA", namedCurve: curva }, false, ["verify"]);
      return (await crypto.subtle.verify({ name: "ECDSA", hash: hashAss }, k, ab(ecdsaCru(valor, tam)), ab(assinado))) ? null : "assinatura ECDSA inválida";
    }
    return `tipo de chave desconhecido (${algChave})`;
  } catch (e) {
    return `erro ao verificar: ${e instanceof Error ? e.message : e}`;
  }
}

// ---------- cadeia até a raiz oficial ----------
function certDeBase64(b64: string) {
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return new pkijs.Certificate({ schema: asn1js.fromBER(der.buffer).result });
}
const ANCORAS = Object.values(RAIZES).map(certDeBase64);
const EXTRAS = Object.values(INTERMEDIARIAS).map(certDeBase64);
const chaveDe = (c: pkijs.Certificate) => new Uint8Array(c.subjectPublicKeyInfo.toSchema().toBER(false));
const mesmoCert = (a: pkijs.Certificate, b: pkijs.Certificate) =>
  nomeDe(a.subject) === nomeDe(b.subject) && igual(chaveDe(a), chaveDe(b));

/** O certificado "filho" foi assinado pela chave do "pai"? */
async function assinadoPor(filho: pkijs.Certificate, pai: pkijs.Certificate) {
  const alg = filho.signatureAlgorithm.algorithmId;
  const hash = HASH_DA_ASSINATURA[alg];
  if (!hash) return false;
  const tbs = new Uint8Array(filho.tbsView);
  const valor = new Uint8Array(filho.signatureValue.valueBlock.valueHexView);
  return (await verificarCom(pai, alg, hash, valor, tbs)) === null;
}

function dentroDaValidade(c: pkijs.Certificate, quando = new Date()) {
  return c.notBefore.value <= quando && quando <= c.notAfter.value;
}

/** URLs (http) de uma extensão do certificado: AIA (caIssuers) ou pontos de distribuição da LCR. */
function urlsDe(c: pkijs.Certificate, extId: string) {
  const ext = c.extensions?.find((e) => e.extnID === extId);
  if (!ext) return [];
  const txt = new TextDecoder("latin1").decode(new Uint8Array(ext.extnValue.valueBlock.valueHexView));
  return [...txt.matchAll(/https?:\/\/[\x21-\x7e]+?(?=[\x00-\x20\x7f-\xff]|$)/g)].map((m) => m[0]);
}

async function baixar(url: string, limite = 8000) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), limite);
  try {
    const r = await fetch(url, { signal: ctl.signal });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return new Uint8Array(await r.arrayBuffer());
  } finally {
    clearTimeout(t);
  }
}

/** Certificados de um .crt/.cer/.p7b (DER) baixado pelo endereço do emissor (AIA). */
function certsDeArquivo(der: Uint8Array): pkijs.Certificate[] {
  try {
    const r = asn1js.fromBER(der.slice().buffer).result;
    try {
      return [new pkijs.Certificate({ schema: r })];
    } catch {
      const sd = new pkijs.SignedData({ schema: new pkijs.ContentInfo({ schema: r }).content });
      return (sd.certificates ?? []).filter((x): x is pkijs.Certificate => x instanceof pkijs.Certificate);
    }
  } catch {
    return [];
  }
}

/**
 * Sobe do certificado do assinante até uma raiz oficial, conferindo a assinatura de cada elo e a validade.
 * Usa os certificados que vieram na assinatura, a cadeia do gov.br embutida e, se faltar um elo, o endereço do emissor (AIA).
 */
async function validarCadeia(folha: pkijs.Certificate, daAssinatura: pkijs.Certificate[]): Promise<{ erro: string | null; raiz?: string; emissor?: pkijs.Certificate }> {
  const pool = [...daAssinatura, ...EXTRAS, ...ANCORAS];
  if (!dentroDaValidade(folha)) return { erro: "certificado do assinante fora da validade" };
  let atual = folha;
  let emissorDaFolha: pkijs.Certificate | undefined;
  for (let passo = 0; passo < 8; passo++) {
    const ancora = ANCORAS.find((a) => mesmoCert(a, atual));
    if (ancora) {
      if (!(await assinadoPor(atual, ancora))) return { erro: "raiz com assinatura inválida" };
      return { erro: null, raiz: (campo(ancora.subject, "2.5.4.3")[0] ?? ""), emissor: emissorDaFolha };
    }
    let candidatos = pool.filter((c) => nomeDe(c.subject) === nomeDe(atual.issuer) && !mesmoCert(c, atual));
    if (!candidatos.length) {
      for (const url of urlsDe(atual, "1.3.6.1.5.5.7.1.1")) {
        try {
          const novos = certsDeArquivo(await baixar(url));
          pool.push(...novos);
        } catch { /* tenta o próximo */ }
      }
      candidatos = pool.filter((c) => nomeDe(c.subject) === nomeDe(atual.issuer) && !mesmoCert(c, atual));
    }
    let pai: pkijs.Certificate | undefined;
    for (const c of candidatos) if (await assinadoPor(atual, c)) { pai = c; break; }
    if (!pai) return { erro: `cadeia não chega a uma raiz oficial do ITI (emissor não reconhecido: ${campo(atual.issuer, "2.5.4.3")[0] ?? "?"})` };
    if (!dentroDaValidade(pai)) return { erro: `certificado da autoridade ${campo(pai.subject, "2.5.4.3")[0] ?? ""} fora da validade` };
    if (passo === 0) emissorDaFolha = pai;
    atual = pai;
  }
  return { erro: "cadeia longa demais" };
}

// ---------- lista de certificados revogados (LCR) ----------
function tl(b: Uint8Array, p: number) {
  const tag = b[p]!;
  let len = b[p + 1]!;
  let hdr = 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[p + 2 + i]!;
    hdr = 2 + n;
  }
  return { tag, len, hdr };
}
const LCR_CACHE = new Map<string, { em: number; tbs: Uint8Array }>();

/**
 * O certificado está revogado? Baixa a LCR do endereço do próprio certificado (guardada por 6h),
 * confere que ela foi assinada pela autoridade emissora e procura o número de série.
 * Devolve "revogado", "ok" ou o motivo de não ter conseguido conferir.
 */
async function situacaoNaLcr(cert: pkijs.Certificate, emissor: pkijs.Certificate): Promise<string> {
  const urls = urlsDe(cert, "2.5.29.31");
  if (!urls.length) return "sem endereço de LCR";
  let tbs: Uint8Array | null = null;
  for (const url of urls) {
    const c = LCR_CACHE.get(url);
    if (c && Date.now() - c.em < 6 * 3600_000) { tbs = c.tbs; break; }
    try {
      const der = await baixar(url, 12000);
      const ext = tl(der, 0);
      const pT = ext.hdr;
      const t = tl(der, pT);
      const corpo = der.subarray(pT, pT + t.hdr + t.len);
      const pA = pT + t.hdr + t.len;
      const a = tl(der, pA);
      const alg = asn1js.fromBER(der.slice(pA, pA + a.hdr + a.len).buffer).result as asn1js.Sequence;
      const algId = (alg.valueBlock.value[0] as asn1js.ObjectIdentifier).valueBlock.toString();
      const pS = pA + a.hdr + a.len;
      const sg = tl(der, pS);
      const valor = der.subarray(pS + sg.hdr + 1, pS + sg.hdr + sg.len);
      const hash = HASH_DA_ASSINATURA[algId];
      if (!hash || (await verificarCom(emissor, algId, hash, valor, corpo)) !== null) continue;
      tbs = corpo.slice();
      LCR_CACHE.set(url, { em: Date.now(), tbs });
      break;
    } catch { /* tenta a próxima */ }
  }
  if (!tbs) return "LCR indisponível";
  const serie = new Uint8Array(cert.serialNumber.valueBlock.valueHexView);
  const padrao = new Uint8Array([0x02, serie.length, ...serie]);
  outer: for (let i = 0; i + padrao.length <= tbs.length; i++) {
    for (let j = 0; j < padrao.length; j++) if (tbs[i + j] !== padrao[j]) continue outer;
    // entrada de revogado: SEQUENCE { INTEGER série, data, ... }
    if (tbs[i - 2] === 0x30 || tbs[i - 3] === 0x30) return "revogado";
  }
  return "ok";
}

function certDoAssinante(sd: pkijs.SignedData) {
  const certs = (sd.certificates ?? []).filter((x): x is pkijs.Certificate => x instanceof pkijs.Certificate);
  const sid = sd.signerInfos[0]?.sid as pkijs.IssuerAndSerialNumber | undefined;
  return { certs, cert: certs.find((x) => sid?.serialNumber && x.serialNumber?.isEqual?.(sid.serialNumber)) ?? certs[0] };
}

export type Conferencia =
  | { ok: true; cpf: string | null; nome: string; emissor: string; govbrOuIcp: boolean; selo: Selo | null; detalhe?: string }
  | { ok: false; motivo: string; detalhe?: string };

const enc = new TextDecoder("latin1");

export type Selo = { x1: number; y1: number; x2: number; y2: number };

/** Retângulo do selo visível da assinatura nova (widget /FT /Sig acrescentado depois do arquivo anterior). */
function seloNovo(parteNova: string): Selo | null {
  const re = /\d+\s+\d+\s+obj\b([\s\S]*?)endobj/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(parteNova))) {
    const o = m[1]!;
    if (!/\/FT\s*\/Sig\b/.test(o)) continue;
    const r = o.match(/\/Rect\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]/);
    if (!r) continue;
    const [a, b, c, d] = r.slice(1, 5).map(Number) as [number, number, number, number];
    const selo = { x1: Math.min(a, c), y1: Math.min(b, d), x2: Math.max(a, c), y2: Math.max(b, d) };
    if (selo.x2 - selo.x1 > 1 && selo.y2 - selo.y1 > 1) return selo;
  }
  return null;
}

function comecaCom(a: Uint8Array, prefixo: Uint8Array) {
  if (a.length <= prefixo.length) return false;
  for (let i = 0; i < prefixo.length; i++) if (a[i] !== prefixo[i]) return false;
  return true;
}

function byteRanges(texto: string) {
  const re = /\/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]/g;
  const out: number[][] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(texto))) out.push([Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])]);
  return out;
}

function hexParaBytes(hex: string) {
  const limpo = hex.replace(/[^0-9a-fA-F]/g, "");
  const b = new Uint8Array(limpo.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(limpo.substr(i * 2, 2), 16);
  return b;
}

function cpfValido(d: string) {
  if (!/^\d{11}$/.test(d) || /^(\d)\1{10}$/.test(d)) return false;
  for (const k of [9, 10]) {
    let s = 0;
    for (let i = 0; i < k; i++) s += Number(d[i]) * (k + 1 - i);
    if (((s * 10) % 11) % 10 !== Number(d[k])) return false;
  }
  return true;
}

function nomeDe(nome: pkijs.RelativeDistinguishedNames) {
  return nome.typesAndValues.map((t) => `${t.type}=${String(t.value.valueBlock.value)}`).join(", ");
}
function campo(nome: pkijs.RelativeDistinguishedNames, oid: string) {
  return nome.typesAndValues.filter((t) => t.type === oid).map((t) => String(t.value.valueBlock.value));
}

/** CPF no certificado: ICP-Brasil (otherName 2.16.76.1.3.1), "NOME:CPF" no CN, serialNumber ou qualquer CPF válido no titular. */
function cpfDoCertificado(cert: pkijs.Certificate): string | null {
  const ext = cert.extensions?.find((e) => e.extnID === "2.5.29.17");
  if (ext?.parsedValue) {
    for (const n of (ext.parsedValue as pkijs.AltName).altNames ?? []) {
      // otherName = tipo 0: { type-id, [0] valor }
      if (n.type === 0 && n.value?.valueBlock?.value) {
        const seq = n.value.valueBlock.value as asn1js.BaseBlock[];
        const oid = (seq[0] as asn1js.ObjectIdentifier)?.valueBlock?.toString?.();
        if (oid === "2.16.76.1.3.1") {
          // dados do titular PF: nascimento (8) + CPF (11) + NIS (11) + RG...; lê os dígitos direto dos bytes do campo
          const bruto = enc.decode(new Uint8Array((n.value as asn1js.BaseBlock).toBER(false)));
          for (const run of bruto.match(/\d{19,}/g) ?? []) {
            if (cpfValido(run.slice(8, 19))) return run.slice(8, 19);
          }
        }
      }
    }
  }
  const cn = campo(cert.subject, "2.5.4.3").join(" ");
  const m = cn.match(/:(\d{11})\b/);
  if (m && cpfValido(m[1]!)) return m[1]!;
  for (const s of campo(cert.subject, "2.5.4.5")) {
    const d = s.replace(/\D/g, "");
    if (cpfValido(d)) return d;
  }
  const todos = nomeDe(cert.subject).match(/\d{11}/g) ?? [];
  return todos.find(cpfValido) ?? null;
}

type Lida = { tipo: "assinatura" | "carimbo"; valida: boolean; erro?: string; sd?: pkijs.SignedData; fim: number };

/** Lê e confere UMA assinatura do PDF (pelo /ByteRange). Carimbo de tempo (RFC 3161) é reconhecido à parte. */
async function lerAssinatura(pdf: Uint8Array, br: number[]): Promise<Lida> {
  const [a, b, c, d] = br as [number, number, number, number];
  const fim = c + d;
  if (a !== 0 || b >= c || fim > pdf.length) return { tipo: "assinatura", valida: false, erro: "intervalo inválido", fim };
  const conteudo = enc.decode(pdf.subarray(b, c)).replace(/^[<\s]+|[>\s]+$/g, "");
  let der = hexParaBytes(conteudo);
  try {
    const cab = asn1js.fromBER(der.buffer);
    if (cab.offset > 0) der = der.slice(0, cab.offset);
  } catch {
    return { tipo: "assinatura", valida: false, erro: "conteúdo ilegível", fim };
  }
  let sd: pkijs.SignedData;
  try {
    const info = new pkijs.ContentInfo({ schema: asn1js.fromBER(der.buffer).result });
    sd = new pkijs.SignedData({ schema: info.content });
  } catch (e) {
    return { tipo: "assinatura", valida: false, erro: `formato desconhecido (${e instanceof Error ? e.message : e})`, fim };
  }
  const carimbo = sd.encapContentInfo?.eContentType === "1.2.840.113549.1.9.16.1.4";
  if (carimbo) {
    // carimbo de tempo: não identifica o assinante; basta estar bem formado
    return { tipo: "carimbo", valida: true, sd, fim };
  }
  const assinado = new Uint8Array(b + d);
  assinado.set(pdf.subarray(a, a + b), 0);
  assinado.set(pdf.subarray(c, c + d), b);
  const { cert } = certDoAssinante(sd);
  if (!cert) return { tipo: "assinatura", valida: false, sd, fim, erro: "certificado do assinante ausente" };
  const erro = await verificarCms(sd, cert, assinado);
  return { tipo: "assinatura", valida: !erro, sd, fim, erro: erro ?? undefined };
}

export async function conferirPdf(anterior: Uint8Array, novo: Uint8Array): Promise<Conferencia> {
  if (novo.length === anterior.length && novo.every((v, i) => v === anterior[i])) {
    return { ok: false, motivo: "Este é o mesmo arquivo de antes: não encontramos a sua assinatura. Assine no gov.br e envie o arquivo assinado." };
  }
  if (!comecaCom(novo, anterior)) {
    return {
      ok: false,
      motivo: "O PDF não é o mesmo documento: o conteúdo ou as assinaturas anteriores foram alterados. Baixe de novo e assine sem modificar.",
      detalhe: `tamanhos ${anterior.length}/${novo.length}; o arquivo foi regravado em vez de receber a assinatura no fim`,
    };
  }
  const brAntes = byteRanges(enc.decode(anterior));
  const novas = byteRanges(enc.decode(novo)).slice(brAntes.length);
  if (!novas.length) return { ok: false, motivo: "Não encontramos uma assinatura nova no arquivo enviado." };
  const lidas: Lida[] = [];
  for (const br of novas) lidas.push(await lerAssinatura(novo, br));
  const detalhe = lidas.map((l, i) => `#${i + 1} ${l.tipo} ${l.valida ? "ok" : `falhou (${l.erro})`} até ${l.fim}`).join("; ") +
    `; arquivo ${novo.length} bytes`;
  const assin = lidas.find((l) => l.tipo === "assinatura");
  if (!assin) return { ok: false, motivo: "O arquivo tem só carimbo de tempo, sem a sua assinatura.", detalhe };
  if (!assin.valida) return { ok: false, motivo: "A assinatura não confere com o conteúdo do documento.", detalhe };
  if (lidas.some((l) => !l.valida)) return { ok: false, motivo: "Uma das assinaturas acrescentadas não confere.", detalhe };
  // depois da última assinatura/carimbo, só se aceitam dados de validação (DSS/VRI) que o assinador acrescenta
  const fimCoberto = Math.max(...lidas.map((l) => l.fim));
  if (fimCoberto < novo.length) {
    const resto = enc.decode(novo.subarray(fimCoberto));
    if (!/\/DSS\b/.test(resto)) {
      return { ok: false, motivo: "A assinatura não cobre o documento inteiro (algo foi acrescentado depois de assinar).", detalhe };
    }
  }
  const sd = assin.sd!;
  const certs = (sd.certificates ?? []).filter((x): x is pkijs.Certificate => x instanceof pkijs.Certificate);
  const sid = sd.signerInfos[0]!.sid as pkijs.IssuerAndSerialNumber;
  const cert = certs.find((x) => sid?.serialNumber && x.serialNumber?.isEqual?.(sid.serialNumber)) ?? certs[0];
  if (!cert) return { ok: false, motivo: "Certificado do assinante não encontrado na assinatura.", detalhe };
  const cad = await validarCadeia(cert, certs);
  if (cad.erro) return { ok: false, motivo: "O certificado da assinatura não é reconhecido pelo ITI (gov.br ou ICP-Brasil).", detalhe: `${detalhe}; ${cad.erro}` };
  const lcr = await situacaoNaLcr(cert, cad.emissor ?? cert);
  if (lcr === "revogado") return { ok: false, motivo: "O certificado usado nesta assinatura foi revogado.", detalhe };
  const govbrOuIcp = true;
  const nome = (campo(cert.subject, "2.5.4.3")[0] ?? "").split(":")[0]!.trim();
  const titular = nomeDe(cert.subject).replace(/\d(?=\d{2})/g, "*");
  const selo = seloNovo(enc.decode(novo.subarray(anterior.length)));
  return { ok: true, cpf: cpfDoCertificado(cert), nome, emissor: nomeDe(cert.issuer), govbrOuIcp, selo, detalhe: `${detalhe}; titular: ${titular}; emissor: ${nomeDe(cert.issuer)}; raiz: ${cad.raiz}; LCR: ${lcr}` };
}

/** Diagnóstico: lista as assinaturas de um PDF (tipo, se conferem, titular e CPF mascarados, emissor). */
export async function inspecionarPdf(pdf: Uint8Array) {
  const out = [];
  for (const br of byteRanges(enc.decode(pdf))) {
    const l = await lerAssinatura(pdf, br);
    const certs = (l.sd?.certificates ?? []).filter((x): x is pkijs.Certificate => x instanceof pkijs.Certificate);
    const sid = l.sd?.signerInfos[0]?.sid as pkijs.IssuerAndSerialNumber | undefined;
    const cert = certs.find((x) => sid?.serialNumber && x.serialNumber?.isEqual?.(sid.serialNumber)) ?? certs[0];
    const cpf = cert ? cpfDoCertificado(cert) : null;
    out.push({
      tipo: l.tipo, valida: l.valida, erro: l.erro, fim: l.fim, tamanho: pdf.length,
      titular: cert ? nomeDe(cert.subject).replace(/\d(?=\d{2})/g, "*") : null,
      emissor: cert ? nomeDe(cert.issuer) : null,
      cpfLido: cpf ? `***.${cpf.slice(3, 6)}.***-**` : null,
      cadeia: certs.map((x) => (campo(x.subject, "2.5.4.3")[0] ?? "")).join(" > "),
      san: cert?.extensions?.find((e) => e.extnID === "2.5.29.17") ? "tem SAN" : "sem SAN",
    });
  }
  return out;
}
