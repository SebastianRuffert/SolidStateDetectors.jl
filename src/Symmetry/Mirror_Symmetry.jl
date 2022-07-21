struct MirrorSymmetry{T}
    symmetry_plane::Plane{T}
end

function MirrorSymmetry{T}(origin::CylindricalPoint{T}, normal::CylindricalVector{T}) where {T}
    _origin = CartesianPoint(origin)
    _normal = CartesianVector(CartesianPoint(origin + normal)-CartesianPoint(origin))
    MirrorSymmetry{T}(Plane{T}(_origin, _normal))
end

function MirrorSymmetry{T}(origin::CartesianPoint{T}, normal::CartesianVector{T}) where {T}
    MirrorSymmetry{T}(Plane{T}(origin, normal))
end

function MirrorSymmetry(axis, value::T) where {T<: SSDFloat}
    if axis == "φ"
        eps = 1e-7
        MirrorSymmetry{T}(CylindricalPoint{T}(r=1, φ = value), CylindricalVector{T}(0,eps,0))
    elseif axis == "x"
        MirrorSymmetry{T}(CartesianPoint{T}(x = value), CartesianVector{T}(1,0,0))
    elseif axis == "y"
        MirrorSymmetry{T}(CartesianPoint{T}(y = value), CartesianVector{T}(0,1,0))
    elseif axis == "z"
        MirrorSymmetry{T}(CartesianPoint{T}(z = value), CartesianVector{T}(0,0,1))
    elseif axis == "r"
        @error "Mirror symmetry along r not defined"
    else
        @error "Wrong axis"
    end
end
        
        