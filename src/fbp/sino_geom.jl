#=
sino_geom.jl
sinogram geometry for 2D tomographic image reconstruction
2019-07-01, Jeff Fessler, University of Michigan
=#

using MIRT: jim, image_geom, MIRT_image_geom # todo
using Plots: Plot, plot!, plot, scatter!, gui
using Test: @test


struct MIRT_sino_geom
	how::Symbol				# :par | :moj | :fan 
	units::Symbol			# :nothing | :mm | :cm etc.
	nb::Int					# # of "radial" samples, aka ns
	na::Int					# # of angular samples
	d::Float32				# aka dr or ds, "radial" sample spacing
							# (is dx for mojette, pixels must be square)
	orbit::Float32			# [degrees]
	orbit_start::Float32	# [degrees]
	offset::Float32			# sample offset, cf offset_r or offset_s [unitless]
	strip_width::Float32	# 

	# for fan:
	source_offset::Float32	# same units as d, etc., e.g., [mm]
							# use with caution!
	dsd::Float32			# dis_src_det, inf for parallel beam
	dod::Float32			# dis_iso_det
#	dso::Float32			# dis_src_iso = dsd-dod, inf for parallel beam
	dfs::Float32			# distance from focal spot to source
end


"""
`sino_geom_help()`
"""
function sino_geom_help()
    print("propertynames:\n")
    print(propertynames(sino_geom(:par)))

	"
	Derived values

	sg.dim			dimensions: (nb,na)
	sg.d			radial sample spacing, aka ds or dr
	sg.s			[nb] s sample locations
	sg.w			(nb-1)/2 + offset ('middle' sample position)
	sg.ad			source angles [degrees]
	sg.ar			source angles [radians]
	sg.ones			ones(Float32, nb,na)
	sg.zeros		zeros(Float32, nb,na)
	sg.rfov			radial fov
	sg.xds			[nb] center of detector elements (beta=0)
	sg.yds			[nb] ''

	For mojette:

	sg.d_ang		[na]

	For fan beam:

	sg.gamma		[nb] gamma sample values [radians]
	sg.gamma_max	half of fan angle [radians]
	sg.dso			# dsd - dod, inf for parallel beam

	Methods

	sg.down(down)		reduce sampling by integer factor
	sg.shape(sino)		reshape sinograms into array [nb na :]
	sg.unitv(;ib,ia)	unit 'vector' with single nonzero element
	sg.taufun(x,y)		projected s/ds for each (x,y) pair [numel(x) na]
	sg.plot(;ig)		plot system geometry (most useful for fan)
	"
end


"""
`function sg = sino_geom(...)`

Constructor for `MIRT_sino_geom`

Create the "sinogram geometry" structure that describes the sampling
characteristics of a given sinogram for a 2D parallel or fan-beam system.
Using this structure facilitates "object oriented" code.
(Use `ct_geom()` instead for 3D axial or helical cone-beam CT.)

in
* `how::Symbol`	`:fan` (fan-beam) | `:par` (parallel-beam) | `:moj` (mojette)
		or `:test` to run a self-test

options for all geometries (including parallel-beam):
* `units::Symbol`	e.g. `:cm` or `:mm`; default: :none
* `orbit_start`		default: 0
* `orbit`			[degrees] default: `180` for parallel / mojette
					and `360` for fan
					can be `:short` for fan-beam short scan
* `down::Int`		down-sampling factor, for testing

* `nb`				# radial samples cf `nr` (i.e., `ns` for `:fan`)
* `na`				# angular samples (cf `nbeta` for `:fan`)
* `d`				radial sample spacing; cf `dr` or `ds`; default 1
					for mojette this is actually `dx`
* `offset`			cf `offset_r` `channel_offset` unitless; default 0
			(relative to centerline between two central channels).
			Use 0.25 or 1.25 for "quarter-detector offset"
* `strip_width`		detector width; default: `d`

options for fan-beam
* `source_offset`		same units as d; use with caution! default 0
fan beam distances:
* `dsd`		cf 'dis_src_det'	default: inf (parallel beam)
* `dod`		cf 'dis_iso_det'	default: 0
* `dfs`		cf 'dis_foc_src'	default: 0 (3rd generation CT arc),
				use Inf for flat detector

out
* `sg::MIRT_sino_geom`	initialized structure

Jeff Fessler, University of Michigan
"""
function sino_geom(how::Symbol; kwarg...)
	if how == :test
		@test sino_geom_test( ; kwarg...)
		return true
	elseif how == :show
		return sino_geom_plot(how; kwarg...) # throw("todo")
	elseif how == :par
		sg = sino_geom_par( ; kwarg...)
	elseif how == :fan
		sg = sino_geom_fan( ; kwarg...)
	elseif how == :moj
		sg = sino_geom_moj( ; kwarg...)
	elseif how == :ge1
		sg = sino_geom_ge1( ; kwarg...)
	elseif how == :hd1
		sg = sino_geom_hd1( ; kwarg...)
