
Adivtype(A, b) = typeof(one(eltype(b))/one(eltype(A)))
function zerox(A, b)
    T = Adivtype(A, b)
    x = zeros(T, size(A, 2))
end


struct ConvergenceHistory{T, R}
    isconverged::Bool
    threshold::T
    mvps::Int
    residuals::R
end

##############################################################################
## LSMR
##
## Minimize ||Ax-b||^2 + λ^2 ||x||^2
##
## Adapted from the BSD-licensed Matlab implementation at
## http://web.stanford.edu/group/SOL/software/lsmr/
##
## A is a StridedVecOrMat or anything that implements 
## A_mul_B!(α, A, b, β, c) updates c -> α Ab + βc
## Ac_mul_B!(α, A, b, β, c) updates c -> α A'b + βc
## eltype(A)
## size(A)
## (this includes SparseMatrixCSC)
## x, v, h, hbar are AbstractVectors or anything that implements
## norm(x)
## copy!(x1, x2)
## scale!(x, α)
## axpy!(α, x1, x2)
## similar(x, T)
## length(x)
## b is an AbstractVector or anything that implements
## eltype(b)
## norm(b)
## copy!(x1, x2)
## fill!(b, α)
## scale!(b, α)
## similar(b, T)
## length(b)

##############################################################################


