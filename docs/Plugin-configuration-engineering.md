# Configuring: engineering properties

## About this page

This page documents **engineering properties** of the JovianDSS Proxmox plugin:
tuning knobs that change how the plugin behaves under failure rather than what
it stores or where.

They are set exactly like every other property, in the same
`/etc/pve/storage.cfg` record described in
[Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration),
and they are all optional. **A storage that sets none of them behaves exactly as
before they existed** — each property falls back to a built-in default that
matches the value the plugin previously used internally.

Change them only when there is a reason to. The defaults suit a healthy network
and a responsive appliance; the properties exist for deployments where that is
not the case — a link that flaps, an appliance under heavy load, or a cluster
where an operation must fail fast instead of retrying for minutes.

Every property on this page applies to both the `joviandss` (iSCSI) and the
`joviandss-nfs` storage types, because both perform the same REST calls to the
appliance.

## How a REST request is retried

The plugin never talks to the appliance directly: it calls the `jdssc` CLI,
which performs the REST request. `jdssc` bounds and retries that request on
three independent levels, and the five properties below control them.

**Level 0 — the single attempt.** Talking to one control address has two phases,
bounded separately because they fail in completely different ways.
[jdssc_rest_connect_timeout](#jdssc_rest_connect_timeout) bounds *establishing*
the TCP connection — this is the one that decides how quickly a dead or
unreachable controller is abandoned.
[jdssc_rest_read_timeout](#jdssc_rest_read_timeout) then applies to a response
that is already arriving.

**Level 1 — the send.** If the appliance answers with a body that is not valid
JSON, that single request is re-sent to the same address, up to
[jdssc_rest_send_retry_on_decode_error_attempts](#jdssc_rest_send_retry_on_decode_error_attempts)
times in total.

**Level 2 — the cycle.** If a request fails against one control address —
connection refused, timeout, an unusable answer — `jdssc` moves to the next
address from [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses)
and tries there. Trying every address once is one **cycle**. After a full cycle
fails, `jdssc` sleeps for
[jdssc_rest_request_send_cycle_delay](#jdssc_rest_request_send_cycle_delay)
seconds and starts another cycle, up to
[jdssc_rest_request_send_cycle_attempts](#jdssc_rest_request_send_cycle_attempts)
cycles. When the last cycle fails, the request fails and the plugin reports the
error to Proxmox VE.

With the defaults and a single unreachable control address, one cycle costs the
5 s connect timeout plus the 3 s sleep, so the request is given up on after
roughly `17 × (5 + 3) = 136` seconds. What matters more than that total is what
happens with **two** addresses and only the first one dead: the first is
abandoned after 5 seconds and the second answers immediately, so the operation
succeeds in seconds rather than failing.

**Nothing on this page bounds the total run time.** That is
[jdssc_timeout](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration),
which kills the `jdssc` process outright — so lengthening the retry properties
past that timeout will not extend how long an operation actually runs.

## Plugin properties

### jdssc_rest_connect_timeout

**Default**: `5`

**Type**: *int*

**Minimum**: `1`

**Required**: `False`

Specifies how many seconds `jdssc` waits to establish a TCP connection to one
control address before giving up on it and moving to the next one.

This is the property that governs **how fast a failed controller is detected**.
A controller that is powered off or whose cable has been pulled does not refuse
connections — it swallows them silently, and without this bound the attempt
lasts until the operating system gives up on its own, which on Linux takes
around two minutes per address.

Lower it further on a fast, reliable local network where a healthy appliance
always answers in milliseconds. Raise it if control traffic crosses a slow or
congested link and legitimate connections are being abandoned prematurely.

**Note**: the operating system imposes its own ceiling of roughly 127 seconds on
an unanswered connection attempt, so a value above that has no effect.


### jdssc_rest_read_timeout

**Default**: `570`

**Type**: *int*

**Minimum**: `1`

**Required**: `False`

Specifies how many seconds `jdssc` waits **between bytes** of a REST response
that is already arriving.

**This is an inactivity timeout, not a deadline for the whole response.** The
clock restarts every time more data arrives, so a large but steadily delivered
response — a long volume listing, for example — is never interrupted by it, no
matter how long it takes in total. It fires only when the appliance stops
sending mid-response and stays silent.

Because of that, this property is rarely the one to reach for. If the goal is
"an operation must not take longer than N seconds", the property that does that
is [jdssc_timeout](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration),
which bounds the whole `jdssc` run. Lower this one only to make a stalled
transfer fail sooner and move on to the next control address.


### jdssc_rest_request_send_cycle_attempts

**Default**: `17`

**Type**: *int*

**Minimum**: `1`

**Required**: `False`

Specifies how many times `jdssc` cycles through the control addresses before
giving up on a single REST request.

One cycle tries every address in
[control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses)
once; the value counts **attempts, not additional retries**, so `1` means a
single cycle with no repetition.

Lower this value to make storage operations fail quickly when the appliance is
unreachable — useful in a cluster where a hung operation is worse than a failed
one. Raise it for an appliance that is regularly busy enough to reject requests
that would succeed shortly after.


### jdssc_rest_request_send_cycle_delay

**Default**: `3`

**Type**: *int*

**Minimum**: `0`

**Required**: `False`

Specifies the number of seconds `jdssc` sleeps between two cycles over the
control addresses.

The delay applies **between** cycles, not between individual addresses within a
cycle: addresses are tried back to back, and the pause happens only after all of
them have failed.

`0` is a valid value and means retry immediately, without sleeping. Use it when
the appliance is reachable but intermittently refuses requests, and waiting adds
nothing. Increase it when retrying instantly would only add load to an appliance
that needs a moment to recover.


### jdssc_rest_send_retry_on_decode_error_attempts

**Default**: `5`

**Type**: *int*

**Minimum**: `1`

**Required**: `False`

Specifies how many times `jdssc` re-sends a single REST request when the
appliance returns a response body that cannot be decoded as JSON.

This is a narrower failure than an unreachable address: the connection
succeeded and the appliance replied, but the reply was malformed — something
JovianDSS can do transiently while under heavy load. The retry happens against
the **same** control address, before the request is treated as failed and the
[cycle](#jdssc_rest_request_send_cycle_attempts) moves to the next address.

The value counts **attempts, not additional retries**, so `1` disables the
behaviour: a malformed answer is treated as a failure immediately.


## Examples

### Failing fast

A cluster where a storage operation must return an error quickly rather than
block, for example because a higher layer retries on its own:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        content rootdir,images
        control_addresses 192.168.28.100,192.168.28.101
        data_addresses 192.168.29.100
        user_name admin
        ssl_cert_verify 0
        jdssc_rest_connect_timeout 2
        jdssc_rest_request_send_cycle_attempts 3
        jdssc_rest_request_send_cycle_delay 0
        jdssc_rest_send_retry_on_decode_error_attempts 1
```

Both control addresses are tried, three times over, with no pause between
cycles and no tolerance for a malformed answer. An address that does not answer
costs 2 seconds rather than 5, so the whole sequence gives up in about
12 seconds even when nothing is reachable.

### Waiting out a busy appliance

An appliance that is heavily loaded and answers slowly or malformed under peak
usage, where an operation should keep trying rather than fail:

```
joviandss-nfs: jdss-nfs-Pool-0
        server 192.168.28.100
        export /Pools/Pool-0/data
        path /mnt/pve/jdss-nfs-Pool-0
        content images
        control_addresses 192.168.28.100
        data_addresses 192.168.29.100
        user_name admin
        ssl_cert_verify 0
        jdssc_rest_connect_timeout 15
        jdssc_rest_request_send_cycle_attempts 30
        jdssc_rest_request_send_cycle_delay 10
        jdssc_rest_send_retry_on_decode_error_attempts 8
```

**Note**: raising these values does not extend an operation beyond
`jdssc_timeout`, which bounds the `jdssc` process independently. Raise that
property as well if the operation needs longer than its default allows.

### Leaving the defaults

A record that names none of these properties uses the built-in defaults — a
`5` second connect timeout, a `570` second read timeout, `17` cycles, a `3`
second pause between them and `5` attempts at an undecodable answer:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        content rootdir,images
        control_addresses 192.168.28.100
        data_addresses 192.168.29.100
        user_name admin
        ssl_cert_verify 0
```
