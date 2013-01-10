program test_complex2

!-------------------------------------------------------------------------------
! Standard eigenvalue problem - COMPLEX version
!
! This program demonstrates the use of the ELPA module
! together with standard scalapack routines
! 
! Copyright of the original code rests with the authors inside the ELPA
! consortium. The copyright of any additional modifications shall rest
! with their original authors, but shall adhere to the licensing terms
! distributed along with the original code in the file "COPYING".
!-------------------------------------------------------------------------------

   use ELPA1
   use ELPA2

   implicit none
   include 'mpif.h'

   !-------------------------------------------------------------------------------
   ! Please set system size parameters below!
   ! na:   System size
   ! nev:  Number of eigenvectors to be calculated
   ! nblk: Blocking factor in block cyclic distribution
   !-------------------------------------------------------------------------------

   integer, parameter :: na = 4000, nev = 1500, nblk = 16

   !-------------------------------------------------------------------------------
   !  Local Variables

   integer np_rows, np_cols, na_rows, na_cols

   integer myid, nprocs, my_prow, my_pcol, mpi_comm_rows, mpi_comm_cols
   integer i, mpierr, my_blacs_ctxt, sc_desc(9), info, nprow, npcol

   integer, external :: numroc

   real*8 err, errmax
   real*8, allocatable :: ev(:), xr(:,:)
   complex*16 :: xc
   complex*16, allocatable :: a(:,:), z(:,:), tmp1(:,:), tmp2(:,:), as(:,:)

   complex*16, parameter :: CZERO = (0.d0,0.d0), CONE = (1.d0,0.d0)

   integer :: iseed(4096) ! Random seed, size should be sufficient for every generator

   !-------------------------------------------------------------------------------
   !  MPI Initialization

   call mpi_init(mpierr)
   call mpi_comm_rank(mpi_comm_world,myid,mpierr)
   call mpi_comm_size(mpi_comm_world,nprocs,mpierr)

   !-------------------------------------------------------------------------------
   ! Selection of number of processor rows/columns
   ! We try to set up the grid square-like, i.e. start the search for possible
   ! divisors of nprocs with a number next to the square root of nprocs
   ! and decrement it until a divisor is found.

   do np_cols = NINT(SQRT(REAL(nprocs))),2,-1
      if(mod(nprocs,np_cols) == 0 ) exit
   enddo
   ! at the end of the above loop, nprocs is always divisible by np_cols

   np_rows = nprocs/np_cols

   if(myid==0) then
      print *
      print '(a)','Standard eigenvalue problem - COMPLEX version'
      print *
      print '(3(a,i0))','Matrix size=',na,', Number of eigenvectors=',nev,', Block size=',nblk
      print '(3(a,i0))','Number of processor rows=',np_rows,', cols=',np_cols,', total=',nprocs
      print *
   endif

   !-------------------------------------------------------------------------------
   ! Set up BLACS context and MPI communicators
   !
   ! The BLACS context is only necessary for using Scalapack.
   !
   ! For ELPA, the MPI communicators along rows/cols are sufficient,
   ! and the grid setup may be done in an arbitrary way as long as it is
   ! consistent (i.e. 0<=my_prow<np_rows, 0<=my_pcol<np_cols and every
   ! process has a unique (my_prow,my_pcol) pair).

   my_blacs_ctxt = mpi_comm_world
   call BLACS_Gridinit( my_blacs_ctxt, 'C', np_rows, np_cols )
   call BLACS_Gridinfo( my_blacs_ctxt, nprow, npcol, my_prow, my_pcol )

   ! All ELPA routines need MPI communicators for communicating within
   ! rows or columns of processes, these are set in get_elpa_row_col_comms.

   call get_elpa_row_col_comms(mpi_comm_world, my_prow, my_pcol, &
                               mpi_comm_rows, mpi_comm_cols)

   ! Determine the necessary size of the distributed matrices,
   ! we use the Scalapack tools routine NUMROC for that.

   na_rows = numroc(na, nblk, my_prow, 0, np_rows)
   na_cols = numroc(na, nblk, my_pcol, 0, np_cols)

   ! Set up a scalapack descriptor for the checks below.
   ! For ELPA the following restrictions hold:
   ! - block sizes in both directions must be identical (args 4+5)
   ! - first row and column of the distributed matrix must be on row/col 0/0 (args 6+7)

   call descinit( sc_desc, na, na, nblk, nblk, 0, 0, my_blacs_ctxt, na_rows, info )

   !-------------------------------------------------------------------------------
   ! Allocate matrices and set up a test matrix for the eigenvalue problem

   allocate(a (na_rows,na_cols))
   allocate(z (na_rows,na_cols))
   allocate(as(na_rows,na_cols))

   allocate(ev(na))

   ! For getting a hermitian test matrix A we get a random matrix Z
   ! and calculate A = Z + Z**H

   ! We want different random numbers on every process
   ! (otherways A might get rank deficient):

   iseed(:) = myid
   call RANDOM_SEED(put=iseed)

   allocate(xr(na_rows,na_cols))
   call RANDOM_NUMBER(xr)
   z(:,:) = xr(:,:)
   call RANDOM_NUMBER(xr)
   z(:,:) = z(:,:) + (0.d0,1.d0)*xr(:,:)
   deallocate(xr)

   a(:,:) = z(:,:)
   call pztranc(na, na, CONE, z, 1, 1, sc_desc, CONE, a, 1, 1, sc_desc) ! A = A + Z**H


   ! Save original matrix A for later accuracy checks

   as = a

   ! set print flag in elpa1
   elpa_print_times = .true.

   !-------------------------------------------------------------------------------
   ! Calculate eigenvalues/eigenvectors

   call mpi_barrier(mpi_comm_world, mpierr) ! for correct timings only
   call solve_evp_complex_2stage(na, nev, a, na_rows, ev, z, na_rows, nblk, &
                                 mpi_comm_rows, mpi_comm_cols, mpi_comm_world)

   if(myid == 0) print *,'Time transform to tridi :',time_evp_fwd
   if(myid == 0) print *,'Time solve tridi        :',time_evp_solve
   if(myid == 0) print *,'Time transform back EVs :',time_evp_back

   !-------------------------------------------------------------------------------
   ! Test correctness of result (using plain scalapack routines)

   ! 1. Residual (maximum of || A*Zi - Zi*EVi ||)

   deallocate(a)
   allocate(tmp1(na_rows,na_cols))

   ! tmp1 =  A * Z
   call pzgemm('N','N',na,nev,na,CONE,as,1,1,sc_desc, &
               z,1,1,sc_desc,CZERO,tmp1,1,1,sc_desc)

   deallocate(as)
   allocate(tmp2(na_rows,na_cols))

   ! tmp2 = Zi*EVi
   tmp2(:,:) = z(:,:)
   do i=1,nev
      xc = ev(i)
      call pzscal(na,xc,tmp2,1,i,sc_desc,1)
   enddo

   !  tmp1 = A*Zi - Zi*EVi
   tmp1(:,:) =  tmp1(:,:) - tmp2(:,:)

   ! Get maximum norm of columns of tmp1
   errmax = 0
   do i=1,nev
      xc = 0
      call pzdotc(na,xc,tmp1,1,i,sc_desc,1,tmp1,1,i,sc_desc,1)
      errmax = max(errmax, sqrt(real(xc,8)))
   enddo

   ! Get maximum error norm over all processors
   err = errmax
   call mpi_allreduce(err,errmax,1,MPI_REAL8,MPI_MAX,MPI_COMM_WORLD,mpierr)
   if(myid==0) print *
   if(myid==0) print *,'Error Residual     :',errmax

   ! 2. Eigenvector orthogonality

   ! tmp1 = Z**T * Z
   tmp1 = 0
   call pzgemm('C','N',nev,nev,na,CONE,z,1,1,sc_desc, &
               z,1,1,sc_desc,CZERO,tmp1,1,1,sc_desc)
   ! Initialize tmp2 to unit matrix
   tmp2 = 0
   call pzlaset('A',nev,nev,CZERO,CONE,tmp2,1,1,sc_desc)

   ! tmp1 = Z**T * Z - Unit Matrix
   tmp1(:,:) =  tmp1(:,:) - tmp2(:,:)

   ! Get maximum error (max abs value in tmp1)
   err = maxval(abs(tmp1))
   call mpi_allreduce(err,errmax,1,MPI_REAL8,MPI_MAX,MPI_COMM_WORLD,mpierr)
   if(myid==0) print *,'Error Orthogonality:',errmax

   deallocate(z)
   deallocate(tmp1)
   deallocate(tmp2)
   deallocate(ev)

   call mpi_finalize(mpierr)

end

!-------------------------------------------------------------------------------