!--------------------------------------------------------------------------------------------------!
! Copyright (C) by the DBCSR developers group - All rights reserved                                !
! This file is part of the DBCSR library.                                                          !
!                                                                                                  !
! For information on the license, see the LICENSE file.                                            !
! For further information please visit https://dbcsr.cp2k.org                                      !
! SPDX-License-Identifier: GPL-2.0+                                                                !
!--------------------------------------------------------------------------------------------------!

MODULE dbcsr_acc_operations
   !! Accelerator support for DBCSR
   USE ISO_C_BINDING, ONLY: C_INT, &
                            C_PTR, &
                            C_CHAR, &
                            C_LOC
   USE dbcsr_acc_devmem, ONLY: acc_devmem_cptr, &
                               acc_devmem_type
   USE dbcsr_acc_stream, ONLY: acc_stream_cptr, &
                               acc_stream_type, &
                               acc_stream_synchronize
   USE dbcsr_config, ONLY: max_kernel_dim
   USE dbcsr_mm_types, ONLY: dbcsr_ps_width
   USE dbcsr_kinds, ONLY: real_8, dp
   USE dbcsr_types, ONLY: dbcsr_type_real_8

!$ USE OMP_LIB, ONLY: omp_get_thread_num, omp_get_num_threads

#include "base/dbcsr_base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'dbcsr_acc_operations'

   LOGICAL, PARAMETER :: careful_mod = .FALSE.

   PUBLIC :: dbcsr_acc_do_mm_stack, dbcsr_acc_transpose

#if defined (__DBCSR_ACC)
   INTERFACE
      FUNCTION libsmm_acc_process_cu(param_stack_host, param_stack_dev, stack_size, nparams, &
                                     data_type, a_data, b_data, c_data, m_max, &
                                     n_max, k_max, max_kernel_dim, def_mnk, &
                                     stream_ptr) &
         RESULT(istat) &
         BIND(C, name="libsmm_acc_process")
         IMPORT
         TYPE(C_PTR), INTENT(IN), VALUE           :: param_stack_host
         TYPE(C_PTR), INTENT(IN), VALUE           :: param_stack_dev
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: stack_size, nparams, data_type
         TYPE(C_PTR), INTENT(IN), VALUE           :: a_data, b_data, c_data
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: m_max, n_max, k_max
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: max_kernel_dim, def_mnk
         TYPE(C_PTR), VALUE                       :: stream_ptr
         INTEGER(KIND=C_INT)                      :: istat

      END FUNCTION libsmm_acc_process_cu
   END INTERFACE

   INTERFACE
      FUNCTION libsmm_acc_transpose_cu(trs_stack, offset, nblks, buffer, &
                                       data_type, m, n, max_kernel_dim, stream_ptr) &
         RESULT(istat) &
         BIND(C, name="libsmm_acc_transpose")
         IMPORT
         TYPE(C_PTR), INTENT(IN), VALUE           :: trs_stack
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: offset, nblks
         TYPE(C_PTR), INTENT(IN), VALUE           :: buffer
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: data_type, m, n
         INTEGER(KIND=C_INT), INTENT(IN), VALUE   :: max_kernel_dim
         TYPE(C_PTR), VALUE                       :: stream_ptr
         INTEGER(KIND=C_INT)                      :: istat

      END FUNCTION libsmm_acc_transpose_cu
   END INTERFACE
#endif

CONTAINS

   SUBROUTINE dbcsr_acc_do_mm_stack(param_stack_host, param_stack_dev, stack_size, datatype, &
      !! Launch an accelerated kernel for processing a stack.
                                    a_data, b_data, c_data, m_max, n_max, k_max, def_mnk, stream, success)
      INTEGER, DIMENSION(:, :), TARGET, INTENT(IN) :: param_stack_host
      TYPE(acc_devmem_type), INTENT(IN)            :: param_stack_dev
      INTEGER, INTENT(IN)                          :: stack_size
      INTEGER, INTENT(IN)                          :: datatype
      TYPE(acc_devmem_type), INTENT(IN)            :: a_data, b_data
      TYPE(acc_devmem_type), INTENT(INOUT)         :: c_data
      INTEGER, INTENT(IN)                          :: m_max, n_max, k_max
      LOGICAL, INTENT(IN)                          :: def_mnk
      TYPE(acc_stream_type), INTENT(IN)            :: stream
      LOGICAL, INTENT(INOUT)                       :: success

