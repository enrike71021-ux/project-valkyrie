local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local expect = JestGlobals.expect
local it = JestGlobals.it

local Hello = require(script.Parent.Hello)

it("exports a function", function()
	expect(type(Hello)).toBe("function")
end)

it("runs without throwing an error", function()
	expect(Hello).never.toThrow()
end)
