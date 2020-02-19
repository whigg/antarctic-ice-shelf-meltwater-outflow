using DelimitedFiles, Printf
using Interpolations, Plots

using Oceananigans
using Oceananigans.Diagnostics
using Oceananigans.OutputWriters
using Oceananigans.Utils

# setting up a 2-d model in the style of NG17

#####
##### Some useful constants
#####

const km = 1000
const Ω_Earth = 7.292115e-5  # [s⁻¹]
const φ = -75  # degrees latitude

#####
##### Model grid and domain size
#####

arch = GPU()
FT = Float64

Nx = 1
Ny = 256 
Nz = 64 

Lx = 5km/Ny
Ly = 5km
Lz = 300 

end_time = 7day

# Make up temperature profiles
zC = collect(((-Lz:Lz/Nz:0).+Lz/(2*Nz))[1:end-1])
T₀ = collect(1:2/(Nz-1):3)
S₀ = 34*ones(Nz) 

#####
##### Set up relaxation areas for the meltwater source and for the northern boundary 
#####

# Meltwater source location - implemented as a box
source_corners_m = ((1,1,1),(Lx,50,10))
N = (Nx,Ny,Nz)
L = (Lx,Ly,Lz)
source_corners = (Int.(ceil.(source_corners_m[1].*N./L)),Int.(ceil.(source_corners_m[2].*N./L)))

λ = 1/(60)  # Relaxation timescale [s⁻¹].

# Temperature and salinity of the meltwater outflow.
T_source = 3 
S_source = 34

# Specify width of stable relaxation area
stable_relaxation_width_m = 400 
stable_relaxation_width = Int(ceil(stable_relaxation_width_m.*Ny./Ly))

# Forcing functions 
@inline T_relax(i, j, k, grid, time, U, C, p) =
@inbounds ifelse((p.source_corners[1][1]<=i<=p.source_corners[2][1])*(p.source_corners[1][2]<=j<=p.source_corners[2][2])*(p.source_corners[1][3]<=k<=p.source_corners[2][3]),(-p.λ * (C.T[i, j, k] - p.T_source)), 0) +
@inbounds ifelse(j>Ny-p.stable_relaxation_width,-p.λ * (C.T[i, j, k] - T₀[k]),0)

@inline S_relax(i, j, k, grid, time, U, C, p) =
@inbounds ifelse((p.source_corners[1][1]<=i<=p.source_corners[2][1])*(p.source_corners[1][2]<=j<=p.source_corners[2][2])*(p.source_corners[1][3]<=k<=p.source_corners[2][3]), (-p.λ * (C.S[i, j, k] - p.S_source)), 0) + 
@inbounds ifelse(j>Ny-p.stable_relaxation_width,-p.λ * (C.S[i, j, k] - p.S₀[k]),0)

params = (source_corners=source_corners, T_source=T_source, S_source=S_source, λ=λ, stable_relaxation_width=stable_relaxation_width, T₀=T₀,S₀=S₀)

forcing = ModelForcing(T = T_relax, S = S_relax)

#####
##### Set up model
#####

# eos = LinearEquationOfState()
eos = RoquetIdealizedNonlinearEquationOfState(:freezing)

model = Model(
           architecture = arch,
             float_type = FT,
                   grid = RegularCartesianGrid(size=(Nx, Ny, Nz), x=(-Lx/2, Lx/2), y=(0, Ly), z=(-Lz, 0)),
                tracers = (:T, :S, :meltwater),
               coriolis = FPlane(rotation_rate=Ω_Earth, latitude=φ),
               buoyancy = SeawaterBuoyancy(equation_of_state=eos),
                closure = AnisotropicMinimumDissipation(),
    boundary_conditions = ChannelSolutionBCs(),
                forcing = forcing,
             parameters = params
)


#####
##### Setting up initial conditions
#####

T₀_3D = repeat(reshape(T₀, 1, 1, Nz), Nx, Ny, 1)
S₀_3D = repeat(reshape(S₀, 1, 1, Nz), Nx, Ny, 1)

set!(model.tracers.T, T₀_3D)
set!(model.tracers.S, S₀_3D)

# Set meltwater concentration to 1 at the source.
model.tracers.meltwater.data[source_corners[1][1]:source_corners[2][1],source_corners[1][2]:source_corners[2][2],source_corners[1][3]:source_corners[2][3]] .= 1  

#####
##### Write out 3D fields and slices to NetCDF files.
#####

fields = Dict(
        "u" => model.velocities.u,
        "v" => model.velocities.v,
        "w" => model.velocities.w,
        "T" => model.tracers.T,
        "S" => model.tracers.S,
"meltwater" => model.tracers.meltwater,
       "nu" => model.diffusivities.νₑ,
   "kappaT" => model.diffusivities.κₑ.T,
   "kappaS" => model.diffusivities.κₑ.S
)

