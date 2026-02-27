using ReTest

# Include the tests module (registers all testsets)
include("KaimonTests.jl")
using .KaimonTests

# Run all tests with ReTest
if isempty(ARGS)
    retest()
else
    retest(ARGS[1])
end