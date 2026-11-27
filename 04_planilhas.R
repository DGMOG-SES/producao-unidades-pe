#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# 04 - Planilhas de produção e valor por unidade de saúde (PE, 2019 a 2026)
#
# Lê as bases do SIA (02_sia.R) e do SIH (03_sih.R), classifica as unidades e
# grava uma planilha Excel por tema, seguindo as tabulações do TabWin usadas
# pela SES (RD_PE.DEF e Prod_PE.def). Em todas: produção | valor por ano.
#
#   01_procedimentos_ambulatoriais   SIA, todos os grupos SIGTAP: qtd. e valor aprovados
#                                    abas Geral (grupo × ano) e Unidades
#   02_internamentos                 SIH, grupo do procedimento realizado (02 a 05):
#                                    AIH (normais e de longa permanência) e valor total
#                                    abas Geral (grupo × ano) e uma por grupo (unidades)
#   03_consultas_medicas_especializadas   SIA 0301010072: abas Geral (CBO) e Unidades
#   04_consultas_multiprofissionais       SIA 0301010048: abas Geral (CBO) e Unidades
#   05_partos                        SIH, procedimentos do PROCOBS2C.CNV, TODO O ESTADO,
#                                    por gestão: abas Geral (tipo e subtipo × gestão)
#                                    e Parto normal / Parto cesáreo (unidades por gestão)
#   06_leitos                        CNES-LT, dezembro de cada ano: existentes | SUS, por gestão
#   07_cuida_pe                      indicadores do Cuida PE: consultas nas 15 UPAEs, cirurgias
#                                    por caráter e gestão (e proporção), RNM e TC, eletivas
#                                    da Portaria 339 por mês
#   00_unidades                      cadastro das unidades que aparecem nas planilhas
#
# Temas 01 a 04: toda a produção sob GESTÃO ESTADUAL (como o filtro "Gestao:
# ESTADUAL" do TabWin; os totais batem com ele). As unidades são classificadas em:
#   Rede própria / OSS   lista validada (REDE_PROPRIA_ESTADUAL, ESTADUAL_ADM_INDIRETA)
#   Rede própria         administração pública estadual no CNES fora da lista
#                        ("Estadual fora da lista SES")
#   Complementar         referências fora da rede da lista validada (ex.: Hospital
#                        das Clínicas) e prestadores privados/filantrópicos
#   Outro público        públicos não estaduais (ex.: "Pública municipal")
# Gestão, como no TabWin: SIH campo GESTAO (E/2 estadual, M/1 municipal); SIA
# PA_CONDIC (E estadual, P municipal, D dupla).
#
# Período: competência = mês de processamento (SIH ANO_CMPT/MES_CMPT; SIA PA_MVM).
# Só regera as planilhas quando alguma entrada mudou.
# Uso: Rscript 04_planilhas.R [--forcar]
# ------------------------------------------------------------------------------

source("utils.R")

SAIDA <- file.path(CFG$dir_dados, "saida")
REF   <- file.path(CFG$dir_dados, "referencias")
PLAN  <- CFG$dir_planilhas

# ---- Regras de cada tema (editar aqui) ----------------------------------------

GRUPOS_PROC <- c("02", "03", "04", "05")
ABA_GRUPO   <- c("02" = "02 Diagnóstico", "03" = "03 Clínicos", "04" = "04 Cirúrgicos", "05" = "05 Transplantes")

# Rótulos do cabeçalho das tabelas
ROTULOS <- c(GRUPO_PROC = "Grupo de procedimento", ESPECIALIDADE = "Especialidade (CBO)",
             CARATER = "Caráter de atendimento", FONTE = "Fonte", SUBGRUPO = "Subgrupo de procedimento", ANO_EXEC = "Ano",
             TIPO_DE_PARTO = "Tipo de parto", TIPO_DE_LEITO = "Tipo de leito", ESPECIALIDADE_LEITO = "Especialidade do leito", PROCEDIMENTO = "Procedimento", GESTAO = "Gestão",
             TIPO_REDE = "Tipo de rede", MODELO_GESTAO = "Modelo de gestão", CNES = "CNES", UNIDADE = "Unidade",
             MUNICIPIO = "Município", REGIAO_SAUDE = "Região de saúde",
             TIPO_DE_ESTABELECIMENTO = "Tipo de estabelecimento", TIPO_UNIDADE = "Tipo de estabelecimento",
             NATUREZA_LEITO = "Natureza", ADMINISTRACAO = "Tipo de administração")
CONSULTA_MEDICA_ESPECIALIZADA <- "0301010072"
CONSULTA_MULTIPROFISSIONAL    <- "0301010048"

# Igual ao PROCOBS2C.CNV do TabWin da SES (variável "Proced obst")
PARTOS <- data.table(
  PROC = c("0310010039", "0310010047", "0310010055", "0411010034", "0411010026", "0411010042"),
  TIPO_PARTO = rep(c("Parto normal", "Parto cesáreo"), each = 3),
  SUBTIPO = c("Parto normal", "Parto normal em gestação de alto risco", "Parto normal em centro de parto normal",
              "Cirurgia cesariana", "Cirurgia cesariana em gestação de alto risco",
              "Cirurgia cesariana c/ laqueadura tubária"))

# Cuida PE
UPAES_CUIDA <- c("0151475", "3460967", "3489302", "3840301", "7296762", "7297394", "7381344", "7465386",
                 "7472552", "7478364", "7484860", "7490534", "7490569", "9229221", "9620508")
SUBGRUPOS_IMAGEM <- c("0206" = "0206 Diagnóstico por tomografia", "0207" = "0207 Diagnóstico por ressonância magnética")
CARATER_CIR <- c("01" = "Eletivo", "02" = "Urgência")   # CARATEND.CNV / CARAT_AT.CNV: urgência = 02
MESES <- c("jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez")

NAT_JUR_ESTADUAL <- c("1023", "1058", "1082", "1112", "1147", "1171", "1236", "1260", "1295", "1325")
NAT_JUR_PUBLICA_EMPRESARIAL <- c("2011", "2038")
ORDEM_REDE <- c("Rede própria", "OSS", "Complementar", "Outro público", "Não identificado")
ORDEM_MODELO <- c("06 grandes", "Gestão direta", "Administração indireta", "Estadual fora da lista SES", "OSS")

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
                "60" = "Cooperativa ou empresa de cessão de trabalhadores na saúde",
                "67" = "Laboratório central de saúde pública (LACEN)",
                "71" = "Centro de apoio à saúde da família", "84" = "Central de abastecimento",
                "82" = "Central de notificação, captação e distribuição de órgãos",
                "83" = "Polo de prevenção e promoção da saúde", "85" = "Centro de imunização")


# ---- SIGTAP e nomes dos estabelecimentos -----------------------------------------

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


# ---- Classificação -------------------------------------------------------------

gestao_sih <- function(x) fcase(x %chin% c("E", "2"), "Estadual", x %chin% c("M", "1"), "Municipal",
                                default = "Não definida")
# PA_CONDIC vem com 2 letras (ex.: "EP", "PG"); o Prod_PE.def lê só a 1ª (TPGESTAO.CNV).
gestao_sia <- function(x) { x <- substr(x, 1, 1)
  fcase(x == "E", "Estadual", x == "P", "Municipal", x == "D", "Dupla",
                                default = "Não informada") }

