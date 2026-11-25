# Produção e valor por unidade de saúde – Pernambuco (2019 a 2026)

Planilhas de produção e valor da rede estadual de saúde de PE, por unidade,
a partir dos dados abertos do DATASUS (SIA, SIH, CNES e SIGTAP). Os dados vêm
do FTP do DATASUS e são atualizados todo dia pelo GitHub Actions: o pipeline só
baixa meses novos ou republicados e só regrava as planilhas quando algo mudou.

Mesmo desenho do [informacoes-estrategicas-geres](https://github.com/DGMOG-SES/informacoes-estrategicas-geres)
(R + `data.table` + `read.dbc`, extração incremental, partições Parquet), mas a
saída são planilhas e não um painel.

## Planilhas

As regras seguem as tabulações do TabWin usadas pela SES (`T:\Tabaih08\RD_PE.DEF`
e `T:\TabSia08\Prod_PE.def`), que leem os mesmos arquivos `.dbc` do FTP do
DATASUS. Ficam em `planilhas/` (Excel, com aba **Leia-me** explicando a regra) e
`planilhas/csv/` (base longa de cada tema: unidade × dimensão × ano, separada por
`;` e com vírgula decimal). Em todas as tabelas: **para cada ano, produção e valor**,
com subtotais e total geral.

| Arquivo | Abas | Produção | Valor |
|---|---|---|---|
| `01_procedimentos_ambulatoriais` | **Geral** (grupo de procedimento × ano) e **Unidades** | SIA, quantidade aprovada, todos os grupos SIGTAP (01 a 09) | Valor aprovado |
| `02_internamentos` | **Geral** (grupo × ano) e uma aba por grupo: **02 Diagnóstico**, **03 Clínicos**, **04 Cirúrgicos**, **05 Transplantes** (unidades × ano) | SIH, número de AIH pelo grupo do procedimento realizado, **incluindo as de longa permanência** (Freqüência do TabWin, padrão da área) | Valor total da AIH |
| `03_consultas_medicas_especializadas` | **Geral** (especialidade/CBO × ano) e **Unidades** | SIA, procedimento 0301010072, quantidade aprovada | Valor aprovado |
| `04_consultas_multiprofissionais` | **Geral** (CBO × ano) e **Unidades** | SIA, procedimento 0301010048 (nível superior, exceto médico) | Valor aprovado |
| `05_partos` | **Geral** (tipo e procedimento × gestão × ano) e **Parto normal** / **Parto cesáreo** (unidades agrupadas por gestão) | SIH, AIH dos 6 procedimentos do `PROCOBS2C.CNV`: normal (0310010039, 0310010047, 0310010055) e cesáreo (0411010034, 0411010026, 0411010042). **Todo o estado**, gestão estadual e municipal | Valor total da AIH |
| `06_leitos` | **Geral** (tipo de leito × gestão × ano), **Por especialidade** (tipo e especialidade × gestão) e **Unidades** (agrupadas por gestão) | CNES-LT, leitos existentes (`QT_EXIST`, a Freqüência do `Leitos_Especialidade.def`), posição de **dezembro** de cada ano (no ano corrente, o último mês publicado). **Todo o estado**, por tipo de gestão (dupla, estadual, municipal, sem gestão) | No lugar do valor: leitos SUS (`QT_SUS`) |
| `07_cuida_pe` | **Consultas UPAEs** (as 15 UPAEs × ano), **Cirurgias por caráter** (eletivo/urgência × gestão estadual/municipal), **Proporção cirurgias** (% de cada caráter na gestão), **RNM e TC** (subgrupos 0206 e 0207) e **Eletivas Portaria 339** (ano × mês) | Consultas: SIA 0301010072, gestão E. Cirurgias: SIA (quantidade aprovada, `PA_CATEND`) + SIH (AIH, `CAR_INT`), grupo 04, caráter 01 eletivo ou 02 urgência, gestão estadual e municipal; proporção sobre eletivo + urgência. RNM/TC: SIA, caráter 01 ou 02 (`PA_CATEND`), gestão E. Eletivas: SIA (quantidade aprovada, `PA_CATEND` 01) **e** SIH (AIH, `CAR_INT` 01), 214 procedimentos da Portaria Estadual 339/2023 (`referencias/portaria_339_cirurgias_eletivas.csv`, do `PORT339.DBF`), grupo 04, gestão E, MAC e FAEC; por ano, fonte e mês | Valor aprovado (SIA) ou total da AIH (SIH); na proporção, o percentual |
| `00_unidades` | Cadastro das unidades que aparecem nas planilhas | | |
| `atualizacao.csv` | Último mês disponível de cada fonte e data da geração | | |

## Regras

**Temas 01 a 04: toda a produção sob gestão estadual**, igual ao filtro `Gestao: ESTADUAL` do TabWin (os totais batem com ele). As unidades são classificadas assim:

| Tipo de rede | Quem entra |
|---|---|
| Rede própria | Lista validada (`referencias/estabelecimentos_validados.csv`), vínculo `REDE_PROPRIA_ESTADUAL` ou `ESTADUAL_ADM_INDIRETA`, modelo 06 grandes, Gestão direta ou Administração indireta |
| OSS | Lista validada, modelo `OSS` |
| Rede própria – "Estadual fora da lista SES" | Estabelecimentos da administração pública estadual no CNES (natureza jurídica 102-3, 111-2 etc.) fora da lista: laboratórios, unidades móveis, assistência farmacêutica |
| Complementar | Referências fora da rede da lista validada (inclui o Hospital das Clínicas) e prestadores privados/filantrópicos (natureza jurídica 2xxx, exceto empresa pública e sociedade de economia mista, 3xxx e 4xxx) |
| Outro público | Públicos não estaduais que faturam sob gestão estadual (ex.: "Pública municipal") |

Os partos (tema 05) incluem **todas** as unidades de PE, com a gestão separada.

**Gestão**, como no TabWin da SES: no SIH, campo `GESTAO` da AIH (E/2 estadual,
M/1 municipal, `GESTAO.CNV`); no SIA, `PA_CONDIC` (E estadual, P municipal, D
dupla, `TPGESTAO.CNV`). A seleção "Gestão: Estadual" dos logs da área é E.

**Período e competência.** Mês de processamento: no SIA, o movimento
(`PA_MVM`); no SIH, `ANO_CMPT`/`MES_CMPT`. Vai de 01/2019 até 12/2026 (ou o
último mês publicado). Cada movimento traz também produção atrasada de meses
anteriores, então **os últimos 3 a 4 meses são parciais**. A base do SIA guarda
também `PA_CMP` (competência de atendimento) para quem precisar dessa visão.

**Quantidade.** SIA: quantidade aprovada (`PA_QTDAPR`), que é a Freqüência do
`Prod_PE.def` (linha `GPA_QTDAPR`). SIH: número de AIH, incluindo as de longa
permanência (`IDENT` 5), como a Freqüência do `RD_PE.DEF`.

**Valor.** Valor aprovado do SIA (`PA_VALAPR`) e valor total da AIH no SIH
(`VAL_TOT`), em R$, pela tabela SUS. **Não** inclui complementos estaduais,
incentivos nem os repasses dos contratos de gestão das OSS; é o valor da
produção registrada, não o custo da unidade.

Para mudar códigos de procedimento, edite o bloco "Regras de cada tema" no
início do `04_planilhas.R`. Para mudar o período, edite `inicio` e `fim` em `utils.R`.

## Scripts

| Script | O que faz | Saída |
|---|---|---|
| `01_unidades.R` | Baixa o CNES-ST de PE (primeiro e último mês de cada ano) e guarda natureza jurídica, tipo e município de cada CNES | `dados/referencias/cnes_st_pe.csv` |
| `01b_leitos.R` | CNES-LT de PE: o mês de dezembro de cada ano e o último mês do ano corrente; guarda leitos existentes, SUS e não SUS por CNES, tipo de leito, especialidade e tipo de gestão | `dados/leitos/*.parquet` → `dados/saida/leitos.parquet` |
| `02_sia.R` | SIA-PA de PE por movimento, toda a produção do estado; agrega por movimento, competência, CNES, gestor, procedimento, CBO (só nas consultas 0301), município, tipo de unidade e de prestador, natureza jurídica, financiamento e instrumento de registro | `dados/sia/*.parquet` → `dados/saida/sia_unidades.parquet` |
| `03_sih.R` | SIH-RD de PE por mês, todas as AIH do estado; agrega por competência, CNES, gestor, procedimento, leito, caráter, complexidade, tipo de AIH, natureza jurídica, município e financiamento | `dados/sih/*.parquet` → `dados/saida/sih_unidades.parquet` |
| `04_planilhas.R` | Classifica as unidades, baixa o SIGTAP para os nomes e grava as cinco planilhas temáticas | `planilhas/` |
| `utils.R` | Funções comuns (FTP, leitura de .dbc, controle do que já foi processado) e configuração | |
| `instalar_pacotes.R` | Instala os pacotes (rodar uma vez) | |

As bases consolidadas em `dados/saida/` não são versionadas no Git (passariam do limite de
100 MB por arquivo com todo o estado desde 2019): elas são remontadas a partir das partições
`dados/sia/` e `dados/sih/` a cada execução.

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
