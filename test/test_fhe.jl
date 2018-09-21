push!(LOAD_PATH, "../src")

using BenchmarkTools

using Random
using SGFHE:
    Params, encrypt_private, encrypt_public, decrypt, PrivateKey, PublicKey,
    flatten_deterministic, flatten, RRElem, RRElemMontgomery, RadixNumber, polynomial_large,
    decompose, external_product, extract_lwes, decrypt_lwe, BootstrapKey, bootstrap_lwe, pack_lwes,
    large_tp, large_rr_tp


function test_private()
    params = Params(512)
    message = rand(Bool, params.n)
    key = PrivateKey(params)
    ct = encrypt_private(key, message)
    decrypted = decrypt(key, ct)
    @assert message == decrypted
end


function test_public()
    params = Params(512)
    message = rand(Bool, params.n)
    key = PrivateKey(params)
    pkey = PublicKey(params, key)
    ct = encrypt_public(pkey, message)
    decrypted = decrypt(key, ct)
    @assert message == decrypted
end


function test_decrypt_lwe()
    params = Params(512)
    message = rand(Bool, params.n)
    key = PrivateKey(params)
    ct = encrypt_private(key, message)

    lwes = extract_lwes(ct)
    decrypted = [decrypt_lwe(key, lwe) for lwe in lwes]

    @assert message == decrypted
end


function test_flatten_deterministic()
    for l in (3, 4)
        for B in (3, 4)
            for q in (B^l, B^l - 3)
                if isodd(B)
                    s = (B - 1) ÷ 2
                else
                    s = B ÷ 2 - 1
                end

                modulus = UInt16(q)
                tp = RRElem{UInt16, modulus}

                lim_lo = convert(tp, q - s)
                lim_hi = convert(tp, B - s - 1)

                B_rr = convert(tp, B)
                for a in 0:q-1

                    a_rr = convert(tp, a)

                    decomp_rr = flatten_deterministic(a_rr, B_rr, l)
                    @assert eltype(decomp_rr) == tp

                    restore_rr = sum(decomp_rr .* B_rr.^(0:l-1))

                    @assert all(d >= lim_hi || d <= lim_lo for d in decomp_rr)
                    @assert restore_rr == a_rr
                end
            end
        end
    end
end


function test_flatten_montgomery()

    tp = UInt8
    len = 4
    rtp = RadixNumber{len, tp}

    modulus_i = 2^30-1
    modulus_r = convert(rtp, modulus_i)

    rrtp = RRElem{rtp, modulus_r}
    mtp = RRElemMontgomery{rtp, modulus_r}

    B_i = 2^20-1
    B_rr = rrtp(B_i)
    B_m = mtp(B_i)

    l = 2
    s = (B_i - 1) ÷ 2

    for i in 1:1000

        a_i = rand(UInt32) % modulus_i

        a_rr = rrtp(a_i)
        a_m = mtp(a_i)

        decomp_m = flatten_deterministic(a_m, B_m, l)
        @assert eltype(decomp_m) == mtp

        restore_m = sum(decomp_m .* B_m.^(0:l-1))
        @assert restore_m == a_m

        decomp = convert.(BigInt, decomp_m)
        restore = mod(sum(decomp .* B_i.^(0:l-1)), modulus_i)

        @assert restore == a_i

        for d in decomp
            @assert d >= B_i - s - 1 || d <= s
        end
    end
end


function test_flatten_performance()

    # Simple type performance
    modulus = UInt64(2^55 - 1)
    tp = RRElem{UInt64, modulus}
    l = 2
    B = convert(tp, 2^31 - 1)
    a = convert(tp, 2^50 - 1)

    display(@benchmark flatten_deterministic($a, $B, $l))
    println()


    # Simple type performance
    modulus = UInt128(2)^80 - 1
    tp = RRElem{UInt128, modulus}
    l = 2
    B = convert(tp, UInt128(2)^51 - 1)
    a = convert(tp, UInt128(2)^79 - 1)

    display(@benchmark flatten_deterministic($a, $B, $l))
    println()


    # Radix type performance
    modulus = BigInt(2)^80 - 1

    rtp = RadixNumber{2, UInt64}
    modulus_r = convert(rtp, modulus)
    mtp = RRElemMontgomery{rtp, modulus_r}
    l = 2
    B_m = convert(mtp, 2^51 - 1)
    a_m = convert(mtp, 2^79 - 1)

    display(@benchmark flatten_deterministic($a_m, $B_m, $l))
    println()

