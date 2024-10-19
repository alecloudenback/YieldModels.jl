@testset "Stochastic Valuation" begin
    c = Yield.Constant(0.04)
    m = HullWhite(0.1, 0.002, c) # a, σ, curve

    @test pv(m, Cashflow(0,))
end