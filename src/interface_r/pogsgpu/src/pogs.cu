#include <thrust/device_vector.h>
#include <thrust/functional.h>
#include <thrust/transform.h>

#include <algorithm>
#include <vector>

#include "_interface_defs.h"
#include "cml/cml_blas.cuh"
#include "cml/cml_linalg.cuh"
#include "cml/cml_matrix.cuh"
#include "cml/cml_vector.cuh"
#include "matrix_util.h"
#include "pogs.h"
#include "sinkhorn_knopp.cuh"

// Apply operator to h.a and h.d.
template <typename T, typename Op>
struct ApplyOp: thrust::binary_function<FunctionObj<T>, FunctionObj<T>, T> {
  Op binary_op;
  ApplyOp(Op binary_op) : binary_op(binary_op) { }
  __device__ FunctionObj<T> operator()(FunctionObj<T> &h, T x) {
    h.a = binary_op(h.a, x); h.d = binary_op(h.d, x);
    return h;
  }
};

// Proximal Operator Graph Solver.
template <typename T, typename M>
int Pogs(PogsData<T, M> *pogs_data) {
  // Constants for adaptive-rho and over-relaxation.
  const T kDeltaMin = static_cast<T>(1.05);
  const T kDeltaMax = static_cast<T>(2);
  const T kGamma = static_cast<T>(1.01);
  const T kTau = static_cast<T>(0.8);
  const T kAlpha = static_cast<T>(1.7);
  const T kKappa = static_cast<T>(0.9);

  int err = 0;

  // Extract values from pogs_data
  size_t m = pogs_data->m, n = pogs_data->n, min_dim = std::min(m, n);
  T rho = pogs_data->rho;
  const T kOne = static_cast<T>(1), kZero = static_cast<T>(0);
  thrust::device_vector<FunctionObj<T> > f = pogs_data->f;
  thrust::device_vector<FunctionObj<T> > g = pogs_data->g;

  // Create cuBLAS hdl.
  cublasHandle_t hdl;
  cublasCreate(&hdl);

  // Allocate data for ADMM variables.
  bool compute_factors = true;
  cml::vector<T> de, z, zt;
  cml::vector<T> zprev = cml::vector_calloc<T>(m + n);
  cml::vector<T> z12 = cml::vector_calloc<T>(m + n);
  cml::vector<T> l = cml::vector_calloc<T>(m);
  cml::matrix<T> A, L;
  cml::matrix<T> C = cml::matrix_alloc<T>(m + n, 2);
  if (pogs_data->factors != 0) {
    cudaMemcpy(&rho, pogs_data->factors, sizeof(T), cudaMemcpyDeviceToHost);
    if (rho > 0) {
      compute_factors = false;
    } else {
      rho = pogs_data->rho;
    }
    de = cml::vector_view_array(pogs_data->factors + 1, m + n);
    z = cml::vector_view_array(pogs_data->factors + 1 + m + n, m + n);
    zt = cml::vector_view_array(pogs_data->factors + 1 + 2 * (m + n), m + n);
    L = cml::matrix_view_array(pogs_data->factors + 1 + 3 * (m + n), min_dim,
                               min_dim);
    A = cml::matrix_view_array(pogs_data->factors + 1 + 3 * (m + n) +
                               min_dim * min_dim, m, n);
  } else {
    de = cml::vector_calloc<T>(m + n);
    z = cml::vector_calloc<T>(m + n);
    zt = cml::vector_calloc<T>(m + n);
    L = cml::matrix_alloc<T>(min_dim, min_dim);
    A = cml::matrix_alloc<T>(m, n);
  }

  if (de.data == 0 || z.data == 0 || zt.data == 0 || zprev.data == 0 ||
      z12.data == 0 || l.data == 0 || A.data == 0 || L.data == 0 || C.data == 0)
    err = 1;

  // Create views for x and y components.
  cml::matrix<T> Cx = cml::matrix_submatrix(&C, 0, 0, n, 2);
  cml::matrix<T> Cy = cml::matrix_submatrix(&C, n, 0, m, 2);
  cml::vector<T> d = cml::vector_subvector(&de, 0, m);
  cml::vector<T> e = cml::vector_subvector(&de, m, n);
  cml::vector<T> x = cml::vector_subvector(&z, 0, n);
  cml::vector<T> y = cml::vector_subvector(&z, n, m);
  cml::vector<T> x12 = cml::vector_subvector(&z12, 0, n);
  cml::vector<T> y12 = cml::vector_subvector(&z12, n, m);
  cml::vector<T> cz0 = cml::matrix_column(&C, 0);
  cml::vector<T> cx0 = cml::vector_subvector(&cz0, 0, n);
  cml::vector<T> cy0 = cml::vector_subvector(&cz0, n, m);
  cml::vector<T> cz1 = cml::matrix_column(&C, 1);
  cml::vector<T> cx1 = cml::vector_subvector(&cz1, 0, n);
  cml::vector<T> cy1 = cml::vector_subvector(&cz1, n, m);

  if (compute_factors && !err) {
    // Copy A to device (assume input row-major).
    T *Acm = new T[m * n];
    RowToColMajor(pogs_data->A, m, n, Acm);
    err = Equilibrate(Acm, &d, &e);
    cml::matrix_memcpy(&A, Acm);
    delete [] Acm;

    if (!err) {
      // Compuate A^TA or AA^T.
      cublasOperation_t op_type = m >= n ? CUBLAS_OP_T : CUBLAS_OP_N;
      cml::blas_syrk(hdl, CUBLAS_FILL_MODE_LOWER, op_type, kOne, &A, kZero, &L);

      // Scale A.
      cml::vector<T> diag_L = cml::matrix_diagonal(&L);
      T mean_diag = cml::blas_asum(hdl, &diag_L) / static_cast<T>(min_dim);
      T sqrt_mean_diag = sqrt(mean_diag);
      cml::matrix_scale(&L, kOne / mean_diag);
      cml::matrix_scale(&A, kOne / sqrt_mean_diag);
      T factor = sqrt(cml::blas_nrm2(hdl, &d) * sqrt(static_cast<T>(n)) /
                     (cml::blas_nrm2(hdl, &e) * sqrt(static_cast<T>(m))));
      cml::blas_scal(hdl, kOne / (factor * sqrt(sqrt_mean_diag)), &d);
      cml::blas_scal(hdl, factor / sqrt(sqrt_mean_diag), &e);

      // Compute cholesky decomposition of (I + A^TA) or (I + AA^T)
      cml::vector_add_constant(&diag_L, kOne);
      cml::linalg_cholesky_decomp(hdl, &L);
    }
  }

  // Scale f and g to account for diagonal scaling e and d.
  if (!err) {
    thrust::transform(f.begin(), f.end(), thrust::device_pointer_cast(d.data),
        f.begin(), ApplyOp<T, thrust::divides<T> >(thrust::divides<T>()));
    thrust::transform(g.begin(), g.end(), thrust::device_pointer_cast(e.data),
        g.begin(), ApplyOp<T, thrust::multiplies<T> >(thrust::multiplies<T>()));
  }

  // Signal start of execution.
  if (!pogs_data->quiet)
    Printf("   #      res_pri    eps_pri   res_dual   eps_dual"
           "        gap    eps_gap  objective\n");

  // Initialize scalars.
  T sqrtn_atol = std::sqrt(static_cast<T>(n)) * pogs_data->abs_tol;
  T sqrtm_atol = std::sqrt(static_cast<T>(m)) * pogs_data->abs_tol;
  T sqrtmn_atol = std::sqrt(static_cast<T>(m + n)) * pogs_data->abs_tol;
  T delta = kDeltaMin, xi = static_cast<T>(1.0);
  unsigned int kd = 0, ku = 0;

  for (unsigned int k = 0; k < pogs_data->max_iter && !err; ++k) {
    cml::vector_memcpy(&zprev, &z);

    // Evaluate Proximal Operators
    cml::vector_memcpy(&cz0, &z);
    cml::blas_axpy(hdl, -kOne, &zt, &cz0);
    ProxEval(g, rho, cx0.data, x12.data);
    ProxEval(f, rho, cy0.data, y12.data);

    // Compute Gap.
    T gap, nrm_r, nrm_s;
    cml::blas_axpy(hdl, -kOne, &z12, &cz0);
    cml::blas_dot(hdl, &cz0, &z12, &gap);
    gap = fabs(gap * rho);
    T obj = FuncEval(f, y12.data) + FuncEval(g, x12.data);
    T eps_pri = sqrtm_atol + pogs_data->rel_tol * cml::blas_nrm2(hdl, &z12);
    T eps_dual = sqrtn_atol +
        pogs_data->rel_tol * rho * cml::blas_nrm2(hdl, &cz0);
    T eps_gap = sqrtmn_atol + pogs_data->rel_tol * fabs(obj);

    // Store dual variable
    if (pogs_data->l != 0)
      cml::vector_memcpy(&l, &cy0);

    // Project and Update Dual Variables
    if (m >= n) {
      cml::blas_gemv(hdl, CUBLAS_OP_T, kOne, &A, &cy0, kOne, &cx0);
      nrm_s = rho * cml::blas_nrm2(hdl, &cx0);
      cml::linalg_cholesky_svx(hdl, &L, &cx0);
      cml::vector_memcpy(&cy0, &y);
      cml::vector_memcpy(&cz1, &z12);
      cml::blas_gemm(hdl, CUBLAS_OP_N, CUBLAS_OP_N, -kOne, &A, &Cx, kOne, &Cy);
      nrm_r = cml::blas_nrm2(hdl, &cy1);
      cml::vector_memcpy(&y, &cy0);
      cml::blas_axpy(hdl, -kOne, &cx0, &x);
    } else {
      cml::vector_memcpy(&z, &z12);
      cml::blas_gemv(hdl, CUBLAS_OP_N, kOne, &A, &x, -kOne, &y);
      nrm_r = cml::blas_nrm2(hdl, &y);
      cml::linalg_cholesky_svx(hdl, &L, &y);
      cml::vector_memcpy(&cy1, &y);
      cml::vector_memcpy(&cx1, &x12);
      cml::blas_scal(hdl, -kOne, &cy0);
      cml::blas_gemm(hdl, CUBLAS_OP_T, CUBLAS_OP_N, -kOne, &A, &Cy, kOne, &Cx);
      nrm_s = rho * cml::blas_nrm2(hdl, &cx0);
      cml::vector_memcpy(&x, &cx1);
      cml::blas_axpy(hdl, kOne, &y12, &y);
    }

    // Apply over relaxation.
    cml::blas_scal(hdl, kAlpha, &z);
    cml::blas_axpy(hdl, kOne - kAlpha, &zprev, &z);

    // Update dual variable.
    cml::blas_axpy(hdl, kAlpha, &z12, &zt);
    cml::blas_axpy(hdl, kOne - kAlpha, &zprev, &zt);
    cml::blas_axpy(hdl, -kOne, &z, &zt);

    // Evaluate stopping criteria.
    bool converged = nrm_r < eps_pri && nrm_s < eps_dual && gap < eps_gap;
    if (!pogs_data->quiet && (k % 10 == 0 || converged))
      Printf("%4d :  %.3e  %.3e  %.3e  %.3e  %.3e  %.3e  %.3e\n",
             k, nrm_r, eps_pri, nrm_s, eps_dual, gap, eps_gap, obj);
    if (converged)
      break;

    // Rescale rho.
    if (pogs_data->adaptive_rho) {
      if (nrm_s < xi * eps_dual && nrm_r > xi * eps_pri && kTau * k > kd) {
        rho *= delta;
        cml::blas_scal(hdl, 1 / delta, &zt);
        delta = std::min(kGamma * delta, kDeltaMax);
        ku = k;
      } else if (nrm_s > xi * eps_dual && nrm_r < xi * eps_pri &&
          kTau * k > ku) {
        rho /= delta;
        cml::blas_scal(hdl, delta, &zt);
        delta = std::min(kGamma * delta, kDeltaMax);
        kd = k;
      } else if (nrm_s < xi * eps_dual && nrm_r < xi * eps_pri) {
        xi *= kKappa;
      } else {
        delta = std::max(delta / kGamma, kDeltaMin);
      }
    }
  }

  pogs_data->optval = FuncEval(f, y12.data) + FuncEval(g, x12.data);

  // Scale x, y and l for output.
  cml::vector_div(&y12, &d);
  cml::vector_mul(&x12, &e);
  cml::vector_mul(&l, &d);
  cml::blas_scal(hdl, rho, &l);

  // Copy results to output.
  if (pogs_data->y != 0 && !err)
    cml::vector_memcpy(pogs_data->y, &y12);
  if (pogs_data->x != 0 && !err)
    cml::vector_memcpy(pogs_data->x, &x12);
  if (pogs_data->l != 0 && !err)
    cml::vector_memcpy(pogs_data->l, &l);

  // Store rho and free memory.
  if (pogs_data->factors != 0 && !err) {
    cudaMemcpy(pogs_data->factors, &rho, sizeof(T), cudaMemcpyHostToDevice);
  } else {
    cml::vector_free(&de);
    cml::vector_free(&z);
    cml::vector_free(&zt);
    cml::matrix_free(&L);
    cml::matrix_free(&A);
  }
  cml::matrix_free(&C);
  cml::vector_free(&z12);
  cml::vector_free(&zprev);
  cml::vector_free(&l);
  return err;
}

