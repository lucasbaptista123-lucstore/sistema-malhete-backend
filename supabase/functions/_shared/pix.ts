/** Cópia de app/src/lib/pix.ts (mantenha as duas iguais).
 * PIX "copia e cola" estático (BR Code, padrão EMV do Banco Central) a partir da chave da loja.
 * Formato: campos ID+tamanho+valor; termina com o CRC16-CCITT (polinômio 0x1021, início 0xFFFF).
 */

const campo = (id: string, valor: string) =>
  `${id}${String(valor.length).padStart(2, "0")}${valor}`;

// sem acento, maiúsculo e só caracteres aceitos pelos bancos
const limpar = (s: string, max: number) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^A-Za-z0-9 .-]/g, "")
    .toUpperCase()
    .trim()
    .slice(0, max);

/** Chave como o Bacen espera: CPF/CNPJ só dígitos; telefone com +55; e-mail e aleatória como estão. */
export function normalizarChave(chave: string): string {
  const c = chave.trim();
  if (c.includes("@") || /^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(c)) return c;
  if (c.startsWith("+")) return `+${c.replace(/\D/g, "")}`;
  const d = c.replace(/\D/g, "");
  // CNPJ (14) ou CPF (11) formatados; telefone deve ser cadastrado com +55
  if (/[./-]/.test(c) && (d.length === 14 || d.length === 11)) return d;
  return d.length >= 11 ? d : c;
}

function crc16(payload: string): string {
  let crc = 0xffff;
  for (let i = 0; i < payload.length; i++) {
    crc ^= payload.charCodeAt(i) << 8;
    for (let b = 0; b < 8; b++)
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return crc.toString(16).toUpperCase().padStart(4, "0");
}

export function pixCopiaECola({
  chave,
  nome,
  cidade,
  valor,
  txid,
  descricao,
}: {
  chave: string;
  nome: string;
  cidade: string;
  valor: number;
  txid: string; // até 25, só letras e números
  descricao?: string;
}): string {
  // Formato mais aceito pelos apps de banco (06/11: QR "inválido" para um irmão): sem texto extra junto da
  // chave e identificador "***" (o recomendado para PIX estático; alguns bancos recusam outro valor).
  // txid e descricao seguem só para identificação dentro do sistema.
  void txid;
  void descricao;
  const conta = campo("00", "br.gov.bcb.pix") + campo("01", normalizarChave(chave));
  const corpo =
    campo("00", "01") +
    campo("26", conta) +
    campo("52", "0000") +
    campo("53", "986") +
    campo("54", valor.toFixed(2)) +
    campo("58", "BR") +
    campo("59", limpar(nome, 25) || "LOJA") +
    campo("60", limpar(cidade, 15) || "BRASIL") +
    campo("62", campo("05", "***")) +
    "6304";
  return corpo + crc16(corpo);
}