# Classifica os CNES. mun_prod: município do estabelecimento tirado da produção,
# usado quando o CNES não está no cadastro (CNES-ST).
montar_unidades <- function(mun_prod) {
  val <- ler_validados()
  st  <- if (file.exists(file.path(REF, "cnes_st_pe.csv"))) ler_csv(file.path(REF, "cnes_st_pe.csv")) else
    data.table(CNES = character(), CODUFMUN = character(), TP_UNID = character(), NAT_JUR = character(), ESFERA_A = character())
  u <- unique(mun_prod, by = "CNES")
  u <- merge(u, st[, .(CNES, CODUFMUN, TP_UNID, NAT_JUR, ESFERA_A)], by = "CNES", all.x = TRUE)
  u[, CODUFMUN := fcoalesce(CODUFMUN, MUN_PROD)]
  u <- merge(u, val[, .(CNES, NOME_LISTA = NOME_FANTASIA, TIPO_LISTA = TIPO, VINCULO, MODELO_GESTAO)],
             by = "CNES", all.x = TRUE)
  u[, NATUREZA := natureza(NAT_JUR, ESFERA_A)]
  u[, LISTA_PROPRIA := VINCULO %chin% c("REDE_PROPRIA_ESTADUAL", "ESTADUAL_ADM_INDIRETA")]
  u[, TIPO_REDE := fcase(
    LISTA_PROPRIA & MODELO_GESTAO == "OSS", "OSS",
    LISTA_PROPRIA, "Rede própria",
    VINCULO == "REFERENCIA_FORA_DA_REDE", "Complementar",
    NAT_JUR %chin% NAT_JUR_ESTADUAL, "Rede própria",
    NATUREZA == "Privada/filantrópica", "Complementar",
    NATUREZA == "Pública", "Outro público",
    default = "Não identificado")]
  u[!LISTA_PROPRIA & TIPO_REDE == "Rede própria", MODELO_GESTAO := "Estadual fora da lista SES"]
  u[TIPO_REDE == "Complementar", MODELO_GESTAO := "Complementar"]
  u[TIPO_REDE %chin% c("Outro público", "Não identificado"), MODELO_GESTAO := NATUREZA]
  u[TIPO_REDE == "Outro público" & ESFERA_A %chin% "M", MODELO_GESTAO := "Pública municipal"]
  u[TIPO_REDE == "Outro público" & ESFERA_A %chin% "F", MODELO_GESTAO := "Pública federal"]
  u[, NA_LISTA_SES := fifelse(is.na(VINCULO), "Não", "Sim")]
  u[, TIPO_UNIDADE := fcoalesce(TIPO_LISTA, unname(TIPOS_CNES[TP_UNID]),
                                fifelse(is.na(TP_UNID), "Não informado", paste("Tipo", TP_UNID)))]
  mun <- ler_csv("referencias/municipios_regiao_saude_pe.csv")
  u <- merge(u, mun[, .(CODUFMUN = CO_MUNICIPIO, MUNICIPIO, REGIAO_SAUDE, MACRORREGIAO)], by = "CODUFMUN", all.x = TRUE)
  u[, .(CNES, NOME_LISTA, TIPO_REDE, MODELO_GESTAO = fcoalesce(MODELO_GESTAO, ""), LISTA_PROPRIA, TIPO_UNIDADE,
        NATUREZA, NAT_JUR = fcoalesce(NAT_JUR, ""), NA_LISTA_SES, MUNICIPIO = fcoalesce(MUNICIPIO, ""),
        REGIAO_SAUDE = fcoalesce(REGIAO_SAUDE, ""), MACRORREGIAO = fcoalesce(MACRORREGIAO, ""))]
}

# Nomes: da lista validada; os demais pela API do CNES (com cache)
nomear <- function(u) {
  falta <- u[is.na(NOME_LISTA)]$CNES
  nomes <- tryCatch(nomes_cnes(falta), error = function(e) {
    log_msg("API CNES indisponível: %s", conditionMessage(e))
    data.table(CNES = character(), NOME_FANTASIA = character(), RAZAO_SOCIAL = character())
  })
  u <- merge(u, nomes, by = "CNES", all.x = TRUE)
  u[, UNIDADE := fcoalesce(NOME_LISTA, NOME_FANTASIA, RAZAO_SOCIAL, paste("CNES", CNES))]
  u[, c("NOME_LISTA", "NOME_FANTASIA", "RAZAO_SOCIAL") := NULL][]
}

# Rede estadual (temas 01 a 04): unidades da lista (rede própria e OSS) com toda a
# produção; complementar e estaduais fora da lista, só sob gestão estadual.
rede_estadual <- function(dt, unidades) {
  # Toda a produção sob gestão estadual, de qualquer unidade (= filtro do TabWin)
  dt[GESTAO == "Estadual"][CNES %chin% unidades$CNES]
}

# ---- Tabelas no formato "produção | valor por ano" ------------------------------

# ag: colunas ids + ANO + QTD + VALOR. Devolve ids + QTD_aaaa, VALOR_aaaa por ano.
largo <- function(ag, ids, anos) {
  ag <- ag[, .(QTD = sum(QTD), VALOR = round(sum(VALOR), 2)), by = c(ids, "ANO")]
  w <- dcast(ag, as.formula(paste(paste0("`", ids, "`", collapse = " + "), "~ ANO")),
             value.var = c("QTD", "VALOR"), fill = 0, sep = "_")
  for (a in anos) for (m in c("QTD", "VALOR")) if (!paste0(m, "_", a) %in% names(w)) set(w, j = paste0(m, "_", a), value = 0)
  setcolorder(w, c(ids, as.vector(rbind(paste0("QTD_", anos), paste0("VALOR_", anos)))))
  w
}

somar_linha <- function(w, cols_val, rotulos) {
  t <- w[, lapply(.SD, sum), .SDcols = cols_val]
  for (nm in names(rotulos)) set(t, j = nm, value = rotulos[[nm]])
  t
}

# rotulo_qtd: nome da 1ª coluna de cada ano. A 2ª é "Valor (R$)", salvo se
# 'rotulos' trouxer os dois nomes (ex.: leitos, c("Existentes", "SUS")).
tabela <- function(dados, ids, anos, rotulo_qtd, linhas_total, larguras, rotulos = NULL, formatos = NULL) {
  for (cl in ids) set(dados, which(is.na(dados[[cl]])), cl, "")
  structure(list(dados = dados, ids = ids, anos = anos,
                 rotulos = rotulos %||% c(rotulo_qtd, "Valor (R$)"),
                 formatos = formatos %||% c("#,##0", "#,##0.00"),
                 linhas_total = linhas_total, larguras = larguras), class = "tabela_anual")
}

# Geral: uma linha por categoria (grupo, CBO...), total geral ao final.
geral <- function(dt, dims, anos, rotulo_qtd, larguras, ...) {
  w <- largo(dt, dims, anos)
  setorderv(w, dims)
  cols_val <- setdiff(names(w), dims)
  w <- rbind(w, somar_linha(w, cols_val, setNames(list("Total geral"), dims[1])), fill = TRUE)
  tabela(w, dims, anos, rotulo_qtd, nrow(w), larguras, ...)
}

# Categoria (e subcategoria) × gestão, com total por gestão de cada categoria e
# total geral. Usado nos partos (tipo e procedimento) e nos leitos.
por_gestao <- function(dt, n1, n2 = NULL, anos, ordem1, ordem2 = NULL, rotulo_qtd, larguras, ...) {
  ord_gestao <- c("Estadual", "Municipal", "Dupla", "Sem gestão", "Não definida", "Não informada", "Total")
  dims <- c(n1, n2)
  ag <- dt[, .(QTD = sum(QTD), VALOR = sum(VALOR)), by = c(dims, "GESTAO", "ANO")]
  partes <- list(ag)
  if (!is.null(n2)) partes[[2]] <- dt[, .(QTD = sum(QTD), VALOR = sum(VALOR)), by = c(n1, "GESTAO", "ANO")][, (n2) := "Total"]
  partes[[length(partes) + 1]] <- dt[, .(QTD = sum(QTD), VALOR = sum(VALOR)), by = .(GESTAO, ANO)][, (n1) := "Total geral"]
  ag <- rbindlist(partes, use.names = TRUE, fill = TRUE)
  if (!is.null(n2)) ag[is.na(get(n2)), (n2) := ""]
  ag <- rbind(ag, ag[, .(GESTAO = "Total", QTD = sum(QTD), VALOR = sum(VALOR)), by = c(dims, "ANO")])
  w <- largo(ag, c(dims, "GESTAO"), anos)
  w[, O1_ := match(get(n1), c(ordem1, "Total geral"), nomatch = 98L)]
  w[, O2_ := if (is.null(n2)) 0L else fifelse(get(n2) == "Total", 999L, match(get(n2), ordem2, nomatch = 500L))]
  w[, O3_ := match(GESTAO, ord_gestao, nomatch = 50L)]
  setorder(w, O1_, O2_, O3_)
  tot <- which(w$GESTAO == "Total" | w[[n1]] == "Total geral" | (if (is.null(n2)) FALSE else w[[n2]] == "Total"))
  w[, c("O1_", "O2_", "O3_") := NULL]
  tabela(w, c(dims, "GESTAO"), anos, rotulo_qtd, tot, larguras, ...)
}

