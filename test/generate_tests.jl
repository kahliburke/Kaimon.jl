using ReTest
using Kaimon

@testset "Generate Module" begin
    @testset "VSCODE_ALLOWED_COMMANDS" begin
        commands = Kaimon.Generate.VSCODE_ALLOWED_COMMANDS

        @testset "No duplicates" begin
            unique_commands = unique(commands)
            @test length(commands) == length(unique_commands)

            if length(commands) != length(unique_commands)
                # Find and report duplicates for debugging
                seen = Set{String}()
                duplicates = String[]
                for cmd in commands
                    if cmd in seen
                        push!(duplicates, cmd)
                    else
                        push!(seen, cmd)
                    end
                end
                @warn "Found duplicate commands" duplicates
            end
        end

        @testset "All commands are strings" begin
            @test all(cmd -> isa(cmd, String), commands)
        end

        @testset "No empty strings" begin
            @test all(cmd -> !isempty(cmd), commands)
        end

        @testset "Commands follow VS Code naming convention" begin
            # All commands should contain at least one dot
            @test all(cmd -> contains(cmd, "."), commands)
        end

        @testset "List is not empty" begin
            @test !isempty(commands)
            @test length(commands) > 0
        end

        @testset "Commands are sorted (for maintainability)" begin
            # This is a recommendation, not a strict requirement
            # Sorting makes it easier to spot duplicates and maintain the list
            sorted_commands = sort(commands)
            if commands != sorted_commands
                @info "Commands list is not sorted. Consider sorting for easier maintenance."
            end
        end
    end

    @testset "Function exports" begin
        # Verify that expected functions are exported
        exported_names = names(Kaimon.Generate)

        @test :create_startup_script in exported_names
        @test :create_repl_script in exported_names
        @test :create_vscode_config in exported_names
        @test :create_env_file in exported_names
        @test :create_claude_env_settings in exported_names
        @test :VSCODE_ALLOWED_COMMANDS in exported_names
    end
end
