-- A different client address per request, so an allowance sees 65,536 of
-- them instead of one. The same script drives the control, so the cost of
-- building the header is on both sides of the comparison.
local n = 0
request = function()
   n = n + 1
   local a = (n % 256)
   local b = (math.floor(n / 256) % 256)
   return wrk.format("GET", "/users/42", { ["X-Forwarded-For"] = "10.0." .. b .. "." .. a })
end
