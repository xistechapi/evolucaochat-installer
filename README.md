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

Depois da confirmação da senha, o terminal informa a etapa atual e exibe um
aviso de espera a cada 15 segundos durante etapas demoradas, com o tempo
decorrido naquela etapa. O tempo depende da VPS e da conexão; não há
porcentagem nem prazo fixo de conclusão. Não feche o terminal até a mensagem
de conclusão. Detalhes técnicos e credenciais continuam fora desses avisos,
e o diagnóstico protegido mantém a ocultação dos segredos.

## Atualização pelo sistema

O instalador 1.1.0 prepara o serviço privado de atualização, seu segredo de
comunicação e a chave pública de verificação. Ele deve ser publicado junto com
uma release assinada que inclua API, painel e atualizador; não use este
instalador novo com os bundles antigos de duas imagens.

Após a instalação, um administrador abre **Atualizações** no menu do sistema,
informa seus dados comerciais e verifica uma versão nova. O botão **Atualizar
agora** aparece quando há uma release autorizada mais recente. A atualização
comum troca somente API e painel, sem remover volumes ou serviços de dados.
Mudanças de migrations ou estrutura exigem atualização assistida.

`enable-updater.sh` permite preparar uma instalação existente compatível usando
os cinco artefatos assinados da mesma versão instalada e um diretório novo de
backup. Imagens legadas sem fingerprints exigem baseline assistido antes.
Não execute uma instalação limpa sobre uma instalação com dados existentes.

O atualizador tem autoridade administrativa do host via Docker. Seu serviço
não é publicado na internet; API e painel não recebem o socket Docker.
Backups, espaço em disco e acesso administrativo exigem proteção operacional.

## Homologação interna

O parâmetro `--test-release-dir` existe apenas para os testes internos. Ele
exige explicitamente `INSTALLER_TEST_MODE=1` e nunca deve ser entregue a um
cliente ou usado em produção.
