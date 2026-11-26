# Kit de agentes - Poudriere

Versao: **1.0.0** | Data: **2026-11-26**

Este pacote contem instrucoes destinadas a agentes de IA que trabalham com o projeto Poudriere. O arquivo principal e `AGENTS.md`; cada diretorio de `skills/` contem um `SKILL.md` autossuficiente com gatilho, controles, sequencia e comandos seguros de observacao.

## Uso no repositorio Git

O arquivo `AGENTS.md` e as skills estao na raiz do repositorio. Claude Code pode ler `AGENTS.md` quando instruido; para descoberta nativa de skills do Claude, copiar ou vincular os diretorios para `.claude/skills/`. Para Codex CLI, se necessario, colocar as skills em `.agents/skills/`, preservando `AGENTS.md` na raiz.

## Importante

Os comandos nas skills sao referencias; mutacoes precisam de aprovacao. Confirmar versoes, opcoes e caminhos na maquina antes de usar comandos de manutencao.

As copias historicas do pacote privado nao foram republicadas. Consultar `INSTALL.md` e os arquivos em `scripts/` como fontes versionadas atuais; comparar com os anexos originais quando necessario.
