# bootstrapped class of curve methods
struct Bootstrap{T} <: YieldCurveFitParameters
    interpolation::T
end

function Bootstrap()
    return Bootstrap(QuadraticSpline())
end

struct BootstrapCurve{T,U,V} <: AbstractYieldCurve
    rates::T
    maturities::U
    zero::V # function time -> continuous zero rate
end
discount(yc::T, time) where {T<:BootstrapCurve} = exp(-yc.zero(time) * time)

__ratetype(::Type{BootstrapCurve{T,U,V}}) where {T,U,V}= Yields.Rate{Float64, typeof(DEFAULT_COMPOUNDING)}

# Forward curves

"""
    ForwardStarting(curve,forwardstart)

Rebase a `curve` so that `discount`/`accumulation`/etc. are re-based so that time zero from the new curves perspective is the given `forwardstart` time.

# Examples

```julia-repl
julia> zero = [5.0, 5.8, 6.4, 6.8] ./ 100
julia> maturity = [0.5, 1.0, 1.5, 2.0]
julia> curve = Yields.Zero(zero, maturity)
julia> fwd = Yields.ForwardStarting(curve, 1.0)

julia> discount(curve,1,2)
0.9275624570410582

julia> discount(fwd,1) # `curve` has effectively been reindexed to `1.0`
0.9275624570410582
```

# Extended Help

While `ForwardStarting` could be nested so that, e.g. the third period's curve is the one-period forward of the second period's curve, it will be more efficient to reuse the initial curve from a runtime and compiler perspective.

`ForwardStarting` is not used to construct a curve based on forward rates. See  [`Forward`](@ref) instead.
"""
struct ForwardStarting{T,U} <: AbstractYieldCurve
    curve::U
    forwardstart::T
end
__ratetype(::Type{ForwardStarting{T,U}}) where {T,U}= __ratetype(U)

function discount(c::ForwardStarting, to)
    discount(c.curve, c.forwardstart, to + c.forwardstart)
end

function Base.zero(c::ForwardStarting, to,cf::C) where {C<:CompoundingFrequency}
    z = forward(c.curve,c.forwardstart,to+c.forwardstart)
    return convert(cf,z)
end


"""
    Constant(rate::Real, cf::CompoundingFrequency=Periodic(1))
    Constant(r::Rate)

Construct a yield object where the spot rate is constant for all maturities. If `rate` is not a `Rate` type, will assume `Periodic(1)` for the compounding frequency

# Examples

```julia-repl
julia> y = Yields.Constant(0.05)
julia> discount(y,2)
0.9070294784580498     # 1 / (1.05) ^ 2
```
"""
struct Constant{T} <: AbstractYieldCurve
    rate::T
end
__ratetype(::Type{Constant{T}}) where {T} = T
CompoundingFrequency(c::Constant{T}) where {T} = c.rate.compounding

function Constant(rate::T, cf::C = Periodic(1)) where {T<:Real,C<:CompoundingFrequency}
    return Constant(Rate(rate, cf))
end

Base.zero(c::Constant, time) = c.rate
Base.zero(c::Constant, time, cf::CompoundingFrequency) = convert(cf, c.rate)
rate(c::Constant) = c.rate
rate(c::Constant, time) = c.rate
discount(r::Constant, time) = discount(r.rate, time)
discount(r::Constant, from, to) = discount(r.rate, to - from)
accumulation(r::Constant, time) = accumulation(r.rate, time)
accumulation(r::Constant, from, to) = accumulation(r.rate, to - from)

"""
    Step(rates,times)

Create a yield curve object where the applicable rate is the effective rate of interest applicable until corresponding time. If `rates` is not a `Vector{Rate}`, will assume `Periodic(1)` type.

The last rate will be applied to any time after the last time in `times`.

# Examples

```julia-repl
julia>y = Yields.Step([0.02,0.05], [1,2])

julia>rate(y,0.5)
0.02

julia>rate(y,1.5)
0.05

julia>rate(y,2.5)
0.05
```
"""
struct Step{R,T} <: AbstractYieldCurve
    rates::R
    times::T
end
__ratetype(::Type{Step{R,T}}) where {R,T}= eltype(R)
CompoundingFrequency(c::Step{T}) where {T} = first(c.rates).compounding

Step(rates) = Step(rates, collect(1:length(rates)))

function Step(rates::Vector{<:Real},times) 
    r = Periodic.(rates,1)
    Step(r, times)
end

