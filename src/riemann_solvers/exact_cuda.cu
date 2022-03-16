/*! \file exact_cuda.cu
 *  \brief Function definitions for the cuda exact Riemann solver.*/

#ifdef CUDA

#include "../utils/gpu.hpp"
#include <math.h>
#include <stdio.h>
#include "../global/global.h"
#include "../global/global_cuda.h"
#include "../riemann_solvers/exact_cuda.h"

#ifdef DE //PRESSURE_DE
#include "../utils/hydro_utilities.h"
#endif



/*! \fn Calculate_Exact_Fluxes_CUDA(Real *dev_bounds_L, Real *dev_bounds_R, Real *dev_flux, int nx, int ny, int nz, int n_ghost, Real gamma, int dir, int n_fields)
 *  \brief Exact Riemann solver based on the Fortran code given in Sec. 4.9 of Toro (1999). */
__global__ void Calculate_Exact_Fluxes_CUDA(Real *dev_bounds_L, Real *dev_bounds_R, Real *dev_flux, int nx, int ny, int nz, int n_ghost, Real gamma, int dir, int n_fields)
{
  // get a thread index
  int blockId = blockIdx.x + blockIdx.y*gridDim.x;
  int tid = threadIdx.x + blockId * blockDim.x;
  int zid = tid / (nx*ny);
  int yid = (tid - zid*nx*ny) / nx;
  int xid = tid - zid*nx*ny - yid*nx;

  int n_cells = nx*ny*nz;
  int o1, o2, o3;
  if (dir == 0) {
    o1 = 1; o2 = 2; o3 = 3;
  }
  if (dir == 1) {
    o1 = 2; o2 = 3; o3 = 1;
  }
  if (dir == 2) {
    o1 = 3; o2 = 1; o3 = 2;
  }

  Real dl, vxl, vyl, vzl, pl, cl; //density, velocity, pressure, sound speed (left)
  Real dr, vxr, vyr, vzr, pr, cr; //density, velocity, pressure, sound speed (right)
  Real ds, vs, ps, Es; //sample_CUDAd density, velocity, pressure, total energy
  Real vm, pm; //velocity and pressure in the star region

  #ifdef DE
  Real gel, ger, E_kin, E, dge ;
  #endif

  #ifdef SCALAR
  Real scalarl[NSCALARS], scalarr[NSCALARS];
  #endif


  // Each thread executes the solver independently
  //if (xid > n_ghost-3 && xid < nx-n_ghost+1 && yid < ny && zid < nz)
  if (xid < nx && yid < ny && zid < nz)
  {
    // retrieve primitive variables
    dl  = dev_bounds_L[            tid];
    vxl = dev_bounds_L[o1*n_cells + tid]/dl;
    vyl = dev_bounds_L[o2*n_cells + tid]/dl;
    vzl = dev_bounds_L[o3*n_cells + tid]/dl;
    #ifdef DE //PRESSURE_DE
    E = dev_bounds_L[4*n_cells + tid];
    E_kin = 0.5 * dl * ( vxl*vxl + vyl*vyl + vzl*vzl );
    dge = dev_bounds_L[(n_fields-1)*n_cells + tid];
    pl = hydro_utilities::Get_Pressure_From_DE( E, E - E_kin, dge, gamma );
    #else
    pl  = (dev_bounds_L[4*n_cells + tid] - 0.5*dl*(vxl*vxl + vyl*vyl + vzl*vzl)) * (gamma - 1.0);
    #endif //PRESSURE_DE
    pl  = fmax(pl, (Real) TINY_NUMBER);
    #ifdef SCALAR
    for (int i=0; i<NSCALARS; i++) {
      scalarl[i] = dev_bounds_L[(5+i)*n_cells + tid]/dl;
    }
    #endif
    #ifdef DE
    gel = dge / dl;
    #endif
    dr  = dev_bounds_R[            tid];
    vxr = dev_bounds_R[o1*n_cells + tid]/dr;
    vyr = dev_bounds_R[o2*n_cells + tid]/dr;
    vzr = dev_bounds_R[o3*n_cells + tid]/dr;
    #ifdef DE //PRESSURE_DE
    E = dev_bounds_R[4*n_cells + tid];
    E_kin = 0.5 * dr * ( vxr*vxr + vyr*vyr + vzr*vzr );
    dge = dev_bounds_R[(n_fields-1)*n_cells + tid];
    pr = Get_Pressure_From_DE( E, E - E_kin, dge, gamma );
    #else
    pr  = (dev_bounds_R[4*n_cells + tid] - 0.5*dr*(vxr*vxr + vyr*vyr + vzr*vzr)) * (gamma - 1.0);
    #endif //PRESSURE_DE
    pr  = fmax(pr, (Real) TINY_NUMBER);
    #ifdef SCALAR
    for (int i=0; i<NSCALARS; i++) {
      scalarr[i] = dev_bounds_R[(5+i)*n_cells + tid]/dr;
    }
    #endif
    #ifdef DE
    ger = dge / dr;
    #endif


    // compute sounds speeds in left and right regions
    cl = sqrt(gamma * pl / dl);
    cr = sqrt(gamma * pr / dr);

    // test for the pressure positivity condition
    if ((2.0 / (gamma - 1.0)) * (cl+cr) <= (vxr-vxl))
    {
      // the initial data is such that vacuum is generated
      printf("Vacuum is generated by the initial data.\n");
      printf("%f %f %f %f %f %f\n", dl, vxl, pl, dr, vxr, pr);
    }

    // Find the exact solution for pressure and velocity in the star region
    starpv_CUDA(&pm, &vm, dl, vxl, pl, cl, dr, vxr, pr, cr, gamma);

    //sample_CUDA the solution at the cell interface
    sample_CUDA(pm, vm, &ds, &vs, &ps, dl, vxl, pl, cl, dr, vxr, pr, cr, gamma);

    // calculate the fluxes through the cell interface
    dev_flux[tid] = ds*vs;
    dev_flux[o1*n_cells + tid] = ds*vs*vs+ps;
    if (vs >= 0)
    {
      dev_flux[o2*n_cells + tid] = ds*vs*vyl;
      dev_flux[o3*n_cells + tid] = ds*vs*vzl;
      #ifdef SCALAR
      for (int i=0; i<NSCALARS; i++) {
        dev_flux[(5+i)*n_cells + tid] = ds*vs*scalarl[i];
      }
      #endif
      #ifdef DE
      dev_flux[(n_fields-1)*n_cells + tid] = ds*vs*gel;
      #endif
      Es = (ps/(gamma - 1.0)) + 0.5*ds*(vs*vs + vyl*vyl + vzl*vzl);
    }
    else
    {
      dev_flux[o2*n_cells + tid] = ds*vs*vyr;
      dev_flux[o3*n_cells + tid] = ds*vs*vzr;
      #ifdef SCALAR
      for (int i=0; i<NSCALARS; i++) {
        dev_flux[(5+i)*n_cells + tid] = ds*vs*scalarr[i];
      }
      #endif
      #ifdef DE
      dev_flux[(n_fields-1)*n_cells + tid] = ds*vs*ger;
      #endif
      Es = (ps/(gamma - 1.0)) + 0.5*ds*(vs*vs + vyr*vyr + vzr*vzr);
    }
    dev_flux[4*n_cells + tid] = (Es+ps)*vs;
  }

}


