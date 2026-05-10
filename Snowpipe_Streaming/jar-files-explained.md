# JAR Files Explained -- Why We Need Them and How to Download

---

## What is a JAR File?

JAR stands for **Java ARchive**. It is a packaged file (like a .zip) that contains compiled Java code (.class files), libraries, and metadata that a Java application needs to run.

**Real-life analogy:** A JAR file is like a **toolbox**. Instead of carrying individual tools (screwdriver, wrench, hammer) separately, you pack them all into one toolbox and carry it wherever you go. A JAR file packs all the Java code a program needs into one portable file.

### Key facts about JARs

| Aspect | Detail |
|--------|--------|
| File extension | `.jar` |
| Internally | A ZIP archive containing `.class` files, config files, and a `MANIFEST.MF` |
| Who runs it | The Java Virtual Machine (JVM) -- you do NOT need Java on your machine because it runs inside Docker |
| Where we get them | Maven Central (the standard public repository for Java libraries) |

---

## Why Does This Project Need JAR Files?

Kafka Connect is a Java application. It loads **plugins** (connectors) as JAR files. Our project uses the **Snowflake Kafka Connector** plugin to move data from Kafka topics into Snowflake tables.

```
Kafka Connect (Java runtime inside Docker)
    |
    +-- Loads plugins from /usr/share/confluent-hub-components/
         |
         +-- snowflake-kafka-connector/
              |
              +-- snowflake-kafka-connector-2.4.1.jar  (the connector itself)
              +-- bc-fips-1.0.2.4.jar                  (encryption library)
              +-- bcpkix-fips-1.0.7.jar                (encryption support)
```

Without these JAR files, Kafka Connect has no idea how to talk to Snowflake.

---

## The 3 JAR Files We Need

### 1. snowflake-kafka-connector-2.4.1.jar (~154 MB)

**What it is:** The Snowflake Kafka Connector plugin -- the main connector code.

**What it does:**
- Reads messages from Kafka topics
- Converts JSON messages into Snowflake-compatible rows
- Authenticates to Snowflake using RSA key pair
- Writes rows into Snowflake tables via the Snowpipe Streaming API
- Tracks offsets (which messages have been processed)
- Handles buffering, error recovery, and retries

**Why it is large (~154 MB):** It bundles many dependencies inside (Snowflake JDBC driver, HTTP client, JSON parser, logging, etc.) so it works as a standalone plugin without needing extra libraries.

### 2. bc-fips-1.0.2.4.jar (~3.8 MB)

**What it is:** Bouncy Castle FIPS (Federal Information Processing Standards) cryptography library.

**What it does:**
- Provides RSA encryption/decryption algorithms
- Reads the PKCS#8 private key file (snowflake_kafka_key.p8)
- Signs authentication tokens when the connector logs into Snowflake
- Handles TLS/SSL cryptographic operations

**Why we need it:** The Snowflake connector uses RSA key pair authentication (not username/password). Bouncy Castle is the Java library that handles reading PEM-formatted RSA keys and performing the cryptographic signing. Without it, the connector cannot authenticate.

**What is FIPS?** FIPS is a US government security standard. The FIPS version of Bouncy Castle is certified for use in government and regulated environments. Snowflake requires this specific version.

### 3. bcpkix-fips-1.0.7.jar (~877 KB)

**What it is:** Bouncy Castle PKIX (Public Key Infrastructure) support library.

**What it does:**
- Parses X.509 certificates and PKCS#8 key formats
- Converts PEM-encoded keys into Java key objects
- Supports certificate chain validation

**Why we need it:** This is a companion to bc-fips. It handles the specific key format parsing -- reading the `-----BEGIN PRIVATE KEY-----` PEM file and converting it into something Java can use for RSA signing. Without it, the connector cannot read your private key file.

### How they work together

```
snowflake_kafka_key.p8 (your private key file)
        |
        v
  bcpkix-fips-1.0.7.jar  (reads and parses the PEM/PKCS#8 format)
        |
        v
  bc-fips-1.0.2.4.jar  (performs RSA signing for authentication)
        |
        v
  snowflake-kafka-connector-2.4.1.jar  (uses the signed token to connect to Snowflake)
        |
        v
  Snowflake  (verifies the signature against the public key)
```

---

## How to Download the JAR Files (CLI Commands)

### Option 1: PowerShell (Windows)

```powershell
# Create the plugin directory
mkdir connect-plugins\snowflake-kafka-connector

# Download the Snowflake Kafka Connector (main JAR)
Invoke-WebRequest `
  -Uri "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar" `
  -OutFile "connect-plugins\snowflake-kafka-connector\snowflake-kafka-connector-2.4.1.jar"

# Download Bouncy Castle FIPS (cryptography library)
Invoke-WebRequest `
  -Uri "https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.4/bc-fips-1.0.2.4.jar" `
  -OutFile "connect-plugins\snowflake-kafka-connector\bc-fips-1.0.2.4.jar"

# Download Bouncy Castle PKIX (key format parser)
Invoke-WebRequest `
  -Uri "https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar" `
  -OutFile "connect-plugins\snowflake-kafka-connector\bcpkix-fips-1.0.7.jar"
```

### Option 2: curl (Windows/Linux/Mac)

