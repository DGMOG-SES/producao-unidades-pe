#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 04 - Planilhas de produção e valor por unidade de saúde (PE, 2023 a 2026)
#
# Junta as bases do SIA (02_sia.R) e do SIH (03_sih.R), classifica cada unidade
# por tipo de rede e grava uma planilha Excel por tema, com uma aba "Leia-me",
# mais o CSV completo de cada tema.
#
# Tipo de rede (coluna TIPO_REDE):
#   Rede própria  lista validada da SES, vínculo REDE_PROPRIA_ESTADUAL ou
#                 ESTADUAL_ADM_INDIRETA, modelo de gestão diferente de OSS
#                 (Gestão direta, 06 grandes, Administração indireta); mais os
#                 estabelecimentos da administração pública estadual no CNES
#                 que não estão na lista (modelo "Estadual fora da lista SES",
#                 só a produção sob gestão estadual)
#   OSS           lista validada, modelo de gestão OSS
#   Complementar  prestador privado ou filantrópico (natureza jurídica do CNES
#                 2xxx, exceto empresa pública 2011 e sociedade de economia mista
#                 2038, 3xxx e 4xxx), e só a produção sob gestão estadual
#                 (PA_GESTAO / UF_ZI = 260000)
# A produção de rede própria e OSS entra com qualquer gestor. Estabelecimentos
# públicos de fora da lista (municipais, federais) ficam de fora e aparecem
# só no log.
#
# Período: mês de processamento (SIA: movimento PA_MVM; SIH: ANO/MES_CMPT),
# de 01/2023 a 12/2026. Os últimos meses são parciais (reapresentações).
#
# Saídas em planilhas/ (Excel) e planilhas/csv/ (CSV separado por ";"):
#   01_producao_geral                 resumo anual, mensal e por grupo SIGTAP
#   02_procedimentos_ambulatoriais_AAAA   SIA por procedimento (um arquivo por ano)
#   03_internamentos_AAAA             SIH por procedimento realizado, leito e caráter (um arquivo por ano)
#   04_transplantes                   subgrupo SIGTAP 05.05 (SIA + SIH)
#   05_consultas_medicas_especializadas   SIGTAP 0301010072, por CBO
#   06_consultas_nivel_superior       SIGTAP 0301010048 (exceto médico), por CBO
#   07_partos                         AIH de parto normal e cesáreo
#   00_unidades                       cadastro das unidades com produção
#
# Só regera as planilhas quando alguma entrada mudou.
# Uso: Rscript 04_planilhas.R [--forcar]
# ------------------------------------------------------------------------------

source("utils.R")

SAIDA   <- file.path(CFG$dir_dados, "saida")
REF     <- file.path(CFG$dir_dados, "referencias")
PLAN    <- CFG$dir_planilhas
LIMITE_LINHAS_EXCEL <- 1000000

# ---- Regras de cada tema (editar aqui) ----------------------------------------

CONSULTA_MEDICA_ESPECIALIZADA <- "0301010072"   # consulta médica em atenção especializada
CONSULTA_NIVEL_SUPERIOR       <- "0301010048"   # consulta de profissionais de nível superior na atenção especializada (exceto médico)
SUBGRUPO_TRANSPLANTE          <- "0505"         # transplante de órgãos, tecidos e células

PARTOS <- data.table(
  PROC = c("0310010039", "0310010055", "0310010047", "0411010034", "0411010026", "0411010042"),
  TIPO_PARTO = c("Parto normal", "Parto normal", "Parto normal", "Parto cesáreo", "Parto cesáreo", "Parto cesáreo"),
  DETALHE = c("Risco habitual", "Centro de parto normal", "Alto risco", "Risco habitual", "Alto risco", "Com laqueadura tubária")
)

NAT_JUR_PUBLICA_EMPRESARIAL <- c("2011", "2038")   # empresa pública, sociedade de economia mista

# Naturezas jurídicas da administração pública estadual (órgão do Executivo,
# Legislativo e Judiciário estadual, autarquia, fundação pública, órgão autônomo,
# Estado, fundação de direito privado e fundos públicos estaduais).
NAT_JUR_ESTADUAL <- c("1023", "1058", "1082", "1112", "1147", "1171", "1236", "1260", "1295", "1325")

