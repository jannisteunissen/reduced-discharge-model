module m_solver
  use m_solver_lib

  implicit none

contains

  subroutine initialize(domain_len, grid_size, box_size, applied_voltage)
    real(dp), intent(in) :: domain_len(2)
    integer, intent(in)  :: grid_size(2)
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
    call af_add_cc_variable(tree, "phi", ix=mg%i_phi)
    call af_add_cc_variable(tree, "E_norm", ix=i_E_norm)
    call af_add_cc_variable(tree, "time", ix=i_time)
    call af_add_fc_variable(tree, "E_vec", ix=i_E_vec)

    call af_set_cc_methods(tree, tree%mg_i_eps, af_bc_neumann_zero)
    call af_set_cc_methods(tree, i_E_norm, af_bc_neumann_zero)
    call af_set_cc_methods(tree, i_time, af_bc_neumann_zero)

    if (rod_radius > 0) then
       call af_add_cc_variable(tree, "lsf", ix=i_lsf)

       mg%lsf_boundary_value = 0.0_dp ! Electrode is grounded
       mg%lsf => rod_lsf
       tree%mg_i_lsf = i_lsf
       call af_set_cc_methods(tree, i_lsf, funcval=set_lsf_box)
    end if

    call af_init(tree, box_size, domain_len, &
         [box_size, box_size], coord=af_cyl, &
         mem_limit_gb=0.1_dp)

    call af_refine_up_to_lvl(tree, max_lvl)

    mg%sides_bc => sides_bc ! Method for boundary conditions

    ! Create a copy of the operator but without the variable coefficient
    mg_lpl = mg
    mg_lpl%operator_mask = mg_normal_box + mg_lsf_box
  end subroutine initialize

  subroutine set_rod_electrode(r0, r1, radius)
    real(dp), intent(in) :: r0(2), r1(2), radius

    if (allocated(tree%boxes)) error stop "Set electrode before initialization"
    rod_r0 = r0
    rod_r1 = r1
    rod_radius = radius
  end subroutine set_rod_electrode

  subroutine set_rhs_and_sigma(Nr, Nz, rhs, sigma)
    integer, intent(in) :: Nr, Nz
    real(dp), intent(in) :: rhs(Nr, Nz)
    real(dp), intent(in) :: sigma(Nr, Nz)

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
       t, dt, channel_delay, first_step)
    integer, intent(in)  :: n_streamers
    real(dp), intent(in) :: r0(n_streamers, 2), r1(n_streamers, 2)
    real(dp), intent(in) :: sigma0(n_streamers), sigma1(n_streamers)
    real(dp), intent(in) :: radius0(n_streamers), radius1(n_streamers)
    real(dp), intent(in) :: t
    real(dp), intent(in) :: dt
    real(dp), intent(in) :: channel_delay
    logical, intent(in)  :: first_step
    integer              :: lvl, n, id, i, j, nc, ix
    real(dp)             :: r(2), dist_vec(2), dist_line, frac, tmp
    real(dp)             :: k_eff
    real(dp), parameter  :: pi = acos(-1.0_dp)
    real(dp), parameter  :: min_electrode_distance = 1e-4_dp

    nc = tree%n_cell

    if (.not. allocated(k_eff_table)) error stop "Call store_k_eff first"

    !$omp parallel private(lvl, n, id, i, j, k, r, dist_vec, dist_line, &
    !$omp &frac, tmp, ix, k_eff)
    do lvl = 1, tree%highest_lvl
       !$omp do
       do n = 1, size(tree%lvls(lvl)%leaves)
          id = tree%lvls(lvl)%leaves(n)

          associate (box => tree%boxes(id))
            do j = 1, nc
               do i = 1, nc
                  box%cc(i, j, i_dsigma) = 0.0_dp

                  if (box%cc(i, j, i_lsf) < 0.0_dp) cycle

                  r = af_r_cc(box, [i, j])

                  do ix = 1, n_streamers
                     call dist_vec_line(r, r0(ix, :), r1(ix, :), &
                          2, dist_vec, dist_line, frac)

                     ! Exclude semi-sphere of previous point
                     if (norm2(dist_vec) <= radius1(ix) .and. (first_step .or. &
                          (frac > 0 .and. norm2(r0(ix, :) - r) > radius0(ix)))) then
                        ! Determine radial profile
                        tmp = dist_line/radius1(ix)
                        tmp = max(0.0_dp, 1 - 3*tmp**2 + 2*tmp**3)

                        ! Normalize so that integral of 2 * pi * r * f(r) from 0
                        ! to R is unity
                        tmp = tmp * 10 / (3 * pi * radius1(ix)**2)

                        box%cc(i, j, i_dsigma) = box%cc(i, j, i_dsigma) + &
                             (frac * sigma1(ix) + (1-frac) * sigma0(ix)) * tmp
                        box%cc(i, j, i_time) = t
                     end if
                  end do

                  ! Update channel conductivity, but only where the channel
                  ! has already existed for some time, and away from the
                  ! electrode surface (to avoid instabilities in high fields)
                  if (box%cc(i, j, i_lsf) > min_electrode_distance .and. &
                       box%cc(i, j, i_time) < t - channel_delay) then
                     call get_k_eff(box%cc(i, j, i_E_norm), k_eff)

                     ! Limit increase to a factor 2 per time step
                     box%cc(i, j, i_dsigma) = min(2.0_dp, exp(dt * k_eff) - 1.0_dp) * &
                          box%cc(i, j, i_sigma)
                  end if

               end do
            end do
          end associate
       end do
       !$omp end do
    end do
    !$omp end parallel

    ! Add the change in sigma
    call af_tree_apply(tree, i_sigma, i_dsigma, '+')

  end subroutine update_sigma

  ! Linearly interpolate tabulated data for effective ionization rate
  subroutine get_k_eff(fld, k_eff)
    real(dp), intent(in)  :: fld
    real(dp), intent(out) :: k_eff
    real(dp)              :: frac, low_frac
    integer               :: low_ix

    frac = (fld - k_eff_table_x_min) * k_eff_table_inv_fac

    ! Check bounds
    if (frac <= 0) then
       low_ix   = 1
       low_frac = 1
    else if (frac >= k_eff_table_n_points - 1) then
       low_ix   = k_eff_table_n_points - 1
       low_frac = 0
    else
       low_ix   = ceiling(frac)
       low_frac = low_ix - frac
    end if

    k_eff = low_frac * k_eff_table(low_ix) + &
         (1-low_frac) * k_eff_table(low_ix+1)

  end subroutine get_k_eff

  ! Store tabulated data for effective ionization rate
  subroutine store_k_eff(E_min, E_max, n_points, k_eff)
    real(dp), intent(in) :: E_min, E_max
    integer, intent(in)  :: n_points
    real(dp), intent(in) :: k_eff(n_points)

    allocate(k_eff_table(n_points))
    k_eff_table(:) = k_eff
    k_eff_table_n_points = n_points
    k_eff_table_x_min = E_min
    k_eff_table_inv_fac = (n_points - 1)/(E_max - E_min)
  end subroutine store_k_eff

  ! Get the potential along a line
  subroutine get_line_potential(z_min, z_max, n_points, z_line, phi_line)
    real(dp), intent(in)  :: z_min
    real(dp), intent(in)  :: z_max
    integer, intent(in)   :: n_points
    real(dp), intent(out) :: z_line(n_points)
    real(dp), intent(out) :: phi_line(n_points)
    integer               :: i
    logical               :: success
    real(dp)              :: dz

    dz = (z_max - z_min) / max(1, n_points-1)

    do i = 1, n_points
       z_line(i) = z_min + (i-1) * dz
       phi_line(i:i) = af_interp1(tree, [0.0_dp, z_line(i)], [mg%i_phi], success)
       if (.not. success) error stop "interpolation error"
    end do
  end subroutine get_line_potential

  ! Compute new potential for a given time step using the current sigma
  subroutine solve(dt)
    real(dp), intent(in)  :: dt
    integer, parameter    :: max_iterations = 100
    integer               :: mg_iter
    real(dp)              :: residu, prev_residu

    call af_loop_box_arg(tree, set_epsilon_from_sigma, [dt], leaves_only=.true.)
    call af_restrict_tree(tree, [tree%mg_i_eps])
    call af_gc_tree(tree, [tree%mg_i_eps], corners=.false.)

    if (.not. mg%initialized) then
       call mg_init(tree, mg)
       call mg_init(tree, mg_lpl)
    else
       call mg_update_operator_stencil(tree, mg, .false., .true.)
    end if

    prev_residu = huge(1.0_dp)

    do mg_iter = 1, max_iterations
       call mg_fas_fmg(tree, mg, set_residual=.true., have_guess=(mg_iter > 1))
       call af_tree_maxabs_cc(tree, mg%i_tmp, residu)
       if (residu > 0.5 * prev_residu) exit
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
  subroutine write_solution(fname, i_cycle, time)
    character(len=*), intent(in) :: fname
    integer, intent(in)          :: i_cycle
    real(dp), intent(in)         :: time
    call af_write_silo(tree, trim(fname), i_cycle, time)
  end subroutine write_solution

end module m_solver
