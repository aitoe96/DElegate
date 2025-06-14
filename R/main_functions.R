 
#' Differential expression tests for single-cell RNA-seq data
#'
#' @param object Input object (of class Seurat, SingleCellExperiment, dgCMatrix, or matrix)
#' @param meta_data Data frame of meta data; can be NULL if object is Seurat or
#' SingleCellExperiment and cell identities are set; default is NULL
#' @param group_column String or integer indicating what column of meta_data to use as group indicator;
#' if NULL, the object cell identities are used; default is NULL
#' @param replicate_column String or integer indicating what column of meta_data
#' to use as replicate indicator; default is NULL
#' @param compare Specifies which groups to compare - see details; default is 'each_vs_rest'
#' @param compare_is_ref If set to TRUE, the compare parameter is interpreted as the reference group
#' level and all other levels are compared to this one; default is FALSE
#' @param method DE method to use, one of edger, deseq, limma; default is edger
#' @param order_results Whether to order the results by comparison, then by p-value, then
#' by test statistic. If FALSE, results will be ordered by comparison only, genes remain
#' in the order as in the input. Default is TRUE
#' @param lfc_shrinkage The type of logFC shrinkage to apply to the results; only used with method deseq;
#' may be set to one of "apeglm", "ashr", "normal"; default is NULL for no shrinkage
#' @param verbosity Integer controlling how many messages the function prints;
#' 0 is silent, 1 prints some messages, 2 prints more messages
#' @returns A data frame of results with the following columns
#'
#' * **feature** the gene (as given by rownames of input)
#' * **ave_expr** average expression of gene (renamed method specific values; edger: logCPM, deseq: baseMean, limma: Amean)
#' * **log_fc** log fold-change (renamed method specific values; edger: logFC, deseq: log2FoldChange, limma: LogFC)
#' * **stat** test statistic (renamed method specific values; edger: F, deseq: stat, limma: lods)
#' * **pvalue** test p-value
#' * **padj** adjusted p-value (FDR)
#' * **rate1** detection rate in group one (fraction of cells with non-zero counts)
#' * **rate2** detection rate in group two (fraction of cells with non-zero counts)
#' * **group1** comparison group one
#' * **group2** comparison group two
#'
#' The log fold-change values are estimates of the form log2(group1/group2) - details will depend on the method chosen.
#'
#'
#' @section Details:
#' Compare groups of cells using DESeq2, edgeR, or limma-trend.
#'
#' There are multiple ways the group comparisons can be specified based on the compare
#' parameter. The default, \code{'each_vs_rest'}, does multiple comparisons, one per
#' group vs all remaining cells. \code{'all_vs_all'}, also does multiple comparisons,
#' covering all group pairs. If compare is set to a length two character vector, e.g.
#' \code{c('T-cells', 'B-cells')}, one comparison between those two groups is done.
#' To put multiple groups on either side of a single comparison, use a list of length two.
#' E.g. \code{compare = list(c('cluster1', 'cluster5'), c('cluster3'))}. Finally, if
#' compare is a character vector of length one and \code{compare_is_ref = TRUE} is set,
#' the compare parameter is interpreted as the reference group level and all other
#' levels are compared to this one.
#'
#' @export
#'
#' @examples
#' \donttest{
#' # Example data
#' counts <- DElegate::pbmc$counts
#' meta_data <- DElegate::pbmc$meta_data
#'
#' # Use matrix and meta data as input and perform all "this group vs rest" comparisons
#' de_res <- findDE(object = counts,
#'                  meta_data = meta_data,
#'                  group_column = 'celltype')
#'
#' # Same with Seurat object as input
#' s <- Seurat::CreateSeuratObject(counts = counts, meta.data = meta_data)
#' Seurat::Idents(s) <- s$celltype
#' de_res <- findDE(object = s)
#' }
#'

findDE <- function(object,
                  meta_data = NULL,
                  group_column = NULL,
                  replicate_column = NULL,
                  covariates = NULL,  # New parameter
                  compare = 'each_vs_rest',
                  compare_is_ref = FALSE,
                  method = 'edger',
                  order_results = TRUE,
                  lfc_shrinkage = NULL,
                  verbosity = 1) {
    
  # extract the data from the input object
  de_data <- get_data(object, meta_data, group_column, replicate_column, verbosity)
  
  # set up the comparisons
  group_levels = levels(x = de_data$grouping)
  comparisons <- set_up_comparisons(group_levels = group_levels, 
                                  compare = compare,
                                  compare_is_ref = compare_is_ref, 
                                  verbosity = verbosity)
  print_comparisons(comparisons, verbosity)
  
  # run DE with covariates
  run_de_comparisons(counts = de_data$counts,
                    grouping = de_data$grouping,
                    replicate_label = de_data$replicate_label,
                    covariates = covariates,  # Pass covariates through
                    comparisons = comparisons,
                    method = method,
                    order_results = order_results,
                    lfc_shrinkage = lfc_shrinkage,
                    verbosity = verbosity)
}

#' Find markers for all groups
#'
#' This calls [findDE()] with compare = 'each_vs_rest' and filters and orders the results.
#'
#' @inheritParams findDE
#' @param min_rate Remove genes from the results that have a detection rate below this threshold; uses the maximum of the groups being compared; default is 0.05
#' @param min_fc Remove genes from the results that have a log fold-change below this threshold; default is 1
#' @returns A data frame of results just as [findDE()], but with 'feature_rank' column added
#'
#' @section Details:
#' After filtering, adjusted p-values (FDR) are recalculated per comparison.
#'
#' @importFrom magrittr %>%
#' @importFrom rlang .data
#'
#' @export
#'
#' @examples
#' \donttest{
#' # Example data
#' counts <- DElegate::pbmc$counts
#' meta_data <- DElegate::pbmc$meta_data
#'
#' # Use matrix and meta data as input
#' markers <- FindAllMarkers2(object = counts,
#'                            meta_data = meta_data,
#'                            group_column = 'celltype')
#'
#' # Same with Seurat object as input
#' s <- Seurat::CreateSeuratObject(counts = counts, meta.data = meta_data)
#' Seurat::Idents(s) <- s$celltype
#' markers <- FindAllMarkers2(object = s)
#' }
FindAllMarkers2 <- function(object,
                            meta_data = NULL,
                            group_column = NULL,
                            replicate_column = NULL,
                            method = 'edger',
                            min_rate = 0.05,
                            min_fc = 1,
                            lfc_shrinkage = NULL,
                            verbosity = 1) {
  res <- findDE(object = object,
                meta_data = meta_data,
                group_column = group_column,
                replicate_column = replicate_column,
                compare = 'each_vs_rest',
                method = method,
                order_results = TRUE,
                lfc_shrinkage = lfc_shrinkage,
                verbosity = verbosity)

    res <- dplyr::filter(res, .data$rate1 >= min_rate | .data$rate2 >= min_rate, .data$log_fc >= min_fc) %>%
      dplyr::group_by(.data$group1) %>%
      dplyr::mutate(padj = stats::p.adjust(.data$pvalue, method = 'fdr')) %>%
      dplyr::mutate(feature_rank = 1:dplyr::n()) %>%
      dplyr::ungroup() %>%
      dplyr::select(-.data$group2)

  return(as.data.frame(res))
}
