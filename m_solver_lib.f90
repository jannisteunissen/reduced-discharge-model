module m_solver_lib
  use m_af_all

  implicit none

  real(dp), parameter :: eps0 = 8.8541878176d-12 ! permitivity of vacuum (SI)
  real(dp), parameter :: pi = acos(-1.0_dp)

  type(af_t) :: tree
  type(mg_t) :: mg
  type(mg_t) :: mg_lpl
  real(dp)   :: phi_bc
  integer    :: i_sigma
  integer    :: i_dsigma
  integer    :: uniform_grid_size(2)

  real(dp), allocatable :: rhs_input(:, :), sigma_input(:, :)

contains

  ! This routine sets the initial conditions for each box
  subroutine set_init_cond(box)
    type(box_t), intent(inout) :: box
    integer                    :: i, j, nc, ix_offset(2), k1, k2

    nc                     = box%n_cell
    box%cc(:, :, mg%i_phi) = 0
    ix_offset              = (box%ix - 1) * nc

    do j = 1, nc
       do i = 1, nc
          k1 = ix_offset(1) + i
          k2 = ix_offset(2) + j

          box%cc(i, j, i_sigma)  = sigma_input(k1, k2)
          box%cc(i, j, mg%i_rhs) = rhs_input(k1, k2)
       end do
    end do
  end subroutine set_init_cond

  subroutine set_epsilon_from_sigma(box, dt_vec)
    type(box_t), intent(inout) :: box
    real(dp), intent(in)       :: dt_vec(:)
    integer                    :: nc

    nc = box%n_cell
    box%cc(1:nc, 1:nc, tree%mg_i_eps) = 1 + (dt_vec(1)/eps0) * &
         box%cc(1:nc, 1:nc, i_sigma)
  end subroutine set_epsilon_from_sigma

  subroutine compute_rhs(tree, mg)
    type(af_t), intent(inout) :: tree
    type(mg_t), intent(in)    :: mg
    integer                   :: lvl, i, id

    call mg_use(tree, mg)

    !$omp parallel private(lvl, i, id)
    do lvl = 1, tree%highest_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%leaves)
          id = tree%lvls(lvl)%leaves(i)
          call mg%box_op(tree%boxes(id), mg%i_rhs, mg)
       end do
       !$omp end do
    end do
    !$omp end parallel
  end subroutine compute_rhs

  ! This routine sets boundary conditions for a box
  subroutine sides_bc(box, nb, iv, coords, bc_val, bc_type)
    type(box_t), intent(in) :: box
    integer, intent(in)     :: nb
    integer, intent(in)     :: iv
    real(dp), intent(in)    :: coords(2, box%n_cell)
    real(dp), intent(out)   :: bc_val(box%n_cell)
    integer, intent(out)    :: bc_type

    if (nb == af_neighb_lowy) then
       bc_type = af_bc_dirichlet
       bc_val = 0.0_dp
    else if (nb == af_neighb_highy) then
       bc_type = af_bc_dirichlet
       bc_val = phi_bc
    else
       bc_type = af_bc_neumann
       bc_val = 0.0_dp
    end if
  end subroutine sides_bc

  ! Compute distance from a line
  pure subroutine dist_vec_line(r, r0, r1, n_dim, dist_vec, frac)
    integer, intent(in)   :: n_dim
    real(dp), intent(in)  :: r(n_dim), r0(n_dim), r1(n_dim)
    real(dp), intent(out) :: dist_vec(n_dim)
    real(dp), intent(out) :: frac !< Fraction [0,1] along line
    real(dp)              :: line_len2

    line_len2 = sum((r1 - r0)**2)
    frac = sum((r - r0) * (r1 - r0))

    if (frac <= 0.0_dp) then
       frac = 0.0_dp
       dist_vec = r - r0
    else if (frac >= line_len2) then
       frac = 1.0_dp
       dist_vec = r - r1
    else
       dist_vec = r - (r0 + frac/line_len2 * (r1 - r0))
       frac = frac / line_len2
    end if
  end subroutine dist_vec_line

end module m_solver_lib