template <>
int AllocFactors(PogsData<double, double*> *pogs_data) {
  size_t m = pogs_data->m, n = pogs_data->n;
  size_t flen = 1 + 3 * (m + n) + std::min(m, n) * std::min(m, n) + m * n;
  cudaError_t err = cudaMalloc(&pogs_data->factors, flen * sizeof(double));
  if (err == cudaSuccess) {
    cudaMemset(pogs_data->factors, 0, flen * sizeof(double));
    return 0;
  } else {
    return 1;
  }
}

template <>
int AllocFactors(PogsData<float, float*> *pogs_data) {
  size_t m = pogs_data->m, n = pogs_data->n;
  size_t flen = 1 + 3 * (m + n) + std::min(m, n) * std::min(m, n) + m * n;
  cudaError_t err = cudaMalloc(&pogs_data->factors, flen * sizeof(float));
  if (err == cudaSuccess) {
    cudaMemset(pogs_data->factors, 0, flen * sizeof(float));
    return 0;
  } else {
    return 1;
  }
}

template <>
void FreeFactors(PogsData<double, double*> *pogs_data) {
  cudaFree(pogs_data->factors);
}

template <>
void FreeFactors(PogsData<float, float*> *pogs_data) {
  cudaFree(pogs_data->factors);
}

template int Pogs<double>(PogsData<double, double*> *);
template int Pogs<float>(PogsData<float, float*> *);