#if ! defined (__DBCSR_ACC)
      MARK_USED(param_stack_host)
      MARK_USED(param_stack_dev)
      MARK_USED(stack_size)
      MARK_USED(datatype)
      MARK_USED(a_data)
      MARK_USED(b_data)
      MARK_USED(c_data)
      MARK_USED(m_max)
      MARK_USED(n_max)
      MARK_USED(k_max)
      MARK_USED(def_mnk)
      MARK_USED(stream)
      MARK_USED(success)
      DBCSR_ABORT("__DBCSR_ACC not compiled in.")
#else

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_acc_do_mm_stack', &
                                     routineP = moduleN//':'//routineN

      INTEGER                                  :: error_handle, istat
      INTEGER(KIND=C_INT)                      :: mnk
      INTEGER, DIMENSION(:, :), POINTER         :: param_stack_host_ptr

      param_stack_host_ptr => param_stack_host(:, :)

      IF (careful_mod) CALL timeset(routineN, error_handle)

      mnk = 0
      IF (def_mnk) mnk = 1
      istat = -100 ! big kernels

      ! Call batched matrix-matrix multiplication in libsmm_acc
      istat = libsmm_acc_process_cu(C_LOC(param_stack_host_ptr), &
                                    acc_devmem_cptr(param_stack_dev), &
                                    INT(stack_size, KIND=C_INT), &
                                    INT(dbcsr_ps_width, KIND=C_INT), &
                                    INT(datatype, KIND=C_INT), &
                                    acc_devmem_cptr(a_data), &
                                    acc_devmem_cptr(b_data), &
                                    acc_devmem_cptr(c_data), &
                                    INT(m_max, KIND=C_INT), &
                                    INT(n_max, KIND=C_INT), &
                                    INT(k_max, KIND=C_INT), &
                                    INT(max_kernel_dim, KIND=C_INT), &
                                    mnk, acc_stream_cptr(stream))
      IF (istat == 100) DBCSR_ABORT("failed due to accGetLastError().")
      success = (istat == 0) ! false if no suitable kernel was found

      IF (careful_mod) CALL timestop(error_handle)
#endif
   END SUBROUTINE dbcsr_acc_do_mm_stack

   SUBROUTINE dbcsr_acc_transpose(trs_stack, offset, nblks, datatype, buffer, m, n, stream)
      !! Launch an accelerated transpose kernel
      TYPE(acc_devmem_type), INTENT(IN)        :: trs_stack
      INTEGER, INTENT(IN)                      :: offset
      INTEGER, INTENT(IN)                      :: nblks
      INTEGER, INTENT(IN)                      :: datatype
      TYPE(acc_devmem_type), INTENT(IN)        :: buffer
      INTEGER, INTENT(IN)                      :: m, n
      TYPE(acc_stream_type), INTENT(IN)        :: stream

#if ! defined (__DBCSR_ACC)
      MARK_USED(trs_stack)
      MARK_USED(offset)
      MARK_USED(nblks)
      MARK_USED(datatype)
      MARK_USED(buffer)
      MARK_USED(m)
      MARK_USED(n)
      MARK_USED(stream)
      DBCSR_ABORT("__DBCSR_ACC not compiled in.")
#else

      CHARACTER(len=*), PARAMETER :: routineN = 'dbcsr_acc_transpose', &
                                     routineP = moduleN//':'//routineN

      INTEGER                                  :: error_handle, istat

      IF (careful_mod) CALL timeset(routineN, error_handle)
      istat = 0

      ! Call batched in-place transpose in libsmm_acc
      IF (m .LE. max_kernel_dim .AND. &
          n .LE. max_kernel_dim) THEN
         istat = libsmm_acc_transpose_cu(acc_devmem_cptr(trs_stack), &
                                         INT(offset, KIND=C_INT), &
                                         INT(nblks, KIND=C_INT), &
                                         acc_devmem_cptr(buffer), &
                                         INT(datatype, KIND=C_INT), &
                                         INT(m, KIND=C_INT), &
                                         INT(n, KIND=C_INT), &
                                         INT(max_kernel_dim, KIND=C_INT), &
                                         acc_stream_cptr(stream))
      ENDIF

      IF (istat /= 0) DBCSR_ABORT("something went wrong.")
      IF (careful_mod) CALL timestop(error_handle)
#endif
   END SUBROUTINE dbcsr_acc_transpose

END MODULE dbcsr_acc_operations
