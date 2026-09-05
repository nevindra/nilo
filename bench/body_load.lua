-- POSTs a body of a fixed size, for what reading one costs.
--
-- The size is the question rather than a detail: `readSizedBody` takes the
-- arena in steps of 16 KiB, so a body under that is one allocation and a body
-- over it is several, and a measurement of only one of those says nothing
-- about the other.
--
--   wrk -t4 -c64 -d10s -s bench/body_load.lua http://127.0.0.1:8792/echo
--   BODY_BYTES=65536 wrk -t4 -c64 -d10s -s bench/body_load.lua http://127.0.0.1:8792/echo

local size = tonumber(os.getenv("BODY_BYTES")) or 1024
local body = string.rep("x", size)

wrk.method = "POST"
wrk.body = body
wrk.headers["Content-Type"] = "application/octet-stream"
