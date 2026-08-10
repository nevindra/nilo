# zio is the Engine, placed behind the Bulkhead

The most tempting road to performance is writing your own event loop on io_uring — that is what zzz does through tardy. We are not taking it. zfast stands on [zio](https://github.com/lalinsky/zio), a third-party `std.Io` implementation that already provides io_uring/epoll on Linux, kqueue on macOS, and IOCP on Windows, on top of fibers.

The reason: the Engine is the highest-risk, lowest-differentiation part there is. Nobody picks a framework because its event loop is nice — they pick one because writing handlers feels good. Writing your own Engine means months without a single line of framework code, on platforms you do not own (io_uring is Linux-only, and development happens on macOS).

## Considered Options

- **Zig's built-in `std.Io`, directly.** Rejected after reading `Io.VTable`: its networking side (`netAccept`, `netSend`, `netReceive`, `netRead`, `netWrite`) has no registered buffers, no multishot, and no vectored writes. Without vectored writes, every response (head + body) means one extra copy or one extra syscall — on every request, forever. The fast `Io.Evented` implementation is also still a proof of concept.
- **Writing an io_uring runtime from scratch.** The highest ceiling, but the largest scope, and untestable on the development machine.

## Consequences

- Everything zfast needs from the Engine goes through the Bulkhead: accept a connection, read, write, close. Not one part of zfast outside the Bulkhead names zio.
- The Bulkhead has to be shaped in the earliest stage, not patched on later. It is the only insurance against two risks: zio going unmaintained, and zio's performance ceiling turning out to be too low.
- Swapping the Engine later must not change a single line of user code.
