module m_solver_3d
  use m_solver_lib_3d

  implicit none

contains

  subroutine initialize(domain_len, grid_size, box_size, applied_voltage)
    real(dp), intent(in) :: domain_len(3)
    integer, intent(in)  :: grid_size(3)
    integer, intent(in)  :: box_size
    real(dp), intent(in) :: applied_voltage
    integer              :: max_lvl

    phi_bc = applied_voltage
    uniform_grid_size = grid_size
    max_lvl = nint(log(grid_size(1) / real(box_size, dp))/log(2.0_dp)) + 1

    if (any(box_size * 2**(max_lvl-1) /= grid_size)) &
         error stop "Incompatible grid size"

    call af_add_cc_variable(tree, "phi", ix=mg%i_phi)
    call af_add_cc_variable(tree, "rhs", ix=mg%i_rhs)
    call af_add_cc_variable(tree, "tmp", ix=mg%i_tmp)
    call af_add_cc_variable(tree, "eps", ix=tree%mg_i_eps)
    call af_add_cc_variable(tree, "sigma", ix=i_sigma)
    call af_add_cc_variable(tree, "dsigma", ix=i_dsigma)
    call af_add_cc_variable(tree, "E_norm", ix=i_E_norm)
    call af_add_fc_variable(tree, "E_vec", ix=i_E_vec)

    call af_set_cc_methods(tree, tree%mg_i_eps, af_bc_neumann_zero)
    call af_set_cc_methods(tree, i_E_norm, af_bc_neumann_zero)

    if (rod_radius > 0) then
       call af_add_cc_variable(tree, "lsf", ix=i_lsf)

       mg%lsf_boundary_value = 0.0_dp ! Electrode is grounded
       mg%lsf => rod_lsf
       tree%mg_i_lsf = i_lsf
       call af_set_cc_methods(tree, i_lsf, funcval=set_lsf_box)
    end if

    call af_init(tree, box_size, domain_len, &
         [box_size, box_size, box_size], coord=af_xyz, &
         mem_limit_gb=2.0_dp)

    call af_refine_up_to_lvl(tree, max_lvl)

    mg%sides_bc => sides_bc ! Method for boundary conditions

    ! Create a copy of the operator but without the variable coefficient
    mg_lpl = mg
    mg_lpl%operator_mask = mg_normal_box + mg_lsf_box
  end subroutine initialize

  subroutine set_rod_electrode(r0, r1, radius)
    real(dp), intent(in) :: r0(3), r1(3), radius

    if (allocated(tree%boxes)) error stop "Set electrode before initialization"
    rod_r0 = r0
    rod_r1 = r1
    rod_radius = radius
  end subroutine set_rod_electrode

  subroutine set_rhs_and_sigma(Nx, Ny, Nz, rhs, sigma)
    integer, intent(in) :: Nx, Ny, Nz
    real(dp), intent(in) :: rhs(Nx, Ny, Nz)
    real(dp), intent(in) :: sigma(Nx, Ny, Nz)

    if (any(shape(rhs) /= uniform_grid_size)) then
       print *, "shape(rhs): ", shape(rhs)
       print *, "uniform_grid_size: ", uniform_grid_size
       error stop "rhs has wrong size"
    end if
    if (any(shape(sigma) /= uniform_grid_size)) then
       print *, "shape(sigma): ", shape(sigma)
       print *, "uniform_grid_size: ", uniform_grid_size
       error stop "sigma has wrong size"
    end if

    rhs_input = rhs
    sigma_input = sigma

    call af_loop_box(tree, set_init_cond, leaves_only=.true.)
  end subroutine set_rhs_and_sigma

  ! Update sigma (conductivity)
  subroutine update_sigma(n_streamers, r0, r1, sigma0, sigma1, radius0, radius1, &
       first_step)
    integer, intent(in)  :: n_streamers
    real(dp), intent(in) :: r0(n_streamers, 3), r1(n_streamers, 3)
    real(dp), intent(in) :: sigma0(n_streamers), sigma1(n_streamers)
    real(dp), intent(in) :: radius0(n_streamers), radius1(n_streamers)
    logical, intent(in)  :: first_step
    integer              :: lvl, n, id, i, j, k, nc, ix
    real(dp)             :: r(3), dist_vec(3), dist_line, frac, tmp
    real(dp), parameter  :: pi = acos(-1.0_dp)

    nc = tree%n_cell

    !$omp parallel private(lvl, n, id, i, j, k, r, dist_vec, dist_line, frac, tmp, ix)
    do lvl = 1, tree%highest_lvl
       !$omp do
       do n = 1, size(tree%lvls(lvl)%leaves)
          id = tree%lvls(lvl)%leaves(n)

          do k = 1, nc
             do j = 1, nc
                do i = 1, nc
                   tree%boxes(id)%cc(i, j, k, i_dsigma) = 0.0_dp

                   if (tree%boxes(id)%cc(i, j, k, i_lsf) < 0.0_dp) cycle

                   r = af_r_cc(tree%boxes(id), [i, j, k])

                   do ix = 1, n_streamers
                      call dist_vec_line(r, r0(ix, :), r1(ix, :), &
                           3, dist_vec, dist_line, frac)

                      ! Exclude semi-sphere of previous point
                      if (norm2(dist_vec) <= radius1(ix) .and. &
                           norm2(r0(ix, :) - r) > radius0(ix) .and. &
                           (frac > 0 .or. first_step)) then
                         ! Determine radial profile
                         tmp = dist_line/radius1(ix)
                         tmp = max(0.0_dp, 1 - 3*tmp**2 + 2*tmp**3)
                         ! Normalize so that integral of 2 * pi * r * f(r) from 0
                         ! to R is unity
                         tmp = tmp * 10 / (3 * pi * radius1(ix)**2)

                         tree%boxes(id)%cc(i, j, k, i_dsigma) = &
                              tree%boxes(id)%cc(i, j, k, i_dsigma) + &
                              (frac * sigma1(ix) + (1-frac) * sigma0(ix)) * tmp
                      end if
                   end do
                end do
             end do
          end do
       end do
       !$omp end do
    end do
    !$omp end parallel

    ! Add the change in sigma
    call af_tree_apply(tree, i_sigma, i_dsigma, '+')

  end subroutine update_sigma

  ! Get the electric field vector at a location
  subroutine get_electric_field(r, E_vec)
    real(dp), intent(in)  :: r(3)
    real(dp), intent(out) :: E_vec(3)
    logical               :: success

    E_vec = af_interp1_fc(tree, r, i_E_vec, success)
    if (.not. success) error stop "Interpolation error"
  end subroutine get_electric_field

  ! Get the potential along a line
  subroutine get_line_potential(r0, r1, n_points, r_line, phi_line)
    real(dp), intent(in)  :: r0(3)
    real(dp), intent(in)  :: r1(3)
    integer, intent(in)   :: n_points
    real(dp), intent(out) :: r_line(3, n_points)
    real(dp), intent(out) :: phi_line(n_points)
    integer               :: i
    logical               :: success
    real(dp)              :: dz(3)

    dz = (r1 - r0) / max(1, n_points-1)

    do i = 1, n_points
       r_line(:, i) = r0 + (i-1) * dz
       phi_line(i:i) = af_interp1(tree, r_line(:, i), [mg%i_phi], success)
       if (.not. success) error stop "interpolation error"
    end do
  end subroutine get_line_potential

  ! Compute new potential for a given time step using the current sigma
  subroutine solve(dt)
    real(dp), intent(in)  :: dt
    integer, parameter    :: max_iterations = 100
    integer               :: mg_iter
    real(dp)              :: residu, prev_residu, max_rhs

    call af_loop_box_arg(tree, set_epsilon_from_sigma, [dt], leaves_only=.true.)
    call af_restrict_tree(tree, [tree%mg_i_eps])
    call af_gc_tree(tree, [tree%mg_i_eps], corners=.false.)

    if (.not. mg%initialized) then
       call mg_init(tree, mg)
       call mg_init(tree, mg_lpl)
    else
       call mg_update_operator_stencil(tree, mg)
    end if

    call af_tree_maxabs_cc(tree, mg%i_rhs, max_rhs)
    prev_residu = huge(1.0_dp)

    do mg_iter = 1, max_iterations
       call mg_fas_fmg(tree, mg, set_residual=.true., have_guess=.true.)
       call af_tree_maxabs_cc(tree, mg%i_tmp, residu)
       if (residu < 1e-5_dp * max_rhs .or. residu > 0.5 * prev_residu) exit
       prev_residu = residu
    end do

    print *, "n_iterations: ", mg_iter, "residu: ", residu

    ! Compute new rhs
    call compute_rhs(tree, mg_lpl)

    ! Compute electric field
    call mg_compute_phi_gradient(tree, mg, i_E_vec, -1.0_dp, i_E_norm)
    call af_gc_tree(tree, [i_E_norm])

  end subroutine solve

  ! Write a silo file
  subroutine write_solution(fname)
    character(len=*), intent(in) :: fname
    call af_write_silo(tree, trim(fname))
  end subroutine write_solution

end module m_solver_3d