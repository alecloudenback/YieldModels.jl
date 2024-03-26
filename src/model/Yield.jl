module Yield
import ..AbstractModel
import ..FinanceCore
import ..Spline as Sp
import ..BSplineKit
import UnicodePlots
import ..Bond: coupon_times

using ..FinanceCore: Continuous, Periodic, discount, accumulation, AbstractContract

export discount, zero, forward, par, pv

abstract type AbstractYieldModel <: AbstractModel end

"""
    Constant(rate)

A yield curve representing a flat term structure. `rate` can be a [`Rate`](@ref) object or a `Real` object.


If [`fit`](@ref FinanceModels.fit-Union{Tuple{F}, Tuple{Any, Any}, Tuple{Any, Any, F}} where F<:FinanceModels.Fit.Loss)ing with the default FinanceModels.jl settings, the solver will attempt to fit a discount rate with the range of: `-1.0 .. 1.0`
"""
struct Constant{R} <: AbstractYieldModel
    rate::R
end

function Constant(rate::R) where {R<:Real}
    Constant(FinanceCore.Rate(rate))
end

Constant() = Constant(0.0)

FinanceCore.discount(c::Constant, t) = FinanceCore.discount(c.rate, t)

# used as the object which gets optmized before finally returning a completed spline
struct IntermediateYieldCurve{U,V} <: AbstractYieldModel
    b::Sp.BSpline
    xs::Vector{U}
    ys::Vector{V} # here, ys are the discount factors
end

function FinanceCore.discount(ic::IntermediateYieldCurve, time)
    zs = zero_vec = -log.(clamp.(ic.ys, 0.00001, 1)) ./ ic.xs
    c = Yield.Spline(ic.b, ic.xs, zs)
    return exp(-c.fn(time) * time)
end

struct Spline{U} <: AbstractYieldModel
    fn::U # here, fn is a map from time to instantaneous zero rate
end

function (c::Spline)(time)
    c.fn(time)
    return exp(-c.fn(time) * time)
end

function FinanceCore.discount(c::Spline, time)
    z = c.fn(time)
    return exp(-z * time)
end

function Spline(b::Sp.BSpline, xs, ys)
    order = min(length(xs), b.order) # in case the length of xs is less than the spline order
    int = BSplineKit.interpolate(xs, ys, BSplineKit.BSplineOrder(order))
    return Spline(BSplineKit.extrapolate(int, BSplineKit.Smooth()))
end


include("Yield/SmithWilson.jl")
include("Yield/NelsonSiegelSvensson.jl")
include("Yield/MonotoneConvex.jl")

## Generic and Fallbacks
"""
    discount(yc, to)
    discount(yc, from,to)

The discount factor for the yield curve `yc` for times `from` through `to`.
"""
FinanceCore.discount(yc::T, from, to) where {T<:AbstractYieldModel} = discount(yc, to) / discount(yc, from)

"""
    forward(yc, from, to)˚

The forward `Rate` implied by the yield curve `yc` between times `from` and `to`.
"""
function FinanceCore.forward(yc::T, from, to=from + 1) where {T<:AbstractYieldModel}
    Continuous(log(discount(yc, from) / discount(yc, to)) / (to - from))
end

"""
    par(curve,time;frequency=2)

Calculate the par yield for maturity `time` for the given `curve` and `frequency`. Returns a `Rate` object with periodicity corresponding to the `frequency`. The exception to this is if `time` is less than what the payments allowed by frequency (e.g. a time `0.5` but with frequency `1`) will effectively assume frequency equal to 1 over `time`.

# Examples

```julia-repl
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
```
"""
function par(curve, time; frequency=2)
    mat_disc = discount(curve, time)
    coup_times = coupon_times(time, frequency)
    coupon_pv = sum(discount(curve, t) for t in coup_times)
    Δt = step(coup_times)
    r = (1 - mat_disc) / coupon_pv
    cfs = [t == last(coup_times) ? 1 + r : r for t in coup_times]
    # `sign(r)`` is used instead of `1` because there are times when the coupons are negative so we want to flip the sign
    cfs = [-1; cfs]
    r = FinanceCore.internal_rate_of_return(cfs, [0; coup_times])
    frequency_inner = min(1 / Δt, max(1 / Δt, frequency))
    r = convert(Periodic(frequency_inner), r)
    return r
end

"""
    zero(curve,time)

Return the zero rate for the curve at the given time.
"""
function Base.zero(c::YC, time) where {YC<:AbstractYieldModel}
    df = discount(c, time)
    r = -log(df) / time
    return Continuous(r)
end

"""
    accumulation(yc, from, to)

The accumulation factor for the yield curve `yc` for times `from` through `to`.
"""
function FinanceCore.accumulation(yc::AbstractYieldModel, time)
    return 1 ./ discount(yc, time)
end

function FinanceCore.accumulation(yc::AbstractYieldModel, from, to)
    return 1 ./ discount(yc, from, to)
end

## Curve Manipulations
"""
    CompositeYield(curve1,curve2,operation)

Creates a datastructure that will perform the given `operation` after independently calculating the effects of the two curves. 
Can only be created via the public API by using the `+`, `-`, `*`, and `/` operatations on `AbstractYield` objects.

As this is double the normal operations when performing calculations, if you are using the curve in performance critical locations, you should consider transforming the inputs and 
constructing a single curve object ahead of time.
"""
struct CompositeYield{T,U,V} <: AbstractYieldModel
    r1::T
    r2::U
    op::V
end


function FinanceCore.discount(rc::CompositeYield, time)
    a1 = discount(rc.r1, time)^(-1 / time) - 1
    a2 = discount(rc.r2, time)^(-1 / time) - 1
    return 1 / (1 + rc.op(a1, a2))^time
end