__device__ Real guessp_CUDA(Real dl, Real vxl, Real pl, Real cl, Real dr, Real vxr, Real pr, Real cr, Real gamma)
{
  // purpose:  to provide a guessed value for pressure
  //    pm in the Star Region. The choice is made
  //    according to adaptive Riemann solver using
  //    the PVRS and TSRS approximate Riemann
  //    solvers. See Sect. 9.5 of Toro (1999)

  Real gl, gr, ppv, pm;
  const Real TOL = 1.0e-6;

  // compute guess pressure from PVRS Riemann solver
  ppv = 0.5*(pl + pr) + 0.125*(vxl - vxr)*(dl + dr)*(cl + cr);

  if (ppv < 0.0) ppv = 0.0;
  // Two-Shock Riemann solver with PVRS as estimate
  gl = sqrt((2.0 / ((gamma + 1.0)*dl))/(((gamma - 1.0) / (gamma + 1.0))*pl + ppv));
  gr = sqrt((2.0 / ((gamma + 1.0)*dr))/(((gamma - 1.0) / (gamma + 1.0))*pr + ppv));
  pm = (gl*pl + gr*pr - (vxr-vxl))/(gl + gr);

  if (pm < 0.0) pm = TOL;

  return pm;
}


__device__ void prefun_CUDA(Real *f, Real *fd, Real p, Real dk, Real pk, Real ck, Real gamma)
{
  // purpose:  to evaluate the pressure functions
  // fl and fr in the exact Riemann solver
  // and their first derivatives

  Real qrt;

  if (p <= pk) {
    // rarefaction wave
    *f = (2.0 / (gamma - 1.0))*ck*(powf(p/pk, (gamma - 1.0)/(2.0 * gamma)) - 1.0);
    *fd = (1.0/(dk*ck))*powf((p/pk), -((gamma + 1.0)/(2.0 * gamma)));
  }
  else
  {
    // shock wave
    qrt = sqrt(((2.0 / (gamma + 1.0)) / dk)/((((gamma - 1.0) / (gamma + 1.0)) * pk) + p));
    *f = (p - pk)*qrt;
    *fd = (1.0 - 0.5*(p - pk)/((((gamma - 1.0) / (gamma + 1.0)) * pk) + p))*qrt;
  }
}


