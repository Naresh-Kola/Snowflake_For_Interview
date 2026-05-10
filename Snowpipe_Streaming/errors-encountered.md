# Errors Encountered During Kafka Docker Compose Setup

## Error 1: Obsolete `version` Attribute Warning

**Message:**
```
level=warning msg="docker-compose.yml: the attribute `version` is obsolete,
it will be ignored, please remove it to avoid potential confusion"
```

**Cause:**
The `docker-compose.yml` file contains `version: '3.8'` at the top. In modern Docker Compose (V2+), the `version` key is deprecated and ignored. Docker Compose now automatically determines the schema version.

**Impact:** Warning only -- does not prevent containers from starting.

**Fix:** Remove the `version: '3.8'` line from `docker-compose.yml`.

---

## Error 2: Image Pull Failure (500 Internal Server Error)

**Message:**
```
unable to get image 'apache/kafka:3.7.0': request returned 500 Internal Server Error
for API route and version http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/v1.54/images/apache/kafka:3.7.0/json,
check if the server supports the requested API version
```

**Cause:**
Docker Desktop's backend (Linux VM engine) was not fully initialized when the `docker compose up -d` command was executed. The Docker API returned a 500 error because the image service was temporarily unavailable.

**Impact:** Fatal -- the compose command failed entirely; no containers were created.

**Fix:** Wait for Docker Desktop to fully start, then re-run the command. Running `docker pull apache/kafka:3.7.0` manually confirmed the image was available and pulled successfully on retry.

---

## Error 3: Container Name Conflict (`kafka-ui`)

**Message:**
```
Error response from daemon: Conflict. The container name "/kafka-ui" is already in use
by container "46544933dd03...". You have to remove (or rename) that container to be able
to reuse that name.
```

**Cause:**
A container named `kafka-ui` from a previous run still existed (in a stopped state). Docker does not allow two containers with the same name, even if one is stopped.

**Impact:** Only the `kafka-ui` service failed to start. The two Kafka brokers (`broker-1`, `broker-2`) started successfully.

**Fix:** Removed the stale container using `docker rm -f kafka-ui`, then re-ran the compose command.

---

## Error 4: Port 8080 Already in Use

**Message:**
```
Error response from daemon: ports are not available: exposing port TCP 0.0.0.0:8080 -> 127.0.0.1:0:
listen tcp 0.0.0.0:8080: bind: Only one usage of each socket address
(protocol/network address/port) is normally permitted.
```

**Cause:**
Port 8080 on the host machine was already occupied by the **Oracle TNS Listener** process (`TNSLSNR`, PID 4080). Docker could not bind the `kafka-ui` container's port mapping `8080:8080` because the host port was unavailable.

**Impact:** The `kafka-ui` container failed to start. Kafka brokers were unaffected.

**Fix:** Changed the host port mapping in `docker-compose.yml` from `8080:8080` to `8081:8080`. The kafka-ui web interface is now accessible at `http://localhost:8081`.

---

## Summary

| # | Error | Severity | Resolution |
|---|-------|----------|------------|
| 1 | Obsolete `version` attribute | Warning | Remove `version: '3.8'` from compose file |
| 2 | 500 Internal Server Error on image pull | Fatal | Wait for Docker Desktop to fully initialize, retry |
| 3 | Container name `/kafka-ui` conflict | Partial failure | Remove stale container with `docker rm -f` |
| 4 | Port 8080 bind failure | Partial failure | Remap host port to 8081 in compose file |
