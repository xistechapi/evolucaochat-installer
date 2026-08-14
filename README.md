# Instalador comercial do EvolucaoChat

O cliente não recebe este repositório. Ele executa somente o bootstrap público:

```bash
curl -fsSL https://raw.githubusercontent.com/xistechapi/evolucaochat-installer/main/bootstrap.sh | sudo bash
```

O bootstrap baixa uma lista fixa de arquivos do repositório público exclusivo
do instalador. O código-fonte da aplicação e a chave privada de assinatura não
fazem parte dessa lista. Durante a execução, o instalador solicita os dados da
compra, pede à central `downloads.evolucaochat.com.br` uma release autorizada,
baixa os cinco artefatos temporários por HTTPS e valida assinatura/checksums
antes de instalar Docker, Traefik, Portainer e o EvolucaoChat.

## Homologação interna

O parâmetro `--test-release-dir` existe apenas para os testes internos. Ele
exige explicitamente `INSTALLER_TEST_MODE=1` e nunca deve ser entregue a um
cliente ou usado em produção.
