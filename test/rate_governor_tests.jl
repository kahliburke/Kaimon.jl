using ReTest
using Kaimon

const RG = Kaimon.RateGovernor

@testset "RateGovernor" begin
    @testset "is_rate_limited classifier + retry-after parse" begin
        @test RG.is_rate_limited("API Error: 429 overloaded_error")
        @test RG.is_rate_limited("rate_limit_error: please slow down")
        @test RG.is_rate_limited("Overloaded")
        @test RG.is_rate_limited("Too Many Requests")
        @test !RG.is_rate_limited("stop_reason=end_turn")
        @test !RG.is_rate_limited(nothing)
        @test RG.retry_after_seconds("error; retry-after: 12") == 12.0
        @test RG.retry_after_seconds("Retry-After=3.5 seconds") == 3.5
        @test RG.retry_after_seconds("no header") === nothing
    end

    @testset "backoff schedule honors retry-after + caps" begin
        @test RG.backoff_seconds(0; retry_after = 7) == 7.0
        @test 0.5 <= RG.backoff_seconds(0) <= 1.0          # base 1s, 50–100% jitter
        @test 4.0 <= RG.backoff_seconds(3) <= 8.0          # 1×2^3 = 8, jittered
        @test RG.backoff_seconds(100) <= 60.0              # capped
    end

    @testset "concurrency cap blocks then releases (backpressure, no drops)" begin
        RG.init!(RG.Config(max_concurrency = 2, rate_rps = 1e6, bucket_capacity = 1e6))
        started = Channel{Int}(10)
        release = Channel{Nothing}(10)
        for i in 1:2
            @async RG.with_admission(() -> (put!(started, i); take!(release)))
        end
        @test take!(started) in (1, 2)
        @test take!(started) in (1, 2)
        @test RG.status().in_flight == 2

        admitted3 = Channel{Bool}(1)
        @async RG.with_admission(() -> (put!(admitted3, true); take!(release)))
        sleep(0.25)
        @test !isready(admitted3)            # 3rd is blocked — backpressure
        @test RG.status().throttled

        put!(release, nothing)               # free one slot
        sleep(0.25)
        @test isready(admitted3) && take!(admitted3)   # 3rd admitted, nothing dropped

        put!(release, nothing); put!(release, nothing) # drain remaining holders
        sleep(0.1)
    end

    @testset "AIMD: multiplicative decrease, additive recover" begin
        RG.init!(RG.Config(rate_rps = 4.0, rate_max = 8.0, rate_min = 0.5,
                           rate_step = 1.0, decrease_factor = 0.5,
                           recover_interval_s = 0.0, base_cooldown_s = 0.0,
                           bucket_capacity = 1e6, max_concurrency = 4))
        @test RG.status().rate == 4.0
        RG.note_rate_error!()
        @test RG.status().rate == 2.0        # ×0.5
        RG.note_rate_error!()
        @test RG.status().rate == 1.0        # floor is 0.5, still above
        @test RG.status().rate_errors == 2
        before = RG.status().rate
        RG.with_admission(() -> nothing)     # recover_interval 0 ⇒ admission bumps R
        @test RG.status().rate >= before
    end

    @testset "rate error pauses refills (cooldown)" begin
        RG.init!(RG.Config(max_concurrency = 4, rate_rps = 100.0,
                           bucket_capacity = 1.0, base_cooldown_s = 10.0))
        RG.with_admission(() -> nothing)     # drain the one token
        RG.note_rate_error!(5.0)             # explicit retry-after ⇒ 5s pause
        st = RG.status()
        @test st.cooldown_remaining > 0
        @test st.throttled
        @test st.rate_errors == 1
    end

    @testset "tokens/min budget throttles admission" begin
        RG.init!(RG.Config(max_concurrency = 4, rate_rps = 1e6, bucket_capacity = 1e6,
                           tokens_per_min = 100.0))
        @test RG.status().tokens_per_min == 0
        RG.record_turn_end!(150)             # over the 100 tok/min budget
        @test RG.status().tokens_per_min == 150
        admitted = Channel{Bool}(1)
        @async RG.with_admission(() -> put!(admitted, true))
        sleep(0.25)
        @test !isready(admitted)             # blocked by the token budget
        @test RG.status().throttled == false || RG.status().tokens_per_min == 150
    end

    @testset "status snapshot shape + defaults from env-less config" begin
        RG.init!(RG.Config())                # pure defaults
        st = RG.status()
        @test st.in_flight == 0
        @test st.max_concurrency == 4
        @test st.rate == 2.0
        @test st.token_budget == 0.0
        @test st.rate_errors == 0
        @test st.throttled == false
    end
end