# Unidades: uma linha por unidade (e por valor de 'agrupar', quando ele vem da
# produção, como a gestão nos partos), subtotal por grupo e total geral.
# Sem a coluna Modelo de gestão nas planilhas (pedido da área); ela só ordena as linhas.
COLS_UNID <- c("TIPO_REDE", "CNES", "UNIDADE", "MUNICIPIO", "REGIAO_SAUDE")
unidades_ano <- function(dt, unidades, anos, rotulo_qtd, agrupar = "TIPO_REDE", ..., cols = COLS_UNID) {
  chave <- unique(c(if (agrupar %in% names(dt)) agrupar, "CNES"))
  w <- largo(dt, chave, anos)
  cols_val <- setdiff(names(w), chave)
  w <- w[rowSums(abs(as.matrix(w[, ..cols_val]))) > 0]
  w <- merge(unidades[, unique(c(cols, "TIPO_REDE", "MODELO_GESTAO")), with = FALSE], w, by = "CNES")
  ids <- unique(c(agrupar, cols))
  setcolorder(w, c(ids, cols_val))
  ordem_grupo <- if (agrupar == "TIPO_REDE") ORDEM_REDE else
    c("Estadual", "Municipal", "Dupla", "Sem gestão", "Não definida", "Não informada")
  w[, `:=`(O1_ = match(get(agrupar), ordem_grupo, nomatch = 99L),
           O2_ = match(TIPO_REDE, ORDEM_REDE, nomatch = 99L),
           O3_ = match(MODELO_GESTAO, ORDEM_MODELO, nomatch = 99L))]
  setorder(w, O1_, O2_, O3_, UNIDADE)
  partes <- lapply(split(w, by = "O1_", sorted = TRUE), function(x) {
    st <- somar_linha(x, cols_val, setNames(list(x[[agrupar]][1], paste("Subtotal", x[[agrupar]][1])),
                                            c(agrupar, "UNIDADE")))
    rbind(x, st, fill = TRUE)
  })
  out <- rbindlist(partes, fill = TRUE)
  out <- rbind(out, somar_linha(w, cols_val, list(UNIDADE = "Total geral")), fill = TRUE)
  out[, intersect(c("O1_", "O2_", "O3_", "MODELO_GESTAO", setdiff("TIPO_REDE", ids)), names(out)) := NULL]
  setcolorder(out, c(ids, cols_val))
  tot <- which(startsWith(fcoalesce(out$UNIDADE, ""), "Subtotal") | out$UNIDADE == "Total geral")
  larg <- c(TIPO_REDE = 14, GESTAO = 12, MODELO_GESTAO = 22, CNES = 10, UNIDADE = 45, TIPO_UNIDADE = 30,
            MUNICIPIO = 20, REGIAO_SAUDE = 26)
  tabela(out, ids, anos, rotulo_qtd, tot, unname(larg[ids]), ...)
}

# ---- Excel -----------------------------------------------------------------------

escrever_tabela <- function(wb, aba, r, ref = NULL) {
  n_id <- length(r$ids); n_anos <- length(r$anos)
  rot_anos <- as.character(r$anos)
  # "*" no último ano quando ele é o ano do último mês de referência
  marca <- !is.null(ref) && is.numeric(r$anos) && as.character(max(r$anos)) == substr(ref$mes, 1, 4)
  if (marca) rot_anos[n_anos] <- paste0(rot_anos[n_anos], "*")
  cab1 <- c(fcoalesce(unname(ROTULOS[r$ids]), r$ids), as.vector(rbind(rot_anos, "")))
  cab2 <- c(rep("", n_id), rep(r$rotulos, n_anos))
  openxlsx::writeData(wb, aba, t(cab1), startRow = 1, colNames = FALSE)
  openxlsx::writeData(wb, aba, t(cab2), startRow = 2, colNames = FALSE)
  for (i in seq_len(n_id)) openxlsx::mergeCells(wb, aba, cols = i, rows = 1:2)
  for (k in seq_len(n_anos)) { c0 <- n_id + (k - 1) * 2 + 1; openxlsx::mergeCells(wb, aba, cols = c0:(c0 + 1), rows = 1) }
  openxlsx::writeData(wb, aba, r$dados, startRow = 3, colNames = FALSE)
  ncol <- ncol(r$dados); nlin <- nrow(r$dados)
  openxlsx::addStyle(wb, aba, openxlsx::createStyle(textDecoration = "bold", halign = "center", valign = "center",
                                                    fgFill = "#DCE6F1", border = "TopBottomLeftRight", wrapText = TRUE),
                     rows = 1:2, cols = 1:ncol, gridExpand = TRUE)
  cols_num <- (n_id + 1):ncol
  for (j in seq_along(cols_num)) openxlsx::addStyle(wb, aba, openxlsx::createStyle(numFmt = r$formatos[2 - j %% 2]),
                                                     rows = 3:(nlin + 2), cols = cols_num[j], stack = TRUE)
  if (length(r$linhas_total)) openxlsx::addStyle(wb, aba, openxlsx::createStyle(textDecoration = "bold", fgFill = "#F2F2F2"),
                                                 rows = r$linhas_total + 2, cols = 1:ncol, gridExpand = TRUE, stack = TRUE)
  openxlsx::setColWidths(wb, aba, cols = 1:n_id, widths = r$larguras)
  openxlsx::setColWidths(wb, aba, cols = cols_num, widths = 15)
  openxlsx::freezePane(wb, aba, firstActiveRow = 3, firstActiveCol = n_id + 1)
  if (marca) {
    openxlsx::writeData(wb, aba, paste0("* ", ref$texto), startRow = nlin + 4, startCol = 1, colNames = FALSE)
    openxlsx::addStyle(wb, aba, openxlsx::createStyle(textDecoration = "italic"), rows = nlin + 4, cols = 1)
  }
}

# Último mês de referência de cada planilha (preenchido no main): o último ano
# das tabelas leva "*" e uma nota embaixo com o mês.
REF_PLANILHA <- list()
mes_txt <- function(aaaamm) {
  if (!length(aaaamm) || is.na(aaaamm)) return(NA_character_)
  m <- c("jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez")
  paste0(m[as.integer(substr(aaaamm, 5, 6))], "/", substr(aaaamm, 1, 4))
}

leia_me <- function(titulo, regras, atualizacao, itens = NULL) {
  x <- data.table(
    Item = c("Tema", "Regra", "Formato", "Período", "Unidades", "Valor", "Meses recentes", "Fonte", "Atualizado em"),
    Texto = c(titulo, regras,
              "Para cada ano: produção (quantidade) e valor (R$). Subtotais e total geral em negrito.",
              sprintf(paste("Competência (mês de processamento) de %s a %s; dados até %s. A série completa",
                            "vai de %s; anos ainda não carregados entram automaticamente."),
                      atualizacao$desde, paste0(substr(CFG$fim, 5, 6), "/", substr(CFG$fim, 1, 4)), atualizacao$ultimo,
                      paste0(substr(CFG$inicio, 5, 6), "/", substr(CFG$inicio, 1, 4))),
              paste("Toda a produção sob gestão estadual (igual ao filtro Gestao: ESTADUAL do TabWin da SES; campo",
                    "GESTAO da AIH no SIH e PA_CONDIC no SIA). Unidades classificadas em rede própria e OSS (lista",
                    "validada pela SES), rede própria fora da lista, complementar (referências fora da rede e",
                    "privados/filantrópicos) e outro público (ex.: municipal sob gestão estadual)."),
              paste("Tabela SUS (SIGTAP): valor aprovado no SIA e valor total da AIH no SIH. Não inclui complementos",
                    "estaduais, incentivos nem repasses de contratos de gestão das OSS."),
              "Os últimos 3 a 4 meses ainda recebem produção com atraso; leia-os como parciais.",
              "DATASUS (SIA-PA, SIH-RD, CNES-ST e SIGTAP), FTP público. Mesmos arquivos do TabWin (T:\\TabSia08, T:\\Tabaih08).",
              atualizacao$em))
  for (nm in names(itens)) x[Item == nm, Texto := itens[[nm]]]
  setnames(x, "Texto", "Descrição")
}

