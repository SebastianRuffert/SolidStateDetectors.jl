function set_passive_or_contact_points(point_types::Array{PointType, 3}, potential::Array{T, 3},
                        grid::CylindricalGrid{T}, obj, pot::T, use_nthreads::Int = 1) where {T}
    if !isnan(pot)
        @onthreads 1:use_nthreads for iz in workpart(axes(potential, 3), 1:use_nthreads, Base.Threads.threadid())
            @inbounds for iφ in axes(potential, 2)
                for ir in axes(potential, 1)
                    pt::CylindricalPoint{T} = CylindricalPoint{T}( grid.axes[1].ticks[ir], grid.axes[2].ticks[iφ], grid.axes[3].ticks[iz] )
                    if pt in obj
                        potential[ ir, iφ, iz ] = pot
                        point_types[ ir, iφ, iz ] = zero(PointType)
                    end
                end
            end
        end
    end
    nothing
end

function set_point_types_and_fixed_potentials!(point_types::Array{PointType, 3}, potential::Array{T, 3},
        grid::CylindricalGrid{T}, det::SolidStateDetector{T}; 
        weighting_potential_contact_id::Union{Missing, Int} = missing,
        use_nthreads::Int = Base.Threads.nthreads(),
        not_only_paint_contacts::Val{NotOnlyPaintContacts} = Val{true}(),
        paint_contacts::Val{PaintContacts} = Val{true}())::Nothing where {T <: SSDFloat, NotOnlyPaintContacts, PaintContacts}

    @onthreads 1:use_nthreads for iz in workpart(axes(potential, 3), 1:use_nthreads, Base.Threads.threadid())
        @inbounds for iφ in axes(potential, 2)
            for ir in axes(potential, 1)
                pt::CylindricalPoint{T} = CylindricalPoint{T}( grid.axes[1].ticks[ir], grid.axes[2].ticks[iφ], grid.axes[3].ticks[iz] )
                if in(pt, det.semiconductor)
                    point_types[ ir, iφ, iz ] += pn_junction_bit
                end
            end
        end
    end
    isEP = ismissing(weighting_potential_contact_id)
    if !ismissing(det.passives)
        for passive in det.passives
            pot::T = isEP ? passive.potential : (isnan(passive.potential) ? passive.potential : zero(T))
            set_passive_or_contact_points(point_types, potential, grid, passive.geometry, pot, use_nthreads)                              
        end
    end
    if NotOnlyPaintContacts
        for contact in det.contacts
            pot::T = isEP ? contact.potential : contact.id == weighting_potential_contact_id
            set_passive_or_contact_points(point_types, potential, grid, contact.geometry, pot, use_nthreads)
        end
    end
    if PaintContacts
        for contact in det.contacts
            pot::T = isEP ? contact.potential : contact.id == weighting_potential_contact_id
            fs = ConstructiveSolidGeometry.surfaces(contact.geometry)
            for face in fs
                paint!(point_types, potential, face, contact.geometry, pot, grid)
            end
        end
    end
    nothing
end

function fill_ρimp_ϵ_ρfix(ρ_eff_imp_tmp::Array{T}, ϵ::Array{T}, ρ_eff_fix_tmp::Array{T}, 
    ::Type{Cylindrical}, mpz::Vector{T}, mpφ::Vector{T}, mpr::Vector{T}, axr::Vector{T}, use_nthreads::Int, obj) where {T}
    @inbounds begin
        @onthreads 1:use_nthreads for iz in workpart(axes(ϵ, 3), 1:use_nthreads, Base.Threads.threadid())
            pos_z::T = mpz[iz]
            for iφ in axes(ϵ, 2)
                pos_φ::T = mpφ[iφ]
                for ir in axes(ϵ, 1)
                    pos_r::T = mpr[ir]
                    if (ir == 1 && axr[1] == 0) pos_r = axr[2] * 0.5 end
                    pt::CylindricalPoint{T} = CylindricalPoint{T}(pos_r, pos_φ, pos_z)
                    if pt in obj
                        ρ_eff_imp_tmp[ir, iφ, iz]::T, ϵ[ir, iφ, iz]::T, ρ_eff_fix_tmp[ir, iφ, iz]::T = get_ρimp_ϵ_ρfix(pt, obj)
                    end
                end
            end
        end
    end
    nothing