TIPOS_CNES <- c("01" = "Posto de saúde", "02" = "Centro de saúde/Unidade básica", "04" = "Policlínica",
                "05" = "Hospital geral", "07" = "Hospital especializado", "15" = "Unidade mista",
                "20" = "Pronto-socorro geral", "21" = "Pronto-socorro especializado",
                "22" = "Consultório isolado", "36" = "Clínica/Centro de especialidade",
                "39" = "Unidade de apoio diagnose e terapia (SADT)", "40" = "Unidade móvel terrestre",
                "42" = "Unidade móvel de urgência",
                "43" = "Farmácia", "50" = "Unidade de vigilância em saúde", "61" = "Centro de parto normal",
                "62" = "Hospital/Dia", "64" = "Central de regulação", "68" = "Central de gestão em saúde",
                "69" = "Centro de atenção hemoterápica/hematológica", "70" = "Centro de Atenção Psicossocial",
                "72" = "Unidade de atenção à saúde indígena", "73" = "Pronto atendimento",
                "74" = "Polo academia da saúde", "75" = "Telessaúde", "76" = "Central de regulação médica das urgências",
                "77" = "Serviço de atenção domiciliar isolado", "79" = "Oficina ortopédica",
                "80" = "Laboratório de saúde pública", "81" = "Central de regulação do acesso",
                "82" = "Central de notificação, captação e distribuição de órgãos",
                "83" = "Polo de prevenção e promoção da saúde", "85" = "Centro de imunização")

CARATER <- c("01" = "Eletivo", "02" = "Urgência", "03" = "Acidente no local de trabalho",
             "04" = "Acidente no trajeto para o trabalho", "05" = "Outros acidentes de trânsito",
             "06" = "Outras lesões/envenenamentos por agentes químicos ou físicos")

ESPEC_LEITO <- c("01" = "Cirúrgico", "02" = "Obstétrico", "03" = "Clínico", "04" = "Crônicos",
                 "05" = "Psiquiatria", "06" = "Pneumologia sanitária (tisiologia)", "07" = "Pediátrico",
                 "08" = "Reabilitação", "09" = "Leito dia/cirúrgico", "10" = "Leito dia/AIDS",
                 "11" = "Leito dia/fibrose cística", "12" = "Leito dia/intercorrência pós-transplante",
                 "13" = "Leito dia/geriatria", "14" = "Leito dia/saúde mental", "87" = "Saúde mental (clínico)",
                 "88" = "Saúde mental (reabilitação psicossocial)")

MESES <- c("jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez")

# ---- SIGTAP (nomes de procedimentos, grupos e ocupações) -----------------------

ler_sigtap <- function(dir, tabela) {
  lay <- fread(file.path(dir, paste0(tabela, "_layout.txt")), colClasses = "character")
  linhas <- enc2utf8(iconv(readLines(file.path(dir, paste0(tabela, ".txt")), warn = FALSE), "latin1", "UTF-8"))
  as.data.table(setNames(lapply(seq_len(nrow(lay)), function(i)
    trimws(substr(linhas, as.integer(lay$Inicio[i]), as.integer(lay$Fim[i])))), lay$Coluna))
}

# Baixa a tabela unificada mais recente; se o FTP falhar, usa a cópia da última execução.
sigtap <- function() {
  arqs <- file.path(REF, c("sigtap_procedimento.csv", "sigtap_ocupacao.csv"))
  res <- tryCatch({
    lst <- listar_ftp(CFG$ftp_sigtap)
    zip <- tail(sort(grep("^TabelaUnificada_\\d{6}_v\\d+\\.zip$", lst$nome, value = TRUE)), 1)
    log_msg("SIGTAP: %s", zip)
    arq <- baixar(CFG$ftp_sigtap, zip)
    dir <- tempfile(); dir.create(dir)
    tabs <- c("tb_procedimento", "tb_grupo", "tb_sub_grupo", "tb_ocupacao")
    unzip(arq, exdir = dir, files = paste0(rep(tabs, each = 2), c(".txt", "_layout.txt")))
    proc <- ler_sigtap(dir, "tb_procedimento")[, .(PROC = CO_PROCEDIMENTO, NO_PROCEDIMENTO)]
    proc[, `:=`(CO_GRUPO = substr(PROC, 1, 2), CO_SUB_GRUPO = substr(PROC, 3, 4))]
    proc <- merge(proc, ler_sigtap(dir, "tb_grupo")[, .(CO_GRUPO, NO_GRUPO)], by = "CO_GRUPO", all.x = TRUE)
    proc <- merge(proc, ler_sigtap(dir, "tb_sub_grupo")[, .(CO_GRUPO, CO_SUB_GRUPO, NO_SUB_GRUPO)],
                  by = c("CO_GRUPO", "CO_SUB_GRUPO"), all.x = TRUE)
    proc[, `:=`(CO_SUB_GRUPO = paste0(CO_GRUPO, CO_SUB_GRUPO))]
    ocup <- ler_sigtap(dir, "tb_ocupacao")[, .(CBO = CO_OCUPACAO, NO_OCUPACAO)]
    gravar_csv(proc, arqs[1]); gravar_csv(ocup, arqs[2])
    list(proc = proc, ocup = ocup)
  }, error = function(e) {
    log_msg("SIGTAP indisponível (%s); usando a cópia anterior", conditionMessage(e))
    if (!all(file.exists(arqs))) return(NULL)
    list(proc = ler_csv(arqs[1]), ocup = ler_csv(arqs[2]))
  })
  if (is.null(res)) {
    log_msg("Sem SIGTAP: as planilhas saem sem os nomes dos procedimentos")
    res <- list(proc = data.table(PROC = character(), NO_PROCEDIMENTO = character(), CO_GRUPO = character(),
                                  NO_GRUPO = character(), CO_SUB_GRUPO = character(), NO_SUB_GRUPO = character()),
                ocup = data.table(CBO = character(), NO_OCUPACAO = character()))
  }
  res
}

