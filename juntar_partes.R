#!/usr/bin/env Rscript
# ------------------------------------------------------------------------------
# Junta o resultado das máquinas da carga paralela (carga_paralela.yml).
# Cada parte (pasta em partes/) traz as partições Parquet que baixou e os seus
# arquivos de controle. As partições são copiadas para dados/, os controles são
# unidos (vale o registro mais recente de cada mês) e as bases consolidadas são
# remontadas.
# Uso: Rscript juntar_partes.R partes
# ------------------------------------------------------------------------------

source("utils.R")

dir_partes <- commandArgs(trailingOnly = TRUE)[1] %||% "partes"
for (sub in c("sia", "sih")) {
  arqs <- list.files(dir_partes, sprintf("^%s_\\d{6}\\.parquet$|^rd_\\d{6}\\.parquet$", sub), recursive = TRUE, full.names = TRUE)
  arqs <- arqs[grepl(paste0("/", sub, "/"), arqs)]
  dir.create(file.path(CFG$dir_dados, sub), recursive = TRUE, showWarnings = FALSE)
  file.copy(arqs, file.path(CFG$dir_dados, sub, basename(arqs)), overwrite = TRUE)
  log_msg("%s: %d partições copiadas", sub, length(arqs))
}
for (ctl in c("sia_processados_v3.csv", "sih_processados_v2.csv")) {
  arqs <- c(file.path(CFG$dir_dados, "controle", ctl),
            list.files(dir_partes, paste0("^", ctl, "$"), recursive = TRUE, full.names = TRUE))
  arqs <- arqs[file.exists(arqs)]
  if (!length(arqs)) next
  todos <- rbindlist(lapply(arqs, ler_csv), use.names = TRUE)
  chave <- names(todos)[1]
  setorderv(todos, c(chave, "processado_em"), c(1, -1))
  todos <- unique(todos, by = chave)
  gravar_csv(todos, file.path(CFG$dir_dados, "controle", ctl))
  log_msg("%s: %d meses", ctl, nrow(todos))
}
consolidar(file.path(CFG$dir_dados, "sia"), file.path(CFG$dir_dados, "saida", "sia_unidades.parquet"))
consolidar(file.path(CFG$dir_dados, "sih"), file.path(CFG$dir_dados, "saida", "sih_unidades.parquet"))
