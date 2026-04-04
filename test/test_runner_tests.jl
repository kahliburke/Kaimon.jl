using ReTest
using Kaimon

@testset "Test Runner" begin
    @testset "pattern filters ReTest suites" begin
        project_path = pkgdir(Kaimon)
        run = Kaimon.spawn_test_run(project_path; pattern = "Version Info Tests", verbose = 1)

        deadline = time() + 90.0
        while (!run.reader_done || run.status == Kaimon.RUN_RUNNING) && time() < deadline
            sleep(0.25)
        end

        @test run.status == Kaimon.RUN_PASSED
        @test run.total_pass > 0
        @test run.total_fail == 0
        @test any(r -> r.name == "Version Info Tests", run.results)
    end
end
