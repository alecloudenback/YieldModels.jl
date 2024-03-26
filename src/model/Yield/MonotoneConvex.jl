"""
An unfit Monotone Convex Yield Curve Model will simply have 


"""
struct MonotoneConvex{T,U} <: AbstractYieldModel
    f::Vector{T}
    fᵈ::Vector{T}
    rates::Vector{T}
    times::Vector{U}
    # inner constructor ensures f consistency with rates at construction
    function MonotoneConvex(rates::Vector{T}, times::Vector{U}) where {T,U}
        f, fᵈ = __monotone_convex_fs(rates, times)
        new{T,U}(f, fᵈ, rates, times)
    end
end


struct MonotoneConvexUnInit
end

MonotoneConvex() = MonotoneConvexUnInit()
function (m::MonotoneConvexUnInit)(times)
    rates = zeros(length(times))
    MonotoneConvex(rates, times)
end


function __issector1(g0, g1)
    a = (g0 > 0) && (g1 >= -2 * g0) && (-0.5 * g0 >= g1)
    b = (g0 < 0) && (g1 <= -2 * g0) && (-0.5 * g0 <= g1)
    a || b
end

function __issector2(g0, g1)
    a = (g0 > 0) && (g1 < -2 * g0)
    b = (g0 < 0) && (g1 > -2 * g0)
    a || b
end

# Hagan West - WILMOTT magazine pgs 75-81
function g(x, f⁻, f, fᵈ)
    g0 = f⁻ - fᵈ
    g1 = f - fᵈ
    A = -2 * g0
    B = -2 * g1
    if sign(g0) == sign(g1)
        # sector (iv)
        η = g1 / (g1 + g0)
        α = -g0 * g1 / (g1 + g0)

        if x < η
            return α + (g0 - α) * ((η - x) / η)^2
        else
            return α + (g1 - α) * ((x - η) / (1 - η))^2
        end


    elseif __issector1(g0, g1)
        # sector (i)
        g0 * (1 - 4 * x + 3 * x^2) + g1 * (-2 * x + 3 * x^2)
    elseif __issector2(g0, g1)
        # sector (ii)
        η = (g1 + 2 * g0) / (g1 - g0)
        if x < η
            return g0
        else
            return g0 + (g1 - g0) * ((x - η) / (1 - η))^2
        end
    else
        # sector (iii)
        η = 3 * g1 / (g1 - g0)
        if x > η
            return g1
        else
            return g1 + (g0 - g1) * ((η - x) / η)^2
        end

    end
end

function g_rate(x, f⁻, f, fᵈ)
    g0 = f⁻ - fᵈ
    g1 = f - fᵈ
    A = -2 * g0
    B = -2 * g1
    if sign(g0) == sign(g1)
        # sector (iv)
        η = g1 / (g1 + g0)
        α = -g0 * g1 / (g1 + g0)

        if x < η
            return α * x - (g0 - α) * ((η - x)^3 / η^2 - η) / 3
        else
            return (2 * α + g0) / 3 * η + α * (x - η) + (g1 - α) / 3 * (x - η)^3 / (1 - η)^2
        end


    elseif __issector1(g0, g1)
        # sector (i)
        g0 * (x - 2 * x^2 + x^3) + g1 * (-x^2 + x^3)
    elseif __issector2(g0, g1)
        # sector (ii)
        η = (g1 + 2 * g0) / (g1 - g0)
        if x < η
            return g0 * x
        else
            return g0 * x + ((g1 - g0) * (x - η)^3 / (1 - η)^2) / 3
        end
    else
        # sector (iii)
        η = 3 * g1 / (g1 - g0)
        if x > η
            return (2 * g1 + g0) / 3 * η + g1 * (x - η)
        else
            return g1 * x - (g0 - g1) * ((η - x)^3 / η^2 - η) / 3
        end

    end
end

function forward(t, rates, times)

    t, i_time, rates, times = __monotone_convex_init(t, rates, times)
    f, fᵈ = __monotone_convex_fs(rates, times)

    x = (t - times[i_time]) / (times[i_time+1] - times[i_time])
    return fᵈ[i_time+1] + g(x, f[i_time], f[i_time+1], fᵈ[i_time+1])
end

