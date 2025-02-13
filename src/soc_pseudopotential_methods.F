!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2023 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

MODULE soc_pseudopotential_methods
   USE atomic_kind_types,               ONLY: atomic_kind_type
   USE core_ppnl,                       ONLY: build_core_ppnl
   USE cp_cfm_types,                    ONLY: cp_cfm_set_all,&
                                              cp_cfm_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_cp2k_link,              ONLY: cp_dbcsr_alloc_block_from_nbl
   USE cp_dbcsr_operations,             ONLY: copy_dbcsr_to_fm,&
                                              copy_fm_to_dbcsr,&
                                              dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_fm_struct,                    ONLY: cp_fm_struct_type
   USE cp_fm_types,                     ONLY: cp_fm_create,&
                                              cp_fm_get_info,&
                                              cp_fm_release,&
                                              cp_fm_type
   USE dbcsr_api,                       ONLY: dbcsr_add,&
                                              dbcsr_create,&
                                              dbcsr_desymmetrize,&
                                              dbcsr_p_type,&
                                              dbcsr_set,&
                                              dbcsr_type_antisymmetric,&
                                              dbcsr_type_no_symmetry
   USE kinds,                           ONLY: dp
   USE mathconstants,                   ONLY: gaussi,&
                                              z_one,&
                                              z_zero
   USE parallel_gemm_api,               ONLY: parallel_gemm
   USE particle_types,                  ONLY: particle_type
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type
   USE qs_force_types,                  ONLY: qs_force_type
   USE qs_kind_types,                   ONLY: qs_kind_type
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type
   USE soc_pseudopotential_utils,       ONLY: add_dbcsr_submat,&
                                              add_fm_submat,&
                                              create_cfm_double
   USE virial_types,                    ONLY: virial_type
#include "./base/base_uses.f90"

   IMPLICIT NONE

   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'soc_pseudopotential_methods'

   PUBLIC :: V_SOC_xyz_from_pseudopotential, H_KS_spinor, remove_soc_outside_energy_window

CONTAINS