gravar_planilha <- function(nome, abas, titulo, regras, atualizacao, csv = NULL, itens = NULL) {
  dir.create(file.path(PLAN, "csv"), recursive = TRUE, showWarnings = FALSE)
  wb <- openxlsx::createWorkbook()
  # Sem aba Leia-me (pedido da área): as regras de cada tema ficam no README.
  for (nm in names(abas)) {
    openxlsx::addWorksheet(wb, nm)
    ref <- REF_PLANILHA[[substr(nome, 1, 2)]]
    if (inherits(abas[[nm]], "tabela_anual")) escrever_tabela(wb, nm, abas[[nm]], ref) else {
      openxlsx::writeData(wb, nm, abas[[nm]], headerStyle = openxlsx::createStyle(textDecoration = "bold"))
      openxlsx::freezePane(wb, nm, firstRow = TRUE)
      if (!is.null(attr(abas[[nm]], "larguras")))
        openxlsx::setColWidths(wb, nm, cols = seq_along(attr(abas[[nm]], "larguras")), widths = attr(abas[[nm]], "larguras"))
      if (!is.null(attr(abas[[nm]], "linhas_total")))
        openxlsx::addStyle(wb, nm, openxlsx::createStyle(textDecoration = "bold"), rows = attr(abas[[nm]], "linhas_total") + 1,
                           cols = seq_len(ncol(abas[[nm]])), gridExpand = TRUE, stack = TRUE)
      num <- which(vapply(abas[[nm]], is.numeric, TRUE))
      if (length(num)) openxlsx::addStyle(wb, nm, openxlsx::createStyle(numFmt = "#,##0"), rows = seq_len(nrow(abas[[nm]])) + 1,
                                          cols = num, gridExpand = TRUE, stack = TRUE)
      if (!is.null(attr(abas[[nm]], "nota"))) {
        openxlsx::writeData(wb, nm, attr(abas[[nm]], "nota"), startRow = nrow(abas[[nm]]) + 3, colNames = FALSE)
        openxlsx::addStyle(wb, nm, openxlsx::createStyle(textDecoration = "italic"), rows = nrow(abas[[nm]]) + 3, cols = 1)
      }
    }
  }
  gravar_atomico(function(f) openxlsx::saveWorkbook(wb, f, overwrite = TRUE), file.path(PLAN, paste0(nome, ".xlsx")))
  if (!is.null(csv)) gravar_atomico(function(f) fwrite(csv, f, sep = ";", dec = ",", bom = TRUE),
                                    file.path(PLAN, "csv", paste0(nome, ".csv")))
  linhas <- vapply(abas, function(a) if (inherits(a, "tabela_anual")) nrow(a$dados) else nrow(a), 1L)
  log_msg("%s.xlsx: %s", nome, paste(sprintf("%s (%s)", names(abas), linhas), collapse = "; "))
}

# Base longa (CSV) de um tema: uma linha por unidade, dimensão e ano
csv_tema <- function(dt, unidades, dims) {
  x <- dt[, .(QTD = sum(QTD), VALOR = round(sum(VALOR), 2)), by = c("ANO", "CNES", dims)]
  x <- merge(unidades[, ..COLS_UNID], x, by = "CNES")
  setcolorder(x, c("ANO", COLS_UNID, dims))
  setorderv(x, c("ANO", "TIPO_REDE", "UNIDADE", dims))
  x
}

# Primeiro ano (AAAA01) a partir do qual SIA e SIH têm todos os meses na base,
# pelos controles de extração. O ano corrente conta até o último mês baixado.
meses_ctl <- function(arq, chave) {
  f <- file.path(CFG$dir_dados, "controle", arq)
  if (file.exists(f)) ler_csv(f)[[chave]] else character()
}
meses_sia <- function() meses_ctl("sia_processados_v3.csv", "mvm")
meses_sih <- function() meses_ctl("sih_processados_v2.csv", "mes")

primeiro_ano_completo <- function() {
  meses <- intersect(meses_sia(), meses_sih())
  if (!length(meses)) return(CFG$inicio)
  ultimo <- max(meses)
  anos <- rev(seq(as.integer(substr(CFG$inicio, 1, 4)), as.integer(substr(ultimo, 1, 4))))
  inicio <- NULL
  for (a in anos) {
    esperados <- sprintf("%d%02d", a, 1:12)
    esperados <- esperados[esperados <= ultimo]
    if (all(esperados %chin% meses)) inicio <- sprintf("%d01", a) else break
  }
  inicio %||% CFG$inicio
}

# ---- Principal ---------------------------------------------------------------------