end


function PotentialCalculationSetup(det::SolidStateDetector{T}, grid::CylindricalGrid{T}, 
                medium::NamedTuple = material_properties[materials["vacuum"]],
                potential_array::Union{Missing, Array{T, 3}} = missing,
                imp_scale::Union{Missing, Array{T, 3}} = missing; 
                weighting_potential_contact_id::Union{Missing, Int} = missing,
                point_types = missing,
                use_nthreads::Int = Base.Threads.nthreads(),
                sor_consts = (1.0, 1.0),
                not_only_paint_contacts::Bool = true, paint_contacts::Bool = true)::PotentialCalculationSetup{T} where {T}
    r0_handling::Bool = typeof(grid.axes[1]).parameters[2] == :r0
    only_2d::Bool = length(grid.axes[2]) == 1 ? true : false
    @assert grid.axes[1][1] == 0 "Something is wrong. R-axis has `:r0`-boundary handling but first tick is $(axr[1]) and not 0."

    is_weighting_potential::Bool = !ismissing(weighting_potential_contact_id)
    depletion_handling::Bool = is_weighting_potential && !ismissing(point_types)

    @inbounds begin
        begin # Geometrical weights of the Axes
            nr = size(grid)[1]

            # R-axis
            axr::Vector{T} = collect(grid.axes[1]) # real grid points/ticks -> the potential at these ticks are going to be calculated
            r_inv::Vector{T} = inv.(axr)
            if r0_handling r_inv[1] = inv(axr[2] * 0.5) end
            r_ext::Vector{T} = get_extended_ticks(grid.axes[1])
            Δr_ext::Vector{T} = diff(r_ext)
            Δr_ext_inv::Vector{T} = inv.(Δr_ext)
            mpr::Vector{T} = midpoints(r_ext)
            Δmpr::Vector{T} = diff(mpr)
            Δmpr_inv::Vector{T} = inv.(Δmpr)
            Δmpr_squared::Vector{T} = T(0.5) .* ((mpr[2:end].^2) .- (mpr[1:end-1].^2))
            if r0_handling
                Δmpr_squared[1] = T(0.5) * (mpr[2]^2)
                Δr_ext_inv[1] = 0 # -> left weight @r=0 becomes 0 through this
            end
            Δhmprr::Vector{T} = mpr[2:end] - axr # distances between midpoints and real grid points (half distances -> h), needed for weights wrr, wrl, ... & dV (volume element)
            Δhmprl::Vector{T} = axr - mpr[1:end - 1]
            wrr::Vector{T} = Δmpr_inv .* Δhmprr # weights for epislon_r adding
            wrl::Vector{T} = Δmpr_inv .* Δhmprl
            if r0_handling wrl[1]::T = 1 - wrr[1] end
            wr::Array{T, 2} = zeros(T, 6, length(wrr))
            wr[1, :] = wrr
            wr[2, :] = wrl
            wr[3, :] = r_inv .* Δmpr
            wr[4, :] = Δr_ext_inv[2:end] .* mpr[2:end]
            wr[5, :] = Δr_ext_inv[1:length(wrr)] .* mpr[1:length(wrr)]
            wr[6, :] = Δmpr_squared
            gw_r::GeometricalRadialAxisWeights{T} = GeometricalRadialAxisWeights{T}( wr ) # Weights needed for Field Simulation loop
            r_ext_mid::T = (r_ext[end - 1] - r_ext[2]) / 2
            grid_boundary_factor_r_left::T = abs((r_ext[2] - r_ext_mid) / (r_ext[1] - r_ext_mid))
            grid_boundary_factor_r_right::T = r0_handling ? abs(r_ext[end - 1] / r_ext[end]) : abs((r_ext[end - 1] - r_ext_mid) / (r_ext[end] - r_ext_mid))

            # φ-axis
            axφ::Vector{T} = collect(grid.axes[2]) # real grid points/ticks -> the potential at these ticks are going to be calculated
            φ_ext::Vector{T} = get_extended_ticks(grid.axes[2])
   
            Δφ_ext::Vector{T} = diff(φ_ext)
            Δφ_ext_inv::Vector{T} = inv.(Δφ_ext)
            mpφ::Vector{T} = midpoints(φ_ext)
            Δmpφ::Vector{T} = diff(mpφ)
            Δmpφ_inv::Vector{T} = inv.(Δmpφ)
            Δhmpφr::Vector{T} = mpφ[2:end] - axφ # distances between midpoints and real grid points (half distances -> h), needed for weights wrr, wrl, ... & dV (volume element)
            Δhmpφl::Vector{T} = axφ - mpφ[1:end - 1]
            wφr::Vector{T} = Δmpφ_inv .* Δhmpφr # weights for epislon_r adding
            wφl::Vector{T} = Δmpφ_inv .* Δhmpφl
            wφ::Array{T, 2} = zeros(T, 4, length(wφr) + 1)
            wφ[1, 1:length(wφr)] = wφr
            wφ[2, 1:length(wφr)] = wφl
            wφ[3, 1:length(wφr)] = Δmpφ
            wφ[4, :] = Δφ_ext_inv
            gw_φ::GeometricalAzimutalAxisWeights{T} = GeometricalAzimutalAxisWeights{T}( wφ ) # Weights needed for Field Simulation loop
            φ_ext_mid::T = (φ_ext[end - 1] - φ_ext[2]) / 2
            grid_boundary_factor_φ_right::T = abs((φ_ext[end - 1] - φ_ext_mid) / (φ_ext[end] - φ_ext_mid))
            grid_boundary_factor_φ_left::T = abs((φ_ext[2] - φ_ext_mid) / (φ_ext[1] - φ_ext_mid))

            # Z-axis
            axz::Vector{T} = collect(grid.axes[3]) # real grid points/ticks -> the potential at these ticks are going to be calculated
            z_ext::Vector{T} = get_extended_ticks(grid.axes[3])
            Δz_ext::Vector{T} = diff(z_ext)
            Δz_ext_inv::Vector{T} = inv.(Δz_ext)
            mpz::Vector{T} = midpoints(z_ext)
            Δmpz::Vector{T} = diff(mpz)
            Δmpz_inv::Vector{T} = inv.(Δmpz)
            Δhmpzr::Vector{T} = mpz[2:end] - axz # distances between midpoints and real grid points (half distances -> h), needed for weights wrr, wrl, ... & dV (volume element)
            Δhmpzl::Vector{T} = axz - mpz[1:end - 1]
            wzr::Vector{T} = Δmpz_inv .* Δhmpzr # weights for epislon_r adding
            wzl::Vector{T} = Δmpz_inv .* Δhmpzl
            wz::Array{T, 2} = zeros(T, 4, length(wzr) + 1)
            wz[1, 1:length(wzr)] = wzr
            wz[2, 1:length(wzr)] = wzl
            wz[3, 1:length(wzr)] = Δmpz
            wz[4, :] = Δz_ext_inv
            gw_z::GeometricalCartesianAxisWeights{T} = GeometricalCartesianAxisWeights{T}( wz ) # Weights needed for Field Simulation loop
            z_ext_mid::T = (z_ext[end - 1] - z_ext[2]) / 2
            grid_boundary_factor_z_right::T = abs((z_ext[end - 1] - z_ext_mid) / (z_ext[end] - z_ext_mid))
            grid_boundary_factor_z_left::T = abs((z_ext[2] - z_ext_mid) / (z_ext[1] - z_ext_mid))

            geom_weights::NTuple{3, AbstractGeometricalAxisWeights{T}} = (gw_r, gw_φ, gw_z) # Weights needed for Field Simulation loop
            grid_boundary_factors::NTuple{3, NTuple{2, T}} = ((grid_boundary_factor_r_left, grid_boundary_factor_r_right), (grid_boundary_factor_φ_left, grid_boundary_factor_φ_right), (grid_boundary_factor_z_left, grid_boundary_factor_z_right))
        end

        bias_voltages::Vector{T} = if length(det.contacts) > 0
            [i.potential for i in det.contacts]
        else
            T[0]
        end
        minimum_applied_potential::T = minimum(bias_voltages)
        maximum_applied_potential::T = maximum(bias_voltages)
        bias_voltage::T = maximum_applied_potential - minimum_applied_potential
        sor_slope = (sor_consts[2] .- sor_consts[1]) / (nr - 1 )
        sor_const::Vector{T} = T[ sor_consts[1] + (i - 1) * sor_slope for i in 1:nr]

        medium_ϵ_r::T = medium.ϵ_r
        ϵ = fill(medium_ϵ_r, length(mpr), length(mpφ), length(mpz))
        ρ_eff_imp_tmp = zeros(T, length(mpr), length(mpφ), length(mpz))
        ρ_eff_fix_tmp = zeros(T, length(mpr), length(mpφ), length(mpz))
        fill_ρimp_ϵ_ρfix(ρ_eff_imp_tmp, ϵ, ρ_eff_fix_tmp, Cylindrical, mpz, mpφ, mpr, axr, use_nthreads, det.semiconductor)
        if !ismissing(det.passives)
            for passive in det.passives
                fill_ρimp_ϵ_ρfix(ρ_eff_imp_tmp, ϵ, ρ_eff_fix_tmp, Cylindrical, mpz, mpφ, mpr, axr, use_nthreads, passive)
            end
        end
        if depletion_handling
            for iz in axes(ϵ, 3)
                pos_z = mpz[iz]
                for iφ in axes(ϵ, 2)
                    pos_φ = mpφ[iφ]
                    for ir in axes(ϵ, 1)
                        pos_r = mpr[ir]
                        if (ir == 1 && axr[1] == 0) pos_r = axr[2] * 0.5 end
                        pt::CylindricalPoint{T} = CylindricalPoint{T}(pos_r, pos_φ, pos_z)
                        ig = find_closest_gridpoint(pt, point_types.grid)
                        if is_undepleted_point_type(point_types.data[ig...])
                            ϵ[ir, iφ, iz] *= scaling_factor_for_permittivity_in_undepleted_region(det.semiconductor) * (1 - imp_scale[ig...])
                        elseif is_fixed_point_type(point_types.data[ig...])
                            ϵ[ir, iφ, iz] *= scaling_factor_for_permittivity_in_undepleted_region(det.semiconductor)
                        end
                    end
                end
            end
        end  
        
        ϵ0_inv::T = inv(ϵ0)
        ρ_eff_imp_tmp *= ϵ0_inv
        ρ_eff_fix_tmp *= ϵ0_inv

        volume_weights::Array{T, 4} = RBExtBy2Array(T, grid)
        q_eff_imp::Array{T, 4} = RBExtBy2Array(T, grid)
        q_eff_fix::Array{T, 4} = RBExtBy2Array(T, grid)
        for iz in range(2, stop = length(z_ext) - 1)
            inz::Int = iz - 1
            irbz::Int = rbidx(inz)
            for iφ in range(2, stop = length(φ_ext) - 1)
                inφ::Int = iφ - 1
                for ir in range(2, stop = length(r_ext) - 1)
                    inr::Int = ir - 1;

                    rbi::Int = iseven(inr + inφ + inz) ? rb_even::Int : rb_odd::Int
                    # rbinds = irbz, iφ, ir, rbi

                    ρ_imp_cell::T = 0
                    ρ_eff_fix_cell::T = 0
                    if !is_weighting_potential
                        if inr > 1
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir,  iφ,  iz] * wzr[inz] * wrr[inr] * wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir,  iφ, inz] * wzl[inz] * wrr[inr] * wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir, inφ,  iz] * wzr[inz] * wrr[inr] * wφl[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir, inφ, inz] * wzl[inz] * wrr[inr] * wφl[inφ]

                            ρ_imp_cell += ρ_eff_imp_tmp[inr,  iφ,  iz] * wzr[inz] * wrl[inr] * wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[inr,  iφ, inz] * wzl[inz] * wrl[inr] * wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[inr, inφ,  iz] * wzr[inz] * wrl[inr] * wφl[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[inr, inφ, inz] * wzl[inz] * wrl[inr] * wφl[inφ]

                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir,  iφ,  iz] * wzr[inz] * wrr[inr] * wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir,  iφ, inz] * wzl[inz] * wrr[inr] * wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir, inφ,  iz] * wzr[inz] * wrr[inr] * wφl[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir, inφ, inz] * wzl[inz] * wrr[inr] * wφl[inφ]

                            ρ_eff_fix_cell += ρ_eff_fix_tmp[inr,  iφ,  iz] * wzr[inz] * wrl[inr] * wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[inr,  iφ, inz] * wzl[inz] * wrl[inr] * wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[inr, inφ,  iz] * wzr[inz] * wrl[inr] * wφl[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[inr, inφ, inz] * wzl[inz] * wrl[inr] * wφl[inφ]
                        else
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir,  iφ,  iz] * wzr[inz] * 0.5 #wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir,  iφ, inz] * wzl[inz] * 0.5 #wφr[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir, inφ,  iz] * wzr[inz] * 0.5 #wφl[inφ]
                            ρ_imp_cell += ρ_eff_imp_tmp[ ir, inφ, inz] * wzl[inz] * 0.5 #wφl[inφ]

                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir,  iφ,  iz] * wzr[inz] * 0.5 #wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir,  iφ, inz] * wzl[inz] * 0.5 #wφr[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir, inφ,  iz] * wzr[inz] * 0.5 #wφl[inφ]
                            ρ_eff_fix_cell += ρ_eff_fix_tmp[ ir, inφ, inz] * wzl[inz] * 0.5 #wφl[inφ]
                        end
                    end
                    if inr > 1
                        wrr_eps::T = ϵ[  ir,  iφ, inz + 1] * wφr[inφ] * wzr[inz]
                        wrr_eps   += ϵ[  ir, inφ, inz + 1] * wφl[inφ] * wzr[inz]
                        wrr_eps   += ϵ[  ir,  iφ, inz ]    * wφr[inφ] * wzl[inz]
                        wrr_eps   += ϵ[  ir, inφ, inz ]    * wφl[inφ] * wzl[inz]
                        # # left weight in r: wrr
                        wrl_eps::T = ϵ[ inr,  iφ, inz + 1] * wφr[inφ] * wzr[inz]
                        wrl_eps   += ϵ[ inr, inφ, inz + 1] * wφl[inφ] * wzr[inz]
                        wrl_eps   += ϵ[ inr,  iφ, inz ]    * wφr[inφ] * wzl[inz]
                        wrl_eps   += ϵ[ inr, inφ, inz ]    * wφl[inφ] * wzl[inz]
                        # right weight in φ: wφr
                        wφr_eps::T = ϵ[ inr,  iφ, inz + 1] * wrl[inr] * wzr[inz]
                        wφr_eps   += ϵ[  ir,  iφ, inz + 1] * wrr[inr] * wzr[inz]
                        wφr_eps   += ϵ[ inr,  iφ, inz ]    * wrl[inr] * wzl[inz]
                        wφr_eps   += ϵ[  ir,  iφ, inz ]    * wrr[inr] * wzl[inz]
                        # left weight in φ: wφl
                        wφl_eps::T = ϵ[ inr, inφ, inz + 1] * wrl[inr] * wzr[inz]
                        wφl_eps   += ϵ[  ir, inφ, inz + 1] * wrr[inr] * wzr[inz]
                        wφl_eps   += ϵ[ inr, inφ, inz ]    * wrl[inr] * wzl[inz]
                        wφl_eps   += ϵ[  ir, inφ, inz ]    * wrr[inr] * wzl[inz]
                        # right weight in z: wzr
                        wzr_eps::T = ϵ[  ir,  iφ, inz + 1] * wrr[inr] * wφr[inφ]
                        wzr_eps   += ϵ[  ir, inφ, inz + 1] * wrr[inr] * wφl[inφ]
                        wzr_eps   += ϵ[ inr,  iφ, inz + 1] * wrl[inr] * wφr[inφ]
                        wzr_eps   += ϵ[ inr, inφ, inz + 1] * wrl[inr] * wφl[inφ]
                        # left weight in z: wzr
                        wzl_eps::T = ϵ[  ir,  iφ,    inz ] * wrr[inr] * wφr[inφ]
                        wzl_eps   += ϵ[  ir, inφ,    inz ] * wrr[inr] * wφl[inφ]
                        wzl_eps   += ϵ[ inr,  iφ,    inz ] * wrl[inr] * wφr[inφ]
                        wzl_eps   += ϵ[ inr, inφ,    inz ] * wrl[inr] * wφl[inφ]

                        volume_weight::T = wrr_eps * Δr_ext_inv[ ir] * mpr[ ir] * Δmpφ[inφ] * Δmpz[inz]
                        volume_weight += wrl_eps * Δr_ext_inv[inr] * mpr[inr] * Δmpφ[inφ] * Δmpz[inz]
                        volume_weight += wφr_eps * r_inv[inr] * Δφ_ext_inv[ iφ] * Δmpr[inr] * Δmpz[inz]
                        volume_weight += wφl_eps * r_inv[inr] * Δφ_ext_inv[inφ] * Δmpr[inr] * Δmpz[inz]
                        volume_weight += wzr_eps * Δz_ext_inv[ iz] * Δmpφ[inφ] * Δmpr_squared[inr]
                        volume_weight += wzl_eps * Δz_ext_inv[inz] * Δmpφ[inφ] * Δmpr_squared[inr]

                        volume_weights[ irbz, iφ, ir, rbi ] = inv(volume_weight)

                        dV::T = Δmpz[inz] * Δmpφ[inφ] * Δmpr_squared[inr]
                        q_eff_imp[ irbz, iφ, ir, rbi ] = dV * ρ_imp_cell
                        q_eff_fix[ irbz, iφ, ir, rbi ] = dV * ρ_eff_fix_cell
                    else
                        wrr_eps = ϵ[  ir,  iφ, inz + 1] * 0.5 * wzr[inz]
                        wrr_eps   += ϵ[  ir, inφ, inz + 1] * 0.5 * wzr[inz]
                        wrr_eps   += ϵ[  ir,  iφ, inz ]    * 0.5 * wzl[inz]
                        wrr_eps   += ϵ[  ir, inφ, inz ]    * 0.5 * wzl[inz]
                        # # left weight in r: wrr
                        wrl_eps = ϵ[ inr,  iφ, inz + 1] * 0.5 * wzr[inz]
                        wrl_eps   += ϵ[ inr, inφ, inz + 1] * 0.5 * wzr[inz]
                        wrl_eps   += ϵ[ inr,  iφ, inz ]    * 0.5 * wzl[inz]
                        wrl_eps   += ϵ[ inr, inφ, inz ]    * 0.5 * wzl[inz]
                        # right weight in φ: wφr
                        wφr_eps = ϵ[ inr,  iφ, inz + 1] * wrl[inr] * wzr[inz]
                        wφr_eps   += ϵ[  ir,  iφ, inz + 1] * wrr[inr] * wzr[inz]
                        wφr_eps   += ϵ[ inr,  iφ, inz ]    * wrl[inr] * wzl[inz]
                        wφr_eps   += ϵ[  ir,  iφ, inz ]    * wrr[inr] * wzl[inz]
                        # left weight in φ: wφl
                        wφl_eps = ϵ[ inr, inφ, inz + 1] * wrl[inr] * wzr[inz]
                        wφl_eps   += ϵ[  ir, inφ, inz + 1] * wrr[inr] * wzr[inz]
                        wφl_eps   += ϵ[ inr, inφ, inz ]    * wrl[inr] * wzl[inz]
                        wφl_eps   += ϵ[  ir, inφ, inz ]    * wrr[inr] * wzl[inz]
                        # right weight in z: wzr
                        wzr_eps = ϵ[  ir,  iφ, inz + 1] * wrr[inr] * 0.5
                        wzr_eps   += ϵ[  ir, inφ, inz + 1] * wrr[inr] * 0.5
                        wzr_eps   += ϵ[ inr,  iφ, inz + 1] * wrl[inr] * 0.5
                        wzr_eps   += ϵ[ inr, inφ, inz + 1] * wrl[inr] * 0.5
                        # left weight in z: wzr
                        wzl_eps = ϵ[  ir,  iφ,    inz ] * wrr[inr] * 0.5
                        wzl_eps   += ϵ[  ir, inφ,    inz ] * wrr[inr] * 0.5
                        wzl_eps   += ϵ[ inr,  iφ,    inz ] * wrl[inr] * 0.5
                        wzl_eps   += ϵ[ inr, inφ,    inz ] * wrl[inr] * 0.5

                        volume_weight = wrr_eps * Δr_ext_inv[ ir] * mpr[ ir] * 2π * Δmpz[inz]
                        volume_weight += wrl_eps * Δr_ext_inv[inr] * mpr[inr] * Δmpφ[inφ] * Δmpz[inz]
                        volume_weight += wφr_eps * r_inv[inr] * 0.15915494f0 * Δmpr[inr] * Δmpz[inz]
                        volume_weight += wφl_eps * r_inv[inr] * 0.15915494f0 * Δmpr[inr] * Δmpz[inz]
                        volume_weight += wzr_eps * Δz_ext_inv[ iz] * 2π * Δmpr_squared[inr]
                        volume_weight += wzl_eps * Δz_ext_inv[inz] * 2π * Δmpr_squared[inr]

                        volume_weights[ irbz, iφ, ir, rbi ] = inv(volume_weight)

                        dV = Δmpz[inz] * 2π * Δmpr_squared[inr]
                        q_eff_imp[ irbz, iφ, ir, rbi ] = dV * ρ_imp_cell
                        q_eff_fix[ irbz, iφ, ir, rbi ] = dV * ρ_eff_fix_cell
                    end
                end
            end
        end
        potential = ismissing(potential_array) ? zeros(T, size(grid)...) : potential_array
        point_types = ones(PointType, size(grid)...)
        set_point_types_and_fixed_potentials!( point_types, potential, grid, det, 
                weighting_potential_contact_id = weighting_potential_contact_id,
                use_nthreads = use_nthreads,
                not_only_paint_contacts = Val(not_only_paint_contacts), 
                paint_contacts = Val(paint_contacts)  )
        rbpotential  = RBExtBy2Array( potential, grid )
        rbpoint_types = RBExtBy2Array( point_types, grid )
    end # @inbounds

    pcs = PotentialCalculationSetup(
        grid,
        rbpotential,
        rbpoint_types,
        volume_weights,
        q_eff_imp,
        ones(T, size(rbpoint_types)),
        q_eff_fix,
        ϵ,
        broadcast(gw -> gw.weights, geom_weights),
        sor_const,
        bias_voltage,
        maximum_applied_potential,
        minimum_applied_potential,
        grid_boundary_factors
     )

    apply_boundary_conditions!(pcs, Val{ true}(), only_2d ? Val{true}() : Val{false}()) # even points
    apply_boundary_conditions!(pcs, Val{false}(), only_2d ? Val{true}() : Val{false}()) # odd
    return pcs
