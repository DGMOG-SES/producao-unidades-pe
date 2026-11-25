# ------------------------------------------------------------------------------
# Funções comuns do pipeline: configuração, log, gravação atômica, tentativas de
# rede, listagem do FTP do DATASUS e leitura dos arquivos .dbc.
# Mesmo padrão do repositório informacoes-estrategicas-geres.
# ------------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(data.table)
  library(curl)
})

CFG <- list(
  dir_dados  = Sys.getenv("PROD_DIR_DADOS", "dados"),
  dir_planilhas = Sys.getenv("PROD_DIR_PLANILHAS", "planilhas"),
  # Primeiro mês do período (movimento do SIA / mês do arquivo do SIH)
  inicio     = "201901",
  # Último mês do período: dezembro de 2026
  fim        = "202612",
  uf         = "PE",
  # Código do gestor estadual de PE no SIA (PA_GESTAO) e no SIH (UF_ZI)
  gestor_estadual = "260000",
  tentativas = 6,
  ftp_sia    = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIASUS/200801_/Dados/",
  ftp_sih    = "ftp://ftp.datasus.gov.br/dissemin/publicos/SIHSUS/200801_/Dados/",
  ftp_st     = "ftp://ftp.datasus.gov.br/dissemin/publicos/CNES/200508_/Dados/ST/",
  ftp_sigtap = "ftp://ftp2.datasus.gov.br/pub/sistemas/tup/downloads/",
  api_cnes   = "https://apidadosabertos.saude.gov.br/cnes/estabelecimentos/"
)

`%||%` <- function(a, b) if (is.null(a)) b else a

log_msg <- function(...) {
  cat(format(Sys.time(), "[%Y-%m-%d %H:%M:%S] "), sprintf(...), "\n", sep = "")
}

# Valor de um argumento "--nome=valor" da linha de comando (ou NULL).
argumento <- function(nome) {
  a <- grep(paste0("^--", nome, "="), commandArgs(trailingOnly = TRUE), value = TRUE)
  if (length(a)) sub(paste0("^--", nome, "="), "", a[1]) else NULL
}
tem_flag <- function(nome) paste0("--", nome) %in% commandArgs(trailingOnly = TRUE)

