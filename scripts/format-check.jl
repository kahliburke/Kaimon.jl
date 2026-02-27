#!/usr/bin/env julia

# Pre-commit hook script that only modifies files if formatting changes are needed
# This prevents unnecessary file touches that cause pre-commit to think files changed

using JuliaFormatter

function main()
    exit_code = 0

    for file in ARGS
        if !isfile(file)
            continue
        end

        # Read original content
        original_content = read(file, String)

        # Format the file (skip if parser fails)
        formatted = try
            JuliaFormatter.format_text(original_content)
        catch e
            @warn "JuliaFormatter failed to parse $file, skipping" exception = e
            continue
        end

        # Only write if content actually changed
        if formatted != original_content
            write(file, formatted)
            println("Formatted: $file")
            exit_code = 1
        end
    end

    return exit_code
end

exit(main())