output_attributes = Dict(
        "u" => Dict("longname" => "Velocity in the x-direction", "units" => "m/s"),
        "v" => Dict("longname" => "Velocity in the y-direction", "units" => "m/s"),
        "w" => Dict("longname" => "Velocity in the z-direction", "units" => "m/s"),
        "T" => Dict("longname" => "Temperature", "units" => "C"),
        "S" => Dict("longname" => "Salinity", "units" => "g/kg"),
"meltwater" => Dict("longname" => "Meltwater concentration"),
       "nu" => Dict("longname" => "Nonlinear LES viscosity", "units" => "m^2/s"),
   "kappaT" => Dict("longname" => "Nonlinear LES diffusivity for temperature", "units" => "m^2/s"),
   "kappaS" => Dict("longname" => "Nonlinear LES diffusivity for salinity", "units" => "m^2/s")
)

eos_name(::LinearEquationOfState) = "LinearEOS"
eos_name(::RoquetIdealizedNonlinearEquationOfState) = "RoquetEOS"
prefix = "ice_shelf_meltwater_outflow_2d_$(eos_name(eos))_"

model.output_writers[:fields] =
    NetCDFOutputWriter(model, fields, filename = prefix * "fields.nc",
                       interval = 6hour, output_attributes = output_attributes)

model.output_writers[:along_channel_slice] =
    NetCDFOutputWriter(model, fields, filename = prefix * "along_channel_yz_slice.nc",
                       interval = 5minute, output_attributes = output_attributes,
                       xC = 1, xF = 1)

#####
##### Print banner
#####

@printf("""

    Simulating ocean dynamics of meltwater outflow from beneath Antarctic ice shelves
        N : %d, %d, %d
        L : %.3g, %.3g, %.3g [km]
        Δ : %.3g, %.3g, %.3g [m]
        φ : %.3g [latitude]
        f : %.3e [s⁻¹]
     days : %d
 T_source : %.2f [°C]
 S_source : %.2f [g/kg]
  closure : %s
      EoS : %s

""", model.grid.Nx, model.grid.Ny, model.grid.Nz,
     model.grid.Lx / km, model.grid.Ly / km, model.grid.Lz / km,
     model.grid.Δx, model.grid.Δy, model.grid.Δz,
     φ, model.coriolis.f, end_time / day,
     T_source, S_source,
     typeof(model.closure), typeof(model.buoyancy.equation_of_state))

#####
##### Time step!
#####

# Wizard utility that calculates safe adaptive time steps.
wizard = TimeStepWizard(cfl=0.2, Δt=1second, max_change=1.2, max_Δt=10second)

# CFL utilities for reporting stability criterions.
cfl = AdvectiveCFL(wizard)
dcfl = DiffusiveCFL(wizard)

# Number of time steps to perform at a time before printing a progress
# statement and updating the adaptive time step.
Ni = 20

# Convenient alias
C_mw = model.tracers.meltwater

while model.clock.time < end_time
    walltime = @elapsed begin
        time_step!(model; Nt=Ni, Δt=wizard.Δt)

	# add passive meltwater tracer at source, remove at boundary
        C_mw.data[source_corners[1][1]:source_corners[2][1],source_corners[1][2]:source_corners[2][2],source_corners[1][3]:source_corners[2][3]] .= 1
	C_mw.data[:,Ny-stable_relaxation_width:Ny,:] .= 0

        ## Normalize meltwater concentration to be 0 <= C_mw <= 1.
        #C_mw.data .= max.(0, C_mw.data)
        #C_mw.data .= C_mw.data ./ maximum(C_mw.data)
    end

    # Calculate simulation progress in %.
    progress = 100 * (model.clock.time / end_time)

    # Find maximum velocities.
    umax = maximum(abs, model.velocities.u.data.parent)
    vmax = maximum(abs, model.velocities.v.data.parent)
    wmax = maximum(abs, model.velocities.w.data.parent)

    # Find maximum ν and κ.
    νmax = maximum(model.diffusivities.νₑ.data.parent)
    κmax = maximum(model.diffusivities.κₑ.T.data.parent)

    # Calculate a new adaptive time step.
    update_Δt!(wizard, model)

    # Print progress statement.
    i, t = model.clock.iteration, model.clock.time
    @printf("[%06.2f%%] i: %d, t: %5.2f days, umax: (%6.3g, %6.3g, %6.3g) m/s, CFL: %6.4g, νκmax: (%6.3g, %6.3g), νκCFL: %6.4g, next Δt: %8.5g s, ⟨wall time⟩: %s\n",
            progress, i, t / day, umax, vmax, wmax, cfl(model), νmax, κmax, dcfl(model), wizard.Δt, prettytime(walltime / Ni))
end

for ow in model.output_writers
	ow isa NetCDFOutputWriter && close(ow)
end
