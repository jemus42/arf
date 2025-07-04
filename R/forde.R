#' Forests for Density Estimation
#' 
#' Uses a pre-trained ARF model to estimate leaf and distribution parameters.
#' 
#' @param arf Pre-trained \code{\link{adversarial_rf}}. Alternatively, any 
#'   object of class \code{ranger}.
#' @param x Training data for estimating parameters.
#' @param oob Only use out-of-bag samples for parameter estimation? If 
#'   \code{TRUE}, \code{x} must be the same dataset used to train \code{arf}. 
#'   Set to \code{"inbag"} to only use in-bag samples. Default is \code{FALSE}, 
#'   i.e. use all observations.
#' @param family Distribution to use for density estimation of continuous 
#'   features. Current options include truncated normal (the default
#'   \code{family = "truncnorm"}) and uniform (\code{family = "unif"}). See 
#'   Details.
#' @param finite_bounds Impose finite bounds on all continuous variables? If
#'   \code{"local"}, infinite bounds are set to empirical extrema within leaves.
#'   If \code{"global"}, infinite bounds are set to global empirical extrema. 
#'   if \code{"no"} (the default), infinite bounds are left unchanged.
#' @param alpha Optional pseudocount for Laplace smoothing of categorical 
#'   features. This avoids zero-mass points when test data fall outside the 
#'   support of training data. Effectively parameterizes a flat Dirichlet prior
#'   on multinomial likelihoods.
#' @param epsilon Optional slack parameter on empirical bounds when 
#'   \code{finite_bounds != "no"}. This avoids zero-density points when test 
#'   data fall outside the support of training data. The gap between lower and 
#'   upper bounds is expanded by a factor of \code{1 + epsilon}. 
#' @param parallel Compute in parallel? Must register backend beforehand, e.g. 
#'   via \code{doParallel} or \code{doFuture}; see examples.
#'   
#'   
#' @details 
#' \code{forde} extracts leaf parameters from a pretrained forest and learns
#' distribution parameters for data within each leaf. The former includes 
#' coverage (proportion of data falling into the leaf) and split criteria. The 
#' latter includes proportions for categorical features and mean/variance for
#' continuous features. The result is a probabilistic circuit, stored as a 
#' \code{data.table}, which can be used for various downstream inference tasks.
#' 
#' Currently, \code{forde} only provides support for a limited number of 
#' distributional families: truncated normal or uniform for continuous data,
#' and multinomial for discrete data. 
#' 
#' Though \code{forde} was designed to take an adversarial random forest as 
#' input, the function's first argument can in principle be any object of class 
#' \code{ranger}. This allows users to test performance with alternative 
#' pipelines (e.g., with supervised forest input). There is also no requirement 
#' that \code{x} be the data used to fit \code{arf}, unless \code{oob = TRUE}. 
#' In fact, using another dataset here may protect against overfitting. This 
#' connects with Wager & Athey's (2018) notion of "honest trees".
#' 
#' 
#' @return 
#' A \code{list} with 5 elements: (1) parameters for continuous data; (2) 
#' parameters for discrete data; (3) leaf indices and coverage; (4) metadata on
#' variables; and (5) the data input class. This list is used for estimating 
#' likelihoods with \code{\link{lik}} and generating data with \code{\link{forge}}.
#' 
#' 
#' @references 
#' Watson, D., Blesch, K., Kapar, J., & Wright, M. (2023). Adversarial random 
#' forests for density estimation and generative modeling. In \emph{Proceedings 
#' of the 26th International Conference on Artificial Intelligence and 
#' Statistics}, pp. 5357-5375.
#' 
#' Wager, S. & Athey, S. (2018). Estimation and inference of heterogeneous 
#' treatment effects using random forests. \emph{J. Am. Stat. Assoc.}, 
#' \emph{113}(523): 1228-1242.
#' 
#' 
#' @examples
#' # Train ARF and estimate leaf parameters
#' arf <- adversarial_rf(iris)
#' psi <- forde(arf, iris)
#' 
#' # Generate 100 synthetic samples from the iris dataset
#' x_synth <- forge(psi, n_synth = 100)
#'
#' # Condition on Species = "setosa" and Sepal.Length > 6
#' evi <- data.frame(Species = "setosa",
#'                   Sepal.Length = "(6, Inf)")
#' x_synth <- forge(psi, n_synth = 100, evidence = evi)
#' 
#' # Estimate average log-likelihood
#' ll <- lik(psi, iris, arf = arf, log = TRUE)
#' mean(ll)
#' 
#' # Expectation of Sepal.Length for class setosa
#' evi <- data.frame(Species = "setosa")
#' expct(psi, query = "Sepal.Length", evidence = evi)
#' 
#' \dontrun{
#' # Parallelization with doParallel
#' doParallel::registerDoParallel(cores = 4)
#'
#' # ... or with doFuture
#' doFuture::registerDoFuture()
#' future::plan("multisession", workers = 4)
#' }
#' 
#' 
#' @seealso
#' \code{\link{arf}}, \code{\link{adversarial_rf}}, \code{\link{forge}}, 
#' \code{\link{expct}}, \code{\link{lik}}
#' 
#'
#' @export
#' @import ranger 
#' @import data.table
#' @importFrom stats predict runif
#' @importFrom foreach foreach %do% %dopar%
#' 