# ---- Nomes dos estabelecimentos fora da lista validada (API de dados abertos) ----

nomes_cnes <- function(cnes) {
  cache_arq <- file.path(REF, "cnes_nomes.csv")
  vazio <- data.table(CNES = character(), NOME_FANTASIA = character(), RAZAO_SOCIAL = character(), STATUS = character())
  cache <- if (file.exists(cache_arq)) ler_csv(cache_arq) else vazio
  # 404 = CNES desativado ou inexistente na API: não consulta de novo
  novos <- setdiff(cnes, cache[STATUS %chin% c("200", "404")]$CNES)
  if (length(novos)) {
    log_msg("API CNES: consultando %d estabelecimentos", length(novos))
    api <- rbindlist(lapply(novos, function(cn) {
      Sys.sleep(0.2)
      r <- tryCatch(curl_fetch_memory(paste0(CFG$api_cnes, as.integer(cn)), handle = novo_handle()),
                    error = function(e) NULL)
      if (is.null(r)) return(data.table(CNES = cn, STATUS = "erro"))
      if (r$status_code != 200) return(data.table(CNES = cn, STATUS = as.character(r$status_code)))
      j <- jsonlite::fromJSON(rawToChar(r$content))
      campo <- function(n) if (!is.null(j[[n]])) as.character(j[[n]]) else NA_character_
      data.table(CNES = cn, NOME_FANTASIA = campo("nome_fantasia"),
                 RAZAO_SOCIAL = campo("nome_razao_social"), STATUS = "200")
    }), fill = TRUE)
    cache <- rbind(cache[!CNES %chin% api$CNES], api, fill = TRUE)
    gravar_csv(cache, cache_arq)
  }
  cache[CNES %chin% cnes, .(CNES, NOME_FANTASIA, RAZAO_SOCIAL)]
}

# ---- Classificação das unidades -------------------------------------------------

natureza <- function(nat_jur, esfera) {
  nat_jur <- fcoalesce(nat_jur, ""); esfera <- fcoalesce(esfera, "")
  fcase(nat_jur %chin% NAT_JUR_PUBLICA_EMPRESARIAL, "Pública",
        substr(nat_jur, 1, 1) %chin% c("2", "3", "4"), "Privada/filantrópica",
        substr(nat_jur, 1, 1) == "1", "Pública",
        # registros antigos sem natureza jurídica: esfera administrativa 04 = privada
        esfera == "04", "Privada/filantrópica",
        esfera %chin% c("01", "02", "03"), "Pública",
        default = "Não identificada")
}