function discount(y::Step, time)
    v = 1.0
    last_time = 0.0


    for (rate,t) in zip(y.rates,y.times)
        duration = min(time - last_time,t-last_time)
        v *= discount(rate,duration)
        last_time = t
        (last_time > time) && return v
        
    end

    # if we did not return in the loop, then we extend the last rate
    v *= discount(last(y.rates), time - last_time)
    return v
end


"""
    Zero(rates, maturities; interpolation=QuadraticSpline())

Construct a yield curve with given zero-coupon spot `rates` at the given `maturities`. If `rates` is not a `Vector{Rate}`, will assume `Periodic(1)` type.

See [`bootstrap`](@ref) for more on the `interpolation` parameter, which is set to `QuadraticSpline()` by default.
"""
function Zero(b::Bootstrap,rates::Vector{<:Rate}, maturities)
    # bump to a constant yield if only given one rate
    length(rates) == 1 && return Constant(first(rates))
    return _zero_inner(rates,maturities,b.interpolation)
end

# zero is different than the other boostrapped curves in that it doesn't actually need to bootstrap 
# because the rate are already zero rates. Instead, we just cut straight to the 
# appropriate interpolation function based on the type dispatch.
function _zero_inner(rates::Vector{<:Rate}, maturities, interp::QuadraticSpline)
    continuous_zeros = rate.(convert.(Continuous(), rates))
    return BootstrapCurve(
        rates,
        maturities,
        cubic_interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

function _zero_inner(rates::Vector{<:Rate}, maturities, interp::LinearSpline)
    continuous_zeros = rate.(convert.(Continuous(), rates))
    return BootstrapCurve(
        rates,
        maturities,
        linear_interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

# fallback for user provied interpolation function
function _zero_inner(rates::Vector{<:Rate}, maturities, interp)
    continuous_zeros = rate.(convert.(Continuous(), rates))
    return BootstrapCurve(
        rates,
        maturities,
        interp([0.0; maturities],[first(continuous_zeros); continuous_zeros])
    )
end

#fallback if `rates` aren't `Rate`s. Assume `Periodic(1)` per Zero docstring
function Zero(b::Bootstrap,rates, maturities)
    Zero(b,Periodic.(rates, 1), maturities)
end


"""
    Par(rates, maturities; interpolation=QuadraticSpline())

Construct a curve given a set of bond equivalent yields and the corresponding maturities. Assumes that maturities <= 1 year do not pay coupons and that after one year, pays coupons with frequency equal to the CompoundingFrequency of the corresponding rate (normally the default for a `Rate` is `1`, but when constructed via `Par` the default compounding Frequency is `2`).

See [`bootstrap`](@ref) for more on the `interpolation` parameter, which is set to `QuadraticSpline()` by default.

# Examples

```julia-repl

julia> par = [6.,8.,9.5,10.5,11.0,11.25,11.38,11.44,11.48,11.5] ./ 100
julia> maturities = [t for t in 1:10]
julia> curve = Par(par,maturities);
julia> zero(curve,1)
Rate(0.06000000000000005, Periodic(1))

```
"""
function Par(b::Bootstrap,rates::Vector{<:Rate}, maturities)
    # bump to a constant yield if only given one rate
    if length(rates) == 1
        return Constant(rate[1])
    end
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise semi-annual
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 1 / r.compounding.frequency for (r, m) in zip(rates, maturities)], b.interpolation)
    )
end

function Par(b::Bootstrap,rates::Vector{T}, maturities) where {T<:Real}
    return Par(b,Yields.Periodic.(rates,2), maturities)
end


"""
    Forward(rate_vector,maturities)

Takes a vector of 1-period forward rates and constructs a discount curve. If rate_vector is not a vector of `Rates` (ie is just a vector of `Float64` values), then
the assumption is that each value is `Periodic` rate compounded once per period.

# Examples

```julia-repl
julia> Yields.Forward( [0.01,0.02,0.03] );

julia> Yields.Forward( Yields.Continuous.([0.01,0.02,0.03]) );

```
"""
function Forward(b::Bootstrap,rates, maturities)
    # convert to zeros and pass to Zero
    disc_v = Vector{Float64}(undef, length(rates))

    v = 1.0

    for (i,r) = enumerate(rates)
        Δt = maturities[i] - (i == 1 ? 0 : maturities[i-1])
        v *= discount(r, Δt)
        disc_v[i] = v
    end

    z = (1.0 ./ disc_v) .^ (1 ./ maturities) .- 1 # convert disc_v to zero
    return Zero(b,z, maturities)
