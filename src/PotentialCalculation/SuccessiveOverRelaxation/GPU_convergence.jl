function _update_till_convergence!( pssrb::PotentialCalculationSetup{T, S, 3}, 
                                    convergence_limit,
                                    device_array_type::Type{DAT};
                                    n_iterations_between_checks = 500,
                                    depletion_handling::Val{depletion_handling_enabled} = Val{false}(),
                                    only2d::Val{only_2d} = Val{false}(), 
                                    is_weighting_potential::Val{_is_weighting_potential} = Val{false}(),
                                    use_nthreads::Int = Base.Threads.nthreads(), 
                                    max_n_iterations::Int = 10_000, # -1
                                    verbose::Bool = true
                                ) where {T, S, depletion_handling_enabled, only_2d, _is_weighting_potential, DAT <: GPUArrays.AbstractGPUArray}
    device = get_device(DAT)
    N_grid_points = prod(size(pssrb.potential)[1:3] .- 2)
    kernel = get_sor_kernel(S, device)
    @showprogress for i in 1:max_n_iterations
        update_even_points = true
        wait(kernel( 
            pssrb.potential, pssrb.point_types, pssrb.volume_weights, pssrb.q_eff_imp, pssrb.q_eff_fix, pssrb.ϵ_r,
            pssrb.geom_weights, pssrb.sor_const, update_even_points, depletion_handling_enabled, _is_weighting_potential, only_2d, 
            ndrange = N_grid_points
        ))
        apply_boundary_conditions!(pssrb, Val(update_even_points), only2d)
        update_even_points = false
        wait(kernel( 
            pssrb.potential, pssrb.point_types, pssrb.volume_weights, pssrb.q_eff_imp, pssrb.q_eff_fix, pssrb.ϵ_r,
            pssrb.geom_weights, pssrb.sor_const, update_even_points, depletion_handling_enabled, _is_weighting_potential, only_2d,
            ndrange = N_grid_points
        ))
        apply_boundary_conditions!(pssrb, Val(update_even_points), only2d)
    end
    return 0
end                

get_sor_kernel(::Type{Cylindrical}, args...) = sor_cyl_gpu!(args...)
get_sor_kernel(::Type{Cartesian},   args...) = sor_car_gpu!(args...)

function get_device end

@inline function sor_kernel(
    potential::AbstractArray{T, 4},
    point_types::AbstractArray{PointType, 4},
    volume_weights::AbstractArray{T, 4},
    q_eff_imp::AbstractArray{T, 4},
    q_eff_fix::AbstractArray{T, 4},
    ϵ_r::AbstractArray{T, 3},
    geom_weights::NTuple{3, <:AbstractArray{T, 2}},
    sor_const::AbstractArray{T, 1},
    update_even_points::Bool,
    depletion_handling_enabled::Bool,
    is_weighting_potential::Bool,
    only2d::Bool,
    ::Type{S},
    linear_idx
) where {T, S}
    eff_size = broadcast(idim -> 2:size(potential, idim)-1, (1, 2, 3))
    if linear_idx <= prod(length.(eff_size))
        i1, i2, i3 = Tuple(CartesianIndices(eff_size)[linear_idx])
        # Comparison to CPU indices: (Cyl / Car)
        # i3 <-> idx3 / ir / iz
        # i2 <-> idx2 / iφ / iy
        # i1 <-> idx1 / iz / ix
        in3 = i3 - 1
        in2 = i2 - 1
        in1 = nidx(i1, update_even_points, iseven(i2 + i3))
        ixr = get_rbidx_right_neighbour(i1, update_even_points, iseven(i2 + i3))
        
        rb_tar_idx, rb_src_idx = update_even_points ? (rb_even::Int, rb_odd::Int) : (rb_odd::Int, rb_even::Int) 

        geom_weights_3 = get_geom_weights_outerloop(geom_weights, in3, S)
        geom_weights_2 = prepare_weights_in_middleloop(
            geom_weights, S, i2, in2, 
            geom_weights_3...,
            in3 == 1
        )
        weights = calculate_sor_weights(
            in1, 
            S, 
            ϵ_r,
            geom_weights[3],
            i2, in2, i3, in3,
            geom_weights_2...
        )

        old_potential = potential[i1, i2, i3, rb_tar_idx]
        q_eff = is_weighting_potential ? zero(T) : (q_eff_imp[i1, i2, i3, rb_tar_idx] + q_eff_fix[i1, i2, i3, rb_tar_idx])

        neighbor_potentials = get_neighbor_potentials(
            potential, old_potential, i1, i2, i3, ixr, in2, in3, rb_src_idx, only2d
        )      
        
        new_potential = calc_new_potential_SOR_3D(
            q_eff,
            volume_weights[i1, i2, i3, rb_tar_idx],
            weights,
            neighbor_potentials,
            old_potential,
            get_sor_constant(sor_const, S, in3)
        )

        if depletion_handling_enabled
            new_potential, point_types[i1, i2, i3, rb_tar_idx] = handle_depletion(
                new_potential,
                point_types[i1, i2, i3, rb_tar_idx],
                r0_handling_depletion_handling(neighbor_potentials, S, in3),
                q_eff_imp[i1, i2, i3, rb_tar_idx],
                volume_weights[i1, i2, i3, rb_tar_idx],
                get_sor_constant(sor_const, S, in3)
            )
        end

        potential[i1, i2, i3, rb_tar_idx] = ifelse(point_types[i1, i2, i3, rb_tar_idx] & update_bit > 0, new_potential, old_potential)
    end
    nothing