montar_unidades <- function(cnes_com_producao) {
  val <- ler_validados()
  st  <- if (file.exists(file.path(REF, "cnes_st_pe.csv"))) ler_csv(file.path(REF, "cnes_st_pe.csv")) else
    data.table(CNES = character(), CODUFMUN = character(), TP_UNID = character(), NAT_JUR = character(), ESFERA_A = character())
  mun <- ler_csv("referencias/municipios_regiao_saude_pe.csv")

  u <- data.table(CNES = unique(cnes_com_producao))
  u <- merge(u, st[, .(CNES, CODUFMUN, TP_UNID, NAT_JUR, ESFERA_A)], by = "CNES", all.x = TRUE)
  u <- merge(u, val[, .(CNES, NOME_LISTA = NOME_FANTASIA, TIPO_LISTA = TIPO, VINCULO, MODELO_GESTAO)],
             by = "CNES", all.x = TRUE)
  u[, NATUREZA := natureza(NAT_JUR, ESFERA_A)]
  u[, TIPO_REDE := fcase(
    VINCULO %chin% c("REDE_PROPRIA_ESTADUAL", "ESTADUAL_ADM_INDIRETA") & MODELO_GESTAO == "OSS", "OSS",
    VINCULO %chin% c("REDE_PROPRIA_ESTADUAL", "ESTADUAL_ADM_INDIRETA"), "Rede própria",
    # Estabelecimento estadual que não está na lista validada (assistência
    # farmacêutica, laboratórios, unidades móveis etc.): rede própria
    NAT_JUR %chin% NAT_JUR_ESTADUAL, "Rede própria",
    NATUREZA == "Privada/filantrópica", "Complementar",
    NATUREZA == "Pública", "Outro público",
    default = "Não identificado")]
  u[TIPO_REDE == "Complementar", MODELO_GESTAO := "Complementar"]
  u[TIPO_REDE == "Rede própria" & is.na(VINCULO), MODELO_GESTAO := "Estadual fora da lista SES"]
  u[, NA_LISTA_SES := fifelse(is.na(VINCULO), "Não", "Sim")]

  # Nomes: lista validada; demais pela API do CNES
  fora <- u[is.na(NOME_LISTA) & TIPO_REDE %chin% c("Complementar", "Rede própria")]$CNES
  nomes <- tryCatch(nomes_cnes(fora), error = function(e) {
    log_msg("API CNES indisponível: %s", conditionMessage(e)); data.table(CNES = character(), NOME_FANTASIA = character(), RAZAO_SOCIAL = character()) })
  u <- merge(u, nomes, by = "CNES", all.x = TRUE)
  u[, UNIDADE := fcoalesce(NOME_LISTA, NOME_FANTASIA, RAZAO_SOCIAL, paste("CNES", CNES))]
  u[, TIPO_UNIDADE := fcoalesce(TIPO_LISTA, unname(TIPOS_CNES[TP_UNID]),
                                fifelse(is.na(TP_UNID), "Não informado", paste("Tipo", TP_UNID)))]
  u <- merge(u, mun[, .(CODUFMUN = CO_MUNICIPIO, MUNICIPIO, REGIAO_SAUDE, MACRORREGIAO)],
             by = "CODUFMUN", all.x = TRUE)
  u[, .(CNES, UNIDADE, TIPO_REDE, MODELO_GESTAO = fcoalesce(MODELO_GESTAO, ""), TIPO_UNIDADE,
        NATUREZA, NAT_JUR = fcoalesce(NAT_JUR, ""), NA_LISTA_SES, MUNICIPIO = fcoalesce(MUNICIPIO, ""),
        REGIAO_SAUDE = fcoalesce(REGIAO_SAUDE, ""), MACRORREGIAO = fcoalesce(MACRORREGIAO, ""))]
}

# Mantém as unidades da lista validada (rede própria e OSS) com qualquer gestor;
# complementar e estaduais fora da lista, só a produção sob gestão estadual.
filtrar_rede <- function(dt, col_gestor, unidades) {
  dt <- merge(dt, unidades[, .(CNES, TIPO_REDE, NA_LISTA_SES)], by = "CNES")
  dt[(TIPO_REDE %chin% c("Rede própria", "OSS") & NA_LISTA_SES == "Sim") |
       (TIPO_REDE %chin% c("Rede própria", "Complementar") & NA_LISTA_SES == "Não" &
          get(col_gestor) == CFG$gestor_estadual)][, c("TIPO_REDE", "NA_LISTA_SES") := NULL][]
}

# ---- Gravação -------------------------------------------------------------------

COLS_UNIDADE <- c("TIPO_REDE", "MODELO_GESTAO", "CNES", "UNIDADE", "TIPO_UNIDADE", "MUNICIPIO", "REGIAO_SAUDE")

# Acrescenta as colunas da unidade e ANO/MES, e ordena.
com_unidade <- function(dt, unidades) {
  dt <- merge(unidades[, ..COLS_UNIDADE], dt, by = "CNES")
  if ("COMPETENCIA" %in% names(dt)) {
    dt[, `:=`(ANO = as.integer(substr(COMPETENCIA, 1, 4)),
              MES = paste0(substr(COMPETENCIA, 5, 6), "-", MESES[as.integer(substr(COMPETENCIA, 5, 6))]))]
    setcolorder(dt, c("ANO", "MES", "COMPETENCIA", COLS_UNIDADE))
  } else if ("ANO" %in% names(dt)) {
    setcolorder(dt, c("ANO", COLS_UNIDADE))
  }
  # Ordem: Rede própria, OSS, Complementar
  dt[, ORDEM_REDE_ := match(TIPO_REDE, c("Rede própria", "OSS", "Complementar"))]
  setorderv(dt, intersect(c("ANO", "COMPETENCIA", "ORDEM_REDE_", "UNIDADE"), names(dt)))
  dt[, ORDEM_REDE_ := NULL]
  num <- names(dt)[vapply(dt, is.double, logical(1))]
  for (cl in grep("^VALOR", num, value = TRUE)) set(dt, j = cl, value = round(dt[[cl]], 2))
  dt
}

# Divide uma tabela em abas por ano (e em partes, se passar do limite do Excel).
abas_por_ano <- function(dt, prefixo = "") {
  abas <- list()
  for (a in sort(unique(dt$ANO))) {
    x <- dt[ANO == a]
    n_partes <- ceiling(nrow(x) / LIMITE_LINHAS_EXCEL)
    for (p in seq_len(n_partes)) {
      nome <- paste0(prefixo, a, if (n_partes > 1) paste0(" (", p, ")") else "")
      abas[[nome]] <- x[((p - 1) * LIMITE_LINHAS_EXCEL + 1):min(p * LIMITE_LINHAS_EXCEL, nrow(x))]
    }
  }
  abas
}

