# s3/refusals

Ten programs written wrong on purpose. Each must fail to compile with a message
`nilo_s3` wrote; `zig build refusals-s3` checks the wording, and
`zig build test-s3` depends on it.

What is checked here is what [ADR 0068](../../docs/adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)
said comptime was *for* — the things a bucket's own type can be wrong about,
plus the one that is a leak rather than a mistake:

| file | what it refuses |
|---|---|
| `bucket_name_too_short.zig` | a name S3 itself will not accept |
| `bucket_name_with_an_underscore.zig` | a name virtual-host addressing cannot carry |
| `bucket_name_with_a_capital.zig` | the same, spelled the way it usually happens |
| `bucket_name_like_an_address.zig` | a name shaped like an IP address |
| `a_secret_in_a_bucket_option.zig` | a credential compiled into the binary |
| `presign_over_seven_days.zig` | a life SigV4 refuses |
| `max_bytes_of_zero.zig` | a bucket that could never answer a get |
| `an_option_that_does_not_exist.zig` | a typo, named alongside the real options |
| `put_without_a_content_type.zig` | storing bytes S3 is told nothing about |
| `a_streamed_put_with_no_length.zig` | a body whose length S3 would answer 411 to |

Note what is **not** here: the endpoint, the region and the credentials. Those
are properties of the deployment rather than of the bucket, they come from a
`Config` at run time, and a compile error about one of them would be nilo
deciding that development and production are two binaries.

**Adding a comptime check means adding both a file here and a row in
`s3_refusals` in `build.zig`.** There are five such tables now, one per module,
and adding a row to one while running another is a check that silently never
ran.