end

Grid(pcs::PotentialCalculationSetup) = pcs.grid

function ElectricPotentialArray(pcs::PotentialCalculationSetup{T, Cylindrical, 3, Array{T, 3}})::Array{T, 3} where {T}
    pot::Array{T, 3} = Array{T, 3}(undef, size(pcs.grid))
    for iz in axes(pot, 3)
        irbz::Int = rbidx(iz)
        for iφ in axes(pot, 2)
            irbφ::Int = iφ + 1
            idxsum::Int = iz + iφ
            for ir in axes(pot, 1)
                irbr::Int = ir + 1
                rbi::Int = iseven(idxsum + ir) ? rb_even::Int : rb_odd::Int
                pot[ir, iφ, iz] = pcs.potential[ irbz, irbφ, irbr, rbi ]
            end
        end
    end
    for iz in axes(pot, 3)
        p_r0 = mean(pot[1,:,iz])
        pot[1,:,iz] .= p_r0
    end
    return pot
end

function ImpurityScaleArray(pcs::PotentialCalculationSetup{T, Cylindrical, 3, Array{T, 3}})::Array{T, 3} where {T}
    s::Array{T, 3} = Array{T, 3}(undef, size(pcs.grid))
    for iz in axes(s, 3)
        irbz::Int = rbidx(iz)
        for iφ in axes(s, 2)
            irbφ::Int = iφ + 1
            idxsum::Int = iz + iφ
            for ir in axes(s, 1)
                irbr::Int = ir + 1
                rbi::Int = iseven(idxsum + ir) ? rb_even::Int : rb_odd::Int
                s[ir, iφ, iz] = pcs.imp_scale[ irbz, irbφ, irbr, rbi ]
            end
        end
    end
    return s