## Arguments:
## x is initial x0. Transformed in place to the solution.
## b equals initial b. Transformed in place
## v, h, hbar are storage arrays of length size(A, 2)
function lsmr!(x, A, b, v, h, hbar; 
    atol::Number = 1e-6, btol::Number = 1e-6, conlim::Number = 1e8, 
    maxiter::Integer = max(size(A,1), size(A,2)), λ::Number = 0)

    # Sanity-checking
    m = size(A, 1)
    n = size(A, 2)
    length(x) == n || error("x has length $(length(x)) but should have length $n")
    length(v) == n || error("v has length $(length(v)) but should have length $n")
    length(h) == n || error("h has length $(length(h)) but should have length $n")
    length(hbar) == n || error("hbar has length $(length(hbar)) but should have length $n")
    length(b) == m || error("b has length $(length(b)) but should have length $m")


    T = Adivtype(A, b)
    Tr = real(T)
    normrs = Tr[]
    normArs = Tr[]
    conlim > 0 ? ctol = convert(Tr, inv(conlim)) : ctol = zero(Tr)
    # form the first vectors u and v (satisfy  β*u = b,  α*v = A'u)
    u = A_mul_B!(-1, A, x, 1, b)
    β = norm(u)
    β > 0 && scale!(u, inv(β))
    Ac_mul_B!(1, A, u, 0, v)
    α = norm(v)
    α > 0 && scale!(v, inv(α))

    # Initialize variables for 1st iteration.
    ζbar = α * β
    αbar = α
    ρ = one(Tr)
    ρbar = one(Tr)
    cbar = one(Tr)
    sbar = zero(Tr)

    copy!(h, v)
    fill!(hbar, zero(Tr))

    # Initialize variables for estimation of ||r||.
    βdd = β
    βd = zero(Tr)
    ρdold = one(Tr)
    τtildeold = zero(Tr)
    θtilde  = zero(Tr)
    ζ = zero(Tr)
    d = zero(Tr)

    # Initialize variables for estimation of ||A|| and cond(A).
    normA, condA, normx = -one(Tr), -one(Tr), -one(Tr)
    normA2 = abs2(α)
    maxrbar = zero(Tr)
    minrbar = 1e100

    # Items for use in stopping rules.
    normb = β
    istop = 0 
    normr = β
    normAr = α * β
    tests = Tuple{Tr, Tr, Tr}[]
    iter = 0
    # Exit if b = 0 or A'b = 0.
    if normAr != 0 
        while iter < maxiter
            iter += 1
            A_mul_B!(1, A, v, -α, u)
            β = norm(u)
            if β > 0
                scale!(u, inv(β))
                Ac_mul_B!(1, A, u, -β, v)
                α = norm(v)
                α > 0 && scale!(v, inv(α))
            end
        
            # Construct rotation Qhat_{k,2k+1}.
            αhat = sqrt(abs2(αbar) + abs2(λ))
            chat = αbar / αhat
            shat = λ / αhat
        
            # Use a plane rotation (Q_i) to turn B_i to R_i.
            ρold = ρ
            ρ = sqrt(abs2(αhat) + abs2(β))
            c = αhat / ρ
            s = β / ρ
            θnew = s * α
            αbar = c * α
        
            # Use a plane rotation (Qbar_i) to turn R_i^T to R_i^bar.
            ρbarold = ρbar
            ζold = ζ
            θbar = sbar * ρ
            ρtemp = cbar * ρ
            ρbar = sqrt(abs2(cbar * ρ) + abs2(θnew))
            cbar = cbar * ρ / ρbar
            sbar = θnew / ρbar
            ζ = cbar * ζbar
            ζbar = - sbar * ζbar
        
            # Update h, h_hat, x.
            scale!(hbar, - θbar * ρ / (ρold * ρbarold))
            axpy!(1, h, hbar)
            axpy!(ζ / (ρ * ρbar), hbar, x)
            scale!(h, - θnew / ρ)
            axpy!(1, v, h)
        
            ##############################################################################
            ##
            ## Estimate of ||r||
            ##
            ##############################################################################
        
            # Apply rotation Qhat_{k,2k+1}.
            βacute = chat * βdd
            βcheck = - shat * βdd
        
            # Apply rotation Q_{k,k+1}.
            βhat = c * βacute
            βdd = - s * βacute
        
            # Apply rotation Qtilde_{k-1}.
            θtildeold = θtilde
            ρtildeold = sqrt(abs2(ρdold) + abs2(θbar))
            ctildeold = ρdold / ρtildeold
            stildeold = θbar / ρtildeold
            θtilde = stildeold * ρbar
            ρdold = ctildeold * ρbar
            βd = - stildeold * βd + ctildeold * βhat
        
            τtildeold = (ζold - θtildeold * τtildeold) / ρtildeold
            τd = (ζ - θtilde * τtildeold) / ρdold
            d  = d + abs2(βcheck)
            normr = sqrt(d + abs2(βd - τd) + abs2(βdd))
        
            # Estimate ||A||.
            normA2 = normA2 + abs2(β)
            normA  = sqrt(normA2)
            normA2 = normA2 + abs2(α)
        
            # Estimate cond(A).
            maxrbar = max(maxrbar, ρbarold)
            if iter > 1 
                minrbar = min(minrbar, ρbarold)
            end
            condA = max(maxrbar, ρtemp) / min(minrbar, ρtemp)
        
            ##############################################################################
            ##
            ## Test for convergence
            ##
            ##############################################################################
        
            # Compute norms for convergence testing.
            normAr  = abs(ζbar)
            normx = norm(x)
        


            # Now use these norms to estimate certain other quantities,
            # some of which will be small near a solution.
            test1 = normr / normb
            test2 = normAr / (normA * normr)
            test3 = inv(condA)
            push!(tests, (test1, test2, test3))

            t1 = test1 / (one(Tr) + normA * normx / normb)
            rtol = btol + atol * normA * normx / normb      
            # The following tests guard against extremely small values of
            # atol, btol or ctol.  (The user may have set any or all of
            # the parameters atol, btol, conlim  to 0.)
            # The effect is equivalent to the normAl tests using
            # atol = eps,  btol = eps,  conlim = 1/eps.
            if iter >= maxiter istop = 7; break end
            if 1 + test3 <= 1 istop = 6; break end
            if 1 + test2 <= 1 istop = 5; break end
            if 1 + t1 <= 1 istop = 4; break end
            # Allow for tolerances set by the user.
            if test3 <= ctol istop = 3; break end
            if test2 <= atol istop = 2; break end
            if test1 <= rtol  istop = 1; break end
        end
    end
    converged = istop ∉ (3, 6, 7)
    tol = (atol, btol, ctol)
    ch = ConvergenceHistory(converged, tol, 2 * iter, tests)
    return x, ch
end


