# Produção e valor por unidade de saúde – Pernambuco (2023 a 2026)

Planilhas de produção e valor da rede estadual de saúde de PE, por unidade,
a partir dos dados abertos do DATASUS (SIA, SIH, CNES e SIGTAP). Os dados vêm
do FTP do DATASUS e são atualizados todo dia pelo GitHub Actions: o pipeline só
baixa meses novos ou republicados e só regrava as planilhas quando algo mudou.

Mesmo desenho do [informacoes-estrategicas-geres](https://github.com/DGMOG-SES/informacoes-estrategicas-geres)
(R + `data.table` + `read.dbc`, extração incremental, partições Parquet), mas a
saída são planilhas e não um painel.

## Planilhas

Ficam em `planilhas/` (Excel, com aba **Leia-me** explicando a regra) e
`planilhas/csv/` (o mesmo conteúdo, separado por `;` e com vírgula decimal).

| Arquivo | Conteúdo | Fonte e regra |
|---|---|---|
| `00_unidades` | Cadastro das unidades com produção: tipo de rede, modelo de gestão, tipo, natureza jurídica, município, região de saúde | Lista validada da SES + CNES-ST |
| `01_producao_geral` | Abas **Resumo anual**, **Mensal** e **Por grupo SIGTAP**: quantidade e valor ambulatorial, internações, AIH, diárias, valor hospitalar e valor total | SIA (aprovado) + SIH |
| `02_procedimentos_ambulatoriais_AAAA` | Um arquivo por ano: unidade × mês × procedimento, com quantidade e valor apresentados e aprovados | SIA-PA, todos os procedimentos |
| `03_internamentos_AAAA` | Um arquivo por ano: unidade × mês × especialidade do leito × caráter × complexidade × procedimento realizado; internações, AIH, diárias, óbitos e valores (total, SH, SP) | SIH-RD |
| `04_transplantes` | Órgãos e tecidos transplantados, por unidade, mês e procedimento | Subgrupo SIGTAP 05.05, no SIA e no SIH |
| `05_consultas_medicas_especializadas` | Aba **Por unidade** e abas **Por CBO** (especialidade do médico) | SIA, procedimento 0301010072 |
| `06_consultas_nivel_superior` | Idem, por CBO do profissional | SIA, procedimento 0301010048 (exceto médico) |
| `07_partos` | Aba **Por tipo de parto** (normal, cesáreo, total e % cesáreo) e **Detalhe** por procedimento | SIH, AIH 0310010039, 0310010055, 0310010047, 0411010034, 0411010026, 0411010042 |
| `atualizacao.csv` | Último mês disponível de cada fonte e data da geração | |

Colunas comuns: `ANO`, `MES`, `COMPETENCIA` (AAAAMM), `TIPO_REDE`,
`MODELO_GESTAO`, `CNES`, `UNIDADE`, `TIPO_UNIDADE`, `MUNICIPIO`, `REGIAO_SAUDE`.

## Regras

**Tipo de rede**

| TIPO_REDE | Quem entra | Produção considerada |
|---|---|---|
| Rede própria | Lista validada (`referencias/estabelecimentos_validados.csv`), vínculo `REDE_PROPRIA_ESTADUAL` ou `ESTADUAL_ADM_INDIRETA`, modelo de gestão Gestão direta, 06 grandes ou Administração indireta | Toda, qualquer gestor |
| OSS | Lista validada, modelo de gestão `OSS` | Toda, qualquer gestor |
| Complementar | Prestadores privados e filantrópicos: natureza jurídica do CNES começando por 2 (exceto empresa pública 2011 e sociedade de economia mista 2038), 3 ou 4 | Só a faturada pelo gestor estadual (`PA_GESTAO` / `UF_ZI` = 260000) |

Estabelecimentos públicos fora da lista (municipais, federais, como o HC/EBSERH)
ficam de fora. A coluna `NA_LISTA_SES` em `00_unidades` mostra quais
complementares já estavam na lista validada como "Referência fora da rede".

**Período e competência.** Mês de processamento: no SIA, o movimento
(`PA_MVM`); no SIH, `ANO_CMPT`/`MES_CMPT`. Vai de 01/2023 até 12/2026 (ou o
último mês publicado). Cada movimento traz também produção atrasada de meses
anteriores, então **os últimos 3 a 4 meses são parciais**. A base do SIA guarda
também `PA_CMP` (competência de atendimento) para quem precisar dessa visão.

**Quantidade.** SIA: quantidade aprovada (`PA_QTDAPR`); a apresentada
(`PA_QTDPRO`) aparece ao lado nas planilhas de procedimentos e consultas.
SIH: internações = AIH normal (`IDENT` 1); `AIH_TOTAL` inclui as de longa
permanência (`IDENT` 5).

**Valor.** Valor aprovado do SIA (`PA_VALAPR`) e valor total da AIH no SIH
(`VAL_TOT`), em R$, pela tabela SUS. **Não** inclui complementos estaduais,
incentivos nem os repasses dos contratos de gestão das OSS; é o valor da
produção registrada, não o custo da unidade.

Para mudar códigos de procedimento, edite o bloco "Regras de cada tema" no
início do `04_planilhas.R`. Para mudar o período, edite `inicio` e `fim` em `utils.R`.

## Scripts

| Script | O que faz | Saída |
|---|---|---|
| `01_unidades.R` | Baixa o CNES-ST de PE (último mês de cada ano) e guarda natureza jurídica, tipo e município de cada CNES | `dados/referencias/cnes_st_pe.csv` |
| `02_sia.R` | SIA-PA de PE por movimento, só unidades da lista validada + produção sob gestão estadual; agrega por movimento, competência, CNES, gestor, procedimento e CBO (só nas consultas 0301) | `dados/sia/*.parquet` → `dados/saida/sia_unidades.parquet` |
| `03_sih.R` | SIH-RD de PE por mês, mesmo filtro; agrega por competência, CNES, gestor, procedimento, leito, caráter, complexidade e tipo de AIH | `dados/sih/*.parquet` → `dados/saida/sih_unidades.parquet` |
| `04_planilhas.R` | Classifica as unidades, baixa o SIGTAP para os nomes e grava as planilhas | `planilhas/` |
| `utils.R` | Funções comuns (FTP, leitura de .dbc, controle do que já foi processado) e configuração | |
| `instalar_pacotes.R` | Instala os pacotes (rodar uma vez) | |

`dados/controle/` guarda o que já foi baixado, com nome, tamanho e data do
arquivo no FTP: arquivo republicado pelo DATASUS é refeito automaticamente.

## Atualização automática (GitHub Actions)

O workflow `.github/workflows/atualizar.yml` roda todo dia às 09h23 (Brasília),
a cada mudança em script e quando disparado à mão em **Actions → Atualizar
planilhas… → Run workflow**. No disparo manual dá para passar, por exemplo,
`--reprocessar-tudo` ou `--forcar=202503`.

Cada movimento do SIA leva de 10 a 15 minutos para baixar do FTP. Por isso cada
etapa tem limite de tempo (`--minutos`: 200 no SIA, 90 no SIH), e cada mês é
enviado ao repositório assim que termina (`publicar.sh`). A carga histórica do
SIA (uns 45 movimentos) se completa em duas ou três execuções; dispare as
seguintes à mão para não esperar o dia seguinte. Se uma execução cair, só se
perde o mês que estava em andamento. Mês que falha fica para a próxima execução.

## Rodar no computador

```r
# no RStudio, com o diretório de trabalho na pasta do projeto
source("instalar_pacotes.R")        # uma vez
system("Rscript 01_unidades.R")
system("Rscript 02_sia.R")          # ou: Rscript 02_sia.R --max=5 para testar
system("Rscript 03_sih.R")
system("Rscript 04_planilhas.R")
```

Se o `arrow` não instalar (máquina sem permissão de administrador), os scripts
usam o `nanoparquet`.

## Lista validada

`referencias/estabelecimentos_validados.csv` é uma cópia da lista do
informacoes-estrategicas-geres (validada pela SES em 16/10/2026 e 13/11/2026).
Quando ela mudar lá, copie para cá. Se entrou unidade nova, dispare o workflow
com `--reprocessar-tudo` nos campos do SIA e do SIH, porque a produção dela sob
gestor municipal não estava nos meses já extraídos.
