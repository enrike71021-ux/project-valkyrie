local ReplicatedStorage = game:GetService("ReplicatedStorage")
local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

local processServiceExists, ProcessService = pcall(function()
    return game:GetService("ProcessService")
end)

local project = ReplicatedStorage.Project

local status, result = runCLI(
    project,
    {
        verbose = true,
        ci = false,
    },
    { project }
):awaitStatus()

if status == "Rejected" then
    error(result)
end

if status == "Resolved" then
    local results = result.results

    if results.numFailedTestSuites == 0
        and results.numFailedTests == 0
        and results.numTotalTests > 0
    then
        if processServiceExists then
            ProcessService:ExitAsync(0)
        end

        return nil
    end
end

if processServiceExists then
    ProcessService:ExitAsync(1)
end

error("Jest tests failed or no tests were found")