end


function test_flatten()
    for l in (3, 4)
        for B in (3, 4)
            for q in (B^l, B^l - 3)
                s = 2 * B

                modulus = UInt16(q)
                tp = RRElem{UInt16, modulus}

                lim_lo = convert(tp, q - s)
                lim_hi = convert(tp, s)

                B_rr = convert(tp, B)

                for a in 0:q-1

                    a_rr = convert(tp, a)

                    decomp_rr = flatten(a_rr, B_rr, l)
                    @assert eltype(decomp_rr) == tp

                    restore_rr = sum(decomp_rr .* B_rr.^(0:l-1))

                    @assert all(d >= lim_hi || d <= lim_lo for d in decomp_rr)
                    @assert restore_rr == a_rr
                end
            end
        end
    end
end


function test_decompose()
    p = Params(64)

    B = p.B
    B_bi = BigInt(B)
    l = 2

    q = B^l - one(typeof(B))
    q_bi = BigInt(q)
    a = polynomial_large(rand(Int128, p.n), q)
    b = polynomial_large(rand(Int128, p.n), q)

    q_r = large_tp(q)
    B_m = large_rr_tp{large_tp, q_r}(B)

    ll = Val(l)

    u = decompose(a, b, B_m, ll)

    for x in u
        coeffs = convert.(BigInt, x.coeffs)
        @assert all(c <= 2 * B_bi || c >= q_bi - 2 * B_bi for c in coeffs)
    end

    a_restored = sum(u[1:l] .* B_m.^(0:l-1))
    b_restored = sum(u[l+1:end] .* B_m.^(0:l-1))

    @assert a == a_restored
    @assert b == b_restored
end


function test_external_product()
    p = Params(64)

    B = p.B
    l = 2

    q = B^l - one(typeof(B))
    a = polynomial_large(rand(Int128, p.n), q)
    b = polynomial_large(rand(Int128, p.n), q)

    cc(x) = RRElemMontgomery{RadixNumber{2, UInt64}, q}(x)

    B_m = cc(B)
    pz = polynomial_large(zeros(Int, p.n), q)
    G = ([pz pz; pz pz; pz pz; pz pz] .+ cc.([1 0; B 0; 0 1; 0 B]))
    a_restored, b_restored = external_product(a, b, G, B_m, l)

    @assert a == a_restored
    @assert b == b_restored
end


function test_bootstrap()
    params = Params(64)
    key = PrivateKey(params)
    bkey = BootstrapKey(params, key)

    message = rand(Bool, params.n)
    ct = encrypt_private(key, message)
    lwes = extract_lwes(ct)

    for i in 1:32
        lwe1 = lwes[i*2-1]
        lwe2 = lwes[i*2]

        bit1 = message[i*2-1]
        bit2 = message[i*2]

        println("Plaintext bits $bit1 $bit2")

        cr1, cr2, cr3 = bootstrap_lwe(bkey, lwe1, lwe2)

        r1, r2, r3 = [decrypt_lwe(key, lwe) for lwe in (cr1, cr2, cr3)]

        println("Result: AND=$r1, OR=$r2, XOR=$r3")
        println("Reference: AND=$(bit1 & bit2), OR=$(bit1 | bit2), XOR=$(xor(bit1, bit2))")

        @assert r1 == bit1 & bit2
        @assert r2 == bit1 | bit2
        @assert r3 == xor(bit1, bit2)
    end
end


function test_rlwe_to_lwe()
    params = Params(64)

    message = rand(Bool, params.n)
    key = PrivateKey(params)
    bkey = BootstrapKey(params, key)
    ct = encrypt_private(key, message)

    lwes = extract_lwes(ct)
    rlwe = pack_lwes(bkey, lwes)

    @assert length(rlwe.a) == params.m
    @assert length(rlwe.b) == params.m

    # Decrypt by converting back to lwes
    lwes2 = extract_lwes(Ciphertext(params, rlwe))
    for i in 1:params.n
        @assert decrypt_lwe(lwes2[i]) == message[i]
    end

    # Decrypt directly
    decrypted = decrypt(key, Ciphertext(params, rlwe))
    @assert message == decrypted
end


test_private()
test_public()
test_flatten_deterministic()
test_flatten_montgomery()
test_flatten_performance()
test_flatten()
test_decompose()
test_external_product()
test_decrypt_lwe()
test_bootstrap()
#test_rlwe_to_lwe()