leia_me <- function(titulo, regras, atualizacao) {
  x <- data.table(Item = c("Tema", "Regra", "Período", "Unidades", "Quantidade", "Valor",
                      "Meses recentes", "Fonte", "Atualizado em"),
             Descricao = c(
               titulo, regras,
               sprintf("Mês de processamento, de %s a %s (dados disponíveis até %s)",
                       "01/2023", "12/2026", atualizacao$ultimo),
               paste("Rede própria (gestão direta, 06 grandes, administração indireta) e OSS: lista validada pela SES,",
                     "qualquer gestor. Rede própria também inclui estabelecimentos estaduais no CNES fora da lista",
                     "(modelo 'Estadual fora da lista SES'), só sob gestão estadual. Complementar: prestadores privados",
                     "e filantrópicos (natureza jurídica no CNES), só a produção sob gestão estadual."),
               "SIA: quantidade aprovada (e apresentada). SIH: AIH aprovadas do tipo normal (IDENT 1); AIH_TOTAL inclui longa permanência.",
               paste("Valores da tabela SUS (SIGTAP) registrados no SIA (aprovado) e no SIH (VAL_TOT), em R$.",
                     "Não incluem complementos estaduais, incentivos nem repasses de contrato de gestão das OSS."),
               "Os últimos 3 a 4 meses ainda recebem produção apresentada com atraso; leia-os como parciais.",
               "DATASUS (SIA-PA, SIH-RD, CNES-ST e SIGTAP), FTP público",
               atualizacao$em))
  setnames(x, "Descricao", "Descri\u00e7\u00e3o")
}

# Temas grandes (procedimentos e internamentos) saem com um arquivo por ano:
# um arquivo único passaria do limite de 100 MB do GitHub e ficaria lento no Excel.
gravar_tema_por_ano <- function(nome, dt, titulo, regras, atualizacao) {
  antigos <- c(file.path(PLAN, paste0(nome, ".xlsx")), file.path(PLAN, "csv", paste0(nome, ".csv")))
  unlink(antigos[file.exists(antigos)])
  for (a in sort(unique(dt$ANO))) {
    x <- dt[ANO == a]
    gravar_tema(paste0(nome, "_", a), abas_por_ano(x), paste0(titulo, " - ", a), regras, atualizacao, csv = x)
  }
}

gravar_tema <- function(nome, abas, titulo, regras, atualizacao, csv = NULL) {
  dir.create(file.path(PLAN, "csv"), recursive = TRUE, showWarnings = FALSE)
  abas <- c(list(`Leia-me` = leia_me(titulo, regras, atualizacao)), abas)
  gravar_atomico(function(f) writexl::write_xlsx(abas, f), file.path(PLAN, paste0(nome, ".xlsx")))
  # CSV no padrão do Excel em português: ";" entre colunas e vírgula decimal
  if (!is.null(csv)) gravar_atomico(function(f) fwrite(csv, f, sep = ";", dec = ",", bom = TRUE),
                                    file.path(PLAN, "csv", paste0(nome, ".csv")))
  log_msg("%s.xlsx: %s", nome, paste(sprintf("%s (%s)", names(abas), vapply(abas, nrow, 1L)), collapse = "; "))
}

# ---- Temas ----------------------------------------------------------------------