#=
	elseif how == :revo1fan
		tmp = ir_fan_geom_revo1(type)
		sg = sino_geom(:fan, tmp{:}, varargin{:})
=#
	else
		throw("unknown sino type $how")
	end

	return sg
end


"""
`sg = downsample(sg, down)`
down-sample (for testing with small problems)
"""
function downsample(sg::MIRT_sino_geom, down::Integer)
	if down == 1
		return sg
	end
	nb = 2 * round(Int, sg.nb / down / 2) # keep it even
	na = round(Int, sg.na / down)

	return MIRT_sino_geom(sg.how, sg.units,
		nb, na, sg.d * down, sg.orbit, sg.orbit_start, sg.offset,
		sg.strip_width * down,
		sg.source_offset, sg.dsd, sg.dod, sg.dfs)
end


"""
`sg = sino_geom_fan()`
"""
function sino_geom_fan( ;
		units::Symbol = :none,
		nb::Integer = 128,
		na::Integer = 2 * floor(Int, nb * pi/2 / 2),
		d::Real = 1,
		orbit::Union{Symbol,Real} = 360, # [degrees]
		orbit_start::Real = 0,
		strip_width::Real = d,
		offset::Real = 0,
		dsd::Real = 4*nb*d,	# dis_src_det
	#	dso::Real = [],		# dis_src_iso
		dod::Real = nb*d,	# dis_iso_det
		dfs::Real = 0,		# dis_foc_src (3rd gen CT)
		down::Integer = 1,
	)

	if orbit == :short # trick
		sg_tmp = MIRT_sino_geom(:fan, units,
			nb, na, d, 0, orbit_start, strip_width,
			dsd, dod, dfs, 0)
		orbit = sg_tmp.orbit_short
	end
	isa(orbit, Symbol) && throw("orbit :orbit")

	sg = MIRT_sino_geom(:fan, units,
		nb, na, d, orbit, orbit_start, offset, strip_width,
		dsd, dod, dfs, 0)

	return downsample(sg, down)
end


"""
`sg = sino_geom_par( ... )`
"""
function sino_geom_par( ;
		units::Symbol = :none,
		nb::Integer = 128,
		na::Integer = 2 * floor(Int, nb * pi/2 / 2),
		down::Integer = 1,
		d::Real = 1,
		orbit::Real = 180, # [degrees]
		orbit_start::Real = 0,
		strip_width::Real = d,
		offset::Real = 0,
	)

	sg = MIRT_sino_geom(:par, units,
		nb, na, d, orbit, orbit_start, offset, strip_width,
		0, 0, 0, 0)

	return downsample(sg, down)
end


"""
`sg = sino_geom_moj( ... )`
"""
function sino_geom_moj( ;
		units::Symbol = :none,
		nb::Integer = 128,
		na::Integer = 2 * floor(Int, nb * pi/2 / 2),
		down::Integer = 1,
		d::Real = 1, # means dx for :moj
		orbit::Real = 180, # [degrees]
		orbit_start::Real = 0,
		strip_width::Real = d, # ignored ?
		offset::Real = 0,
	)

	sg = MIRT_sino_geom(:moj, units,
		nb, na, d, orbit, orbit_start, offset, strip_width,
		0, 0, 0, 0)

	return downsample(sg, down)
end


"""
`sino_geom_gamma()`
gamma sample values for :fan
"""
function sino_geom_gamma(sg)
	return	sg.dfs == 0 ? sg.s / sg.dsd : # 3rd gen: equiangular
			sg.dfs == Inf ? atan(sg.s / sg.dsd) : # flat
			throw("bad dfs $(sg.dfs)")
end


"""
`sino_geom_rfov()`
radial FOV
"""
function sino_geom_rfov(sg)
	return	sg.how == :par ? maximum(abs.(sg.r)) :
			sg.how == :fan ? sg.dso * sin(sg.gamma_max) :
				throw("bad how $(sg.how)")
end


