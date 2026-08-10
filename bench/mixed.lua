-- Exercises the fail-function Failure under load (ADR 0007).
--
-- Not a benchmark: what is measured is not speed but whether a fail
-- function's message ever gets crossed between requests running at the
-- same time. If the Failure were bound to the thread rather than the
-- fiber, the number on the last line would be greater than zero.
--
--   wrk -t4 -c64 -d10s -s bench/mixed.lua http://127.0.0.1:8787
--
-- The routes follow the example in src/main.zig: /users/7 exists,
-- /users/9999999 does not, and the missing one is answered by a fail
-- function whose message names the id.

local n = 0

request = function()
    n = n + 1
    if n % 2 == 0 then
        return wrk.format("GET", "/users/9999999")
    else
        return wrk.format("GET", "/users/7")
    end
end

local wrong = 0

response = function(status, headers, body)
    if status == 404 then
        if not string.find(body, "no user 9999999", 1, true) then
            wrong = wrong + 1
        end
    elseif status == 200 then
        if not string.find(body, '"id":7', 1, true) then
            wrong = wrong + 1
        end
    else
        wrong = wrong + 1
    end
end

done = function(summary, latency, requests)
    io.write(string.format(
        "\nwrong or crossed responses: %d out of %d\n", wrong, summary.requests))
    if wrong > 0 then
        io.write("FAIL-FUNCTION MESSAGES LEAKED BETWEEN REQUESTS — see ADR 0007\n")
    end
end
