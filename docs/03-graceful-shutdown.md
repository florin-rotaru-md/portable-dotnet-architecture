# Graceful Shutdown and Request Draining

## Problem

A new deployment should not terminate active requests mid-flight.

## Desired behavior

When an application instance is about to be removed from service:

1. stop accepting new traffic
2. continue processing already accepted requests
3. exit only after requests complete or the shutdown timeout is reached

## Recommended behavior in the application

During shutdown:
- set internal draining flag to `true`
- readiness endpoint returns unhealthy immediately
- liveness endpoint stays healthy until the host is actually stopping
- background services react to cancellation correctly

## Recommended behavior in the deployment logic

1. bring up new slot
2. verify readiness
3. switch Nginx to new slot
4. wait for drain window (for example 20 to 30 seconds)
5. send graceful stop to old slot
6. allow Docker `stop_grace_period` to finish active work

## Runtime settings

Recommended baseline:
- `HostOptions.ShutdownTimeout = 60 seconds`
- Docker `stop_signal = SIGTERM`
- Docker `stop_grace_period = 60 seconds`

Tune these values according to the longest acceptable request duration.

## Validation scenarios

Test the following before production:
- long-running HTTP request during deployment
- background job cancellation and completion behavior
- readiness dropping immediately when shutdown starts
- old slot receiving no new requests after Nginx switch
