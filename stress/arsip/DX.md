# What fought back

The findings log. One entry per thing that cost time, in the milestone that
found it, with what it would take to fix. **An entry earns its place by being
something a second user would hit too** — a mistake only this app made is not a
finding.

Severity is about the user, not the code:

- **blocker** — there is no way to do it; you stop.
- **friction** — there is a way, and you had to find it somewhere other than
  where you looked first.
- **paper cut** — you found it, it just cost a minute you did not expect.
- **note** — nothing is wrong; it is worth writing down before it becomes one.

---

## M0 — Scaffold

### `zig init` gives you a `build.zig` you delete rather than edit — paper cut

`docs/guide/getting-started.md` says `zig init` first, correctly: `zig fetch
--save` refuses without a `build.zig`. But the `build.zig` it writes is a
library-and-executable template around `src/root.zig`, and the guide's snippet
is a fragment that assumes a different file. You replace the file rather than
paste into it, and you delete `src/root.zig`.

That is Zig's template rather than nilo's, and nothing can be done about the
template. What could be done is one sentence in the guide: *replace the
generated `build.zig` with this, and delete `src/root.zig`.*

### A dependent has to guess `.optimize` matters — note

The guide does say to pass `.optimize` through to the dependency, and says
plainly that not doing so is "legal and slow, and nothing warns about it". It
is in the right place and it is easy to skim past, which is what makes it worth
recording: the failure mode is a server that is merely slow, and that is the
same failure mode `std_options_debug_io` has — which nilo *does* warn about at
`listen()`. Two symptoms, one warning.

Whether the build can see it at all is the open question: the check would have
to compare the dependent's optimize mode against the one nilo was built with,
which is knowable at comptime. Worth asking before M7.

### Four of the eight modules have no guide page — note, to be tested at M2–M5

`docs/guide/README.md` is explicit about it rather than silent: `nilo_s3`,
`nilo_fetch`, `nilo_config` and `nilo_id` are pointed at sections of
`docs/reference.md`, and `nilo_pw` at the Sessions page. So this is a stated
position, not an oversight, and the interesting question is whether it holds:
**can you adopt a module from a reference section alone?**

M2 answers it for `nilo_config` and `nilo_id`, M4 for `nilo_s3`, M5 for
`nilo_fetch`. Recording it now so the answer is measured rather than
remembered — if the reference turns out to be enough, that is a finding worth
having too, and it costs the project four pages it was going to write.