__device__ void starpv_CUDA(Real *p, Real *v, Real dl, Real vxl, Real pl, Real cl, Real dr, Real vxr, Real pr, Real cr, Real gamma)
{
  // purpose:  Uses Newton-Raphson iteration
  // to compute the solution for pressure and
  // velocity in the Star Region

  const int nriter = 20;
  const Real TOL = 1.0e-6;
  Real change, fl, fld, fr, frd, pold, pstart;

  //guessed value pstart is computed
  pstart = guessp_CUDA(dl, vxl, pl, cl, dr, vxr, pr, cr, gamma);
  pold = pstart;

  int i = 0;
  for (i=0 ; i <= nriter; i++) {
    prefun_CUDA(&fl, &fld, pold, dl, pl, cl, gamma);
    prefun_CUDA(&fr, &frd, pold, dr, pr, cr, gamma);
    *p = pold - (fl + fr + vxr - vxl)/(fld + frd);
    change = 2.0*fabs((*p - pold)/(*p + pold));

    if (change <= TOL) break;
    if (*p < 0.0) *p = TOL;
    pold = *p;
  }
  if (i > nriter) {
    //printf("Divergence in Newton-Raphson iteration. p = %e\n", *p);
  }

  // compute velocity in star region
  *v = 0.5*(vxl + vxr + fr - fl);

}


__device__ void sample_CUDA(const Real pm, const Real vm, Real *d, Real *v, Real *p,
      Real dl, Real vxl, Real pl, Real cl, Real dr, Real vxr, Real pr, Real cr, Real gamma)
{
  // purpose:  to sample the solution throughout the wave
  //   pattern. Pressure pm and velocity vm in the
  //   star region are known. Sampled
  //   values are d, v, p.

  Real c, sl, sr;

  if (vm >= 0) // sampling point lies to the left of the contact discontinuity
  {
    if (pm <= pl) // left rarefaction
    {
      if (vxl - cl >= 0) // sampled point is in left data state
      {
        *d = dl;
        *v = vxl;
        *p = pl;
      }
      else
      {
        if (vm - cl*powf(pm/pl, (gamma - 1.0)/(2.0 * gamma)) < 0) // sampled point is in star left state
        {
          *d = dl*powf(pm/pl, 1.0/gamma);
          *v = vm;
          *p = pm;
        }
        else // sampled point is inside left fan
        {
          c = (2.0 / (gamma + 1.0))*(cl + ((gamma - 1.0) / 2.0)*vxl);
          *v = c;
          *d = dl*powf(c/cl, 2.0 / (gamma - 1.0));
          *p = pl*powf(c/cl, 2.0 * gamma / (gamma - 1.0));
        }
      }
    }
    else // left shock
    {
      sl = vxl - cl*sqrt(((gamma + 1.0)/(2.0 * gamma))*(pm/pl) + ((gamma - 1.0)/(2.0 * gamma)));
      if (sl >= 0) // sampled point is in left data state
      {
        *d = dl;
        *v = vxl;
        *p = pl;
      }
      else // sampled point is in star left state
      {
        *d = dl*(pm/pl + ((gamma - 1.0) / (gamma + 1.0)))/((pm/pl)*((gamma - 1.0) / (gamma + 1.0)) + 1.0);
        *v = vm;
        *p = pm;
      }
    }
  }
  else // sampling point lies to the right of the contact discontinuity
  {
    if (pm > pr) // right shock
    {
      sr = vxr + cr*sqrt(((gamma + 1.0)/(2.0 * gamma))*(pm/pr) + ((gamma - 1.0)/(2.0 * gamma)));
      if (sr <= 0) // sampled point is in right data state
      {
        *d = dr;
        *v = vxr;
        *p = pr;
      }
      else // sampled point is in star right state
      {
        *d = dr*(pm/pr + ((gamma - 1.0) / (gamma + 1.0)))/((pm/pr)*((gamma - 1.0) / (gamma + 1.0)) + 1.0);
        *v = vm;
        *p = pm;
      }
    }
    else // right rarefaction
    {
      if (vxr + cr <= 0) // sampled point is in right data state
      {
        *d = dr;
        *v = vxr;
        *p = pr;
      }
      else
      {
        if (vm + cr*powf(pm/pr, (gamma - 1.0)/(2.0 * gamma)) >= 0) // sampled point is in star right state
        {
          *d = dr*powf(pm/pr, (1.0/gamma));
          *v = vm;
          *p = pm;
        }
        else // sampled point is inside right fan
        {
          c = (2.0 / (gamma + 1.0))*(cr - ((gamma - 1.0) / 2.0)*vxr);
          *v = -c;
          *d = dr*powf(c/cr, 2.0 / (gamma - 1.0));
          *p = pr*powf(c/cr, 2.0 * gamma / (gamma - 1.0));
        }
      }
    }
  }
}



#endif //CUDA