main <- function() {
  arq_sia <- file.path(SAIDA, "sia_unidades.parquet")
  arq_sih <- file.path(SAIDA, "sih_unidades.parquet")
  if (!file.exists(arq_sia) || !file.exists(arq_sih)) {
    log_msg("Planilhas não geradas: faltam as bases do SIA e/ou do SIH (rode 02_sia.R e 03_sih.R)")
    return(invisible(NULL))
  }
  entradas <- c(arq_sia, arq_sih, file.path(SAIDA, "leitos.parquet"), file.path(REF, "cnes_st_pe.csv"), "referencias/estabelecimentos_validados.csv",
                "referencias/municipios_regiao_saude_pe.csv", "04_planilhas.R",
                "referencias/leitos_tipo.csv", "referencias/leitos_especialidade.csv",
                list.files(file.path(CFG$dir_dados, "cnes_st"), "\\.parquet$", full.names = TRUE),
                file.path(CFG$dir_dados, "controle", c("sia_processados_v3.csv", "sih_processados_v2.csv")))
  hash <- paste(tools::md5sum(entradas[file.exists(entradas)]), collapse = "")
  arq_hash <- file.path(CFG$dir_dados, "controle", "planilhas_hash.txt")
  if (!tem_flag("forcar") && file.exists(arq_hash) && identical(readLines(arq_hash), hash) &&
      file.exists(file.path(PLAN, "02_internamentos.xlsx"))) {
    log_msg("Entradas sem mudança; planilhas mantidas.")
    return(invisible(NULL))
  }

  arq_lt <- file.path(SAIDA, "leitos.parquet")
  # Se o 01b não consolidou (ex.: FTP fora do ar), monta a base com as partições já baixadas
  if (!file.exists(arq_lt) && length(list.files(file.path(CFG$dir_dados, "leitos"), "\\.parquet$")))
    consolidar(file.path(CFG$dir_dados, "leitos"), arq_lt)
  lt <- NULL
  # As planilhas começam no primeiro ano completo na base (SIA e SIH com todos
  # os meses daquele ano em diante): durante a carga histórica, os anos antigos
  # entram sozinhos à medida que são baixados.
  inicio <- primeiro_ano_completo()
  log_msg("Planilhas a partir de %s", inicio)
  # Só os meses registrados como baixados no layout atual: partições antigas
  # (layout anterior, ainda não refeitas) ficam de fora até serem refeitas.
  sia <- ler_parquet(arq_sia)[PA_MVM >= inicio & PA_MVM <= CFG$fim & PA_MVM %chin% meses_sia()]
  if (file.exists(arq_lt)) lt <- ler_parquet(arq_lt)[COMPETENCIA >= inicio & COMPETENCIA <= CFG$fim]
  sih <- ler_parquet(arq_sih)[COMPETENCIA >= inicio & COMPETENCIA <= CFG$fim & COMPETENCIA %chin% meses_sih()]
  for (cl in c("PA_CONDIC", "PA_UFMUN", "PA_CATEND")) if (!cl %in% names(sia)) set(sia, j = cl, value = NA_character_)
  for (cl in c("TP_GESTAO", "MUNIC_MOV")) if (!cl %in% names(sih)) set(sih, j = cl, value = NA_character_)
  sia[, `:=`(ANO = as.integer(substr(PA_MVM, 1, 4)), GESTAO = gestao_sia(PA_CONDIC),
             GRUPO = substr(PA_PROC_ID, 1, 2), QTD = QTD_APROVADA, VALOR = VALOR_APROVADO)]
  sih[, `:=`(ANO = as.integer(substr(COMPETENCIA, 1, 4)), GESTAO = gestao_sih(TP_GESTAO),
             GRUPO = substr(PROC_REA, 1, 2), QTD = N_AIH, VALOR = VALOR_TOTAL)]
  log_msg("Gestão (registros) SIA: %s | SIH: %s",
          paste(sia[, .N, by = GESTAO][, paste(GESTAO, N, sep = "=")], collapse = ", "),
          paste(sih[, .N, by = GESTAO][, paste(GESTAO, N, sep = "=")], collapse = ", "))
  anos <- seq(as.integer(substr(inicio, 1, 4)), max(c(sia$ANO, sih$ANO)))

  # Cadastro de dezembro de cada ano (01_unidades.R), para os estabelecimentos SUS
  arqs_st <- list.files(file.path(CFG$dir_dados, "cnes_st"), "\\.parquet$", full.names = TRUE)
  st_ano <- if (length(arqs_st)) rbindlist(lapply(arqs_st, ler_parquet), use.names = TRUE, fill = TRUE) else NULL
  if (!is.null(st_ano)) {
    st_ano[, ANO := as.integer(substr(COMPETENCIA, 1, 4))]
    st_ano <- st_ano[ANO %in% anos & VINC_SUS == "1"]
  }
  mun_prod <- rbind(sia[, .(CNES, MUN_PROD = PA_UFMUN)], sih[, .(CNES, MUN_PROD = MUNIC_MOV)],
                    if (!is.null(lt)) lt[, .(CNES, MUN_PROD = CODUFMUN)],
                    if (!is.null(st_ano)) st_ano[, .(CNES, MUN_PROD = CODUFMUN)])
  unidades <- montar_unidades(mun_prod)

  sig <- sigtap()
  grupos <- unique(sig$proc[, .(GRUPO = CO_GRUPO, NO_GRUPO)])
  nome_grupo <- function(g) fcoalesce(grupos$NO_GRUPO[match(g, grupos$GRUPO)], paste("Grupo", g))

  # Bases de cada tema (já filtradas)
  amb  <- rede_estadual(sia, unidades)   # todos os grupos do SIGTAP
  int  <- rede_estadual(sih[GRUPO %chin% GRUPOS_PROC], unidades)
  cons <- function(cod) {
    x <- rede_estadual(sia[PA_PROC_ID == cod], unidades)
    x <- merge(x, sig$ocup, by = "CBO", all.x = TRUE)
    x[, ESPECIALIDADE := fifelse(!is.na(NO_OCUPACAO), paste(CBO, NO_OCUPACAO),
                                 fifelse(is.na(CBO) | CBO == "", "CBO não informado", paste("CBO", CBO)))]
    x
  }
  cm <- cons(CONSULTA_MEDICA_ESPECIALIZADA)
  cs <- cons(CONSULTA_MULTIPROFISSIONAL)
  pt <- merge(sih[PROC_REA %chin% PARTOS$PROC], PARTOS, by.x = "PROC_REA", by.y = "PROC")

  # Nomes só das unidades que aparecem em algum tema
  usados <- unique(c(amb$CNES, int$CNES, cm$CNES, cs$CNES, pt$CNES, lt$CNES, st_ano$CNES))
  unidades <- nomear(unidades[CNES %chin% usados])
  unidades[, O_ := match(TIPO_REDE, ORDEM_REDE, nomatch = 99L)]
  setorder(unidades, O_, MODELO_GESTAO, UNIDADE)[, O_ := NULL]

  atualizacao <- list(
    desde = paste0(substr(inicio, 5, 6), "/", substr(inicio, 1, 4)),
    ultimo = sprintf("SIA %s/%s, SIH %s/%s", substr(max(sia$PA_MVM), 5, 6), substr(max(sia$PA_MVM), 1, 4),
                     substr(max(sih$COMPETENCIA), 5, 6), substr(max(sih$COMPETENCIA), 1, 4)),
    em = format(Sys.time(), "%d/%m/%Y %H:%M", tz = "America/Recife"))

  # Último mês de referência por planilha (prefixo do nome do arquivo)
  ult <- list(sia = max(sia$PA_MVM), sih = max(sih$COMPETENCIA),
              lt = if (!is.null(lt) && nrow(lt)) max(lt$COMPETENCIA),
              st = if (!is.null(st_ano) && nrow(st_ano)) max(st_ano$COMPETENCIA))
  ref_prod <- function(m, fonte) list(mes = m, texto = sprintf("Dados preliminares até %s (%s), sujeitos a alteração.",
                                                                mes_txt(m), fonte))
  ref_cnes <- function(m) if (!is.null(m)) list(mes = m, texto = sprintf(
    "Dados preliminares de %s, sujeitos a alteração.", mes_txt(m)))
  cuida <- if (ult$sia == ult$sih) ref_prod(ult$sia, "SIA e SIH") else
    list(mes = max(ult$sia, ult$sih), texto = sprintf("Dados preliminares até %s no SIA e %s no SIH, sujeitos a alteração.",
                                                      mes_txt(ult$sia), mes_txt(ult$sih)))
  REF_PLANILHA <<- list(`01` = ref_prod(ult$sia, "SIA"), `02` = ref_prod(ult$sih, "SIH"),
                        `03` = ref_prod(ult$sia, "SIA"), `04` = ref_prod(ult$sia, "SIA"),
                        `05` = ref_prod(ult$sih, "SIH"), `06` = ref_cnes(ult$lt), `07` = cuida,
                        `08` = ref_cnes(ult$st), `09` = ref_cnes(ult$lt))
  # Ano completo (ex.: dezembro já publicado): sem asterisco
  REF_PLANILHA <<- Filter(function(r) !is.null(r) && substr(r$mes, 5, 6) != "12", REF_PLANILHA)

  # Recomeça a pasta: só ficam as planilhas desta versão
  unlink(list.files(PLAN, recursive = TRUE, full.names = TRUE))

  larg_grupo <- c(48)
  # 01 Procedimentos ambulatoriais
  amb[, GRUPO_PROC := paste(GRUPO, nome_grupo(GRUPO))]
  gravar_planilha("01_procedimentos_ambulatoriais",
                  list(Geral = geral(amb, "GRUPO_PROC", anos, "Quantidade", larg_grupo),
                       Unidades = unidades_ano(amb, unidades, anos, "Quantidade")),
                  "Procedimentos ambulatoriais",
                  paste("SIA, todos os grupos SIGTAP (01 a 09).",
                        "Produção = quantidade aprovada (PA_QTDAPR,",
                        "a Freqüência do Prod_PE.def); valor = valor aprovado."),
                  atualizacao, csv = csv_tema(amb, unidades, "GRUPO_PROC"))

  # 02 Internamentos por grupo de procedimento
  int[, GRUPO_PROC := paste(GRUPO, nome_grupo(GRUPO))]
  # Geral (grupo × ano); Rede própria e OSS (unidades × ano, todos os grupos somados);
  # Rede complementar (grupo × ano, só as unidades complementares)
  int <- merge(int, unidades[, .(CNES, TIPO_REDE)], by = "CNES")
  abas_int <- list(Geral = geral(int, "GRUPO_PROC", anos, "AIH", larg_grupo))
  x <- int[TIPO_REDE %chin% c("Rede própria", "OSS")]
  if (nrow(x)) abas_int[["Rede própria e OSS"]] <- unidades_ano(x[, !"TIPO_REDE"], unidades, anos, "AIH")
  x <- int[TIPO_REDE == "Complementar"]
  if (nrow(x)) abas_int[["Rede complementar"]] <- geral(x, "GRUPO_PROC", anos, "AIH", larg_grupo)
  int[, TIPO_REDE := NULL]
  gravar_planilha("02_internamentos", abas_int, "Internamentos por grupo de procedimento",
                  paste("SIH (AIH reduzida), grupo do procedimento realizado (PROC_REA), grupos",
                        paste(GRUPOS_PROC, collapse = ", "), ". Produção = número de AIH, incluindo as de longa",
                        "permanência (Freqüência do RD_PE.DEF, padrão da área); valor = valor total da AIH (VAL_TOT)."),
                  atualizacao, csv = csv_tema(int, unidades, "GRUPO_PROC"))

  # 03 e 04 Consultas
  for (tema in list(list("03_consultas_medicas_especializadas", cm, CONSULTA_MEDICA_ESPECIALIZADA,
                         "Consultas médicas especializadas", "consulta médica em atenção especializada"),
                    list("04_consultas_multiprofissionais", cs, CONSULTA_MULTIPROFISSIONAL,
                         "Consultas multiprofissionais na atenção especializada",
                         "consulta de profissionais de nível superior na atenção especializada, exceto médico"))) {
    x <- tema[[2]]
    gravar_planilha(tema[[1]],
                    list(Geral = geral(x, "ESPECIALIDADE", anos, "Consultas", 55),
                         Unidades = unidades_ano(x, unidades, anos, "Consultas")),
                    tema[[4]],
                    sprintf(paste("SIA, procedimento %s (%s). Aba Geral por ocupação do profissional (CBO), como a linha",
                                  "Profissional-CBO do TabWin. Produção = quantidade aprovada; valor = valor aprovado."),
                            tema[[3]], tema[[5]]),
                    atualizacao, csv = csv_tema(x, unidades, "ESPECIALIDADE"))
  }

  # 05 Partos (todo o estado, por gestão)
  setnames(pt, c("TIPO_PARTO", "SUBTIPO"), c("TIPO_DE_PARTO", "PROCEDIMENTO"))
  abas_pt <- list(Geral = por_gestao(pt, "TIPO_DE_PARTO", "PROCEDIMENTO", anos, c("Parto normal", "Parto cesáreo"),
                                     PARTOS$SUBTIPO, "Partos", c(16, 42, 12)))
  for (tp in c("Parto normal", "Parto cesáreo")) abas_pt[[tp]] <- unidades_ano(pt[TIPO_DE_PARTO == tp], unidades, anos, "Partos", "GESTAO")
  gravar_planilha("05_partos", abas_pt, "Partos por tipo de parto e gestão",
                  paste("SIH, procedimento realizado entre os 6 do PROCOBS2C.CNV (Proced obst do TabWin): parto normal",
                        "(0310010039, 0310010047, 0310010055) e cesáreo (0411010034, 0411010026, 0411010042).",
                        "TODO O ESTADO, por gestão (campo GESTAO da AIH: Estadual/Municipal). Produção = número de AIH;",
                        "valor = valor total da AIH. Nas abas por tipo, as unidades estão agrupadas por gestão."),
                  atualizacao, csv = csv_tema(pt, unidades, c("GESTAO", "TIPO_DE_PARTO", "PROCEDIMENTO")),
                  itens = c(Unidades = "Todas as unidades de PE com parto, separadas pela gestão da AIH (campo GESTAO)."))

  # 06 Leitos (todo o estado, por tipo de gestão)
  if (!is.null(lt) && nrow(lt)) {
    tipos <- ler_csv("referencias/leitos_tipo.csv"); esp <- ler_csv("referencias/leitos_especialidade.csv")
    lt[, `:=`(ANO = as.integer(substr(COMPETENCIA, 1, 4)),
              GESTAO = fcase(TPGESTAO == "E", "Estadual", TPGESTAO == "M", "Municipal", TPGESTAO == "D", "Dupla",
                             TPGESTAO %chin% c("S", "Z"), "Sem gestão", default = "Não informada"),
              TIPO_DE_LEITO = fcoalesce(tipos$TIPO_LEITO[match(TP_LEITO, tipos$TP_LEITO)], paste("Tipo", TP_LEITO)),
              ESPECIALIDADE_LEITO = paste(CODLEITO, fcoalesce(esp$ESPECIALIDADE[match(CODLEITO, esp$CODLEITO)], "(sem descrição)")),
              QTD = QT_EXIST, VALOR = QT_SUS)]
    rl <- list(rotulos = c("Existentes", "SUS"), formatos = c("#,##0", "#,##0"))
    meses_ref <- paste(sort(unique(lt$COMPETENCIA)), collapse = ", ")
    abas_lt <- list(
      Geral = do.call(por_gestao, c(list(lt, "TIPO_DE_LEITO", NULL, anos, tipos$TIPO_LEITO, NULL, "Existentes", c(24, 12)), rl)),
      `Por especialidade` = do.call(por_gestao, c(list(lt, "TIPO_DE_LEITO", "ESPECIALIDADE_LEITO", anos, tipos$TIPO_LEITO,
                                                      sort(unique(lt$ESPECIALIDADE_LEITO)), "Existentes", c(24, 40, 12)), rl)),
      Unidades = do.call(unidades_ano, c(list(lt, unidades, anos, "Existentes", "GESTAO"), rl)))
    gravar_planilha("06_leitos", abas_lt, "Leitos por tipo de leito e tipo de gestão",
                    paste("CNES-LT (Leitos_Especialidade.def do TabWin): leitos existentes (QT_EXIST, a Freqüência do TabWin)",
                          "e leitos SUS (QT_SUS), por tipo de leito (TIP1LEIT.CNV), especialidade (ESP_LEIT.CNV) e tipo de",
                          "gestão do estabelecimento (TPGESTAO: dupla, estadual, municipal, sem gestão). TODO O ESTADO."),
                    atualizacao, csv = setnames(csv_tema(lt, unidades, c("GESTAO", "TIPO_DE_LEITO", "ESPECIALIDADE_LEITO")),
                                                c("QTD", "VALOR"), c("LEITOS_EXISTENTES", "LEITOS_SUS")),
                    itens = c(Formato = "Para cada ano: leitos existentes e leitos SUS. Subtotais e total geral em negrito.",
                              `Período` = paste("Leito é estoque: cada ano mostra a posição de dezembro; o ano corrente, o último",
                                                "mês publicado. Meses usados:", meses_ref),
                              Unidades = "Todos os estabelecimentos de PE com leitos, agrupados pelo tipo de gestão.",
                              Valor = "Não se aplica.",
                              `Meses recentes` = "O CNES é atualizado mensalmente; o ano corrente pode mudar até dezembro.",
                              Fonte = "DATASUS, CNES-LT (arquivos LTPEaamm.dbc), FTP público. Mesmos arquivos do TabWin (T:\\TabWCNES\\LEITO)."))
  }

  # 07 Cuida PE ---------------------------------------------------------------------
  p339 <- ler_csv("referencias/portaria_339_cirurgias_eletivas.csv")$PROC
  upae <- sia[CNES %chin% UPAES_CUIDA & PA_PROC_ID == CONSULTA_MEDICA_ESPECIALIZADA & GESTAO == "Estadual"]
  # Cirurgias (grupo 04) por caráter e gestão: SIA + SIH
  cir <- rbind(
    sia[GRUPO == "04" & PA_CATEND %chin% names(CARATER_CIR) & GESTAO %chin% c("Estadual", "Municipal"),
        .(CARATER = CARATER_CIR[PA_CATEND], FONTE = "Ambulatorial (SIA)", GESTAO, ANO, QTD, VALOR)],
    sih[GRUPO == "04" & CAR_INT %chin% names(CARATER_CIR) & GESTAO %chin% c("Estadual", "Municipal"),
        .(CARATER = CARATER_CIR[CAR_INT], FONTE = "Hospitalar (SIH)", GESTAO, ANO, QTD, VALOR)])
  img  <- sia[substr(PA_PROC_ID, 1, 4) %chin% names(SUBGRUPOS_IMAGEM) & PA_CATEND %chin% names(CARATER_CIR) &
                GESTAO == "Estadual"]
  img[, SUBGRUPO := SUBGRUPOS_IMAGEM[substr(PA_PROC_ID, 1, 4)]]
  # Eletivas da Portaria 339: SIA + SIH, como nos dois logs da área
  ele <- rbind(
    sia[PA_PROC_ID %chin% p339 & GRUPO == "04" & PA_CATEND == "01" & GESTAO == "Estadual",
        .(ANO_EXEC = as.character(ANO), MES = substr(PA_MVM, 5, 6), FONTE = "Ambulatorial (SIA)", QTD, VALOR)],
    sih[PROC_REA %chin% p339 & GRUPO == "04" & CAR_INT == "01" & GESTAO == "Estadual",
        .(ANO_EXEC = as.character(ANO), MES = substr(COMPETENCIA, 5, 6), FONTE = "Hospitalar (SIH)", QTD, VALOR)])
  ele[, ANO := MESES[as.integer(MES)]]
  ele_t <- rbind(ele, ele[, .(QTD = sum(QTD), VALOR = sum(VALOR), FONTE = "Total"), by = .(ANO_EXEC, ANO)], fill = TRUE)
  ele_t <- rbind(ele_t, ele_t[, .(QTD = sum(QTD), VALOR = sum(VALOR), ANO_EXEC = "Total geral"), by = .(FONTE, ANO)], fill = TRUE)
  we <- largo(ele_t, c("ANO_EXEC", "FONTE"), MESES)
  we[, `:=`(O1_ = fifelse(ANO_EXEC == "Total geral", "9999", ANO_EXEC),
            O2_ = match(FONTE, c("Ambulatorial (SIA)", "Hospitalar (SIH)", "Total")))]
  setorder(we, O1_, O2_); we[, c("O1_", "O2_") := NULL]
  # Proporção: % de cada caráter no total de cirurgias da gestão, por ano
  prop <- cir[, .(QTD = sum(QTD)), by = .(GESTAO, CARATER, ANO)]
  if (!nrow(prop)) prop <- data.table(GESTAO = character(), CARATER = character(), ANO = integer(), QTD = numeric())
  prop <- rbind(prop, prop[, .(GESTAO = "Total", QTD = sum(QTD)), by = .(CARATER, ANO)])
  prop[, VALOR := QTD / sum(QTD), by = .(GESTAO, ANO)]
  wp <- largo(prop, c("GESTAO", "CARATER"), anos)
  for (a in anos) set(wp, j = paste0("VALOR_", a), value = round(wp[[paste0("VALOR_", a)]], 4))
  wp[, O_ := match(GESTAO, c("Estadual", "Municipal", "Total"))]; setorder(wp, O_, CARATER); wp[, O_ := NULL]
  # Cada aba só entra se houver dados (ex.: base ainda incompleta durante a recarga)
  se <- function(x, expr) if (nrow(x)) expr else NULL
  abas_cuida <- Filter(Negate(is.null), list(
    `Consultas UPAEs` = se(upae, unidades_ano(upae, unidades, anos, "Consultas")),
    `Cirurgias por caráter` = se(cir, por_gestao(cir, "CARATER", "FONTE", anos, unname(CARATER_CIR),
                                                 c("Ambulatorial (SIA)", "Hospitalar (SIH)"), "Cirurgias", c(16, 20, 12))),
    `Proporção cirurgias` = se(cir, tabela(wp, c("GESTAO", "CARATER"), anos, NULL, which(wp$GESTAO == "Total"), c(12, 16),
                                           rotulos = c("Cirurgias", "% na gestão"), formatos = c("#,##0", "0.0%"))),
    `RNM e TC` = se(img, geral(img, "SUBGRUPO", anos, "Exames", 45)),
    `Eletivas Portaria 339` = se(ele, tabela(we, c("ANO_EXEC", "FONTE"), MESES, "Cirurgias",
                                             which(we$FONTE == "Total" | we$ANO_EXEC == "Total geral"), c(11, 20)))))
  gravar_planilha("07_cuida_pe", abas_cuida, "Indicadores do Cuida PE",
                  paste("Consultas UPAEs: SIA, 0301010072, gestão estadual (PA_CONDIC = E), nas 15 UPAEs do log da área.",
                        "Cirurgias por caráter: SIA + SIH, grupo 04, caráter eletivo (01) ou urgência (02) (CARAT_AT.CNV e",
                        "CARATEND.CNV), gestão estadual e municipal (PA_CONDIC / GESTAO); SIA = quantidade aprovada, SIH =",
                        "número de AIH; linhas por fonte e total. Proporção: % de cada caráter no total de cirurgias",
                        "eletivas + urgência (SIA + SIH) da gestão; acidentes (03 a 06) ficam fora. RNM e TC: SIA, subgrupos 0206 e 0207, caráter eletivo",
                        "ou urgência (PA_CATEND), gestão estadual. Eletivas Portaria 339: procedimentos da Portaria",
                        "Estadual 339/2023 (PORT339.DBF, 214 procedimentos), grupo 04, caráter eletivo, gestão estadual,",
                        "MAC e FAEC, no SIA (quantidade aprovada; PA_CATEND = 01) e no SIH (número de AIH; CAR_INT = 01),",
                        "com o total dos dois; linhas = ano e fonte, colunas = mês de competência."),
                  atualizacao, csv = if (nrow(upae)) csv_tema(upae, unidades, character()),
                  itens = c(Unidades = paste("Consultas: as 15 UPAEs. Cirurgias: todo o estado, gestão estadual e municipal.",
                                             "RNM/TC e eletivas da Portaria 339: toda a produção sob gestão estadual.")))

  # 08 Estabelecimentos SUS e 09 Leitos SUS (todo o estado, por tipo de gestão) ------
  # % = participação no total do estado no ano (soma 100% no Total geral)
  gestao_cnes <- function(x) fcase(x == "E", "Estadual", x == "M", "Municipal", x == "D", "Dupla",
                                   x %chin% c("S", "Z"), "Sem gestão", default = "Não informada")
  rot_pct <- function(r1) list(rotulos = c(r1, "%"), formatos = c("#,##0", "0.0%"))
  # % dentro de cada bloco: linha de gestão ÷ total da sua categoria (ou unidade ÷
  # subtotal da sua gestão); totais de categoria, subtotais e totais gerais ÷ total geral.
  pct_bloco <- function(t) {
    d <- t$dados; q <- grep("^QTD_", names(d), value = TRUE); v <- sub("^QTD_", "VALOR_", q)
    c1 <- t$ids[1]
    if ("UNIDADE" %in% t$ids) {                       # unidades agrupadas (ex.: por gestão)
      eh_geral <- d$UNIDADE == "Total geral"
      eh_sub <- startsWith(fcoalesce(d$UNIDADE, ""), "Subtotal")
      grupo <- d[[c1]]; den_linha <- !eh_geral & !eh_sub
      for (k in seq_along(q)) {
        tg <- d[[q[k]]][eh_geral]
        sub_g <- setNames(d[[q[k]]][eh_sub], grupo[eh_sub])
        set(d, j = v[k], value = fifelse(den_linha, d[[q[k]]] / sub_g[grupo], d[[q[k]]] / tg))
      }
    } else if ("GESTAO" %in% t$ids && c1 != "GESTAO") { # categoria × gestão
      eh_tot <- d$GESTAO == "Total"; tg_lin <- d[[c1]] == "Total geral" & eh_tot
      for (k in seq_along(q)) {
        tg <- d[[q[k]]][tg_lin]
        tot_cat <- setNames(d[[q[k]]][eh_tot], d[[c1]][eh_tot])
        set(d, j = v[k], value = fifelse(eh_tot | d[[c1]] == "Total geral" & !eh_tot,
                                         d[[q[k]]] / tg, d[[q[k]]] / tot_cat[d[[c1]]]))
      }
    } else {                                           # categoria simples
      for (k in seq_along(q)) set(d, j = v[k], value = d[[q[k]]] / d[[q[k]]][d[[c1]] == "Total geral"])
    }
    for (cl in v) set(d, which(!is.finite(d[[cl]])), cl, NA_real_)
    t$dados <- d; t
  }
  pct_abas <- function(abas) lapply(Filter(Negate(is.null), abas), function(t) if (inherits(t, "tabela_anual")) pct_bloco(t) else t)
  meses_cnes <- function(x) paste(sort(unique(x)), collapse = ", ")
  cols_sus <- c("CNES", "UNIDADE", "TIPO_UNIDADE", "MUNICIPIO", "REGIAO_SAUDE")
  if (!is.null(st_ano) && nrow(st_ano)) {
    es <- copy(st_ano)
    es[, `:=`(GESTAO = gestao_cnes(TPGESTAO),
              TIPO_DE_ESTABELECIMENTO = fcoalesce(unname(TIPOS_CNES[TP_UNID]), paste("Tipo", TP_UNID)),
              QTD = 1)]
    es[, VALOR := QTD / .N, by = ANO]
    ordem_tipo <- es[, .N, by = TIPO_DE_ESTABELECIMENTO][order(-N)]$TIPO_DE_ESTABELECIMENTO
    un_es <- pct_bloco(do.call(unidades_ano, c(list(es, unidades, anos, "Estabelecimentos", "GESTAO"),
                                     rot_pct("Estabelecimentos"), list(cols = cols_sus))))
    # % por unidade não diz nada: fica só nos subtotais e no total
    un_es$dados[!seq_len(nrow(un_es$dados)) %in% un_es$linhas_total,
                (grep("^VALOR_", names(un_es$dados), value = TRUE)) := NA_real_]
    gravar_planilha("08_estabelecimentos_sus", list(
      Geral = pct_bloco(do.call(por_gestao, c(list(es, "TIPO_DE_ESTABELECIMENTO", NULL, anos, ordem_tipo, NULL,
                                         "Estabelecimentos", c(40, 12)), rot_pct("Estabelecimentos")))),
      Unidades = un_es),
      "Estabelecimentos com vínculo SUS por tipo de gestão",
      paste("CNES-ST, cadastro de dezembro de cada ano (no ano corrente, o último mês publicado; meses:",
            meses_cnes(es$COMPETENCIA), "). Estabelecimentos com vínculo SUS (VINC_SUS = 1), por tipo de",
            "estabelecimento (TP_UNID) e tipo de gestão (TPGESTAO). % dentro do bloco: gestão sobre o total do",
            "tipo; totais sobre o total geral. TODO O ESTADO."),
      atualizacao)
  }
  if (!is.null(lt) && nrow(lt)) {
    ls_ <- lt[QT_SUS > 0]
    ls_[, `:=`(QTD = QT_SUS)]
    ls_[, VALOR := QTD / sum(QTD), by = ANO]
    # Natureza como no TabWin (Leitos_Especialidade.def): 1º dígito do NAT_JUR do
    # próprio arquivo de leitos, NATJUR1.CNV (empresa pública e sociedade de
    # economia mista, ex.: HC/EBSERH, ficam em Entidades Empresariais)
    ls_ <- merge(ls_, unidades[, .(CNES, TIPO_REDE_U = TIPO_REDE, MODELO_U = MODELO_GESTAO, NAT_JUR_U = NAT_JUR)],
                 by = "CNES", all.x = TRUE)
    nj <- if ("NAT_JUR" %in% names(ls_)) substr(ls_$NAT_JUR, 1, 1) else rep(NA_character_, nrow(ls_))
    ls_[, NATUREZA_LEITO := fcase(nj == "1", "Administração Pública", nj == "2", "Entidades Empresariais",
                                  nj == "3", "Entidades sem Fins Lucrativos", nj == "4", "Pessoas Físicas",
                                  nj == "5", "Instituições Extraterritoriais",
                                  default = "Não especificado ou ignorado")]
    ord_nat <- c("Administração Pública", "Entidades Empresariais", "Entidades sem Fins Lucrativos",
                 "Pessoas Físicas", "Instituições Extraterritoriais", "Não especificado ou ignorado")
    # Próprios (rede própria e OSS) sob gestão estadual, em três categorias:
    # - Gestão por OSS: modelo OSS da lista validada;
    # - Administração indireta (fundações e autarquias): modelo "Administração
    #   indireta" da lista; fora da lista, natureza jurídica de autarquia ou
    #   fundação pública estadual (1112, 1147, 1260), Decreto-Lei 200/1967;
    # - Administração direta: 06 grandes, gestão direta e demais estaduais.
    prop <- ls_[GESTAO == "Estadual" & TIPO_REDE_U %chin% c("Rede própria", "OSS")]
    ADM_CAT <- c("Administração direta", "Administração indireta (fundações e autarquias)", "Gestão por OSS")
    prop[, ADMINISTRACAO := fcase(
      TIPO_REDE_U == "OSS" | MODELO_U %chin% "OSS", ADM_CAT[3],
      MODELO_U %chin% "Administração indireta", ADM_CAT[2],
      (is.na(MODELO_U) | MODELO_U %chin% "Estadual fora da lista SES") & NAT_JUR_U %chin% c("1112", "1147", "1260"), ADM_CAT[2],
      default = ADM_CAT[1])]
    ordena <- function(t, col, ordem) {
      d <- t$dados; o <- order(match(d[[col]], c(ordem, "Total geral"), nomatch = 50L))
      t$dados <- d[o]; t$linhas_total <- which(d[o][[col]] == "Total geral"); t
    }
    est_dupla <- ls_[GESTAO %chin% c("Estadual", "Dupla")]
    gravar_planilha("09_leitos_sus", pct_abas(list(
      Geral = do.call(por_gestao, c(list(ls_, "TIPO_DE_LEITO", NULL, anos, tipos$TIPO_LEITO, NULL,
                                         "Leitos SUS", c(24, 12)), rot_pct("Leitos SUS"))),
      Unidades = do.call(unidades_ano, c(list(ls_, unidades, anos, "Leitos SUS", "GESTAO"),
                                         rot_pct("Leitos SUS"), list(cols = cols_sus))),
      `Est. e dupla por natureza` = se(est_dupla, do.call(por_gestao, c(list(est_dupla, "NATUREZA_LEITO", NULL, anos,
                                         ord_nat, NULL, "Leitos SUS", c(28, 12)), rot_pct("Leitos SUS")))),
      `Estadual por natureza` = se(ls_[GESTAO == "Estadual"], ordena(do.call(geral, c(list(ls_[GESTAO == "Estadual"],
                                         "NATUREZA_LEITO", anos, "Leitos SUS", 28), rot_pct("Leitos SUS"))),
                                         "NATUREZA_LEITO", ord_nat)),
      `Próprios por administração` = se(prop, ordena(do.call(geral, c(list(prop, "ADMINISTRACAO", anos, "Leitos SUS", 44),
                                         rot_pct("Leitos SUS"))), "ADMINISTRACAO", ADM_CAT)))),
      "Leitos SUS por tipo de gestão",
      paste("CNES-LT, posição de dezembro de cada ano (meses:", meses_cnes(ls_$COMPETENCIA), "). Leitos SUS",
            "(QT_SUS), por tipo de leito (TIP1LEIT.CNV) e tipo de gestão do estabelecimento (TPGESTAO).",
            "% dentro do bloco: gestão sobre o total da categoria, unidade sobre o subtotal da sua gestão;",
            "totais sobre o total geral da aba. TODO O ESTADO. Natureza como no TabWin: 1º dígito da natureza",
            "jurídica do arquivo de leitos (NATJUR1.CNV). Próprios: rede própria e OSS da",
            "lista validada (e estaduais fora da lista), sob gestão estadual: administração direta (06 grandes,",
            "gestão direta, demais estaduais), administração indireta (fundações e autarquias: modelo da lista ou",
            "natureza jurídica 1112, 1147, 1260) e gestão por OSS."),
      atualizacao)
  }

  # 10 Estabelecimentos de PE (todos, qualquer gestão), só o mês mais recente ---------
  if (length(arqs_st)) {
    arq_ult <- sort(arqs_st)[length(arqs_st)]
    e10 <- ler_parquet(arq_ult)
    comp10 <- max(e10$COMPETENCIA)
    nj1 <- substr(e10$NAT_JUR, 1, 1)
    e10[, `:=`(
      GESTAO = gestao_cnes(TPGESTAO),
      TIPO = fcoalesce(unname(TIPOS_CNES[TP_UNID]), paste("Tipo", TP_UNID)),
      # Natureza como no TabWin do CNES (NATJUR1.CNV, pelo código da natureza jurídica)
      NATUREZA = fcase(nj1 == "1", "Administração Pública", nj1 == "2", "Entidades Empresariais",
                       nj1 == "3", "Entidades sem Fins Lucrativos", nj1 == "4", "Pessoas Físicas",
                       nj1 == "5", "Instituições Extraterritoriais", default = "Não especificado ou ignorado"))]
    ord_g <- c("Estadual", "Dupla", "Municipal", "Sem gestão", "Não informada")
    ord_n <- c("Administração Pública", "Entidades Empresariais", "Entidades sem Fins Lucrativos",
               "Pessoas Físicas", "Instituições Extraterritoriais", "Não especificado ou ignorado")
    ord_t <- e10[, .N, by = TIPO][order(-N)]$TIPO
    nota10 <- if (substr(comp10, 5, 6) != "12") sprintf("* Dados preliminares de %s, sujeitos a alteração.", mes_txt(comp10)) else
      sprintf("Competência: %s.", mes_txt(comp10))
    rot10 <- sprintf("Total de unidades (%s%s)", mes_txt(comp10), if (substr(comp10, 5, 6) != "12") "*" else "")
    com_total <- function(x, rot1) {
      x <- rbind(x, as.data.table(c(setNames(list("Total"), names(x)[1]),
                                    lapply(x[, -1, with = FALSE], function(v) if (is.numeric(v)) sum(v) else NA))),
                 fill = TRUE)
      setattr(x, "linhas_total", nrow(x)); x
    }
    base10 <- e10[, .(N = .N), by = .(GESTAO, TIPO, NATUREZA)]
    base10 <- base10[order(match(GESTAO, ord_g), match(TIPO, ord_t), match(NATUREZA, ord_n))]
    setnames(base10, c("Gestão", "Tipo de estabelecimento", "Natureza jurídica", rot10))
    base10 <- com_total(base10)
    matriz <- function(linha, ordem_l, rot_l) {
      m <- dcast(e10, as.formula(paste(linha, "~ GESTAO")), value.var = "CNES", fun.aggregate = length)
      gs <- intersect(ord_g, names(m)); setcolorder(m, c(linha, gs))
      m[, Total := rowSums(.SD), .SDcols = gs]
      m <- m[order(match(get(linha), ordem_l))]
      setnames(m, linha, rot_l); com_total(m)
    }
    abas10 <- list(`Gestão, tipo e natureza` = base10,
                   `Tipo × gestão` = matriz("TIPO", ord_t, "Tipo de estabelecimento"),
                   `Natureza × gestão` = matriz("NATUREZA", ord_n, "Natureza jurídica"))
    larg10 <- list(c(14, 52, 32, 24), c(52, 12, 12, 12, 12, 12), c(32, 12, 12, 12, 12, 12))
    for (k in seq_along(abas10)) { setattr(abas10[[k]], "nota", nota10); setattr(abas10[[k]], "larguras", larg10[[k]]) }
    gravar_planilha("10_estabelecimentos_pe", abas10, "Estabelecimentos de saúde de PE",
                    "CNES-ST, todos os estabelecimentos de PE no mês mais recente", atualizacao)
  }

  # 00 Unidades
  gravar_planilha("00_unidades", list(Unidades = unidades[, .(CNES, UNIDADE, TIPO_REDE, TIPO_UNIDADE,
                                                               NATUREZA, NAT_JUR, NA_LISTA_SES, MUNICIPIO, REGIAO_SAUDE,
                                                               MACRORREGIAO)]),
                  "Cadastro das unidades", "Uma linha por CNES que aparece em alguma planilha.", atualizacao)

  gravar_csv(data.table(FONTE = c("SIA", "SIH"), ULTIMO_MES = c(max(sia$PA_MVM), max(sih$COMPETENCIA)),
                        GERADO_EM = atualizacao$em), file.path(PLAN, "atualizacao.csv"))
  dir.create(dirname(arq_hash), recursive = TRUE, showWarnings = FALSE)
  writeLines(hash, arq_hash)
}

if (sys.nframe() == 0L) main()
