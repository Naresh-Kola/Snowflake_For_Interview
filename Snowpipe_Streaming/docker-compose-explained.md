# Docker Compose File - Line by Line Explanation for Beginners

## What is this file?

Think of `docker-compose.yml` as a **recipe card for your kitchen**. Instead of cooking one dish at a time, this recipe tells Docker: "Here are 3 applications I need -- start them all together, connect them, and make sure they can talk to each other."

In our case, the 3 applications are:
- **broker-1** -- A Kafka message broker (like a post office branch #1)
- **broker-2** -- Another Kafka message broker (like a post office branch #2)
- **kafka-ui** -- A web dashboard to see what is happening inside Kafka (like a tracking website for your parcels)

---

## What is Kafka in Simple Terms?

Imagine a **post office system**:
- **Producers** are people who send letters (your applications that send data)
- **Consumers** are people who receive letters (your applications that read data)
- **Brokers** are the post office branches that store and deliver letters
- **Topics** are like different mailboxes -- one for bills, one for personal letters, etc.
- **Partitions** are like dividing a mailbox into slots so multiple postmen can deliver at the same time

Kafka sits in the middle and makes sure every message gets delivered reliably, even if things get busy.

---

## Line-by-Line Explanation

---

### Line 1: `version: '3.8'`

```yaml
version: '3.8'
```

**What it does:** This used to tell Docker which version of the compose file format to use.

**Real-life analogy:** Like writing "Recipe Format v3.8" at the top of a recipe card. Modern kitchens (Docker Compose V2) ignore this because they can figure out the format automatically.

**Note:** This line is now deprecated (outdated). Docker will show a warning but still work. You can safely remove it.

---

### Line 3: `services:`

```yaml
services:
```

**What it does:** This is the section where you list all the applications (containers) you want to run. Everything indented under this line is a separate service.

**Real-life analogy:** This is like the "Ingredients" heading in a recipe. Below it, you list everything you need.

---

## BROKER-1 (First Kafka Server)

---

### Line 4: `broker-1:`

```yaml
  broker-1:
```

**What it does:** This is the name of the first service. You are saying "I want an application called broker-1."

**Real-life analogy:** Naming the first post office branch -- "Branch Office #1."

---

### Line 5: `image: apache/kafka:3.7.0`

```yaml
    image: apache/kafka:3.7.0
```

**What it does:** Tells Docker which pre-built software package to download and use. `apache/kafka` is the software name, and `3.7.0` is the specific version.

**Real-life analogy:** Like saying "Use the Samsung Galaxy S24 model" instead of just "use a phone." You are picking an exact product and version so everyone gets the same thing.

---

### Line 6: `container_name: broker-1`

```yaml
    container_name: broker-1
```

**What it does:** Gives a fixed name to the running container. Without this, Docker would generate a random name like `kafka_sf-broker-1-1`.

**Real-life analogy:** Putting a name plate on the post office door: "Branch #1" instead of letting the city assign a random building number.

---

### Line 7: `hostname: broker-1`

```yaml
    hostname: broker-1
```

**What it does:** Sets the hostname inside the container's own network. Other containers can reach this container by calling it "broker-1."

**Real-life analogy:** Like registering the post office's name in the city phone directory. When Branch #2 needs to call Branch #1, it just dials "broker-1."

---

### Lines 8-9: `ports: - "9092:9092"`

```yaml
    ports:
      - "9092:9092"
```

**What it does:** Maps a port from your computer (left side) to a port inside the container (right side). This means when you access `localhost:9092` on your machine, the traffic goes to port 9092 inside the container.

**Real-life analogy:** The post office is inside a gated building. The gate has window #9092 open. When you walk up to window #9092 from the street, you can talk directly to the post office counter #9092 inside.

**Format:** `"HOST_PORT:CONTAINER_PORT"`

---

### Line 10: `environment:`

```yaml
    environment:
```

**What it does:** Starts the section for environment variables -- these are configuration settings passed into the container when it starts.

**Real-life analogy:** Like handing an instruction manual to the post office manager on their first day. "Here is how you should run this branch."

---

### Line 11: `KAFKA_NODE_ID: 1`

```yaml
      KAFKA_NODE_ID: 1
```

**What it does:** Gives this broker a unique ID number: `1`. Every Kafka broker in a cluster must have a different ID.

**Real-life analogy:** Every post office branch gets a unique license number. Branch #1 is ID=1, Branch #2 is ID=2. No two branches can share the same number.

---

### Line 12: `KAFKA_PROCESS_ROLES: broker,controller`

```yaml
      KAFKA_PROCESS_ROLES: broker,controller
```

**What it does:** Tells this Kafka node to act as both a **broker** (handles messages) AND a **controller** (manages the cluster). This is called **KRaft mode** (Kafka without Zookeeper).

**Real-life analogy:** The post office branch manager does two jobs:
- **Broker role:** Receives, stores, and delivers letters (messages)
- **Controller role:** Coordinates with other branches -- decides who handles what, keeps track of which branches are alive

In older Kafka, a separate system called "Zookeeper" did the controller job. KRaft mode removes that need.

---

### Line 13: `KAFKA_LISTENERS`

```yaml
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:9092
```

**What it does:** Defines the "doors" (network endpoints) where this broker listens for incoming connections. There are three doors:

| Listener   | Address           | Purpose                                      |
|------------|-------------------|----------------------------------------------|
| PLAINTEXT  | 0.0.0.0:19092     | For other brokers to talk to this broker      |
| CONTROLLER | 0.0.0.0:9093      | For cluster management / voting               |
| EXTERNAL   | 0.0.0.0:9092      | For your applications on the host machine     |

`0.0.0.0` means "listen on all network interfaces" (accept connections from anywhere).

**Real-life analogy:** The post office has 3 separate entrances:
- **Back door (19092):** For inter-branch postal trucks (broker-to-broker communication)
- **Staff door (9093):** For managers to hold meetings (controller communication)
- **Front door (9092):** For customers to drop off and pick up letters (your applications)

---

### Line 14: `KAFKA_ADVERTISED_LISTENERS`

```yaml
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker-1:19092,EXTERNAL://localhost:9092
```

**What it does:** Tells clients "here is how to reach me." When a client first connects, Kafka says: "Next time, connect to me at this address." This is the address Kafka **advertises** (announces) to the outside world.

- `PLAINTEXT://broker-1:19092` -- Other brokers (inside Docker network) should reach me at `broker-1:19092`
- `EXTERNAL://localhost:9092` -- Applications on your computer should reach me at `localhost:9092`

**Why is this different from KAFKA_LISTENERS?**
- `LISTENERS` = "which doors I open" (the actual ports I bind to)
- `ADVERTISED_LISTENERS` = "which address I tell people to use" (the address I give out on my business card)

**Real-life analogy:** The post office is inside a mall. The actual office door is "Mall, Floor 2, Room 19092". But on the business card, it says:
- For other branches: "Come to broker-1, Room 19092" (internal address)
- For customers: "Come to localhost, Room 9092" (street address)

**Note:** The CONTROLLER listener is NOT advertised because only internal cluster nodes use it.

---

### Line 15: `KAFKA_LISTENER_SECURITY_PROTOCOL_MAP`

```yaml
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
```

**What it does:** Maps each listener name to a security protocol. Here, all three listeners use `PLAINTEXT` (no encryption).

**Format:** `LISTENER_NAME:PROTOCOL`

**Real-life analogy:** Deciding the security level for each door:
- Front door: No lock (PLAINTEXT) -- anyone can walk in
- Back door: No lock (PLAINTEXT)
- Staff door: No lock (PLAINTEXT)

In production, you would use `SSL` or `SASL_SSL` for encryption -- like adding locks and ID card scanners to the doors.

---

### Line 16: `KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT`

```yaml
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
```

**What it does:** Specifies which listener brokers use to talk to each other. Here, broker-1 and broker-2 communicate over the `PLAINTEXT` listener (port 19092).

**Real-life analogy:** "When branch offices need to transfer letters between each other, use the back door (PLAINTEXT on 19092)."

---

### Line 17: `KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER`

```yaml
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
```

**What it does:** Specifies which listener is used for controller-related communication (cluster management, leader election).

**Real-life analogy:** "When managers need to hold meetings and vote, use the staff door (CONTROLLER on 9093)."

---

### Line 18: `KAFKA_CONTROLLER_QUORUM_VOTERS`

```yaml
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9093,2@broker-2:9093
```

**What it does:** Lists all the nodes that participate in the controller quorum (voting group). Format is `NODE_ID@HOSTNAME:PORT`.

- Node 1 (broker-1) votes at broker-1:9093
- Node 2 (broker-2) votes at broker-2:9093

**Why this matters:** If broker-1 goes down, broker-2 can take over as the leader because it is also a voter. This is how Kafka achieves **fault tolerance**.

**Real-life analogy:** A company board of directors. "The voting members are: Member #1 (reachable at broker-1, room 9093) and Member #2 (reachable at broker-2, room 9093). Decisions require a majority vote."

---

### Line 19: `KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0`

```yaml
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
```

**What it does:** When a consumer group starts, Kafka normally waits a few seconds for more consumers to join before assigning partitions. Setting this to `0` means "don't wait, assign immediately."

**Real-life analogy:** At a restaurant, the host normally waits 3 minutes for your full party to arrive before seating you. Setting this to 0 means "seat me right away, even if my friends haven't arrived yet." Great for development, not ideal for production.

---

### Line 20: `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 2`

```yaml
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 2
```

**What it does:** The `__consumer_offsets` topic (an internal Kafka topic that tracks "how far has each consumer read?") will be replicated across **2 brokers**.

**Real-life analogy:** The post office keeps a logbook that records "Customer X has picked up letters up to letter #50." With replication factor 2, this logbook is photocopied and kept at both Branch #1 and Branch #2. If one branch burns down, the other still has the records.

---

### Line 21: `KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 2`

```yaml
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 2
```

**What it does:** The internal `__transaction_state` topic (tracks ongoing transactions) is also replicated across 2 brokers.

**Real-life analogy:** When someone sends a registered letter (a transaction), both branches keep a copy of the tracking receipt. If one branch loses it, the other still has proof.

---

### Line 22: `KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1`

```yaml
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
```

**What it does:** ISR = **In-Sync Replicas**. This says "at least 1 replica must be in sync for transactions to work." If both brokers were required (min ISR = 2) and one went down, transactions would fail entirely.

**Real-life analogy:** "We need at least 1 out of 2 branches to confirm they have the tracking receipt before we consider the registered letter as 'sent successfully.'"

---

### Line 23: `KAFKA_NUM_PARTITIONS: 3`

```yaml
      KAFKA_NUM_PARTITIONS: 3
```

**What it does:** When a new topic is created without specifying partition count, it gets **3 partitions** by default.

**What are partitions?** A topic is split into partitions so multiple consumers can read from it in parallel.

**Real-life analogy:** A mailbox topic "Orders" is divided into 3 slots:
- Slot 0: Orders A-I
- Slot 1: Orders J-R
- Slot 2: Orders S-Z

Three postal workers can each handle one slot simultaneously, making delivery 3x faster.

---

### Line 24: `KAFKA_LOG_DIRS: /var/lib/kafka/data`

```yaml
      KAFKA_LOG_DIRS: /var/lib/kafka/data
```

**What it does:** Tells Kafka where to store message data on disk (inside the container). All the messages (logs) go into `/var/lib/kafka/data`.

**Real-life analogy:** "Store all the letters in the warehouse at the address `/var/lib/kafka/data` inside the building."

---

### Line 25: `CLUSTER_ID: 'MkU3OEVBNTcwNTJENDM2Qk'`

```yaml
      CLUSTER_ID: 'MkU3OEVBNTcwNTJENDM2Qk'
```

**What it does:** A unique identifier for this Kafka cluster. All brokers in the same cluster **must** share the same CLUSTER_ID. This is required in KRaft mode.

**Real-life analogy:** All branches of the same post office company share the same company registration number. If a branch has a different number, it belongs to a different company and cannot join the network.

---

### Lines 26-27: `volumes`

```yaml
    volumes:
      - broker1-data:/var/lib/kafka/data
```

**What it does:** Mounts a Docker **named volume** called `broker1-data` to the path `/var/lib/kafka/data` inside the container. This means Kafka's data is saved outside the container.

**Why this matters:** Without this, if you restart the container, all messages would be **lost**. The volume keeps data persistent.

**Real-life analogy:** Instead of keeping letters inside a temporary tent (container), you store them in a permanent warehouse (volume). Even if the tent blows away and you set up a new one, the letters are still safe in the warehouse.

---

## BROKER-2 (Second Kafka Server)

### Lines 29-52

Broker-2 is almost identical to broker-1, with these key differences:

| Setting                    | broker-1              | broker-2              | Why Different                              |
|----------------------------|-----------------------|-----------------------|--------------------------------------------|
| `KAFKA_NODE_ID`            | 1                     | 2                     | Each broker needs a unique ID              |
| `EXTERNAL port`            | 9092                  | 9094                  | Two services cannot share the same port    |
| `ADVERTISED (EXTERNAL)`    | localhost:9092        | localhost:9094        | Clients need the correct port to connect   |
| `volume`                   | broker1-data          | broker2-data          | Each broker stores data separately         |

Everything else (CLUSTER_ID, quorum voters, replication factors, etc.) is the **same** because both brokers belong to the same cluster.

**Real-life analogy:** Branch #2 is a copy of Branch #1 but with its own unique ID, its own front door number, and its own warehouse. They follow the same company rules and share the same company registration number.

---

## KAFKA-UI (Web Dashboard)

---

### Lines 54-55: Service and Image

```yaml
  kafka-ui:
    image: provectuslabs/kafka-ui:latest
```

**What it does:** Creates a service called `kafka-ui` using the `provectuslabs/kafka-ui` image. The `:latest` tag means "use the newest version available."

**Real-life analogy:** Installing a **tracking dashboard** (like a FedEx tracking website) so you can visually monitor all the letters moving through your post offices.

---

### Line 56: `container_name: kafka-ui`

```yaml
    container_name: kafka-ui
```

**What it does:** Names the container `kafka-ui` for easy reference.

---

### Lines 57-58: `ports: - "8081:8080"`

```yaml
    ports:
      - "8081:8080"
```

**What it does:** Maps port 8081 on your computer to port 8080 inside the container. The kafka-ui app runs on port 8080 internally, but you access it at `http://localhost:8081` from your browser.

**Why 8081 and not 8080?** Port 8080 on this machine was already taken by Oracle TNS Listener, so we remapped it to 8081.

**Real-life analogy:** The tracking website runs on floor 8080 inside the building, but the building entrance for visitors is at gate 8081.

---

### Lines 59-61: Environment Variables

```yaml
    environment:
      KAFKA_CLUSTERS_0_NAME: local-kraft
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: broker-1:19092,broker-2:19092
```

**What it does:**
- `KAFKA_CLUSTERS_0_NAME: local-kraft` -- Names the cluster "local-kraft" in the UI dashboard.
- `KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: broker-1:19092,broker-2:19092` -- Tells the UI where to find the Kafka brokers. It connects to both brokers on their internal PLAINTEXT port (19092).

**Why `_0_` in the name?** The UI supports monitoring multiple clusters. `0` is the index for the first cluster. If you had a second cluster, you would use `KAFKA_CLUSTERS_1_NAME`, etc.

**Real-life analogy:** Configuring the tracking website: "Monitor the company called 'local-kraft', and connect to Branch #1 and Branch #2 to get status updates."

---

### Lines 62-64: `depends_on`

```yaml
    depends_on:
      - broker-1
      - broker-2
```

**What it does:** Tells Docker to start `broker-1` and `broker-2` **before** starting `kafka-ui`. The UI needs the brokers to be running so it can connect to them.

**Important caveat:** `depends_on` only waits for the containers to **start**, not for Kafka to be fully **ready**. The UI might briefly show errors until the brokers finish their initialization.

**Real-life analogy:** "Don't open the tracking website until both post office branches have at least unlocked their doors. (They might still be setting up inside, but at least the buildings are open.)"

---

## VOLUMES SECTION

### Lines 66-68

```yaml
volumes:
  broker1-data:
  broker2-data:
```

**What it does:** Declares two named volumes at the top level. Docker creates and manages these storage locations. They are referenced by the brokers in their `volumes:` sections above.

**Real-life analogy:** Registering two warehouses with the city:
- `broker1-data` -- Warehouse for Branch #1's letters
- `broker2-data` -- Warehouse for Branch #2's letters

These warehouses exist independently of the branches. Even if you demolish and rebuild a branch (`docker compose down` and `up`), the warehouse and its contents survive. Only `docker compose down -v` (the `-v` flag) would delete the warehouses too.

---

## How It All Fits Together

```
YOUR COMPUTER (Host Machine)
|
|-- localhost:9092 -----> broker-1 (Kafka node 1)
|                              |
|                              |--- internal port 19092 (broker-to-broker)
|                              |--- internal port 9093  (controller voting)
|                              |--- volume: broker1-data
|
|-- localhost:9094 -----> broker-2 (Kafka node 2)
|                              |
|                              |--- internal port 19092 (broker-to-broker)
|                              |--- internal port 9093  (controller voting)
|                              |--- volume: broker2-data
|
|-- localhost:8081 -----> kafka-ui (Web Dashboard)
|                              |
|                              |--- connects to broker-1:19092
|                              |--- connects to broker-2:19092
|
|  [ Docker Internal Network: kafka_sf_default ]
|  (All 3 containers can talk to each other by name)
```

## Quick Reference: Common Commands

| Command | What it does |
|---------|-------------|
| `docker compose up -d` | Start all services in background |
| `docker compose down` | Stop and remove all containers (keeps data) |
| `docker compose down -v` | Stop, remove containers AND delete stored data |
| `docker compose ps` | Show status of all services |
| `docker compose logs broker-1` | View logs of broker-1 |
| `docker compose restart kafka-ui` | Restart only the kafka-ui service |
