% Generated by roxygen2 (4.0.1): do not edit by hand
\name{pogsnet}
\alias{pogsnet}
\title{Fit a GLM with lasso or elasticnet regularization using POGS}
\usage{
pogsnet(x, y, family = c("gaussian", "binomial"), weights, alpha = 1,
  nlambda = 100, lambda.min.ratio = ifelse(nobs < nvars, 0.01, 1e-04),
  lambda = NULL, penalty.factor = rep(1, nvars), intercept = TRUE,
  params = list(quiet = TRUE), cutoff = TRUE)
}
\arguments{
\item{x}{Input matrix.}

\item{y}{Response variable.}

\item{family}{Response type.}

\item{weights}{Observation weights.}

\item{alpha}{The elasticnet mixing parameter with \eqn{0 \le \alpha \le 1}. The penalty
is defined as \deqn{(1-\alpha)/2||\beta||_2^2 + \alpha ||\beta||_1.}}

\item{nlambda}{The number of \code{lambda} values.}

\item{lambda.min.ratio}{Smallest value for \code{lambda} as fraction of \code{lambda.max}.}

\item{lambda}{A user supplied \eqn{lambda} sequence.}

\item{penalty.factor}{Separate penalty factors can be applied to each coefficient.}

\item{intercept}{Should intercept be fitted.}

\item{params}{Pass list of parameters to solver}

\item{cutoff}{Discard values of lambda for which beta remains unchanged.}
}
\description{
Fit a generalized linear model via penalized maximum likelihood.
See glmnet package for more detail.
}