# Grava em arquivo temporário e renomeia, para nunca deixar arquivo pela metade.
gravar_atomico <- function(escrever, destino) {
  dir.create(dirname(destino), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(destino, ".tmp")
  escrever(tmp)
  if (file.exists(destino)) file.remove(destino)
  file.rename(tmp, destino)
}
gravar_csv <- function(dt, destino) gravar_atomico(function(f) fwrite(dt, f, sep = ";", bom = TRUE), destino)
# Parquet com o arrow; se ele não estiver instalado (ex.: máquina sem permissão
# de administrador), usa o nanoparquet, que é mais leve.
usar_arrow <- function() requireNamespace("arrow", quietly = TRUE)
gravar_parquet <- function(dt, destino) {
  gravar_atomico(function(f) {
    if (usar_arrow()) arrow::write_parquet(dt, f) else nanoparquet::write_parquet(as.data.frame(dt), f)
  }, destino)
}
ler_parquet <- function(caminho) {
  as.data.table(if (usar_arrow()) arrow::read_parquet(caminho) else nanoparquet::read_parquet(caminho))
}
ler_csv <- function(caminho) fread(caminho, colClasses = "character", encoding = "UTF-8")

com_tentativas <- function(f, descricao) {
  for (i in seq_len(CFG$tentativas)) {
    res <- tryCatch(f(), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    log_msg("Falha em %s (tentativa %d/%d): %s",
            descricao, i, CFG$tentativas, conditionMessage(res))
    # Espera crescente (10 s, 20 s, 40 s... até 5 min): o FTP do DATASUS costuma
    # recusar conexões por alguns minutos quando está sobrecarregado.
    if (i < CFG$tentativas) Sys.sleep(min(2^i * 5, 300))
  }
  stop("Desisti de ", descricao, " após ", CFG$tentativas, " tentativas")
}

novo_handle <- function() {
  new_handle(connecttimeout = 60, low_speed_limit = 1000, low_speed_time = 180,
             ftp_use_epsv = FALSE)
}

# ---- FTP -----------------------------------------------------------------------

# Interpreta a listagem do FTP. Aceita o formato MS-DOS (usado pelo DATASUS:
# "10-25-24  02:15PM  123456 PAPE2409.dbc") e o formato Unix ("-rw-r--r-- ...").
interpretar_listagem <- function(linhas) {
  linhas <- trimws(linhas[nzchar(trimws(linhas))])
  vazio <- data.table(nome = character(), tamanho = numeric(), data = character())
  if (!length(linhas)) return(vazio)
  partes <- strsplit(linhas, "\\s+")
  res <- rbindlist(lapply(partes, function(p) {
    if (grepl("^\\d{2}-\\d{2}-\\d{2,4}$", p[1]) && length(p) >= 4) {
      data.table(nome = paste(p[4:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[3])),
                 data = paste(p[1], p[2]))
    } else if (length(p) >= 9) {
      data.table(nome = paste(p[9:length(p)], collapse = " "),
                 tamanho = suppressWarnings(as.numeric(p[5])),
                 data = paste(p[6], p[7], p[8]))
    } else {
      NULL
    }
  }))
  if (!nrow(res)) vazio else res
}

listar_ftp <- function(url) {
  res <- com_tentativas(function() curl_fetch_memory(url, handle = novo_handle()), paste("listar", url))
  interpretar_listagem(strsplit(rawToChar(res$content), "\r?\n")[[1]])
}

# Baixa um arquivo do FTP para a pasta temporária e devolve o caminho local.
baixar <- function(url_dir, nome) {
  destino <- file.path(tempdir(), nome)
  com_tentativas(function() curl_download(paste0(url_dir, nome), destino,
                                          handle = novo_handle(), quiet = TRUE),
                 paste("baixar", nome))
  destino
}

ler_arquivo <- function(caminho) {
  if (grepl("\\.dbc$", caminho, ignore.case = TRUE)) {
    if (requireNamespace("read.dbc", quietly = TRUE)) {
      df <- read.dbc::read.dbc(caminho, as.is = TRUE)
    } else {
      # Alternativa: descompacta com o pyreaddbc (pip install pyreaddbc).
      dbf <- sub("\\.dbc$", ".dbf", caminho, ignore.case = TRUE)
      on.exit(unlink(dbf))
      status <- system2("python3", c("-c", shQuote(sprintf(
        "from pyreaddbc import dbc2dbf; dbc2dbf('%s', '%s')", caminho, dbf))))
      if (status != 0 || !file.exists(dbf)) {
        stop("Não foi possível ler .dbc: instale read.dbc (instalar_pacotes.R) ou pyreaddbc")
      }
      df <- foreign::read.dbf(dbf, as.is = TRUE)
    }
  } else {
    df <- foreign::read.dbf(caminho, as.is = TRUE)
  }
  setDT(df)
}

baixar_ler <- function(url_dir, nome) {
  caminho <- baixar(url_dir, nome)
  on.exit(unlink(caminho))
  ler_arquivo(caminho)
}

# Garante que as colunas existem (vazias quando o layout do mês não as tem) e
# converte texto com espaços em texto limpo.
padronizar <- function(dt, texto = character(), numero = character()) {
  for (cl in setdiff(c(texto, numero), names(dt))) set(dt, j = cl, value = NA)
  dt <- dt[, c(texto, numero), with = FALSE]
  for (cl in texto) set(dt, j = cl, value = trimws(as.character(dt[[cl]])))
  for (cl in numero) set(dt, j = cl, value = suppressWarnings(as.numeric(dt[[cl]])))
  dt
}

# Junta as partições Parquet de uma pasta numa base única.
consolidar <- function(dir_particoes, destino) {
  arqs <- list.files(dir_particoes, "\\.parquet$", full.names = TRUE)
  if (!length(arqs)) return(invisible(NULL))
  base <- rbindlist(lapply(arqs, ler_parquet), use.names = TRUE, fill = TRUE)
  gravar_parquet(base, destino)
  log_msg("%s: %s linhas (%d partições)", basename(destino), format(nrow(base), big.mark = "."), length(arqs))
  invisible(base)
}

# Controle de arquivos já processados: nome/mês + assinatura do FTP (nome,
# tamanho e data). Arquivo republicado pelo DATASUS muda de assinatura e é refeito.
ler_controle <- function(caminho, chave) {
  if (file.exists(caminho)) return(ler_csv(caminho))
  dt <- data.table(a = character(), assinatura = character(), processado_em = character())
  setnames(dt, "a", chave)
  dt
}
registrar_controle <- function(ctrl, caminho, chave, valor, assinatura) {
  ctrl <- rbind(ctrl[get(chave) != valor],
                setnames(data.table(valor, assinatura, format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
                         c(chave, "assinatura", "processado_em")))
  gravar_csv(ctrl, caminho)
  ctrl
}

# No GitHub Actions (PUBLICAR_PARCIAL=1), grava e envia ao repositório cada mês
# assim que ele termina: se a execução cair, o que já foi feito não se perde.
publicar_parcial <- function(mensagem) {
  if (!nzchar(Sys.getenv("PUBLICAR_PARCIAL"))) return(invisible(NULL))
  status <- system2("bash", c("publicar.sh", shQuote(mensagem)))
  if (status != 0) log_msg("AVISO: não consegui publicar \"%s\"; vai na publicação final", mensagem)
}

# Limite de tempo (--minutos=N): para de começar meses novos depois de N
# minutos, para sobrar tempo para as etapas seguintes dentro do limite do Actions.
tempo_esgotado <- function(inicio, minutos) {
  !is.null(minutos) && as.numeric(difftime(Sys.time(), inicio, units = "mins")) > as.numeric(minutos)
}

# --periodo=AAAAMM-AAAAMM: restringe os meses processados (usado na carga
# paralela, em que cada máquina do GitHub Actions baixa um trecho do período).
no_periodo <- function(meses) {
  p <- argumento("periodo")
  if (is.null(p)) return(rep(TRUE, length(meses)))
  lim <- strsplit(p, "-")[[1]]
  meses >= lim[1] & meses <= lim[2]
}

# Lista de unidades validada pela SES (rede própria, OSS e referências fora da rede).
ler_validados <- function() ler_csv("referencias/estabelecimentos_validados.csv")