forde <- function(
    arf, 
    x, 
    oob = FALSE,
    family = 'truncnorm', 
    finite_bounds = c('no', 'local', 'global'),
    alpha = 0,
    epsilon = 0,
    parallel = TRUE) {
  
  # To avoid data.table check issues
  tree <- n_oob <- cvg <- leaf <- variable <- count <- sd <- value <- psi_cnt <- 
    psi_cat <- f_idx <- sigma <- new_min <- new_max <- mid <- sigma0 <- prob <- 
    val <- val_count <- level <- all_na <- i <- k <- cnt <- . <- NA_share <-
    mu <- length_emp <- max_emp <- min_emp <- inbag <- n_inbag <- NULL
  
  # Prelimz
  if (isTRUE(oob) & !nrow(x) %in% c(arf$num.samples, arf$num.samples/2)) {
    stop('Forest must be trained on x when oob = TRUE.')
  }
  if (!family %in% c('truncnorm', 'unif')) {
    stop('family not recognized.')
  }
  
  finite_bounds <- match.arg(finite_bounds)
  
  # Uniform distribution requires finite bounds
  if (family == 'unif' & finite_bounds == 'no') {
    finite_bounds <- 'local'
    warning('Density estimation with uniform distribution requires finite bounds. ',
            'Resetting finite_bounds to "local".')
  }
  
  if (alpha < 0) {
    stop('alpha must be nonnegative.')
  }
  if (epsilon < 0) {
    stop('epsilon must be nonnegative.')
  }
  
  # Prep data
  input_class <- class(x)
  x <- as.data.frame(x)
  inf_flag <- sapply(seq_along(x), function(j) any(is.infinite(x[[j]])))
  if (any(inf_flag)) {
    stop('x contains infinite values.')
  }
  n <- nrow(x)
  d <- ncol(x)
  colnames_x <- colnames(x)
  classes <- sapply(x, class)
  x <- suppressWarnings(prep_x(x))
  factor_cols <- sapply(x, is.factor)
  if (any(factor_cols)) {
    # Store levels used in rf (used for internal calculations with all-NA leaves)
    lvls_rf <- arf$forest$covariate.levels[factor_cols]
    lvl_df_rf <- data.table(variable = colnames_x[factor_cols], val = lvls_rf)[
      , .(val = unlist(val), level = seq_len(length(unlist(val)))), by = variable]
    # Store levels used in data (used for forde output to post-process synthetic data)
    lvl_df_data <- data.table(x)[, .(variable = colnames_x[factor_cols], val = lapply(.SD, levels)) ,.SDcols = factor_cols][
      , .(val = unlist(val)), by = variable]
  } else {
    lvl_df_rf <- lvl_df_data <- data.table()
  }
  names(factor_cols) <- colnames_x
  deci <- rep(NA_integer_, d) 
  if (any(!factor_cols)) {
    deci[!factor_cols] <- sapply(which(!factor_cols), function(j) {
      if (any(grepl('\\.', x[[j]]))) {
        tmp <- x[grepl('\\.', x[[j]]), j]
        out <- max(nchar(sub('.*[.]', '', tmp)))
      } else {
        out <- 0L
      }
      return(out)
    })
  }
  
  # Compute leaf bounds and coverage
  num_trees <- arf$num.trees
  bnd_fn <- function(tree) {
    num_nodes <- length(arf$forest$split.varIDs[[tree]])
    lb <- matrix(-Inf, nrow = num_nodes, ncol = d)
    ub <- matrix(Inf, nrow = num_nodes, ncol = d)
    if (finite_bounds == 'global' & any(!factor_cols)) {
      for (j in which(!factor_cols)) {
        min_j <- min(x[[j]], na.rm = TRUE)
        max_j <- max(x[[j]], na.rm = TRUE)
        gap <- max_j - min_j
        lb[, j] <- min_j - epsilon / 2 * gap
        ub[, j] <- max_j + epsilon / 2 * gap
      }
    }
    for (i in 1:num_nodes) {
      left_child <- arf$forest$child.nodeIDs[[tree]][[1]][i] + 1L
      right_child <- arf$forest$child.nodeIDs[[tree]][[2]][i] + 1L
      splitvarID <- arf$forest$split.varIDs[[tree]][i] + 1L
      splitval <- arf$forest$split.values[[tree]][i]
      if (left_child > 1) {
        ub[left_child, ] <- ub[right_child, ] <- ub[i, ]
        lb[left_child, ] <- lb[right_child, ] <- lb[i, ]
        if (left_child != right_child) {
          # If no pruned node, split changes bounds
          ub[left_child, splitvarID] <- lb[right_child, splitvarID] <- splitval
        }
      }
    }
    leaves <- which(arf$forest$child.nodeIDs[[tree]][[1]] == 0L) 
    colnames(lb) <- colnames(ub) <- colnames_x
    merge(melt(data.table(tree = tree, leaf = leaves, lb[leaves, , drop = FALSE]), 
               id.vars = c('tree', 'leaf'), value.name = 'min'), 
          melt(data.table(tree = tree, leaf = leaves, ub[leaves, , drop = FALSE]), 
               id.vars = c('tree', 'leaf'), value.name = 'max'), 
          by = c('tree', 'leaf', 'variable'), sort = FALSE)
  }
  if (isTRUE(parallel)) {
    bnds <- foreach(tree = seq_len(num_trees), .combine = rbind) %dopar% bnd_fn(tree)
  } else {
    bnds <- foreach(tree = seq_len(num_trees), .combine = rbind) %do% bnd_fn(tree)
  }
  # Compute coverage
  pred <- stats::predict(arf, x, type = 'terminalNodes')$predictions + 1L
  keep <- data.table('tree' = rep(seq_len(num_trees), each = n), 
                     'leaf' = as.vector(pred))
  if (isTRUE(oob)) {
    keep[, oob := as.vector(sapply(seq_len(num_trees), function(b) {
      arf$inbag.counts[[b]][seq_len(n)] == 0L
    }))]
    keep <- keep[oob == TRUE]
    keep <- unique(keep[, cnt := .N, by = .(tree, leaf)])
    keep[, n_oob := sum(oob), by = tree]
    keep[, cvg := cnt / n_oob][, c('oob', 'cnt', 'n_oob') := NULL]
  } else if (oob == "inbag") {
    keep[, inbag := as.vector(sapply(seq_len(num_trees), function(b) {
      arf$inbag.counts[[b]][seq_len(n)] > 0L
    }))]
    keep <- keep[inbag == TRUE]
    keep <- unique(keep[, cnt := .N, by = .(tree, leaf)])
    keep[, n_inbag := sum(inbag), by = tree]
    keep[, cvg := cnt / n_inbag][, c('inbag', 'cnt', 'n_inbag') := NULL]
  } else {
    keep <- unique(keep[, cnt := .N, by = .(tree, leaf)])
    keep[, cvg := cnt / n][, cnt := NULL]
  }
  bnds <- merge(bnds, keep, by = c('tree', 'leaf'), sort = FALSE)
  rm(keep)
  # Create forest index
  setkey(bnds, tree, leaf)
  bnds[, f_idx := .GRP, by = key(bnds)]
  
  # Calculate distribution parameters for each variable
  setnames(x, colnames_x)
  # Continuous case
  if (any(!factor_cols)) {
    psi_cnt_fn <- function(tree) {
      dt <- data.table(x[, !factor_cols, drop = FALSE], leaf = pred[, tree])
      if (isTRUE(oob)) {
        dt <- dt[arf$inbag.counts[[tree]][1:n] == 0L, ]
        dt <- dt[!is.na(leaf)]
      } else if (oob == "inbag") {
        dt <- dt[arf$inbag.counts[[tree]][1:n] > 0L, ]
        dt <- dt[!is.na(leaf)]
      }
      dt <- melt(dt, id.vars = 'leaf', variable.factor = FALSE)[, tree := tree]
      dt <- merge(dt, bnds[, .(tree, leaf, variable, min, max, f_idx)],
                  by = c('tree', 'leaf', 'variable'), sort = FALSE)
      # Caculate bounds for finite_bounds == 'local'
      if (finite_bounds == 'local') {
        dt[, c('min_emp', 'max_emp') := .(min(value, na.rm = T), max(value, na.rm = T)), by = .(leaf, variable)]
        dt[, length_emp := max_emp - min_emp]
        # Calculate bounds if min_emp == max_emp in order to be able to sample from cont. distribution
        length_emp_0_replace <- min(dt[length_emp > 0, min(length_emp, na.rm = T)], max(epsilon, 1e-12))
        dt[length_emp == 0, c('min_emp', 'max_emp', 'length_emp') := .(min_emp - length_emp_0_replace/2, max_emp + length_emp_0_replace/2, length_emp_0_replace)]
        dt[, c('min', 'max', 'min_emp', 'max_emp', 'length_emp') := .(fifelse(!is.finite(min) & !is.na(min_emp), min_emp - length_emp*(epsilon/2), min),
                                                                      fifelse(!is.finite(max) & !is.na(max_emp), max_emp + length_emp*(epsilon/2), max),
                                                                      NULL, NULL, NULL)]
      }
      if (family == 'truncnorm') {
        dt[, c('mu', 'sigma', 'NA_share') := .(mean(value, na.rm = T), sd(value, na.rm = T), sum(is.na(value))/.N),
           by = .(leaf, variable)]
        dt[, c('min_emp', 'max_emp') := .(min(value, na.rm = T), max(value, na.rm = T)), by = variable]
        dt[NA_share == 1, c('min', 'max') := .(fifelse(is.infinite(min), min_emp, min),
                                               fifelse(is.infinite(max), max_emp, max))]
        dt[, c("min_emp", "max_emp") := NULL]
        dt[NA_share == 1, mu := (max + min) / 2]
        dt[is.na(sigma), sigma := 0]
        if (any(dt[, sigma == 0])) {
          dt[, new_min := fifelse(!is.finite(min), min(value, na.rm = TRUE), min), by = variable]
          dt[, new_max := fifelse(!is.finite(max), max(value, na.rm = TRUE), max), by = variable]
          dt[, mid := (new_min + new_max) / 2]
          dt[, sigma0 := (new_max - mid) / stats::qnorm(0.975)] 
          # This prior places 95% of the density within the bounding box.
          # In addition, we set the prior degrees of freedom at nu0 = 2. 
          # Since the mode of a chisq is max(df-2, 0), this means that
          # (1) with a single observation, the posterior reduces to the prior; and
          # (2) with more invariant observations, the posterior tends toward zero.
          dt[sigma == 0, sigma := sqrt(2 / .N * sigma0^2), by = .(variable, leaf)]
          dt[, c('new_min', 'new_max', 'mid', 'sigma0') := NULL]
        }
      } else if (family == 'unif') {
        dt[, NA_share := sum(is.na(value))/.N, by = .(leaf, variable)]
      }
      return(unique(dt[, c('tree', 'leaf', 'value') := NULL]))
    }
    if (isTRUE(parallel)) {
      psi_cnt <- foreach(tree = seq_len(num_trees), .combine = rbind) %dopar% 
        psi_cnt_fn(tree)
    } else {
      psi_cnt <- foreach(tree = seq_len(num_trees), .combine = rbind) %do% 
        psi_cnt_fn(tree)
    }
    setkey(psi_cnt, f_idx, variable)
    setcolorder(psi_cnt, c('f_idx', 'variable'))
  } else {
    psi_cnt <- data.table(f_idx = integer(), variable = character(), min = numeric(), max = numeric(), 
                          mu = numeric(), sigma = numeric(), NA_share = numeric())
  }
  
  # Categorical case
  if (any(factor_cols)) {
    psi_cat_fn <- function(tree) {
      dt <- data.table(x[, factor_cols, drop = FALSE], leaf = pred[, tree])
      if (isTRUE(oob)) {
        dt <- dt[!is.na(leaf)]
      }
      dt <- melt(dt, id.vars = 'leaf', variable.factor = FALSE,
                 value.factor = FALSE, value.name = 'val')[, tree := tree]
      dt[, NA_share := sum(is.na(val))/.N, by = .(leaf, variable)]
      dt <- dt[!(is.na(val) & NA_share != 1)]
      if (dt[, any(NA_share == 1)]) {
        # Handle leaves where all values for a categorical variable are NA
        all_na <- unique(dt[NA_share == 1, ])
        dt <- dt[NA_share != 1, ]
        all_na <- merge(all_na, bnds[, .(tree, leaf, variable, min, max, f_idx)],
                        by = c('tree', 'leaf', 'variable'), sort = FALSE)
        all_na[!is.finite(min), min := 0.5]
        for (j in names(which(factor_cols))) {
          all_na[!is.finite(max) & variable == j, max := lvl_df_rf[variable == j, max(level)]]
        }
        all_na[!grepl('\\.5', min), min := min + 0.5]
        all_na[!grepl('\\.5', max), max := max + 0.5]
        all_na[, min := min + 0.5][, max := max - 0.5]
        all_na <- all_na[, .(level = seq(min, max), NA_share), by = .(leaf, variable)]
        all_na <- merge(all_na, lvl_df_rf, by = c('variable', 'level'))
        all_na[, level := NULL][, tree := tree]
        setcolorder(all_na, colnames(dt))
        dt <- rbind(dt, all_na)
      }
      dt[, count := .N, by = .(leaf, variable)]
      dt <- merge(dt, bnds[, .(tree, leaf, variable, min, max, f_idx)], 
                  by = c('tree', 'leaf', 'variable'), sort = FALSE)
      dt[, c('tree', 'leaf') := NULL]
      if (alpha == 0) {
        dt <- unique(dt[, prob := .N / count, by = .(f_idx, variable, val)])
      } else {
        # Define the range of each variable in each leaf
        dt <- unique(dt[, val_count := .N, by = .(f_idx, variable, val)])
        dt <- merge(dt, lvl_df_rf[, .(k = .N), by = variable], by = "variable")
        dt[!is.finite(min), min := 0.5][!is.finite(max), max := k + 0.5]
        dt[!grepl('\\.5', min), min := min + 0.5][!grepl('\\.5', max), max := max + 0.5]
        dt[, k := max - min]
        # Enumerate each possible leaf-variable-value combo
        tmp <- dt[, seq(min[1] + 0.5, max[1] - 0.5), by = .(f_idx, variable)]
        setnames(tmp, 'V1', 'level')
        tmp <- merge(tmp, lvl_df_rf, by = c('variable', 'level'), 
                     sort = FALSE)[, level := NULL]
        # Populate count, k
        tmp <- merge(tmp, unique(dt[, .(f_idx, variable, count, k)]),
                     by = c('f_idx', 'variable'), sort = FALSE)
        # Merge with dt, set val_count = 0 for possible but unobserved levels
        dt <- merge(tmp, dt, by = c('f_idx', 'variable', 'val', 'count', 'k'), 
                    all.x = TRUE, sort = FALSE)
        dt[is.na(val_count), val_count := 0]
        dt[, NA_share := mean(NA_share, na.rm = T), by = .(f_idx, variable)]
        # Compute posterior probabilities
        dt[, prob := (val_count + alpha) / (count + alpha * k), by = .(f_idx, variable, val)]
        dt[, c('val_count', 'k') := NULL]
      }
      dt[, c('count', 'min', 'max') := NULL]
      setcolorder(dt, c("f_idx", "variable", "val", "prob", "NA_share"))
      dt
    }
    if (isTRUE(parallel)) {
      psi_cat <- foreach(tree = seq_len(num_trees), .combine = rbind) %dopar% 
        psi_cat_fn(tree)
    } else {
      psi_cat <- foreach(tree = seq_len(num_trees), .combine = rbind) %do% 
        psi_cat_fn(tree)
    }
    lvl_df_rf[, level := NULL]
    setkey(psi_cat, f_idx, variable)
    setcolorder(psi_cat, c('f_idx', 'variable'))
  } else {
    psi_cat <- data.table(f_idx = integer(), variable = character(), val = character(), prob = numeric(),
                          NA_share = numeric())
  }
  
  # Add metadata, export
  psi <- list(
    'cnt' = psi_cnt, 
    'cat' = psi_cat, 
    'forest' = unique(bnds[, .(f_idx, tree, leaf, cvg)]),
    'meta' = data.table('variable' = colnames_x, 'class' = classes, 
                        'family' = fifelse(factor_cols, 'multinom', family),
                        'decimals' = deci), 
    'levels' = lvl_df_data, 
    'input_class' = input_class
  )
  return(psi)
}
