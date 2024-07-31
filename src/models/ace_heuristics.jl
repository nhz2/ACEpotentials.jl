import Random 

# --------------------------------------------------
#   different notions of "level" / total degree.

abstract type AbstractLevel end 
struct TotalDegree <: AbstractLevel
   wn::Float64
   wl::Float64
end 

TotalDegree() = TotalDegree(1.0, 0.66)

(l::TotalDegree)(b::NamedTuple) = b.n/l.wn + b.l/l.wl
(l::TotalDegree)(bb::AbstractVector{<: NamedTuple}) = sum(l(b) for b in bb)


struct EuclideanDegree <: AbstractLevel
   wn::Float64
   wl::Float64
end

EuclideanDegree() = EuclideanDegree(1.0, 0.66)

(l::EuclideanDegree)(b::NamedTuple) = sqrt( (b.n/l.wn)^2 + (b.l/l.wl)^2 )
(l::EuclideanDegree)(bb::AbstractVector{<: NamedTuple}) = sqrt( sum(l(b)^2 for b in bb) )


# -------------------------------------------------------
#  construction of Rnlrzz bases with lots of defaults
#
# TODO: offer simple option to initialize ACE1-like or trACE-like
#

function ace_learnable_Rnlrzz(; 
               max_level = nothing, 
               level = nothing, 
               maxl = nothing, 
               maxn = nothing,
               maxq_fact = 1.5, 
               maxq = :auto, 
               elements = nothing, 
               spec = nothing, 
               rin0cuts = _default_rin0cuts(elements),
               transforms = agnesi_transform.(rin0cuts, 2, 2), 
               polys = :legendre, 
               envelopes = :poly2sx, 
               Winit = :glorot_normal, 
               )
   if elements == nothing
      error("elements must be specified!")
   end
   if (spec == nothing) && (level == nothing || max_level == nothing)
      error("Must specify either `spec` or `level, max_level`!")
   end

   zlist =_convert_zlist(elements)
   NZ = length(zlist)

   if spec == nothing
      spec = [ (n = n, l = l) for n = 1:maxn, l = 0:maxl
                              if level((n = n, l = l)) <= max_level ]
   end

   # now the actual maxn is the maximum n in the spec
   actual_maxn = maximum([ s.n for s in spec ])
   
   if maxq == :auto 
      maxq = ceil(Int, actual_maxn * maxq_fact)
   end 

   if maxq < actual_maxn 
      @warn("maxq < actual_maxn; this results in linear dependence")
   end 

   if polys isa Symbol 
      if polys == :legendre
         polys = Polynomials4ML.legendre_basis(maxq) 
      else
         error("unknown polynomial type : $polys")
      end
   end

   if transforms isa Tuple && transforms[1] == :agnesi 
      p = transforms[2] 
      q = transforms[3]
      transforms = agnesi_transform.(rin0cuts, p, q)
   end

   if envelopes == :poly2sx
      envelopes = PolyEnvelope2sX(-1.0, 1.0, 2, 2)
   elseif envelopes == :poly1sr
      envelopes = [ PolyEnvelope1sR(rin0cuts[iz, jz].rcut, 1) 
                    for iz = 1:NZ, jz = 1:NZ ]
   end

   if actual_maxn > length(polys)
      error("actual_maxn > length of polynomial basis")
   end

   return LearnableRnlrzzBasis(zlist, polys, transforms, envelopes, 
                               rin0cuts, spec; 
                               Winit = Winit)
end 



function ace_model(; elements = nothing, 
                     order = nothing, 
                     Ytype = :solid,  
                     E0s = nothing,
                     rin0cuts = :auto,
                     # radial basis 
                     rbasis = nothing, 
                     rbasis_type = :learnable, 
                     maxl = 30, # maxl, max are fairly high defaults 
                     maxn = 50, # that we will likely never reach 
                     maxq_fact = 1.5, 
                     maxq = :auto, 
                     init_Wradial = :glorot_normal, 
                     # basis size parameters 
                     level = nothing, 
                     max_level = nothing, 
                     init_WB = :zeros, 
                     # pair basis 
                     pair_maxn = nothing, 
                     pair_basis = :auto, 
                     pair_learnable = false, 
                     pair_transform = (:agnesi, 1, 4), 
                     init_Wpair = "linear", 
                     rng = Random.default_rng(), 
                     )

   if rin0cuts == :auto
      rin0cuts = _default_rin0cuts(elements)
   else
      NZ = length(elements)
      @assert rin0cuts isa SMatrix && size(rin0cuts) == (NZ, NZ)
   end

   # construct an rbasis if needed
   if isnothing(rbasis)
      if rbasis_type == :learnable
         rbasis = ace_learnable_Rnlrzz(; max_level = max_level, level = level, 
                                         maxl = maxl, maxn = maxn, 
                                         maxq_fact = maxq_fact, maxq = maxq, 
                                         elements = elements, 
                                         rin0cuts = rin0cuts, 
                                         Winit = init_Wradial)
      else
         error("unknown rbasis_type = $rbasis_type")
      end
   end

   # construct a pair basis if needed 
   if pair_basis == :auto
      @assert pair_maxn isa Integer 

      pair_basis = ace_learnable_Rnlrzz(; 
               elements = rbasis._i2z, 
               level = TotalDegree(), 
               max_level = pair_maxn, 
               maxl = 0, 
               maxn = pair_maxn, 
               rin0cuts = rbasis.rin0cuts,
               transforms = pair_transform, 
               envelopes = :poly1sr )
   end

   pair_basis.meta["Winit"] = init_Wpair 

   if !pair_learnable
      ps_pair = initialparameters(rng, pair_basis)
      pair_basis = splinify(pair_basis, ps_pair)
   end

   AA_spec = sparse_AA_spec(; order = order, r_spec = rbasis.spec, 
                              level = level, max_level = max_level)

   model = ace_model(rbasis, Ytype, AA_spec, level, pair_basis, E0s)
   model.meta["init_WB"] = String(init_WB)
   model.meta["init_Wpair"] = String(init_Wpair)

   return model 
end


# -------------------------------------------------------