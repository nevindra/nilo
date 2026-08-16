# DX beats performance, with a 10% threshold

nilo is sold as a fast HTTP framework, so anyone reading the code later will reasonably assume every decision was won by a benchmark number. What was actually decided is the opposite: **the comfort of writing code wins, unless it costs more than 10%.** Performance numbers are what get attention; comfort is what keeps people.

The reason is in the audience. People coming from Go or Node live at 30–80k requests per second today; the existing Zig frameworks hand them 140k. A 40% difference in the HTTP layer is not something they will feel — it disappears into the first database query. What they will feel is whether they can get running in ten minutes, whether the error messages are readable, and whether they have to think about allocators.

## Consequences

- Most conflicts turn out to be far below the threshold, because the parts that make a server fast (event loop strategy, buffer pools, thread division) are entirely invisible to users. That is not a conflict — that is just work.
- This rule is not active until there is a Linux machine to measure on. Until then every conflict goes to DX automatically, because there is no evidence that could beat it. That is acceptable because the decisions being made right now are all about API shape, and API shape does not need a benchmark.
- Until there are numbers from a real machine, the README must carry no performance claims. A claim with no numbers behind it is the fastest way to get this project torn apart in public.