! **************************************************************************************************
!> \brief Compute V^SOC_µν^(α) = ħ/2 < ϕ_µ | sum_ℓ ΔV_ℓ^SO(r,r') L^(α) | ϕ_ν >, α = x, y, z, see
!>        Hartwigsen, Goedecker, Hutter, Eq.(18), (19) (doi.org/10.1103/PhysRevB.58.3641)
!>        Caution: V^SOC_µν^(α) is purely imaginary and Hermitian; V^SOC_µν^(α) is stored as real
!>                 dbcsr matrix mat_V_SOC_xyz without symmetry; V^SOC_µν^(α) is stored without
!>                 the imaginary unit, i.e. mat_V_SOC_xyz is real and antisymmetric
!> \param qs_env ...
!> \param mat_V_SOC_xyz ...
!> \par History
!>    * 09.2023 created
! **************************************************************************************************
   SUBROUTINE V_SOC_xyz_from_pseudopotential(qs_env, mat_V_SOC_xyz)
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: mat_V_SOC_xyz

      CHARACTER(LEN=*), PARAMETER :: routineN = 'V_SOC_xyz_from_pseudopotential'

      INTEGER                                            :: handle, nder, xyz
      LOGICAL                                            :: calculate_forces, use_virial
      REAL(KIND=dp)                                      :: eps_ppnl
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: mat_l, mat_l_nosym, mat_pot_dummy, &
                                                            matrix_dummy
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb, sap_ppnl
      TYPE(particle_type), DIMENSION(:), POINTER         :: particle_set
      TYPE(qs_force_type), DIMENSION(:), POINTER         :: force
      TYPE(qs_kind_type), DIMENSION(:), POINTER          :: qs_kind_set
      TYPE(virial_type), POINTER                         :: virial

      CALL timeset(routineN, handle)

      NULLIFY (qs_kind_set, dft_control, sab_orb, sap_ppnl, particle_set, atomic_kind_set)
      CALL get_qs_env(qs_env=qs_env, qs_kind_set=qs_kind_set, dft_control=dft_control, &
                      matrix_s=matrix_s, atomic_kind_set=atomic_kind_set, &
                      particle_set=particle_set, sab_orb=sab_orb, sap_ppnl=sap_ppnl)

      eps_ppnl = dft_control%qs_control%eps_ppnl

      NULLIFY (mat_l)
      CALL dbcsr_allocate_matrix_set(mat_l, 3, 1)
      DO xyz = 1, 3
         ALLOCATE (mat_l(xyz, 1)%matrix)
         CALL dbcsr_create(mat_l(xyz, 1)%matrix, template=matrix_s(1)%matrix, &
                           matrix_type=dbcsr_type_antisymmetric)
         CALL cp_dbcsr_alloc_block_from_nbl(mat_l(xyz, 1)%matrix, sab_orb)
         CALL dbcsr_set(mat_l(xyz, 1)%matrix, 0.0_dp)
      END DO

      ! get mat_l
      CPASSERT(ASSOCIATED(sap_ppnl))
      nder = 0
      use_virial = .FALSE.
      calculate_forces = .FALSE.

      NULLIFY (mat_pot_dummy)
      CALL dbcsr_allocate_matrix_set(mat_pot_dummy, 1, 1)
      ALLOCATE (mat_pot_dummy(1, 1)%matrix)
      CALL dbcsr_create(mat_pot_dummy(1, 1)%matrix, template=matrix_s(1)%matrix)
      CALL cp_dbcsr_alloc_block_from_nbl(mat_pot_dummy(1, 1)%matrix, sab_orb)
      CALL dbcsr_set(mat_pot_dummy(1, 1)%matrix, 0.0_dp)

      CALL build_core_ppnl(mat_pot_dummy, matrix_dummy, force, virial, &
                           calculate_forces, use_virial, nder, &
                           qs_kind_set, atomic_kind_set, particle_set, sab_orb, sap_ppnl, &
                           eps_ppnl, nimages=1, basis_type="ORB", matrix_l=mat_l)

      NULLIFY (mat_l_nosym)
      CALL dbcsr_allocate_matrix_set(mat_l_nosym, 3, 1)
      DO xyz = 1, 3
         ALLOCATE (mat_l_nosym(xyz, 1)%matrix)
         CALL dbcsr_create(mat_l_nosym(xyz, 1)%matrix, template=matrix_s(1)%matrix, &
                           matrix_type=dbcsr_type_no_symmetry)
         CALL dbcsr_desymmetrize(mat_l(xyz, 1)%matrix, mat_l_nosym(xyz, 1)%matrix)

      END DO

      NULLIFY (mat_V_SOC_xyz)
      CALL dbcsr_allocate_matrix_set(mat_V_SOC_xyz, 3, 1)
      DO xyz = 1, 3
         ALLOCATE (mat_V_SOC_xyz(xyz, 1)%matrix)
         CALL dbcsr_create(mat_V_SOC_xyz(xyz, 1)%matrix, template=matrix_s(1)%matrix, &
                           matrix_type=dbcsr_type_no_symmetry)
         CALL cp_dbcsr_alloc_block_from_nbl(mat_V_SOC_xyz(xyz, 1)%matrix, sab_orb)
         ! factor 0.5 from ħ/2 prefactor
         CALL dbcsr_add(mat_V_SOC_xyz(xyz, 1)%matrix, mat_l_nosym(xyz, 1)%matrix, 0.0_dp, 0.5_dp)
      END DO

      CALL dbcsr_deallocate_matrix_set(mat_pot_dummy)
      CALL dbcsr_deallocate_matrix_set(mat_l_nosym)
      CALL dbcsr_deallocate_matrix_set(mat_l)

      CALL timestop(handle)

   END SUBROUTINE V_SOC_xyz_from_pseudopotential

! **************************************************************************************************
!> \brief Spinor KS-matrix H_µν,σσ' = h_µν*δ_σσ' + sum_α V^SOC_µν^(α)*Pauli-matrix^(α)_σσ', see
!>        Hartwigsen, Goedecker, Hutter, Eq.(18) (doi.org/10.1103/PhysRevB.58.3641)
!> \param cfm_ks_spinor_ao ...
!> \param fm_ks ...
!> \param mat_V_SOC_xyz ...
!> \param cfm_s_double ...
!> \param fm_s ...
! **************************************************************************************************
   SUBROUTINE H_KS_spinor(cfm_ks_spinor_ao, fm_ks, mat_V_SOC_xyz, cfm_s_double, fm_s)
      TYPE(cp_cfm_type)                                  :: cfm_ks_spinor_ao
      TYPE(cp_fm_type)                                   :: fm_ks
      TYPE(dbcsr_p_type), DIMENSION(:)                   :: mat_V_SOC_xyz
      TYPE(cp_cfm_type), OPTIONAL                        :: cfm_s_double
      TYPE(cp_fm_type), OPTIONAL                         :: fm_s

      CHARACTER(LEN=*), PARAMETER                        :: routineN = 'H_KS_spinor'

      INTEGER                                            :: handle, nao, s
      TYPE(cp_fm_struct_type), POINTER                   :: str

      CALL timeset(routineN, handle)

      CALL cp_fm_get_info(fm_ks, nrow_global=nao)

      CALL create_cfm_double(fm_ks, cfm_ks_spinor_ao)
      CALL cp_cfm_set_all(cfm_ks_spinor_ao, z_zero)

      str => fm_ks%matrix_struct

      s = nao + 1

      CALL add_dbcsr_submat(cfm_ks_spinor_ao, mat_V_SOC_xyz(1)%matrix, str, s, 1, z_one, .TRUE.)
      CALL add_dbcsr_submat(cfm_ks_spinor_ao, mat_V_SOC_xyz(2)%matrix, str, s, 1, gaussi, .TRUE.)
      CALL add_dbcsr_submat(cfm_ks_spinor_ao, mat_V_SOC_xyz(3)%matrix, str, 1, 1, z_one, .FALSE.)
      CALL add_dbcsr_submat(cfm_ks_spinor_ao, mat_V_SOC_xyz(3)%matrix, str, s, s, -z_one, .FALSE.)

      CALL add_fm_submat(cfm_ks_spinor_ao, fm_ks, 1, 1)
      CALL add_fm_submat(cfm_ks_spinor_ao, fm_ks, s, s)

      IF (PRESENT(cfm_s_double)) THEN
         CPASSERT(PRESENT(fm_s))
         CALL create_cfm_double(fm_s, cfm_s_double)
         CALL cp_cfm_set_all(cfm_s_double, z_zero)
         CALL add_fm_submat(cfm_s_double, fm_s, 1, 1)
         CALL add_fm_submat(cfm_s_double, fm_s, s, s)
      END IF

      CALL timestop(handle)

   END SUBROUTINE H_KS_spinor

! **************************************************************************************************
!> \brief ...
!> \param mat_V_SOC_xyz ...
!> \param e_win ...
!> \param fm_mo_coeff ...
!> \param homo ...
!> \param eigenval ...
!> \param fm_s ...
! **************************************************************************************************
   SUBROUTINE remove_soc_outside_energy_window(mat_V_SOC_xyz, e_win, fm_mo_coeff, homo, &
                                               eigenval, fm_s)
      TYPE(dbcsr_p_type), DIMENSION(:)                   :: mat_V_SOC_xyz
      REAL(KIND=dp)                                      :: e_win
      TYPE(cp_fm_type)                                   :: fm_mo_coeff
      INTEGER                                            :: homo
      REAL(KIND=dp), DIMENSION(:)                        :: eigenval
      TYPE(cp_fm_type)                                   :: fm_s

      CHARACTER(LEN=*), PARAMETER :: routineN = 'remove_soc_outside_energy_window'

      INTEGER                                            :: handle, i_glob, iiB, j_glob, jjB, nao, &
                                                            ncol_local, nrow_local, xyz
      INTEGER, DIMENSION(:), POINTER                     :: col_indices, row_indices
      REAL(KIND=dp)                                      :: E_HOMO, E_i, E_j, E_LUMO
      TYPE(cp_fm_type)                                   :: fm_V_ao, fm_V_mo, fm_work

      CALL timeset(routineN, handle)

      CALL cp_fm_create(fm_work, fm_s%matrix_struct)
      CALL cp_fm_create(fm_V_ao, fm_s%matrix_struct)
      CALL cp_fm_create(fm_V_mo, fm_s%matrix_struct)

      CALL cp_fm_get_info(matrix=fm_s, &
                          nrow_local=nrow_local, &
                          ncol_local=ncol_local, &
                          row_indices=row_indices, &
                          col_indices=col_indices)

      nao = SIZE(eigenval)

      E_HOMO = eigenval(homo)
      E_LUMO = eigenval(homo + 1)

      DO xyz = 1, 3

         CALL copy_dbcsr_to_fm(mat_V_SOC_xyz(xyz)%matrix, fm_V_ao)

         ! V_MO = C^T*V_AO*C
         CALL parallel_gemm(transa="N", transb="N", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_V_ao, matrix_b=fm_mo_coeff, beta=0.0_dp, matrix_c=fm_work)

         CALL parallel_gemm(transa="T", transb="N", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_mo_coeff, matrix_b=fm_work, beta=0.0_dp, matrix_c=fm_V_mo)

         DO jjB = 1, ncol_local
            j_glob = col_indices(jjB)
            DO iiB = 1, nrow_local
               i_glob = row_indices(iiB)

               E_i = eigenval(i_glob)
               E_j = eigenval(j_glob)

               IF (E_i < E_HOMO - 0.5_dp*e_win .OR. E_i > E_LUMO + 0.5_dp*e_win .OR. &
                   E_j < E_HOMO - 0.5_dp*e_win .OR. E_j > E_LUMO + 0.5_dp*e_win) THEN
                  fm_V_mo%local_data(iiB, jjB) = 0.0_dp
               END IF

            END DO
         END DO

         ! V_AO = S*C*V_MO*C^T*S
         CALL parallel_gemm(transa="N", transb="T", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_V_mo, matrix_b=fm_mo_coeff, beta=0.0_dp, matrix_c=fm_work)

         CALL parallel_gemm(transa="N", transb="N", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_mo_coeff, matrix_b=fm_work, beta=0.0_dp, matrix_c=fm_V_ao)

         CALL parallel_gemm(transa="N", transb="N", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_s, matrix_b=fm_V_ao, beta=0.0_dp, matrix_c=fm_work)

         CALL parallel_gemm(transa="N", transb="N", m=nao, n=nao, k=nao, alpha=1.0_dp, &
                            matrix_a=fm_work, matrix_b=fm_s, beta=0.0_dp, matrix_c=fm_V_ao)

         CALL copy_fm_to_dbcsr(fm_V_ao, mat_V_SOC_xyz(xyz)%matrix)

      END DO

      CALL cp_fm_release(fm_work)
      CALL cp_fm_release(fm_V_ao)
      CALL cp_fm_release(fm_V_mo)

      CALL timestop(handle)

   END SUBROUTINE remove_soc_outside_energy_window

END MODULE soc_pseudopotential_methods