```bash
# Create the plugin directory
mkdir -p connect-plugins/snowflake-kafka-connector

# Download the Snowflake Kafka Connector
curl -L -o connect-plugins/snowflake-kafka-connector/snowflake-kafka-connector-2.4.1.jar \
  "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar"

# Download Bouncy Castle FIPS
curl -L -o connect-plugins/snowflake-kafka-connector/bc-fips-1.0.2.4.jar \
  "https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.4/bc-fips-1.0.2.4.jar"

# Download Bouncy Castle PKIX
curl -L -o connect-plugins/snowflake-kafka-connector/bcpkix-fips-1.0.7.jar \
  "https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar"
```

### Option 3: Python (if curl/Invoke-WebRequest have issues)

```python
"""
Download Snowflake Kafka Connector JARs from Maven Central.
Usage: python download_jars.py
"""

import os
import urllib.request

DEST_DIR = os.path.join("connect-plugins", "snowflake-kafka-connector")

JARS = [
    {
        "name": "snowflake-kafka-connector-2.4.1.jar",
        "url": "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar",
        "expected_size_mb": 154,
    },
    {
        "name": "bc-fips-1.0.2.4.jar",
        "url": "https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.4/bc-fips-1.0.2.4.jar",
        "expected_size_mb": 3.8,
    },
    {
        "name": "bcpkix-fips-1.0.7.jar",
        "url": "https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar",
        "expected_size_mb": 0.9,
    },
]


def download_jars():
    os.makedirs(DEST_DIR, exist_ok=True)

    for jar in JARS:
        dest_path = os.path.join(DEST_DIR, jar["name"])
        print(f"Downloading {jar['name']} (~{jar['expected_size_mb']} MB)...")
        urllib.request.urlretrieve(jar["url"], dest_path)

        actual_size_mb = os.path.getsize(dest_path) / (1024 * 1024)
        print(f"  [SAVED] {dest_path}  ({actual_size_mb:.1f} MB)")

        # Warn if file size looks wrong (truncated download)
        if actual_size_mb < jar["expected_size_mb"] * 0.8:
            print(f"  [WARNING] Expected ~{jar['expected_size_mb']} MB but got {actual_size_mb:.1f} MB.")
            print(f"            File may be truncated. Delete and re-download.")

    print("\nDone. All JARs saved to:", DEST_DIR)


if __name__ == "__main__":
    download_jars()
```

Run it:
```powershell
python download_jars.py
```

---

## Verify the Downloads

After downloading, check the file sizes:

```powershell
Get-ChildItem connect-plugins\snowflake-kafka-connector | Format-Table Name, @{N='Size (MB)';E={[math]::Round($_.Length / 1MB, 1)}}
```

Expected output:
```
Name                                    Size (MB)
----                                    ---------
bc-fips-1.0.2.4.jar                          3.6
bcpkix-fips-1.0.7.jar                        0.8
snowflake-kafka-connector-2.4.1.jar         147.7
```

**Critical check:** The main connector JAR must be ~147-155 MB. If it is significantly smaller (e.g., 80 MB or 114 MB), the download was truncated. Delete it and re-download.

A truncated JAR will cause Kafka Connect to silently fail to register the Snowflake connector -- you will only see the built-in MirrorMaker connectors when you check `http://localhost:8083/connector-plugins`, and the Snowflake connector will be missing.

---

## Where Do the JARs Go?

The JARs live on your local machine in `connect-plugins/snowflake-kafka-connector/`. Docker mounts this directory into the Kafka Connect container:

```yaml
# From docker-compose.yml
volumes:
  - ./connect-plugins/snowflake-kafka-connector:/usr/share/confluent-hub-components/snowflake-kafka-connector
```

```
Your machine (host)                          Docker container (kafka-connect)
connect-plugins/                             /usr/share/confluent-hub-components/
  snowflake-kafka-connector/                   snowflake-kafka-connector/
    snowflake-kafka-connector-2.4.1.jar  -->     snowflake-kafka-connector-2.4.1.jar
    bc-fips-1.0.2.4.jar                  -->     bc-fips-1.0.2.4.jar
    bcpkix-fips-1.0.7.jar               -->     bcpkix-fips-1.0.7.jar
```

When Kafka Connect starts, it scans the plugin path, finds the JARs, loads them, and the Snowflake connector becomes available.

---

## Do I Need Java Installed?

**No.** You do NOT need Java on your local machine. The JARs run inside the Docker container (`confluentinc/cp-kafka-connect-base:7.6.0`), which has Java pre-installed. You only download the JARs -- Docker handles running them.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Snowflake connector not in plugin list | JAR not downloaded or wrong directory | Verify files exist in `connect-plugins/snowflake-kafka-connector/` |
| Connector JAR too small | Truncated download (network issue, OneDrive sync) | Delete and re-download; use `C:\temp\` as intermediate to avoid OneDrive sync |
| Cryptography error on startup | Missing BouncyCastle JARs | Ensure both `bc-fips` and `bcpkix-fips` JARs are present |
| "No suitable driver" error | Wrong connector version | Ensure you have version 2.4.1 (matches the config files) |
| Plugin not found after restart | Docker volume mount path wrong | Check `docker-compose.yml` volume mount matches your local directory |