"""
    ForwardStarting(curve,forwardstart)

Rebase a `curve` so that `discount`/`accumulation`/etc. are re-based so that time zero from the new curves perspective is the given `forwardstart` time.

# Examples

```julia-repl
julia> zero = [5.0, 5.8, 6.4, 6.8] ./ 100
julia> maturity = [0.5, 1.0, 1.5, 2.0]
julia> curve = Yields.Zero(zero, maturity)
julia> fwd = Yields.ForwardStarting(curve, 1.0)

julia> FinanceCore.discount(curve,1,2)
0.9275624570410582

julia> FinanceCore.discount(fwd,1) # `curve` has effectively been reindexed to `1.0`
0.9275624570410582
```

# Extended Help

While `ForwardStarting` could be nested so that, e.g. the third period's curve is the one-period forward of the second period's curve, it will be more efficient to reuse the initial curve from a runtime and compiler perspective.

`ForwardStarting` is not used to construct a curve based on forward rates. 
"""
struct ForwardStarting{T,U} <: AbstractYieldModel
    curve::U
    forwardstart::T
end

function FinanceCore.discount(c::ForwardStarting, to)
    FinanceCore.discount(c.curve, c.forwardstart, to + c.forwardstart)
end

"""
    Yields.AbstractYieldModel + Yields.AbstractYieldModel

The addition of two yields will create a `CompositeYield`. For `rate`, `discount`, and `accumulation` purposes the spot rates of the two curves will be added together.
"""
function Base.:+(a::AbstractYieldModel, b::AbstractYieldModel)
    return CompositeYield(a, b, +)
end

function Base.:+(a::Constant, b::Constant)
    return Constant(a.rate + b.rate)
end

function Base.:+(a::T, b) where {T<:AbstractYieldModel}
    return a + Constant(b)
end

function Base.:+(a, b::T) where {T<:AbstractYieldModel}
    return Constant(a) + b
end

"""
    Yields.AbstractYieldModel * Yields.AbstractYieldModel

The multiplication of two yields will create a `CompositeYield`. For `rate`, `discount`, and `accumulation` purposes the spot rates of the two curves will be added together. This can be useful, for example, if you wanted to after-tax a yield.

# Examples

```julia-repl
julia> m = Yields.Constant(0.01) * 0.79;

julia> accumulation(m,1)
1.0079

julia> accumulation(.01*.79,1)
1.0079
```
"""
function Base.:*(a::AbstractYieldModel, b::AbstractYieldModel)
    return CompositeYield(a, b, *)
end

function Base.:*(a::Constant, b::Constant)
    a_kind = a.rate.compounding
    rate_new_basis = FinanceCore.rate(convert(a_kind, b.rate))
    return Constant(
        FinanceCore.Rate(
            FinanceCore.rate(a.rate) * rate_new_basis,
            a_kind
        )
    )
end

function Base.:*(a::T, b) where {T<:AbstractYieldModel}
    return a * Constant(b)
end

function Base.:*(a, b::T) where {T<:AbstractYieldModel}
    return Constant(a) * b
end

"""
    Yields.AbstractYieldModel - Yields.AbstractYieldModel

The subtraction of two yields will create a `CompositeYield`. For `rate`, `discount`, and `accumulation` purposes the spot rates of the second curves will be subtracted from the first.
"""
function Base.:-(a::AbstractYieldModel, b::AbstractYieldModel)
    return CompositeYield(a, b, -)
end

function Base.:-(a::Constant, b::Constant)
    Constant(a.rate - b.rate)
end

function Base.:-(a::T, b) where {T<:AbstractYieldModel}
    return a - Constant(b)
end

function Base.:-(a, b::T) where {T<:AbstractYieldModel}
    return Constant(a) - b
end

"""
    Yields.AbstractYieldModel / Yields.AbstractYieldModel

The division of two yields will create a `CompositeYield`. For `rate`, `discount`, and `accumulation` purposes the spot rates of the two curves will have the first divided by the second. This can be useful, for example, if you wanted to gross-up a yield to be pre-tax.

# Examples

```julia-repl
julia> m = Yields.Constant(0.01) / 0.79;

julia> accumulation(d,1)
1.0126582278481013

julia> accumulation(.01/.79,1)
1.0126582278481013
```
"""
function Base.:/(a::AbstractYieldModel, b::AbstractYieldModel)
    return CompositeYield(a, b, /)
end

function Base.:/(a::Constant, b::Constant)
    a_kind = a.rate.compounding
    rate_new_basis = FinanceCore.rate(convert(a_kind, b.rate))
    return Constant(
        FinanceCore.Rate(
            FinanceCore.rate(a.rate) / rate_new_basis,
            a_kind
        )
    )
end

function Base.:/(a::T, b) where {T<:AbstractYieldModel}
    return a / Constant(b)
end

function Base.:/(a, b::T) where {T<:AbstractYieldModel}
    return Constant(a) / b
end


# used to display simple type name in show method
# https://stackoverflow.com/questions/70043313/get-simple-name-of-type-in-julia?noredirect=1#comment123823820_70043313
name(::Type{T}) where {T} = (isempty(T.parameters) ? T : T.name.wrapper)

function Base.show(io::IO, curve::T) where {T<:AbstractYieldModel}
    r = zero(curve, 1)
    ylabel = isa(r.compounding, Continuous) ? "Continuous" : "Periodic($(r.compounding.frequency))"
    kind = name(typeof(curve))
    l = UnicodePlots.lineplot(
        0.0, #from 
        30.0,  # to
        t -> FinanceCore.rate(zero(curve, t)),
        xlabel="time",
        ylabel=ylabel,
        compact=true,
        name="Zero rates",
        width=60,
        title="Yield Curve ($kind)"
    )
    show(io, l)
end

end