end

@inline function get_neighbor_potentials(
    potential::AbstractArray{T, 4},
    old_potential, i1, i2, i3, i1r, in2, in3, rb_src_idx, only2d::Bool
)::NTuple{6, T} where {T}
    @inbounds return ( # p: potential; 1: RB-dimension; l/r: left/right
    potential[i1r - 1,     i2,     i3, rb_src_idx], # p1l
    potential[    i1r,     i2,     i3, rb_src_idx], # p1r
    only2d ? old_potential : potential[ i1,    in2, i3, rb_src_idx], # p2l
    only2d ? old_potential : potential[ i1, i2 + 1, i3, rb_src_idx], # p2r
    potential[     i1,     i2,    in3, rb_src_idx], # p3l
    potential[     i1,     i2, i3 + 1, rb_src_idx], # p3r
    ) 
end

@inline function prepare_weights_in_middleloop(
    geom_weights::NTuple{3, <:AbstractArray{T, 2}}, ::Type{Cylindrical},
    i2, in2,
    pwwrr, pwwrl, r_inv_pwΔmpr, Δr_ext_inv_r_pwmprr, Δr_ext_inv_l_pwmprl, Δmpr_squared, 
    is_r0::Bool
) where {T}
    pwwφr        = geom_weights[2][1, in2]
    pwwφl        = geom_weights[2][2, in2]
    pwΔmpφ       = geom_weights[2][3, in2]
    Δφ_ext_inv_r = geom_weights[2][4,  i2]
    Δφ_ext_inv_l = geom_weights[2][4, in2]

    if is_r0
        pwwφr = T(0.5)
        pwwφl = T(0.5)
        pwΔmpφ = T(2π)
        Δφ_ext_inv_r = inv(pwΔmpφ)
        Δφ_ext_inv_l = Δφ_ext_inv_r
    end
    pwwrr_pwwφr = pwwrr * pwwφr
    pwwrl_pwwφr = pwwrl * pwwφr
    pwwrr_pwwφl = pwwrr * pwwφl
    pwwrl_pwwφl = pwwrl * pwwφl

    pwΔmpφ_Δmpr_squared = pwΔmpφ * Δmpr_squared
    Δr_ext_inv_r_pwmprr_pwΔmpφ = Δr_ext_inv_r_pwmprr * pwΔmpφ
    Δr_ext_inv_l_pwmprl_pwΔmpφ = Δr_ext_inv_l_pwmprl * pwΔmpφ
    r_inv_pwΔmpr_Δφ_ext_inv_r = r_inv_pwΔmpr * Δφ_ext_inv_r
    r_inv_pwΔmpr_Δφ_ext_inv_l = r_inv_pwΔmpr * Δφ_ext_inv_l
    return (
        pwwrr, pwwrl, pwwφr, pwwφl, 
        pwwrr_pwwφr, pwwrl_pwwφr, pwwrr_pwwφl, pwwrl_pwwφl,
        pwΔmpφ_Δmpr_squared,
        Δr_ext_inv_r_pwmprr_pwΔmpφ, Δr_ext_inv_l_pwmprl_pwΔmpφ,
        r_inv_pwΔmpr_Δφ_ext_inv_r, r_inv_pwΔmpr_Δφ_ext_inv_l
    )
end