"""
`sino_geom_taufun()`
projected `s/ds`, useful for footprint center and support
"""
function sino_geom_taufun(sg, x, y)
	size(x) != size(y) && throw("bad x,y size")
	x = x[:]
	y = y[:]
	if sg.how == :par
		tau = (x * cos.(sg.ar) + y * cos.(sg.ar)) / sg.dr
	elseif sg.how == :fan
		b = sg.ar' # row vector, for outer-product
		xb = x * cos.(b) + y * sin.(b)
		yb = -x * sin.(b) + y * cos.(b)
		tangam = (xb .- sg.source_offset) ./ (sg.dso .- yb) # e,tomo,fan,L,gam
		if sg.dfs == 0 # arc
			tau = sg.dsd / sg.ds * atan.(tangam)
		elseif sg.dfs == Inf # flat
			tau = sg.dsd / sg.ds * tangam
		else
			throw("bad dfs $(sg.dfs)")
		end
	else
		throw("bad how $(sg.how)")
	end
	return tau
end


"""
`sino_geom_xds()`
center positions of detectors (for beta = 0)
"""
function sino_geom_xds(sg)
	if sg.how == :par
		xds = sg.s
	elseif sg.how == :fan
		if sg.dfs == 0 # arc
			gam = sg.gamma
			xds = sg.dsd * sin.(gam)
		elseif sg.def == inf # flat
			xds = sg.s
		else
			throw("bad dfs $(sg.dfs))")
		end
	else
		throw("bad how $how")
	end
	return xds .+ sg.source_offset
end


"""
`sino_geom_yds()`
center positions of detectors (for beta = 0)
"""
function sino_geom_yds(sg)
	if sg.how == :par
		yds = zeros(Float32, sg.nb)
	elseif sg.how == :fan
		if sg.dfs == 0 # arc
			gam = sg.gamma
			yds = sg.dso .- sg.dsd * cos.(gam)
		elseif sg.def == inf # flat
			yds = fill(-sg.dod, sg.nb)
		else
			throw("bad dfs $(sg.dfs))")
		end
	else
		throw("bad how $how")
	end
	return yds
end


"""
`sino_geom_unitv()`
sinogram with a single ray
"""
function sino_geom_unitv(sg::MIRT_sino_geom;
		ib=round(Int, sg.nb/2+1),
		ia=round(Int, sg.na/2+1))
	out = sg.zeros
	out[ib,ia] = 1
	return out
end


function Base.display(sg::MIRT_sino_geom)
	ir_dump(sg)
end


# Extended properties

fun0 = Dict([
    (:help, sg -> print(sino_geom_help())),

	(:dim, sg -> (sg.nb, sg.na)),
	(:w, sg -> (sg.nb-1)/2 + sg.offset),
	(:ones, sg -> ones(Float32, sg.dim)),
	(:zeros, sg -> zeros(Float32, sg.dim)),

	(:dr, sg -> sg.d),
	(:ds, sg -> sg.d),
	(:r, sg -> sg.d * ((0:sg.nb-1) .- sg.w)),
	(:s, sg -> sg.r), # sample locations ('radial')

	(:gamma, sg -> sino_geom_gamma(sg)),
	(:gamma_max, sg -> maximum(abs.(sg.gamma))),
	(:orbit_short, sg -> 180 + 2 * rad2deg(sg.gamma_max)),
	(:ad, sg -> (0:sg.na-1)/sg.na * sg.orbit .+ sg.orbit_start),
	(:ar, sg -> deg2rad.(sg.ad)),

	(:rfov, sg -> sino_geom_rfov(sg)),
	(:xds, sg -> sino_geom_xds(sg)),
	(:yds, sg -> sino_geom_yds(sg)),
	(:dso, sg -> sg.dsd - sg.dod),

	# angular dependent d for :moj
	(:d_ang, sg -> sg.d * max.(abs.(cos.(sg.ar)), abs.(sin.(sg.ar)))),

	(:shape, sg -> ((x::AbstractArray{<:Number} -> reshape(x, sg.dim..., :)))),
	(:taufun, sg -> ((x,y) -> sino_geom_taufun(sg,x,y))),
	(:unitv, sg -> ((;kwarg...) -> sino_geom_unitv(sg; kwarg...))),
	(:plot, sg -> ((;ig) -> sino_geom_plot(sg, ig=ig))),

	# functions that return new geometry:

    (:down, sg -> (down::Int -> downsample(sg, down)))

	])


# Tricky overloading here!

Base.getproperty(sg::MIRT_sino_geom, s::Symbol) =
		haskey(fun0, s) ? fun0[s](sg) :
		getfield(sg, s)

Base.propertynames(sg::MIRT_sino_geom) =
	(fieldnames(typeof(sg))..., keys(fun0)...)


