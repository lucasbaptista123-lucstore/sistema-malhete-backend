---
updatedAt: 2026-10-13T13:37:54.000Z
agentTools:
  projectIndex: https://docs.asaas.com/llms.txt
---

# Autenticação

De que forma o Asaas identifica quem é você?

# Autentique suas requisições à API

A API do Asaas utiliza uma **chave de API** para identificar a conta responsável pela requisição.

Envie a chave no header `access_token`. Caso ela esteja ausente, inválida ou não pertença ao ambiente utilizado, a API retornará `401 Unauthorized`.

<Callout icon="📘" theme="info">
  Ao concluir este guia, você saberá configurar os headers, escolher o ambiente correto e identificar os principais erros de autenticação.
</Callout>

## Antes de começar

<Anchor target="_blank" href="https://docs.asaas.com/docs/chaves-de-api">Crie uma chave de API</Anchor> no ambiente que será utilizado.

A segurança da chave é responsabilidade da sua aplicação. Armazene-a de forma segura e considere restringir os IPs autorizados.

Consulte também os <Anchor target="_blank" href="https://docs.asaas.com/docs/mecanismos-de-seguranca">mecanismos adicionais de segurança</Anchor>.

<Callout icon="⚠️" theme="warn">
  Nunca exponha sua chave de API em código público, aplicações frontend, imagens, logs ou repositórios.
</Callout>

## Configure os headers

Envie os seguintes headers:

```json
{
  "Content-Type": "application/json",
  "User-Agent": "nome_da_sua_aplicação",
  "access_token": "sua_api_key"
}
```

<br />

| Header         | Uso                                                                      |
| -------------- | ------------------------------------------------------------------------ |
| `access_token` | Chave de API da conta. Obrigatório em todas as requisições autenticadas. |
| `User-Agent`   | Identifica a aplicação responsável pela requisição.                      |
| `Content-Type` | Utilize `application/json` nas requisições que enviam body em JSON.      |

<Callout icon="🚧" theme="warn">
  ### Envio do User-Agent

  O header `User-Agent` é obrigatório para novas contas raiz criadas a partir de **13/06/2024**.

  Utilize um valor que identifique sua aplicação, principalmente quando seu framework não configurar esse header automaticamente.

  Consulte <Anchor target="_blank" href="https://docs.asaas.com/docs/autenticação-1#envio-do-user-agent">Como definir o User-Agent</Anchor>.
</Callout>

## Escolha o ambiente

Use a URL correspondente ao ambiente da sua chave de API:

| Ambiente | URL base                           |
| -------- | ---------------------------------- |
| Sandbox  | `https://api-sandbox.asaas.com/v3` |
| Produção | `https://api.asaas.com/v3`         |

<Callout icon="📘" theme="info">
  As chaves de API de Sandbox e Produção são diferentes.

  Ao alterar o ambiente, atualize também a chave utilizada no header `access_token`.
</Callout>

## Teste os endpoints desta documentação

<Callout icon="❗️" theme="error">
  ### Utilize uma chave de Sandbox

  Os testes executados diretamente pela referência da API utilizam o ambiente Sandbox.

  Para testar os endpoints, <Anchor target="_blank" href="https://sandbox.asaas.com/onboarding/createAccount?customerSignUpOriginChannel=HOME">crie uma conta Sandbox</Anchor> e utilize a chave de API desse ambiente.

  Uma chave de Produção retornará `401 Unauthorized`.

  <Anchor target="_blank" href="https://docs.asaas.com/docs/sandbox">Saiba mais sobre o Sandbox</Anchor>.
</Callout>

Durante o desenvolvimento, utilize dados fictícios e valide sua integração no Sandbox antes de alterar a URL e a chave para Produção.

## Requisitos de segurança TLS

A API do Asaas aceita conexões com TLS 1.2 e TLS 1.3.

Recomendamos utilizar TLS 1.3 sempre que houver suporte.

## Erros de autenticação

Uma resposta `401 Unauthorized` indica que a requisição não pôde ser autenticada.

### Chave utilizada no ambiente incorreto

```json
{
  "errors": [
    {
      "code": "invalid_environment",
      "description": "A chave de API informada não pertence a este ambiente"
    }
  ]
}
```

**Como resolver:** confirme se a URL e a chave pertencem ao mesmo ambiente.

* Produção: chave iniciada por `$aact_prod_`
* Sandbox: chave iniciada por `$aact_hmlg_`

### Header de autenticação ausente

```json
{
  "errors": [
    {
      "code": "access_token_not_found",
      "description": "O cabeçalho de autenticação 'access_token' é obrigatório e não foi encontrado na requisição"
    }
  ]
}
```

**Como resolver:** envie o header `access_token` em todas as requisições autenticadas.

### Formato da chave incorreto

```json
{
  "errors": [
    {
      "code": "invalid_access_token_format",
      "description": "O valor fornecido não parece ser uma chave de API válida do Asaas. Verifique o formato da sua chave"
    }
  ]
}
```

**Como resolver:** verifique se a chave contém espaços, caracteres adicionais ou foi copiada de forma incompleta.

### Chave inválida ou revogada

```json
{
  "errors": [
    {
      "code": "invalid_access_token",
      "description": "A chave de API fornecida é inválida"
    }
  ]
}
```

**Como resolver:** confirme se a chave está correta e se não foi desabilitada, expirada ou excluída.

## Próximos passos

* <Anchor target="_blank" href="https://docs.asaas.com/docs/chaves-de-api">Crie e gerencie suas chaves de API</Anchor>
* <Anchor target="_blank" href="https://docs.asaas.com/docs/sandbox">Conheça o ambiente Sandbox</Anchor>
* <Anchor target="_blank" href="https://docs.asaas.com/docs/mecanismos-de-seguranca">Configure mecanismos adicionais de segurança</Anchor>
* <Anchor target="_blank" href="https://docs.asaas.com/docs/postman">Teste a API com o Postman</Anchor>
* <Anchor target="_blank" href="https://docs.asaas.com/reference">Consulte a referência da API</Anchor>

<br />

# Sibling pages

* [Chaves de API](https://docs.asaas.com/docs/chaves-de-api.md)
* [PCI-DSS](https://docs.asaas.com/docs/pci-dss-1.md)
* [Mecanismos adicionais de segurança](https://docs.asaas.com/docs/mecanismos-de-seguranca.md)