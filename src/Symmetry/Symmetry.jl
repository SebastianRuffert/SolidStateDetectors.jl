include("Mirror_Symmetry.jl")

struct Symmetry{T}
    nt::NamedTuple
end

function Symmetry{T}(symmetry_type::AbstractString, config_dict::AbstractDict) where T
    if symmetry_type == "mirror"
        println(config_dict)
        axis = collect(keys(config_dict))[1]
        println(typeof(axis))
        return MirrorSymmetry(axis,T(config_dict[axis]))
    end
end

function Symmetry{T}(config_file_dict::AbstractDict)::NamedTuple where T
    nt = NamedTuple()
    if haskey(config_file_dict, "symmetry")
        sym_keys = collect(keys(config_file_dict["symmetry"])) # Vector with all components of specified symmetry (e.g. contact_1, electric_potential)
        sym_values = collect(values(config_file_dict["symmetry"]))
        sym_values = Tuple(Symmetry{T}(keys(sym_values[i])..., values(sym_values[i])...) for i in 1:length(sym_values))
        sym_keys = Tuple(Symbol(sym_keys[i]) for i in 1:length(sym_keys))
        nt = NamedTuple{sym_keys}(sym_values)
    end
    return nt
end

    
 