end

# if rates isn't a vector of Rates, then we assume periodic rates compounded once per period.
function Forward(b::Bootstrap,rates::Vector{<:Real}, maturities)
    return Forward(b,Yields.Periodic.(rates, 1), maturities)
end

"""
    Yields.CMT(rates, maturities; interpolation=QuadraticSpline())

Takes constant maturity (treasury) yields (bond equivalent), and assumes that instruments <= one year maturity pay no coupons and that the rest pay semi-annual.

See [`bootstrap`](@ref) for more on the `interpolation` parameter, which is set to `QuadraticSpline()` by default.

# Examples

```
# 2021-03-31 rates from Treasury.gov
rates =[0.01, 0.01, 0.03, 0.05, 0.07, 0.16, 0.35, 0.92, 1.40, 1.74, 2.31, 2.41] ./ 100
mats = [1/12, 2/12, 3/12, 6/12, 1, 2, 3, 5, 7, 10, 20, 30]
	
Yields.CMT(rates,mats)
```
"""
function CMT(b::Bootstrap,rates::Vector{T}, maturities) where {T<:Real}
    rs = map(zip(rates, maturities)) do (r, m)
        if m <= 1
            Rate(r, Periodic(1 / m))
        else
            Rate(r, Periodic(2))
        end
    end

    CMT(b,rs, maturities)
end

function CMT(b::Bootstrap,rates::Vector{<:Rate}, maturities)
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise semi-annual
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 0.5 for m in maturities], b.interpolation)
    )
end


"""
    OIS(rates,maturities)
Takes Overnight Index Swap rates, and assumes that instruments <= one year maturity are settled once and other agreements are settled quarterly with a corresponding CompoundingFrequency.

See [`bootstrap`](@ref) for more on the `interpolation` parameter, which is set to `QuadraticSpline()` by default.

"""
function OIS(b::Bootstrap,rates::Vector{T}, maturities) where {T<:Real}
    rs = map(zip(rates, maturities)) do (r, m)
        if m <= 1
            Rate(r, Periodic(1 / m))
        else
            Rate(r, Periodic(4))
        end
    end

    return OIS(b,rs, maturities)
end
function OIS(b::Bootstrap,rates::Vector{<:Rate}, maturities)
    return BootstrapCurve(
        rates,
        maturities,
        # assume that maturities less than or equal to 12 months are settled once, otherwise quarterly
        # per Hull 4.7
        bootstrap(rates, maturities, [m <= 1 ? nothing : 1 / 4 for m in maturities], b.interpolation)
    )
end


"""
    par(curve,time;frequency=2)

Calculate the par yield for maturity `time` for the given `curve` and `frequency`. Returns a `Rate` object with periodicity corresponding to the `frequency`. The exception to this is if `time` is less than what the payments allowed by frequency (e.g. a time `0.5` but with frequency `1`) will effectively assume frequency equal to 1 over `time`.

# Examples

julia> c = Yields.Constant(0.04);

julia> Yields.par(c,4)
Yields.Rate{Float64, Yields.Periodic}(0.03960780543711406, Yields.Periodic(2))

julia> Yields.par(c,4;frequency=1)
Yields.Rate{Float64, Yields.Periodic}(0.040000000000000036, Yields.Periodic(1))

julia> Yields.par(c,0.6;frequency=4)
Yields.Rate{Float64, Yields.Periodic}(0.039413626195875295, Yields.Periodic(4))

julia> Yields.par(c,0.2;frequency=4)
Yields.Rate{Float64, Yields.Periodic}(0.039374942589460726, Yields.Periodic(5))

julia> Yields.par(c,2.5)
Yields.Rate{Float64, Yields.Periodic}(0.03960780543711406, Yields.Periodic(2))

"""
function par(curve, time; frequency=2)
    mat_disc = discount(curve, time)
    coup_times = coupon_times(time,frequency)
    coupon_pv = sum(discount(curve,t) for t in coup_times)
    Δt = step(coup_times)
    r = (1-mat_disc) / coupon_pv
    cfs = [t == last(coup_times) ? 1+r : r for t in coup_times]
    # `sign(r)`` is used instead of `1` because there are times when the coupons are negative so we want to flip the sign
    cfs = [-1;cfs]
    r = internal_rate_of_return(cfs,[0;coup_times])
    frequency_inner = min(1/Δt,max(1 / Δt, frequency))
    r = convert(Periodic(frequency_inner),r)
    return r
end