end


function PointTypeArray(pcs::PotentialCalculationSetup{T, Cylindrical, 3, Array{T, 3}})::Array{PointType, 3} where {T}
    point_types::Array{PointType, 3} = zeros(PointType, size(pcs.grid))
    for iz in axes(point_types, 3)
        irbz::Int = rbidx(iz)
        for iφ in axes(point_types, 2)
            irbφ::Int = iφ + 1
            idxsum::Int = iz + iφ
            for ir in axes(point_types, 1)
                irbr::Int = ir + 1
                rbi::Int = iseven(idxsum + ir) ? rb_even::Int : rb_odd::Int
                point_types[ir, iφ, iz] = pcs.point_types[irbz, irbφ, irbr, rbi ]
            end
        end
    end
    return point_types
end


function EffectiveChargeDensityArray(pcs::PotentialCalculationSetup{T, Cylindrical, 3, Array{T, 3}})::Array{T} where {T}
    ρ::Array{T, 3} = zeros(T, size(pcs.grid))
    for iz in axes(ρ, 3)
        irbz::Int = rbidx(iz)
        Δmpz::T = pcs.geom_weights[3][3, iz]
        for iφ in axes(ρ, 2)
            irbφ::Int = iφ + 1
            idxsum::Int = iz + iφ
            Δmpφ::T = pcs.geom_weights[2][3, iφ]
            Δmpzφ::T = Δmpz * Δmpφ
            for ir in axes(ρ, 1)
                irbr::Int = ir + 1
                rbi::Int = iseven(idxsum + ir) ? rb_even::Int : rb_odd::Int
                dV::T = pcs.geom_weights[1][6, ir] * Δmpzφ  #Δmpz[inz] * Δmpφ[inφ] * Δmpr_squared[inr]
                if ir == 1
                    dV = dV * 2π / Δmpφ
                end
                ρ[ir, iφ, iz] = pcs.q_eff_imp[irbz, irbφ, irbr, rbi ] / dV
            end
        end
    end
    return ρ