main <- function() {
  arq_sia <- file.path(SAIDA, "sia_unidades.parquet")
  arq_sih <- file.path(SAIDA, "sih_unidades.parquet")
  if (!file.exists(arq_sia) || !file.exists(arq_sih)) {
    log_msg("Planilhas não geradas: faltam as bases do SIA e/ou do SIH (rode 02_sia.R e 03_sih.R)")
    return(invisible(NULL))
  }

  # Só regera quando alguma entrada mudou
  entradas <- c(arq_sia, arq_sih, file.path(REF, "cnes_st_pe.csv"), "referencias/estabelecimentos_validados.csv",
                "referencias/municipios_regiao_saude_pe.csv", "04_planilhas.R")
  hash <- paste(tools::md5sum(entradas[file.exists(entradas)]), collapse = "")
  arq_hash <- file.path(CFG$dir_dados, "controle", "planilhas_hash.txt")
  if (!tem_flag("forcar") && file.exists(arq_hash) && identical(readLines(arq_hash), hash) &&
      file.exists(file.path(PLAN, "01_producao_geral.xlsx"))) {
    log_msg("Entradas sem mudança; planilhas mantidas.")
    return(invisible(NULL))
  }

  sia <- ler_parquet(arq_sia)[PA_MVM >= CFG$inicio & PA_MVM <= CFG$fim]
  sih <- ler_parquet(arq_sih)[COMPETENCIA >= CFG$inicio & COMPETENCIA <= CFG$fim]
  sia[, COMPETENCIA := PA_MVM]

  unidades <- montar_unidades(c(sia$CNES, sih$CNES))
  resumo_cl <- unidades[, .N, by = TIPO_REDE]
  log_msg("Unidades com produção por tipo de rede: %s",
          paste(sprintf("%s = %d", resumo_cl$TIPO_REDE, resumo_cl$N), collapse = "; "))
  sia <- filtrar_rede(sia, "PA_GESTAO", unidades)
  sih <- filtrar_rede(sih, "GESTOR", unidades)
  unidades <- unidades[CNES %chin% c(sia$CNES, sih$CNES)]
  unidades[, ORDEM_ := match(TIPO_REDE, c("Rede própria", "OSS", "Complementar"))]
  setorder(unidades, ORDEM_, MODELO_GESTAO, UNIDADE)[, ORDEM_ := NULL]

  sig <- sigtap()
  proc <- sig$proc
  sih[, INTERNACAO := IDENT == "1"]

  atualizacao <- list(
    ultimo = sprintf("SIA %s, SIH %s",
                     format(as.Date(paste0(max(sia$PA_MVM), "01"), "%Y%m%d"), "%m/%Y"),
                     format(as.Date(paste0(max(sih$COMPETENCIA), "01"), "%Y%m%d"), "%m/%Y")),
    em = format(Sys.time(), "%d/%m/%Y %H:%M", tz = "America/Recife"))

  # 00 Unidades
  gravar_tema("00_unidades", list(Unidades = unidades), "Cadastro das unidades com produção no período",
              "Uma linha por CNES com produção. TIPO_REDE define a rede usada em todas as planilhas.",
              atualizacao, csv = unidades)

  # 01 Produção geral -------------------------------------------------------------
  amb_m <- sia[, .(QTD_AMBULATORIAL = sum(QTD_APROVADA), VALOR_AMBULATORIAL = sum(VALOR_APROVADO)),
               by = .(COMPETENCIA, CNES)]
  hosp_m <- sih[, .(INTERNACOES = sum(N_AIH[INTERNACAO]), AIH_TOTAL = sum(N_AIH), DIARIAS = sum(DIARIAS),
                    VALOR_HOSPITALAR = sum(VALOR_TOTAL)), by = .(COMPETENCIA, CNES)]
  geral_m <- merge(amb_m, hosp_m, by = c("COMPETENCIA", "CNES"), all = TRUE)
  for (cl in setdiff(names(geral_m), c("COMPETENCIA", "CNES"))) set(geral_m, which(is.na(geral_m[[cl]])), cl, 0)
  geral_m[, VALOR_TOTAL := VALOR_AMBULATORIAL + VALOR_HOSPITALAR]
  geral_a <- geral_m[, lapply(.SD, sum), by = .(ANO = as.integer(substr(COMPETENCIA, 1, 4)), CNES),
                     .SDcols = setdiff(names(geral_m), c("COMPETENCIA", "CNES"))]

  grupo_amb <- sia[, .(QUANTIDADE = sum(QTD_APROVADA), VALOR = sum(VALOR_APROVADO)),
                   by = .(ANO = as.integer(substr(COMPETENCIA, 1, 4)), CNES, CO_GRUPO = substr(PA_PROC_ID, 1, 2))]
  grupo_amb[, ORIGEM := "Ambulatorial (SIA)"]
  grupo_hosp <- sih[, .(QUANTIDADE = sum(N_AIH[INTERNACAO]), VALOR = sum(VALOR_TOTAL)),
                    by = .(ANO = as.integer(substr(COMPETENCIA, 1, 4)), CNES, CO_GRUPO = substr(PROC_REA, 1, 2))]
  grupo_hosp[, ORIGEM := "Hospitalar (SIH, procedimento principal)"]
  grupos <- rbind(grupo_amb, grupo_hosp)
  grupos <- merge(grupos, unique(proc[, .(CO_GRUPO, NO_GRUPO)]), by = "CO_GRUPO", all.x = TRUE)
  setcolorder(grupos, c("ANO", "CNES", "ORIGEM", "CO_GRUPO", "NO_GRUPO", "QUANTIDADE", "VALOR"))

  geral_m_u <- com_unidade(geral_m, unidades)
  gravar_tema("01_producao_geral",
              list(`Resumo anual` = com_unidade(geral_a, unidades),
                   Mensal = geral_m_u,
                   `Por grupo SIGTAP` = com_unidade(grupos, unidades)),
              "Produção geral por unidade",
              paste("Ambulatorial: quantidade e valor aprovados no SIA. Hospitalar: internações (AIH normal),",
                    "AIH totais, diárias e valor total das AIH no SIH. VALOR_TOTAL = ambulatorial + hospitalar.",
                    "Por grupo SIGTAP: o grupo da AIH é o do procedimento realizado (principal)."),
              atualizacao, csv = geral_m_u)

  # 02 Procedimentos ambulatoriais -----------------------------------------------
  amb <- sia[, .(QTD_APRESENTADA = sum(QTD_APRESENTADA), QTD_APROVADA = sum(QTD_APROVADA),
                 VALOR_APRESENTADO = sum(VALOR_APRESENTADO), VALOR_APROVADO = sum(VALOR_APROVADO)),
             by = .(COMPETENCIA, CNES, PROC = PA_PROC_ID)]
  amb <- merge(amb, proc[, .(PROC, NO_PROCEDIMENTO, CO_GRUPO, NO_GRUPO, CO_SUB_GRUPO, NO_SUB_GRUPO)],
               by = "PROC", all.x = TRUE)
  setcolorder(amb, c("COMPETENCIA", "CNES", "CO_GRUPO", "NO_GRUPO", "CO_SUB_GRUPO", "NO_SUB_GRUPO", "PROC", "NO_PROCEDIMENTO"))
  amb <- com_unidade(amb, unidades)
  gravar_tema_por_ano("02_procedimentos_ambulatoriais", amb, "Procedimentos ambulatoriais (SIA) por unidade",
              "Todos os procedimentos do SIA-PA, por mês de processamento (movimento), unidade e procedimento SIGTAP.",
              atualizacao)

  # 03 Internamentos ----------------------------------------------------------------
  int <- sih[, .(INTERNACOES = sum(N_AIH[INTERNACAO]), AIH_TOTAL = sum(N_AIH), DIARIAS = sum(DIARIAS),
                 OBITOS = sum(OBITOS[INTERNACAO]), VALOR_TOTAL = sum(VALOR_TOTAL),
                 VALOR_SH = sum(VALOR_SH), VALOR_SP = sum(VALOR_SP)),
             by = .(COMPETENCIA, CNES, PROC = PROC_REA, ESPEC, CAR_INT, COMPLEX)]
  int[, `:=`(LEITO = fcoalesce(unname(ESPEC_LEITO[ESPEC]), paste("Especialidade", ESPEC)),
             CARATER = fcoalesce(unname(CARATER[CAR_INT]), paste("Caráter", CAR_INT)),
             COMPLEXIDADE = fifelse(COMPLEX == "02", "Média", fifelse(COMPLEX == "03", "Alta", COMPLEX)))]
  int <- merge(int, proc[, .(PROC, NO_PROCEDIMENTO, CO_GRUPO, NO_GRUPO)], by = "PROC", all.x = TRUE)
  int[, c("ESPEC", "CAR_INT", "COMPLEX") := NULL]
  setcolorder(int, c("COMPETENCIA", "CNES", "LEITO", "CARATER", "COMPLEXIDADE", "CO_GRUPO", "NO_GRUPO", "PROC", "NO_PROCEDIMENTO"))
  int <- com_unidade(int, unidades)
  gravar_tema_por_ano("03_internamentos", int, "Internamentos (SIH) por unidade",
              paste("AIH aprovadas por mês de processamento, unidade, especialidade do leito, caráter,",
                    "complexidade e procedimento realizado. INTERNACOES e OBITOS contam só AIH normal (IDENT 1);",
                    "AIH_TOTAL e os valores incluem as de longa permanência (IDENT 5)."),
              atualizacao)

  # 04 Transplantes ---------------------------------------------------------------
  tx_amb <- sia[substr(PA_PROC_ID, 1, 4) == SUBGRUPO_TRANSPLANTE,
                .(QUANTIDADE = sum(QTD_APROVADA), VALOR = sum(VALOR_APROVADO)),
                by = .(COMPETENCIA, CNES, PROC = PA_PROC_ID)][, ORIGEM := "Ambulatorial (SIA)"]
  tx_hosp <- sih[substr(PROC_REA, 1, 4) == SUBGRUPO_TRANSPLANTE,
                 .(QUANTIDADE = sum(N_AIH[INTERNACAO]), VALOR = sum(VALOR_TOTAL)),
                 by = .(COMPETENCIA, CNES, PROC = PROC_REA)][, ORIGEM := "Hospitalar (SIH)"]
  tx <- merge(rbind(tx_amb, tx_hosp), proc[, .(PROC, NO_PROCEDIMENTO)], by = "PROC", all.x = TRUE)
  setcolorder(tx, c("COMPETENCIA", "CNES", "ORIGEM", "PROC", "NO_PROCEDIMENTO"))
  tx <- com_unidade(tx, unidades)
  gravar_tema("04_transplantes", list(Mensal = tx), "Órgãos e tecidos transplantados",
              paste("Procedimentos do subgrupo SIGTAP 05.05 (transplante de órgãos, tecidos e células),",
                    "no SIA (quantidade aprovada) e no SIH (AIH normal pelo procedimento realizado)."),
              atualizacao, csv = tx)

  # 05 e 06 Consultas -----------------------------------------------------------
  consultas <- function(cod) {
    x <- sia[PA_PROC_ID == cod, .(QTD_APRESENTADA = sum(QTD_APRESENTADA), QTD_APROVADA = sum(QTD_APROVADA),
                                  VALOR_APROVADO = sum(VALOR_APROVADO)),
             by = .(COMPETENCIA, CNES, CBO)]
    x <- merge(x, sig$ocup, by = "CBO", all.x = TRUE)
    x[, NO_OCUPACAO := fcoalesce(NO_OCUPACAO, fifelse(CBO == "", "CBO não informado", paste("CBO", CBO)))]
    setcolorder(x, c("COMPETENCIA", "CNES", "CBO", "NO_OCUPACAO"))
    x <- com_unidade(x, unidades)
    por_unidade <- x[, .(QTD_APROVADA = sum(QTD_APROVADA), VALOR_APROVADO = sum(VALOR_APROVADO)),
                     by = c("ANO", "MES", "COMPETENCIA", COLS_UNIDADE)]
    list(detalhe = x, abas = c(list(`Por unidade` = por_unidade), abas_por_ano(x, "Por CBO ")))
  }
  cm <- consultas(CONSULTA_MEDICA_ESPECIALIZADA)
  gravar_tema("05_consultas_medicas_especializadas", cm$abas, "Consultas médicas especializadas",
              sprintf("SIA, procedimento SIGTAP %s (consulta médica em atenção especializada), por unidade e CBO do profissional.",
                      CONSULTA_MEDICA_ESPECIALIZADA), atualizacao, csv = cm$detalhe)
  cs <- consultas(CONSULTA_NIVEL_SUPERIOR)
  gravar_tema("06_consultas_nivel_superior", cs$abas, "Consultas de nível superior (exceto médico)",
              sprintf(paste("SIA, procedimento SIGTAP %s (consulta de profissionais de nível superior na atenção",
                            "especializada, exceto médico), por unidade e CBO do profissional."),
                      CONSULTA_NIVEL_SUPERIOR), atualizacao, csv = cs$detalhe)

  # 07 Partos ----------------------------------------------------------------------
  pt <- merge(sih[PROC_REA %chin% PARTOS$PROC], PARTOS, by.x = "PROC_REA", by.y = "PROC")
  pt <- pt[, .(PARTOS = sum(N_AIH[INTERNACAO]), VALOR_TOTAL = sum(VALOR_TOTAL)),
           by = .(COMPETENCIA, CNES, TIPO_PARTO, DETALHE, PROC = PROC_REA)]
  pt <- merge(pt, proc[, .(PROC, NO_PROCEDIMENTO)], by = "PROC", all.x = TRUE)
  setcolorder(pt, c("COMPETENCIA", "CNES", "TIPO_PARTO", "DETALHE", "PROC", "NO_PROCEDIMENTO"))
  pt <- com_unidade(pt, unidades)
  pt_tipo <- dcast(pt, ANO + MES + COMPETENCIA + TIPO_REDE + MODELO_GESTAO + CNES + UNIDADE + TIPO_UNIDADE +
                     MUNICIPIO + REGIAO_SAUDE ~ TIPO_PARTO, value.var = "PARTOS", fun.aggregate = sum)
  tipos_pt <- intersect(c("Parto normal", "Parto cesáreo"), names(pt_tipo))
  pt_tipo[, PARTOS_TOTAL := rowSums(.SD), .SDcols = tipos_pt]
  if ("Parto cesáreo" %in% names(pt_tipo)) pt_tipo[, PERC_CESAREO := round(100 * `Parto cesáreo` / PARTOS_TOTAL, 1)]
  pt_tipo[, ORDEM_ := match(TIPO_REDE, c("Rede própria", "OSS", "Complementar"))]
  setorder(pt_tipo, ANO, COMPETENCIA, ORDEM_, UNIDADE)[, ORDEM_ := NULL]
  gravar_tema("07_partos", list(`Por tipo de parto` = pt_tipo, Detalhe = pt), "Partos realizados",
              paste("AIH normal (IDENT 1) pelo procedimento realizado:", paste(sprintf("%s (%s, %s)", PARTOS$PROC,
                    tolower(PARTOS$TIPO_PARTO), tolower(PARTOS$DETALHE)), collapse = "; ")),
              atualizacao, csv = pt)

  gravar_csv(data.table(FONTE = c("SIA", "SIH"), ULTIMO_MES = c(max(sia$PA_MVM), max(sih$COMPETENCIA)),
                        GERADO_EM = atualizacao$em), file.path(PLAN, "atualizacao.csv"))
  dir.create(dirname(arq_hash), recursive = TRUE, showWarnings = FALSE)
  writeLines(hash, arq_hash)
}

if (sys.nframe() == 0L) main()