"""
`sino_geom_plot()`
picture of the source position / detector geometry
"""
function sino_geom_plot(sg; ig::Union{Nothing,MIRT_image_geom})
	plot()

	if !isnothing(ig)
		plot!(jim(ig.x, ig.y, ig.mask[:,:,1]))
		xmin = minimum(ig.x); xmax = maximum(ig.x)
		ymin = minimum(ig.y); ymax = maximum(ig.y)
		plot!([xmax, xmin, xmin, xmax, xmax],
			[ymax, ymax, ymin, ymin, ymax], color=:green, label="")
	end

	t = LinRange(0,2*pi,1001)
	rmax = maximum(abs.(sg.r))
	scatter!([0], [0], marker=:circle, label="")
	plot!(rmax * cos.(t), rmax * sin.(t), label="fov") # fov circle
	plot!(xlabel="x", ylabel="y", title = "fov = $(sg.rfov)")
#	axis equal, axis tight

#	if sg.how == :par
#	end

	if sg.how == :fan
		x0 = 0
		y0 = sg.dso
		t = LinRange(0,2*pi,100)
		rot = sg.ar[1]
		rot = [cos(rot) -sin(rot); sin(rot) cos(rot)]
		p0 = rot * [x0; y0]
		pd = rot * [sg.xds'; sg.yds']

		tmp = sg.ar .+ pi/2 # trick: angle beta defined ccw from y axis
		scatter!([p0[1]], [p0[2]], color=:yellow, label="") # source
		plot!(sg.dso * cos.(t), sg.dso * sin.(t), color=:cyan, label="") # source circle
		plot!(sg.dso * cos.(tmp), sg.dso * sin.(tmp), color=:cyan, label="") # source
		scatter!(pd[1,:][:], pd[2,:][:], color=:yellow, label="")

		plot!([pd[1,1], p0[1], pd[1,end]], [pd[2,1], p0[2], pd[2,end]],
			color=:red, label="")
		plot!(sg.rfov * cos.(t), sg.rfov * sin.(t), color=:magenta, label="") # fov circle
	end

#= todo
case 'moj'
	if isvar('ig') && ~isempty(ig)
		im(ig.x, ig.y, ig.mask(:,:,1))
		hold on
	end
	t = linspace(0,2*pi,1001)
	rmax = max(sg.s)
	rphi = sg.nb/2 * sg.d ./ (max(abs(cos(t)), abs(sin(t))))
	plot(0, 0, '.', rmax * cos(t), rmax * sin(t), '-') # fov circle
	plot(0, 0, '.', rphi .* cos(t), rphi .* sin(t), '-m') # fov circle
	if isvar('ig') && ~isempty(ig)
		hold off
	end
	axis([-1 1 -1 1] * max([rmax ig.fov/2]) * 1.1)
=#

	plot!()
end


"""
`sino_geom_ge1()`
sinogram geometry for GE lightspeed system
These numbers are published in IEEE T-MI Oct. 2006, p.1272-1283 wang:06:pwl
"""
function sino_geom_ge1( ;
		na::Int = 984,
		nb::Int = 888,
		orbit::Union{Symbol,Real} = 360,
		units::Symbol = :mm, # default units is mm
		kwarg...)

	if orbit == :short
		na = 642 # trick: reduce na for short scans
		orbit = na/984*360
	end

	scale = units == :mm ? 1 :
			units == :cm ? 10 :
			throw("units $units")
	return sino_geom(:fan, units=units,
			nb=nb, na=na,
			d = 1.0239/scale, offset = 1.25,
			dsd = 949.075/scale,
			dod = 408.075/scale,
			dfs = 0; kwarg...)
end


"""
`sino_geom_test()`
"""
function sino_geom_test( ; kwarg...)
	ig = image_geom(nx=512, fov=500)

	pl = Array{Plot}(undef, 2)
	ii = 1
	for dfs in (0,Inf) # arc flat
		sg = sino_geom(:ge1, orbit_start=20, dfs=dfs)

		sg.ad[2]
		sino_geom(:par)
		sino_geom(:moj)
		sg = sino_geom(:ge1)
		sg.rfov
		sd = sg.down(2)
		ii == 1 && sg.help
		sg.dim
		sg.w
		sg.ones
		sg.zeros
		sg.dr
		sg.ds
		sg.r
		sg.s
		sg.gamma
		sg.gamma_max
		sg.orbit_short
		sg.ad
		sg.ar
		sg.xds
		sg.yds
		sg.dso

		sg.d_ang # angular dependent d for :moj

		sg.shape(sg.ones[:])
		sg.taufun(ig.x, 0*ig.x)
		sg.unitv()
		sg.unitv(ib=1, ia=2)

		pl[ii] = sg.plot(ig=ig)
		ii += 1
	end

	plot(pl...)
	gui()

	true
end


sino_geom(:test) # todo