end

function FixedEffectiveChargeDensityArray(pcs::PotentialCalculationSetup{T, Cylindrical, 3, Array{T, 3}})::Array{T} where {T}
    ρ::Array{T, 3} = zeros(T, size(pcs.grid))
    for iz in axes(ρ, 3)
        irbz::Int = rbidx(iz)
        Δmpz::T = pcs.geom_weights[3][3, iz]
        for iφ in axes(ρ, 2)
            irbφ::Int = iφ + 1
            idxsum::Int = iz + iφ
            Δmpφ::T = pcs.geom_weights[2][3, iφ]
            Δmpzφ::T = Δmpz * Δmpφ
            for ir in axes(ρ, 1)
                irbr::Int = ir + 1
                rbi::Int = iseven(idxsum + ir) ? rb_even::Int : rb_odd::Int
                dV::T = pcs.geom_weights[1][6, ir] * Δmpzφ  #Δmpz[inz] * Δmpφ[inφ] * Δmpr_squared[inr]
                if ir == 1
                    dV = dV * 2π / Δmpφ
                end
                ρ[ir, iφ, iz] = pcs.q_eff_fix[irbz, irbφ, irbr, rbi ] / dV
            end
        end
    end
    return ρ
end




function DielectricDistributionArray(pcs::PotentialCalculationSetup{T, S, 3, Array{T, 3}})::Array{T, 3} where {T, S}
    return pcs.ϵ_r
end