"""
    returns the index associated with the time t, an initial rate vector, and a time vector
"""
function __monotone_convex_init(t, rates, times)
    # the array indexing in the paper and psuedo-VBA is messy
    t = min(t, last(times))
    # times = collect(times)
    # rates = collect(rates)
    i_time = findfirst(x -> x > t, times)
    if i_time == nothing
        i_time = lastindex(times)
    end
    # if !iszero(first(times))
    #     pushfirst!(times, zero(eltype(times)))
    #     pushfirst!(rates, first(rates))

    # end

    return t, i_time, rates, times
end
"""
    returns a pair of vectors (f and fᵈ) used in Monotone Convex Yield Curve fitting
"""
function __monotone_convex_fs(rates, times)
    # step 1
    fᵈ = map(2:length(times)) do i
        (times[i] * rates[i] - times[i-1] * rates[i-1]) / (times[i] - times[i-1])
    end
    pushfirst!(fᵈ, 0)
    # step 2
    f = map(2:length(times)-1) do i
        (times[i] - times[i-1]) / (times[i+1] - times[i-1]) * fᵈ[i+1] +
        (times[i+1] - times[i]) / (times[i+1] - times[i-1]) * fᵈ[i]
    end
    # step 3
    # collar(a,b,c) = clamp(b, a, c)
    pushfirst!(f, fᵈ[2] - 0.5 * (f[1] - fᵈ[2]))
    fᵈ[end], f[end-1], fᵈ[end]
    push!(f, fᵈ[end] - 0.5 * (f[end] - fᵈ[end]))
    f[1] = clamp(f[1], 0, 2 * fᵈ[2])
    f[end] = clamp(f[end], 0, 2 * fᵈ[end])

    for j in 2:(length(times)-1)
        f[j] = clamp(f[j], 0, 2 * min(fᵈ[j], fᵈ[j+1]))
    end

    return f, fᵈ
end
function myzero(t, rates, times)
    lt = last(times)
    # if the time is greater than the last input time then extrapolate using the forwards
    if t > lt
        r = myzero(lt, rates, times)
        return r * lt / t + forward(lt, rates, times) * (1 - lt / t)
    end

    t, i_time, rates, times = __monotone_convex_init(t, rates, times)
    f, fᵈ = __monotone_convex_fs(rates, times)
    x = (t - times[i_time]) / (times[i_time+1] - times[i_time])
    G = g_rate(x, f[i_time], f[i_time+1], fᵈ[i_time+1])
    return 1 / t * (times[i_time] * rates[i_time] + (t - times[i_time]) * fᵈ[i_time+1] + (times[i_time+1] - times[i_time]) * G)




end

function Base.zero(mc::MonotoneConvex, t)
    lt = last(times)
    # if the time is greater than the last input time then extrapolate using the forwards
    if t > lt
        r = myzero(lt, rates, times)
        return r * lt / t + forward(lt, rates, times) * (1 - lt / t)
    end

    t, i_time, rates, times = __monotone_convex_init(t, rates, times)
    f, fᵈ = mc.f, mc.fᵈ
    x = (t - times[i_time]) / (times[i_time+1] - times[i_time])
    G = g_rate(x, f[i_time], f[i_time+1], fᵈ[i_time+1])
    return 1 / t * (times[i_time] * rates[i_time] + (t - times[i_time]) * fᵈ[i_time+1] + (times[i_time+1] - times[i_time]) * G)

end

function FinanceCore.discount(mc::MonotoneConvex, t)
    r = zero(mc, t)
    return exp(-r * t)
end

times = 1:5
rates = [0.03, 0.04, 0.047, 0.06, 0.06]
# forward(5.19, rates, times)
# myzero(1, rates, times)


# using Test
# @test forward(0.5, rates, times) ≈ 0.02875
# @test forward(1, rates, times) ≈ 0.04
# @test forward(2, rates, times) ≈ 0.0555
# @test forward(2.5, rates, times) ≈ 0.0571254591368226
# @test forward(5, rates, times) ≈ 0.05025
# @test forward(5.2, rates, times) ≈ 0.05025

# @test myzero(0.5, rates, times) ≈ 0.02625
# @test myzero(1, rates, times) ≈ 0.03
# @test myzero(2, rates, times) ≈ 0.04
# @test myzero(2.5, rates, times) ≈ 0.0431375956535047
# @test myzero(5, rates, times) ≈ 0.06
# @test myzero(5.2, rates, times) ≈ 0.059625


